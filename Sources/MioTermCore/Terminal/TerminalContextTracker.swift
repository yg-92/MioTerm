import Foundation

/// 目录跟随的证据有三处：shell 主动报的 OSC 7、屏幕上当前提示符里的路径、`cd` 命令的预测。
/// 排队与嵌套判定原先埋在视图控制器里，只能靠实机一试再试；抽出来之后每条规则都能写回归测试。
///
/// 除了“再 ssh 到另一台机器”，进入 Docker/LXC 等容器也会让内层路径脱离宿主机；
/// 这种切换从屏幕证据里往往看不出来（容器里的 bash 可能压根不报 OSC 7），
/// 所以还要从 `docker exec` 这类命令本身下手，提前冻结跟随。
public struct TerminalContextTracker {
    public private(set) var context = TerminalContext()
    /// 终端此刻是否停在另一台机器里（会话里再 ssh 出去）。
    public private(set) var isNested = false

    private var osc7Host: String?
    private var promptHost: String?
    private var nestedByOSC7 = false
    private var nestedByPrompt = false
    /// 由命令识别出的容器环境；nil 表示回到了外层 shell。
    private var containerMode: TerminalMode?
    /// 进入容器后是否已经读到过容器内的提示符。
    private var containerPromptSeen = false
    /// 容器内提示符的主机名；空串表示提示符里不带主机名。
    /// 只有它和外层基线不同，才允许再靠“提示符回到基线”判断退出。
    private var containerPromptHost: String?
    /// 最近一次回车（或首次连上时的探测）发生的时刻；OSC 7 比它新就不必再兜底。
    public private(set) var submittedAt = Date.distantPast
    private var predictedDirectory: String?
    private var pendingFileChange = false
    private var reportedAt = Date.distantPast

    public init() {}

    /// 用户按下回车。命令文本还原不出来时（Tab 补全会把文本换成 shell 写回的结果）
    /// 也要记这一刻：跟随正是挂在回车上，漏了它就整条链路不动。
    /// `assumeFileChanges` 用于命令行文本已经还原不出来的提交（Tab 补全、粘贴、输入法）：
    /// 既然不知道跑了什么，就按“可能改了文件”处理，宁可多读一次目录也不能让面板停在旧内容。
    public mutating func submit(command: String?, assumeFileChanges: Bool = false,
                                shellExited: Bool = false, at date: Date = Date()) {
        submittedAt = date
        if shellExited {
            // 空行 Ctrl+D：容器里的那层 shell 已结束。外层提示符随后读屏时再落目录。
            if containerMode != nil { leaveContainer() }
            return
        }
        if let command {
            if let entered = ContainerCommandDetector.enteringContainer(command) {
                containerMode = entered
                containerPromptSeen = false
                containerPromptHost = nil
                predictedDirectory = nil
                pendingFileChange = false
                applyMode()
                return
            }
            if containerMode != nil, ContainerCommandDetector.isShellExit(command) {
                leaveContainer()
                return
            }
        }
        guard !isNested, containerMode == nil else { return }
        guard let command else {
            pendingFileChange = pendingFileChange || assumeFileChanges
            return
        }
        let effect = ShellCommandClassifier.classify(command, currentDirectory: context.directory)
        if let predicted = effect.predictedDirectory {
            predictedDirectory = predicted
        }
        pendingFileChange = pendingFileChange || effect.mayChangeFiles
    }

