import Foundation

/// 终端目录跟随的整条通路：按键字节 + 屏幕文本进，「目录变了」的事实出。
///
/// 时序规则全部收在这里：回车只是「命令执行了」，要等屏幕安静下来再读提示符；
/// 备用屏幕里的回车不算命令；刚连上时屏幕可能还没吐出提示符，得重试几次。
/// 这几步以前散在控制器里，出过一次「Tab 补全之后跟随整个停摆」的事故却没法测。
///
/// 等待是事件驱动的：每次收到远端输出就把一次性的读屏任务往后推，
/// 输出停下 `quietWindow` 后才真正读屏，不靠固定节拍轮询。
/// 也不再用 `Timer`：Timer 挂在主 RunLoop 上，主线程一旦进模态或事件跟踪
/// 就收不到回调，跟随会静默停摆——这类故障在日志里只表现为「没反应」。
@MainActor
public final class TerminalFollowPipeline {
    /// 还原得出来的完整命令行，交给命令库记账。
    public var onCommand: ((String) -> Void)?
    /// 上下文变了，广播给文件面板与标题栏。
    public var onChange: ((TerminalContext) -> Void)?

    public var context: TerminalContext { tracker.context }
    /// 是否正在等屏幕安静下来：测试与界面都靠它判断「这一次还没读完」。
    public var isWaitingForScreen: Bool { waiting }
    /// 会话是否活着：退出之后不该再把屏幕上的残羹当提示符。
    public var isLive: Bool = false

    /// 输出停下来多久之后读屏：太短会读到命令还没打印完的半截屏幕。
    private let quietWindow: TimeInterval = 0.2
    /// 提交命令后迟迟没有输出时的兜底读屏时间。
    private let outputFallback: TimeInterval = 8

    private var tracker = TerminalContextTracker()
    private var commandTracker = ShellCommandTracker()
    private var settleTask: Task<Void, Never>?
    private var waiting = false
    /// 会话开头重试几次读屏，次数封顶，免得连不上的会话一直空转。
    private var warmupTries = 0
    /// 同一个命令读到的还是旧画面时的重读次数，封顶避免空转。
    private var emptyReads = 0
    /// 用户提交的命令必然有回显或输出；见到输出之前读屏读到的是旧提示符。
    private var expectsOutput = false
    /// 最近一次粘贴的单行文本：SSH 高延迟下用户粘贴完立刻按回车时，远端回显可能还没到屏幕，用它兜底。
    private var pendingPastedLine: String?
    private var screenLine: () -> String? = { nil }

    public init() {}

    /// 屏幕最下面一行非空文本由宿主提供：读屏要碰视图，判定不要。
    public func setScreenLineProvider(_ provider: @escaping () -> String?) {
        screenLine = provider
    }

    /// 重开一条会话可能就换了一台机器，基线主机名与嵌套状态都要重来。
    public func reset() {
        stop()
        tracker = TerminalContextTracker()
        commandTracker = ShellCommandTracker()
        warmupTries = 0
        emptyReads = 0
        pendingPastedLine = nil
    }

    public func stop() {
        settleTask?.cancel()
        settleTask = nil
        waiting = false
    }

    /// 连上之后不必等用户敲命令也读一次：远端 shell 打出的第一行提示符
    /// 就是「这台机器上我在哪个目录」，跟随开关打开时文件面板靠它落地。
    public func sessionDidOpen() {
        submit(command: nil, expectsOutput: false)
    }

