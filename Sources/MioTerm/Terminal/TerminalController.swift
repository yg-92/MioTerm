import AppKit
import MioTermCore
import SwiftTerm

/// 一个终端会话的控制器：持有 SwiftTerm 视图、子进程生命周期与 askpass 清理。
/// 视图由标签容器负责挂载，控制器只管进程与状态。
@MainActor
final class TerminalController: NSObject, LocalProcessTerminalViewDelegate {
    enum State: Equatable {
        case idle
        case starting
        case running
        case exited(Int32?)
        case failed(String)

        var isAlive: Bool { self == .starting || self == .running }

        var label: String {
            switch self {
            case .idle: return "未启动"
            case .starting: return "连接中"
            case .running: return "已连接"
            case .exited(let code):
                guard let code else { return "已断开" }
                return code == 0 ? "已结束" : "已退出 (\(code))"
            case .failed: return "启动失败"
            }
        }
    }

    let sessionID = UUID()
    /// nil 表示本机 shell 标签，不关联任何主机配置。
    let host: HostProfile?
    let terminalView: TrackingTerminalView

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    private(set) var workingDirectory: String?
    private var askpassFile: URL?
    private var remoteTitle: String?

    var onStateChange: ((State) -> Void)?
    var onTitleChange: ((String) -> Void)?

    /// 文件面板要的事实：当前目录 + “文件系统又变了”的计数。
    private(set) var context = TerminalContext()
    var onContextChange: ((TerminalContext) -> Void)?

    private var commandTracker = ShellCommandTracker()
    private let outputClock = OutputClock()
    private var settleTimer: Timer?
    private var predictedDirectory: String?
    private var pendingFileChange = false
    private var commandSubmittedAt = Date.distantPast
    private var lastDirectoryReportedAt = Date.distantPast

    /// 标签标题：主机名优先，本地 shell 用当前目录名，OSC 标题作为补充。
    var title: String {
        if let host { return host.displayName }
        if let remoteTitle, !remoteTitle.isEmpty { return remoteTitle }
        guard let directory = workingDirectory else { return "本地终端" }
        let last = (directory as NSString).lastPathComponent
        return last.isEmpty ? directory : last
    }

    var tooltip: String {
        let subject = host.map { "\($0.protocolKind.displayName) · \($0.subtitle)" } ?? "本地终端"
        return "\(subject) · \(state.label)"
    }