    /// OSC 7 由 shell 钩子主动报出，权威最高；载荷里的 `file://主机/路径` 顺便用来认嵌套。
    @discardableResult
    public mutating func reportOSC7(_ payload: String?, at date: Date = Date()) -> Bool {
        let before = context
        reportedAt = date
        if let machine = OSC7.host(from: payload) {
            if let baseline = osc7Host {
                if containerMode != nil, machine == baseline {
                    // 外层宿主又开始报目录：容器已经退出（或压根没进去）。
                    leaveContainer()
                }
                nestedByOSC7 = machine != baseline
                if !nestedByOSC7 {
                    // 本机 shell 又开口报目录了，说明人已经回来，提示符那份怀疑作废。
                    nestedByPrompt = false
                    promptHost = nil
                }
            } else if containerMode == nil {
                // 基线只在普通 shell 里建立；容器内报上来的主机名不能当成“本机”。
                osc7Host = machine
                nestedByOSC7 = false
                // 提示符之前怀疑过的“另一台机器”若正是这台，说明人根本没走远。
                if promptHost == machine {
                    nestedByPrompt = false
                    promptHost = nil
                }
            }
        }
        applyNesting()
        if !isNested, containerMode == nil, let path = OSC7.path(from: payload) {
            context.directory = path
            context.promptHomeHint = nil
        }
        return context != before
    }

    /// 命令跑完、屏幕安静下来之后读一次提示符；返回上下文有没有变化。
    @discardableResult
    public mutating func settle(promptLine: String?, inAlternateScreen: Bool) -> Bool {
        let before = context
        if reportedAt < submittedAt, !inAlternateScreen {
            applyPrompt(promptLine)
            let promptSaidNothing = context.directory == before.directory
                && context.promptHomeHint == before.promptHomeHint
            if promptSaidNothing, let predicted = predictedDirectory,
               !isNested, containerMode == nil {
                context.directory = predicted
                context.promptHomeHint = nil
            }
        }
        if pendingFileChange {
            context.filesystemRevision += 1
            pendingFileChange = false
        }
        predictedDirectory = nil
        return context != before
    }

    /// 证据优先级：OSC 7 在命令之后报过就不必兜底，否则提示符 > cd 预测。
    private mutating func applyPrompt(_ line: String?) {
        guard let line, let fact = TerminalPrompt.parse(line) else { return }
        if containerMode != nil {
            if !containerPromptSeen {
                // 进容器后读到的第一个提示符一定来自容器内部。容器常被配置成与宿主
                // 同名，若拿它和外层基线比对，`docker exec` 的同一秒就会误判“已退出”。
                containerPromptSeen = true
                containerPromptHost = fact.host ?? ""
            } else if let machine = fact.host, let outer = promptHost,
                      machine == outer, let inner = containerPromptHost, inner != outer {
                // 容器主机名与外层不同，提示符却回到了外层：容器里那层 shell 已 exit。
                leaveContainer()
            }
        }
        if let machine = fact.host {
            if promptHost == nil { promptHost = machine }
            nestedByPrompt = machine != promptHost
        }
        applyNesting()
        guard !isNested, containerMode == nil else { return }
        if let directory = fact.absoluteDirectory {
            context.directory = directory
            context.promptHomeHint = nil
            return
        }
        if let relative = fact.homeRelativePath {
            context.directory = nil
            context.promptHomeHint = relative
            return
        }
        // 只剩末级名字（PS1 里的 `\W`）：够不着定位，只能给 cd 预测盖个章。
        guard let base = fact.baseName, let predicted = predictedDirectory else { return }
        if (predicted as NSString).lastPathComponent == base {
            context.directory = predicted
            context.promptHomeHint = nil
        }
    }

    private mutating func applyNesting() {
        isNested = nestedByOSC7 || nestedByPrompt
        applyMode()
    }

    /// 容器退出：只撤掉容器自身的证据，嵌套 ssh 的判断交给下一次读屏重算。
    /// 这样在容器外还有一台远程机时，短暂模式是“远程 Shell”而非“普通 Shell”，
    /// 不会在提示符回来之前抢着跳一次目录。
    private mutating func leaveContainer() {
        containerMode = nil
        containerPromptSeen = false
        containerPromptHost = nil
        predictedDirectory = nil
        applyMode()
    }

    /// 容器优先于嵌套 ssh：`docker exec` 里的 shell 往往也会让主机名变化，
    /// 但界面该显示的是“Docker”，而不是笼统的“远程 Shell”。
    private mutating func applyMode() {
        let mode = containerMode ?? (isNested ? .remoteShell : .shell)
        context.mode = mode
        context.followAllowed = mode.isFollowingAllowed
    }
}
