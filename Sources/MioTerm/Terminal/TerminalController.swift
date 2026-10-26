import AppKit
import MioTermCore
import SwiftTerm

/// 一个终端会话的控制器：持有 SwiftTerm 视图、传输通道与 askpass 清理。
/// 视图由标签容器负责挂载，控制器只管通道与状态。
///
/// 两种通道共用这一个控制器：SSH 与本地铁壳靠 OpenSSH 子进程，Telnet/串口靠
/// TerminalStream 的字节事件流。二者的区别只在于“谁在另一端”，界面行为一致。
@MainActor
final class TerminalController: NSObject, LocalProcessTerminalViewDelegate, TerminalViewDelegate {
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
    /// 标签容器只关心视图；子进程专属的操作走 processView。
    let terminalView: TerminalView
    private var processView: LocalProcessTerminalView?
    private var keyboardMonitor: TerminalKeyboardMonitor?
    private var keypadNormalizer: TerminalKeypadNormalizer?
    private var stream: (any TerminalStream)?
    private var streamTask: Task<Void, Never>?

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    private(set) var workingDirectory: String?
    private var askpassFile: URL?
    private var remoteTitle: String?

    var onStateChange: ((State) -> Void)?
    var onTitleChange: ((String) -> Void)?
    /// 用户回车提交了一条完整命令。命令库据此记账，界面不参与逐字节输入。
    var onCommand: ((String) -> Void)?

    /// 文件面板要的事实：当前目录 + “文件系统又变了”的计数。
    /// 判定与读屏的时序全在 TerminalFollowPipeline，这里只接视图事件。
    private let follow = TerminalFollowPipeline()
    var context: TerminalContext { follow.context }
    /// 上下文变更是多播的：文件树要重读目录，工作区要更新窗口副标题，
    /// 单持有者闭包只够一个消费者用。
    private var contextObservers: [UUID: (TerminalContext) -> Void] = [:]

    /// 订阅会话上下文，返回注销用的令牌；令牌交给调用方自己保管。
    func addContextObserver(_ observer: @escaping (TerminalContext) -> Void) -> UUID {
        let token = UUID()
        contextObservers[token] = observer
        return token
    }

    func removeContextObserver(_ token: UUID?) {
        guard let token else { return }
        contextObservers[token] = nil
    }

    private func notifyContextChange() {
        // 广播没人接是「跟随不动」最常见的原因：文件面板没订阅上时，
        // 终端这边的日志看起来一切正常，所以把订阅数一起写出来。
        FileLogger.shared.info("跟随：广播给 \(contextObservers.count) 个订阅者")
        for observer in contextObservers.values { observer(context) }
    }