    /// 逐字节攒行在 ShellCommandTracker 里，这里只管「这一下算不算执行了命令」。
    public func userInput(_ bytes: ArraySlice<UInt8>, inAlternateScreen: Bool) {
        if bytes.contains(where: { $0 == 0x03 || $0 == 0x15 || $0 == 0x7F || $0 == 0x08 }) {
            pendingPastedLine = nil
        }
        // consume 只在回车那一刻返回值，拿不到就说明这批字节里没有执行。
        guard let submission = commandTracker.consume(bytes) else { return }
        let pastedFallback = pendingPastedLine
        pendingPastedLine = nil
        // 回车前的屏幕底行有两个用处：还原 Tab 补全，以及认出「这行是敲给口令提示的」。
        let screenBeforeEnter = screenLine()
        let isSecret = SecretPrompt.isAskingForSecret(screenBeforeEnter)
        log("收到回车（命令 \(Self.describe(submission.command, missing: "还原不出"))，备用屏 \(inAlternateScreen)）")
        guard !inAlternateScreen else {
            // vim 里敲的是半句话，不能当命令；但退出编辑器之后屏幕上就是新提示符，
            // 所以这次回车仍然要安排一次读屏，否则跟随会停在打开 vim 之前。
            armSettle()
            return
        }
        if submission.endedShell {
            log("收到 Ctrl+D，结束当前 shell")
            submit(command: nil, expectsOutput: true, shellExited: true)
            return
        }
        if isSecret {
            // 口令既不进命令库（那里的条目能点回终端），也不参与 cd 预测。
            log("屏幕在要口令，这一行不进命令库")
            submit(command: nil, expectsOutput: true)
            return
        }
        // Tab 补全后本端记的行是残的，但屏幕回显里留着补全后的完整命令行。
        // 尤其当提示符只报末级目录（PS1 的 `\W`）时，没有这一步就没有 cd 预测可用。
        var command = submission.command
        if command == nil, let partial = submission.partialLine,
           let recovered = Self.recoverCompletedCommand(from: screenBeforeEnter, typed: partial) {
            log("从屏幕回显还原补全后的命令（\(Self.describe(recovered, missing: "—"))）")
            command = recovered
        }
        // 粘贴和输入法让本端连半截都不剩，但 shell 的回显还挂在提示符后面。
        // 实机事故：`cd /home/jenkins_home/` 这类粘贴进来的路径没有被攒行器看到，
        // 只剩末级名的提示符又定位不了，树就一直停在旧目录。
        if command == nil, let recovered = TerminalPrompt.commandAfterPrompt(in: screenBeforeEnter) {
            log("从屏幕回显还原命令行（\(Self.describe(recovered, missing: "—"))）")
            command = recovered
        }
        if command == nil, let pastedFallback {
            log("从粘贴缓冲还原命令行（\(Self.describe(pastedFallback, missing: "—"))）")
            command = pastedFallback
        }
        if let line = command {
            onCommand?(line)
        }
        // 文本还原不出来（Tab 补全、粘贴、空回车）也要记下这一刻：跟随正是挂在回车上的。
        // 其中“文本不可信”的那类还要按改了文件处理，否则粘贴的 rm/vim 不会让面板重读。
        submit(
            command: command,
            expectsOutput: true,
            assumeFileChanges: submission.isTextUnreliable && command == nil
        )
    }