    init(host: HostProfile?, settings: AppSettings) {
        self.host = host
        var options = TerminalOptions()
        options.scrollback = settings.scrollbackLines
        if let terminalType = host?.terminalType, !terminalType.isEmpty {
            options.termName = terminalType
        } else {
            options.termName = "xterm-256color"
        }
        terminalView = TrackingTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            font: TerminalController.font(for: settings),
            options: options
        )
        super.init()
        terminalView.processDelegate = self
        terminalView.autoresizingMask = [.width, .height]
        terminalView.onUserInput = { [weak self] bytes in self?.observeInput(bytes) }
        apply(settings)
    }

    func apply(_ settings: AppSettings) {
        terminalView.font = TerminalController.font(for: settings)
        terminalView.bellStyle = settings.playBellSound ? .sound : .none
    }

    static func font(for settings: AppSettings) -> NSFont {
        NSFont(name: settings.terminalFontName, size: CGFloat(settings.terminalFontSize))
            ?? NSFont.monospacedSystemFont(ofSize: CGFloat(settings.terminalFontSize), weight: .regular)
    }

    /// 启动 SSH 会话。launch 由 SSHLaunchPlanner 生成，机密落在一次性文件里。
    func start(_ launch: ProcessLaunch) {
        guard !state.isAlive else { return }
        askpassFile = launch.askpassFile
        state = .starting
        FileLogger.shared.info("启动会话 \(title)：\(launch.redactedDescription)")
        installOutputWatch()
        terminalView.startProcess(
            executable: launch.executable,
            args: launch.arguments,
            environment: launch.environment
        )
    }

    func startLocalShell() {
        guard !state.isAlive else { return }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var entries = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        entries.append("TERM=xterm-256color")
        entries.append("COLORTERM=truecolor")
        state = .running
        installOutputWatch()
        terminalView.startProcess(executable: shell, args: ["-l"], environment: entries)
    }

    func stop() {
        settleTimer?.invalidate()
        settleTimer = nil
        if state.isAlive, terminalView.process?.running == true {
            terminalView.terminate()
        }
        destroyAskpass()
    }

    func focus() {
        terminalView.window?.makeFirstResponder(terminalView)
    }

    /// 收到第一帧远端输出即认为握手完成；回调在解析线程上执行，
    /// 这里只投递一次到主线程。
    private func installOutputWatch() {
        let done = MutableFlag()
        terminalView.setProcessOutputHandler { [weak self] in
            // 解析线程：只盖时间戳，判断都留给主线程的定时器。
            self?.outputClock.stamp()
            guard !done.testAndSet() else { return }
            Task { @MainActor in
                guard let self, self.state == .starting else { return }
                self.state = .running
            }
        }
    }

    // MARK: - 命令还原

    /// 用户敲了回车才谈“命令”：逐字节攒行由 ShellCommandTracker 负责。
    private func observeInput(_ bytes: ArraySlice<UInt8>) {
        guard let line = commandTracker.consume(bytes) else { return }
        let effect = ShellCommandClassifier.classify(line, currentDirectory: context.directory)
        if let predicted = effect.predictedDirectory {
            predictedDirectory = predicted
        }
        pendingFileChange = pendingFileChange || effect.mayChangeFiles
        commandSubmittedAt = Date()
        armSettle()
    }

    /// 命令跑完、屏幕安静下来才算数：中途重读目录看到的还是旧内容。
    private func armSettle() {
        guard settleTimer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickSettle() }
        }
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    private func tickSettle() {
        let stalled = Date().timeIntervalSince(commandSubmittedAt) >= 8
        guard stalled || outputClock.idleFor >= 0.35 else { return }
        settle()
    }

    private func settle() {
        settleTimer?.invalidate()
        settleTimer = nil
        // OSC 7 在命令之后报上来过，就用它这个真实目录；否则拿 cd 的预测兜底。
        if lastDirectoryReportedAt < commandSubmittedAt, let predicted = predictedDirectory {
            context.directory = predicted
        }
        if pendingFileChange {
            context.filesystemRevision += 1
            pendingFileChange = false
        }
        predictedDirectory = nil
        onContextChange?(context)
    }

    private func destroyAskpass() {
        AskpassHelper.destroy(fileAt: askpassFile)
        askpassFile = nil
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        remoteTitle = title
        onTitleChange?(self.title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        workingDirectory = directory
        if let path = OSC7.path(from: directory), path != context.directory {
            context.directory = path
            onContextChange?(context)
        }
        lastDirectoryReportedAt = Date()
        onTitleChange?(title)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        destroyAskpass()
        state = .exited(exitCode)
        let reason: String
        switch exitCode {
        case .none: reason = "进程被信号终止"
        case .some(0): reason = "连接正常结束"
        case .some(let code): reason = "退出码 \(code)"
        }
        terminalView.feed(text: "\r\n\u{1B}[2m[\(title)] \(reason)，关闭标签或重新连接\r\n\u{1B}[0m")
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        destroyAskpass()
        state = .failed(String(describing: error))
        terminalView.feed(text: "\r\n\u{1B}[31m[启动失败] \(error)\r\n\u{1B}[0m")
    }
}

/// 一次性开关：解析线程与主线程共用，因此需要加锁。
private final class MutableFlag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()

    /// 首次调用返回 false，之后恒为 true。
    func testAndSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return true }
        value = true
        return false
    }
}

/// 最后一帧远端输出的时刻：解析线程写、主线程读，用来判断屏幕安静了没有。
private final class OutputClock: @unchecked Sendable {
    private var last = Date()
    private let lock = NSLock()

    func stamp() {
        lock.withLock { last = Date() }
    }

    var idleFor: TimeInterval {
        lock.withLock { Date().timeIntervalSince(last) }
    }
}