    private let outputClock = OutputClock()

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
        let frame = NSRect(x: 0, y: 0, width: 800, height: 480)
        let font = TerminalController.font(for: settings)
        // SSH 和本地 shell 有子进程可托管，用 LocalProcessTerminalView；
        // Telnet/串口只有一头 socket，视图不需要进程生命周期，用基类即可。
        let process: LocalProcessTerminalView?
        if host?.protocolKind.usesHostKey ?? true {
            process = LocalProcessTerminalView(frame: frame, font: font, options: options)
        } else {
            process = nil
        }
        terminalView = process ?? TerminalView(frame: frame, font: font, options: options)
        processView = process
        super.init()
        applyTheme()
        // 解析线程只负责戳时间戳，主线程据此把读屏往后推；不轮询。
        outputClock.onActivity = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.outputClock.clearActivity()
                self.follow.noteOutput()
            }
        }
        follow.setScreenLineProvider { [weak self] in self?.lastScreenLine() }
        follow.settleProbe = TerminalFollowPipeline.SettleProbe(
            idleFor: { [weak self] in self?.outputClock.idleFor ?? 0 },
            inAlternateScreen: { [weak self] in self?.isInAlternateScreen ?? false },
            hasOutputSince: { [weak self] date in self?.outputClock.hasOutput(since: date) ?? true }
        )
        follow.onCommand = { [weak self] line in self?.onCommand?(line) }
        follow.onChange = { [weak self] _ in self?.notifyContextChange() }
        if let process {
            process.processDelegate = self
            // 键盘字节由 SwiftTerm 直接写进 pty，委托看不到；在窗口事件层旁听。
            keyboardMonitor = TerminalKeyboardMonitor(view: process) { [weak self] stroke in
                self?.handleKeyStroke(stroke)
            }
            FileLogger.shared.info("键盘监听：\(title) 已挂上")
        } else {
            terminalView.terminalDelegate = self
        }
        // 小键盘在 application keypad 模式下会被编成 SS3，zsh 这类只开模式不绑序列的
        // 对端只会响铃；事件进视图前换成主键盘等价键，两种视图都适用。
        keypadNormalizer = TerminalKeypadNormalizer(view: terminalView)
        terminalView.autoresizingMask = [.width, .height]
        apply(settings)
    }

    func apply(_ settings: AppSettings) {
        terminalView.font = TerminalController.font(for: settings)
        terminalView.bellStyle = settings.playBellSound ? .sound : .none
    }

    /// 终端配色只认具体色值，切换深浅外观后要重新装一遍；`apply(settings)` 不负责外观。
    func applyTheme() {
        let dark = Theme.isDark(terminalView.effectiveAppearance)
        terminalView.nativeBackgroundColor = Theme.terminalBackground(dark: dark)
        terminalView.nativeForegroundColor = Theme.terminalForeground(dark: dark)
        terminalView.installColors(Theme.terminalPalette(dark: dark))
        terminalView.needsDisplay = true
    }

    static func font(for settings: AppSettings) -> NSFont {
        NSFont(name: settings.terminalFontName, size: CGFloat(settings.terminalFontSize))
            ?? NSFont.monospacedSystemFont(ofSize: CGFloat(settings.terminalFontSize), weight: .regular)
    }

    /// 启动 SSH 会话。launch 由 SSHLaunchPlanner 生成，机密落在一次性文件里。
    /// 状态已结束时会原地重启同一个视图，断线重连不会丢掉标签和输出历史。
    func start(_ launch: ProcessLaunch) {
        guard !state.isAlive, let process = processView else { return }
        prepareForReconnectIfNeeded()
        resetContextTracking()
        askpassFile = launch.askpassFile
        state = .starting
        FileLogger.shared.info("启动会话 \(title)：\(launch.redactedDescription)")
        installOutputWatch(process)
        process.startProcess(
            executable: launch.executable,
            args: launch.arguments,
            environment: launch.environment
        )
    }

    func startLocalShell() {
        guard !state.isAlive, let process = processView else { return }
        prepareForReconnectIfNeeded()
        resetContextTracking()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var entries = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        entries.append("TERM=xterm-256color")
        entries.append("COLORTERM=truecolor")
        state = .running
        installOutputWatch(process)
        // 从 Finder 启动时进程的工作目录是 `/`，本地终端应该落在用户家目录。
        process.startProcess(
            executable: shell,
            args: ["-l"],
            environment: entries,
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
        armInitialContextRead()
    }

    /// 启动 Telnet 或串口会话。视图、标题、状态机与 SSH 会话完全共用，
    /// 变的只是“另一端是谁”。
    func start(_ stream: any TerminalStream) {
        guard !state.isAlive, processView == nil else { return }
        prepareForReconnectIfNeeded()
        resetContextTracking()
        self.stream = stream
        state = .starting
        // 事件的投递顺序即线上顺序，所以这里不做任何重排。
        streamTask = Task { [weak self] in
            for await event in stream.events {
                guard let self, !Task.isCancelled else { return }
                self.handle(event)
            }
        }
        // 写也要串成链：无结构 Task 之间没有调度顺序，键盘字节不能乱。
        writeChain = Task { await stream.start() }
    }

    func stop() {
        follow.isLive = false
        follow.stop()
        keyboardMonitor?.stop()
        keyboardMonitor = nil
        keypadNormalizer?.stop()
        keypadNormalizer = nil
        if let process = processView, state.isAlive, process.process?.running == true {
            process.terminate()
        }
        streamTask?.cancel()
        streamTask = nil
        writeChain?.cancel()
        writeChain = nil
        if let closing = stream {
            stream = nil
            Task { await closing.close() }
        }
        destroyAskpass()
    }

    func focus() {
        terminalView.window?.makeFirstResponder(terminalView)
    }

    /// 收到第一帧远端输出即认为握手完成；回调在解析线程上执行，
    /// 这里只投递一次到主线程。
    private func installOutputWatch(_ process: LocalProcessTerminalView) {
        let done = MutableFlag()
        process.setProcessOutputHandler { [weak self] in
            // 解析线程：只盖时间戳，判断都留给主线程的定时器。
            self?.outputClock.stamp()
            guard !done.testAndSet() else { return }
            Task { @MainActor in
                guard let self, self.state == .starting else { return }
                self.state = .running
                self.armInitialContextRead()
            }
        }
    }

    // MARK: - 字节流会话

    /// SwiftTerm 不公开视图的行列数，只能靠 sizeChanged 回调缓存。
    private var terminalSize = (columns: 80, rows: 24)
    private var writeChain: Task<Void, Never>?

    private func handle(_ event: StreamEvent) {
        switch event {
        case .data(let bytes):
            outputClock.stamp()
            if state == .starting {
                state = .running
                armInitialContextRead()
            }
            terminalView.feed(byteArray: ArraySlice(bytes))
        case .connected:
            state = .running
            armInitialContextRead()
            // 连上先报一次尺寸：设备在同意 NAWS 之前不知道窗口多大，会按 80 列排版。
            enqueueResize()
        case .notice(let text):
            terminalView.feed(text: "\r\n\u{1B}[2m\(text)\u{1B}[0m\r\n")
        case .closed(let reason):
            detachStream()
            state = .exited(nil)
            follow.isLive = false
            follow.stop()
            terminalView.feed(text: "\r\n\u{1B}[2m[\(title)] \(reason ?? "连接已断开")，关闭标签或重新连接\r\n\u{1B}[0m")
        case .failed(let reason):
            detachStream()
            state = .failed(reason)
            follow.isLive = false
            follow.stop()
            terminalView.feed(text: "\r\n\u{1B}[31m[\(title)] \(reason)\r\n\u{1B}[0m")
        }
    }

    private func detachStream() {
        stream = nil
        streamTask = nil
        writeChain = nil
    }

    /// 把视图当前的行列数告诉远端；串口实现会自行忽略（没有终端尺寸的概念）。
    private func enqueueResize() {
        guard let stream else { return }
        let size = terminalSize
        let previous = writeChain
        writeChain = Task {
            await previous?.value
            await stream.resize(columns: size.columns, rows: size.rows)
        }
    }

    private func enqueueWrite(_ data: Data) {
        guard let stream else { return }
        let previous = writeChain
        writeChain = Task {
            await previous?.value
            await stream.write(data)
        }
    }

    /// 串口控制台的 BREAK 信号。排在写链上，免得中断插到键入字节中间。
    func sendBreak() {
        guard let stream else { return }
        let previous = writeChain
        writeChain = Task {
            await previous?.value
            await stream.sendBreak()
        }
    }

    /// 菜单项是否该启用：只有串口会话有 BREAK 可用。
    var supportsBreak: Bool { host?.protocolKind == .serial && stream != nil }

    /// 命令库的记账作用域：主机 ID，本地终端标签单独一档。
    var commandScope: String { CommandScope.key(host: host) }

    /// 命令库“点击填入”：文本进终端但不回车，是否执行由用户决定。
    /// 这是程序写入，不走键盘监听，所以要自己把这段字节喂给攒行器，
    /// 否则用户接着按回车时，统计里只会剩一个回车。
    func injectInput(_ text: String) {
        guard !text.isEmpty, state.isAlive else { return }
        FileLogger.shared.info("注入命令：\(text)")
        // 先拿焦点再写：写入后立刻按回车时，按键不能再落到命令列表上。
        focus()
        let bytes = ArraySlice(Array(text.utf8))
        if processView != nil { observeInput(bytes) }
        terminalView.send(data: bytes)
        // 这次点击的响应链还没走完，表格可能随后把焦点要回去；下一拍再确认一次。
        DispatchQueue.main.async { [weak self] in self?.focus() }
    }

    // MARK: - 命令还原

    /// 用户敲了回车才谈“命令”：逐字节攒行由 ShellCommandTracker 负责。
    private func observeInput(_ bytes: ArraySlice<UInt8>) {
        follow.userInput(bytes, inAlternateScreen: isInAlternateScreen)
    }

    /// SSH/本地 shell 的按键走这条；Telnet/串口仍由视图委托直接送字节。
    private func handleKeyStroke(_ stroke: TerminalKeyStroke) {
        guard state.isAlive else { return }
        switch TerminalKeyTranslator.translate(stroke) {
        case .bytes(let bytes):
            observeInput(bytes[...])
        case .invalidatesLine:
            follow.invalidateLine()
        case .ignored:
            break
        }
    }

    /// SwiftTerm 不把 Terminal 实例暴露给宿主，但输入状态快照是公开且不用拷行数据的。
    private var isInAlternateScreen: Bool {
        terminalView.terminalInputStateSnapshot()?.isAlternateBuffer ?? false
    }

    /// 连上之后先读一次屏幕，见 TerminalFollowPipeline.sessionDidOpen()。
    private func armInitialContextRead() {
        follow.sessionDidOpen()
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
        _ = follow.reportOSC7(directory)
        onTitleChange?(title)
    }

    /// 屏幕最下面一行非空文本：命令跑完、输出安静下来之后，它就是当前提示符。
    private func lastScreenLine() -> String? {
        guard let snapshot = terminalView.terminalContentSnapshot(region: .history(maximumScrollbackRows: -1)) else {
            return nil
        }
        for row in snapshot.rows.reversed() {
            let text = row.text.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        return nil
    }

    /// 重开一条会话可能就换了一台机器，基线主机名与嵌套状态都要重来。
    private func resetContextTracking() {
        follow.reset()
        follow.isLive = true
    }

    /// 断线时远端来不及收尾：屏幕可能还停在 vim 之类的备用缓冲，鼠标上报等模式
    /// 也还开着。重连前退回主缓冲并软复位，否则新提示符会画在上一轮的残留上。
    /// 主缓冲里的历史滚屏保持不动。
    private func prepareForReconnectIfNeeded() {
        guard state != .idle, !state.isAlive else { return }
        remoteTitle = nil
        workingDirectory = nil
        terminalView.feed(text: "\u{1B}[?1049l\u{1B}[!p")
        terminalView.feed(text: "\r\n\u{1B}[2m[\(title)] 重新连接…\u{1B}[0m\r\n")
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        destroyAskpass()
        state = .exited(exitCode)
        follow.isLive = false
        follow.stop()
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
        follow.isLive = false
        follow.stop()
        terminalView.feed(text: "\r\n\u{1B}[31m[启动失败] \(error)\r\n\u{1B}[0m")
    }

    // MARK: - TerminalViewDelegate

    // 只有 Telnet/串口会话把控制器当成视图的委托：那种会话没有子进程，
    // 键入与尺寸变化必须自己送达通道。

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        observeInput(data)
        enqueueWrite(Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        terminalSize = (newCols, newRows)
        enqueueResize()
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        remoteTitle = title
        onTitleChange?(self.title)
    }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    // Kitty 剪贴板（OSC 5522）与 programStatusChanged：两个委托协议都给了默认实现，
    // 同时遵守时会出现两个同样匹配的候选。这里显式写死“不接管”，
    // 让见证唯一，顺带说明我们没有实现这些扩展。
    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities { [] }

    func kittyClipboardAvailableMimeTypes(source: TerminalView, location: KittyClipboardLocation) -> [String]? { nil }

    func kittyClipboardRead(source: TerminalView, location: KittyClipboardLocation, mimeType: String) -> KittyClipboardReadResult? { nil }

    func kittyClipboardWrite(source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent) -> KittyClipboardWriteResult { .unsupported }

    func kittyClipboardRequestPermission(source: TerminalView, request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult { .deny }

    func programStatusChanged(source: TerminalView, records: [TerminalProgramStatus]) {}
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
/// 每批输出还会触发一次 `onActivity`，把待办的读屏顺延到输出停下之后。
private final class OutputClock: @unchecked Sendable {
    private var last = Date()
    private var activityPending = false
    private let lock = NSLock()
    /// 在开始收字节之前设置，之后只读。
    var onActivity: (() -> Void)?

    func stamp() {
        lock.lock()
        last = Date()
        let shouldNotify = !activityPending
        if shouldNotify { activityPending = true }
        lock.unlock()
        if shouldNotify { onActivity?() }
    }

    /// 主线程消费掉这个批次的通知，下一批输出可以再叫一次。
    func clearActivity() {
        lock.withLock { activityPending = false }
    }

    var idleFor: TimeInterval {
        lock.withLock { Date().timeIntervalSince(last) }
    }

    func hasOutput(since date: Date) -> Bool {
        lock.withLock { last >= date }
    }
}