    /// 用户通过快捷键、右键或菜单粘贴了一段文本。
    /// 若粘贴内容自带换行，终端不会再收到回车键事件，需要当场按提交处理；
    /// 若是单行文本，先记下兜底，防止用户秒按回车时远端回显还没到屏幕。
    public func userPaste(_ text: String, inAlternateScreen: Bool) {
        invalidateLine()
        guard !text.isEmpty else { return }
        let hasNewline = text.contains("\r") || text.contains("\n")
        guard hasNewline else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            pendingPastedLine = trimmed.isEmpty ? nil : trimmed
            return
        }
        guard !inAlternateScreen else {
            armSettle()
            return
        }
        let isSecret = SecretPrompt.isAskingForSecret(screenLine())
        guard !isSecret else {
            submit(command: nil, expectsOutput: true)
            return
        }
        let segments = text.components(separatedBy: CharacterSet.newlines)
        let trailingEndsWithNewline = text.last == "\r" || text.last == "\n"
        let executedSlices = trailingEndsWithNewline ? segments[...] : segments.dropLast()
        let executedCommands = executedSlices
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !trailingEndsWithNewline, let tail = segments.last?.trimmingCharacters(in: .whitespacesAndNewlines), !tail.isEmpty {
            pendingPastedLine = tail
        }
        guard !executedCommands.isEmpty else {
            submit(command: nil, expectsOutput: true, assumeFileChanges: true)
            return
        }
        for line in executedCommands {
            onCommand?(line)
            submit(command: line, expectsOutput: true, assumeFileChanges: true)
        }
    }

    /// 日志一律不写命令原文：敲给认证提示的口令会连着命令行一起被还原出来，
    /// 而日志是要拿出去排障的。长度已经够判断攒行器还原到了什么。
    private static func describe(_ command: String?, missing: String) -> String {
        guard let command, !command.isEmpty else { return missing }
        return "\(command.count) 字符"
    }

    /// 读屏日志同理：串口控制台有的会把口令回显在提示语后面，这一行原样写进日志就等于泄漏。
    private static func screenForLog(_ line: String?) -> String {
        guard let line else { return "（空）" }
        return SecretPrompt.isAskingForSecret(line) ? "（口令提示，不记原文）" : "「\(line)」"
    }

    /// 回车前的屏幕底行是「提示符 + 命令行」。用用户已键入的前缀在回显里找最后
    /// 一次出现的位置，把它之后的部分当作命令：补全插入的那一段也就一起拿回来了。
    static func recoverCompletedCommand(from screen: String?, typed: String) -> String? {
        guard let screen, !typed.isEmpty else { return nil }
        let subject = TerminalPrompt.commandAfterPrompt(in: screen) ?? screen
        guard let range = subject.range(of: typed, options: .backwards) else { return nil }
        let tail = subject[range.lowerBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? nil : tail
    }

    /// 命令行被粘贴、历史或输入法改了，本端记的文本作废；回车仍会安排读屏。
    public func invalidateLine() {
        commandTracker.markLineUnreliable()
        pendingPastedLine = nil
    }

    /// OSC 7 是主动上报，不用等屏幕安静：立刻更新并广播。
    @discardableResult
    public func reportOSC7(_ payload: String?) -> Bool {
        let changed = tracker.reportOSC7(payload)
        if changed {
            log("OSC 7 上报 \(context.directory ?? "—")")
            onChange?(context)
        }
        return changed
    }

    /// 检查一次要不要读屏。返回 false 表示还没到时候，过一会儿再看。
    @discardableResult
    public func settleNow(
        idleFor: TimeInterval,
        inAlternateScreen: Bool,
        outputSinceSubmit: Bool = true
    ) -> Bool {
        let outcome = evaluate(
            idleFor: idleFor,
            inAlternateScreen: inAlternateScreen,
            outputSinceSubmit: outputSinceSubmit
        )
        if outcome != .waiting { stop() }
        return outcome != .waiting
    }

    /// 宿主每收到一批远端输出就调一次：把待办的读屏往后推，输出停下才读。
    /// 没在等读屏时什么也不做，正常刷屏不会产生额外工作。
    public func noteOutput() {
        guard waiting else { return }
        scheduleCheck(after: quietWindow)
    }

    private enum SettleOutcome {
        /// 屏幕还在动（或编辑器还开着），过一会儿再看。
        case waiting
        /// 这次有了结论。
        case done
        /// 还没有任何证据（刚连上），稍后再试。
        case retry
    }

    private func evaluate(
        idleFor: TimeInterval,
        inAlternateScreen: Bool,
        outputSinceSubmit: Bool
    ) -> SettleOutcome {
        let waited = Date().timeIntervalSince(tracker.submittedAt)
        guard waited >= outputFallback || idleFor >= quietWindow else { return .waiting }
        // 回车之后还没见到任何回显/输出，屏幕上还是命令执行前的旧提示符。
        guard !expectsOutput || outputSinceSubmit || waited >= outputFallback else { return .waiting }
        if inAlternateScreen {
            // 编辑器还开着，屏幕上根本没有提示符可读。等它的退出输出把读屏推回来。
            return .waiting
        }
        let line = screenLine()
        let changed = tracker.settle(promptLine: line, inAlternateScreen: false)
        // 丢掉定位这件事本身要留痕：否则日志里只看到「未上报」，看不出是提示符
        // 只报了末级目录名、和 cd 预测对不上，还是压根没读到提示符。
        let shown = tracker.lostTrackAtLastSettle
            ? "\(shownDirectory)（提示符只报了末级目录名，与预测对不上，位置未知）"
            : shownDirectory
        log("读屏 \(Self.screenForLog(line)) → \(shown)")
        if changed {
            emptyReads = 0
            onChange?(context)
        }
        // 刚连上时屏幕可能还没吐出提示符，在没有别的证据之前重试几次。
        if isLive, context.directory == nil, context.promptHomeHint == nil, warmupTries < 10 {
            warmupTries += 1
            return .retry
        }
        // 命令的输出可能中途停顿超过静默窗口，读到的只是半截屏幕：再等一次。
        if expectsOutput, !changed, emptyReads < 3 {
            emptyReads += 1
            return .retry
        }
        return .done
    }

    private func submit(command: String?, expectsOutput: Bool, assumeFileChanges: Bool = false,
                        shellExited: Bool = false) {
        let before = tracker.context
        tracker.submit(command: command, assumeFileChanges: assumeFileChanges, shellExited: shellExited)
        // 进入/退出容器时目录没变，但跟随权限和顶部模式变了，必须立刻广播，
        // 不能等下一次读屏；否则 `docker exec` 之后面板还会再跳一次宿主机路径。
        if tracker.context != before {
            log("模式切换为 \(tracker.context.mode.shortName)")
            onChange?(tracker.context)
        }
        self.expectsOutput = expectsOutput
        emptyReads = 0
        FileLogger.shared.info("跟随：提交 \(Self.describe(command, missing: "（空回车）"))，等待屏幕安静")
        guard isLive else { return }
        armSettle()
    }

    /// 命令跑完、屏幕安静下来才读：中途读到的还是命令执行前的旧提示符。
    private func armSettle() {
        guard isLive else { return }
        waiting = true
        scheduleCheck(after: quietWindow)
    }

    /// 一次性的延时检查：新输出进来时取消上一个、按最后一帧重新计时。
    private func scheduleCheck(after delay: TimeInterval) {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0.01) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.runCheck()
        }
    }

    private func runCheck() {
        settleTask = nil
        guard isLive else {
            waiting = false
            return
        }
        guard let probe = settleProbe else {
            waiting = false
            return
        }
        let inAlternateScreen = probe.inAlternateScreen()
        let outcome = evaluate(
            idleFor: probe.idleFor(),
            inAlternateScreen: inAlternateScreen,
            outputSinceSubmit: probe.hasOutputSince(tracker.submittedAt)
        )
        switch outcome {
        case .done:
            waiting = false
        case .retry:
            scheduleCheck(after: 0.35)
        case .waiting:
            if inAlternateScreen {
                // 编辑器里的光标移动也会触发输出；留一个兜底，免得彻底睡死。
                scheduleCheck(after: 10)
            } else if expectsOutput, !probe.hasOutputSince(tracker.submittedAt) {
                let remaining = outputFallback - Date().timeIntervalSince(tracker.submittedAt)
                scheduleCheck(after: max(0.25, remaining))
            } else {
                scheduleCheck(after: max(0.05, quietWindow - probe.idleFor()))
            }
        }
    }

    /// 宿主回答两个问题：屏幕安静了多久、现在是不是备用屏幕。
    public struct SettleProbe {
        public var idleFor: () -> TimeInterval
        public var inAlternateScreen: () -> Bool
        /// 提交之后远端有没有吐过字节：没有就说明回显还没到，屏幕上是旧提示符。
        public var hasOutputSince: (Date) -> Bool

        public init(
            idleFor: @escaping () -> TimeInterval,
            inAlternateScreen: @escaping () -> Bool,
            hasOutputSince: @escaping (Date) -> Bool = { _ in true }
        ) {
            self.idleFor = idleFor
            self.inAlternateScreen = inAlternateScreen
            self.hasOutputSince = hasOutputSince
        }
    }

    public var settleProbe: SettleProbe?

    private var shownDirectory: String {
        if let directory = context.directory { return directory }
        if let hint = context.promptHomeHint { return "~" + (hint.isEmpty ? "" : "/\(hint)") }
        return "未上报"
    }

    private func log(_ text: String) {
        FileLogger.shared.info("跟随：\(text)")
    }
}
