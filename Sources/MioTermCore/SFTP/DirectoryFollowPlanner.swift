import Foundation

/// 文件面板面对一次终端上下文更新该做什么。
///
/// 面板原来自己判断，规则散在视图控制器里：通道没就绪时这次不算看过、
/// 提示符只说「在主目录」要先问绝对路径、第一次拿到目标必须真的动一次。
/// 这几条都出过「跟随没反应」，而视图控制器没法在测试里跑，所以抽到这里。
public enum PanelFollowAction: Equatable {
    /// 树挪到这个绝对路径。
    case jump(String)
    /// 目录没变，但终端改了文件系统：重读当前这一层。
    case reload
    /// 提示符只说得出「主目录里的哪一段」，先去文件通道问出绝对路径。
    case resolveHome
    /// 终端跑到了别的机器上，跟随暂停，并把原因说给用户。
    case pause(reason: String)
    /// 开了跟随却拿不到目录：与其默默不动，不如把状态条写清楚。
    case explainMissingDirectory
    /// 文件通道还没就绪，这次上下文不算「已经跟上」。
    case channelNotReady
    /// 什么都不用做。
    case idle
}

/// 决策要看的全部事实，一次传进来。
public struct PanelFollowFacts: Equatable {
    public var terminal: TerminalContext
    /// 跟随开关（全局设置或本标签覆盖）此刻是否打开。
    public var followEnabled: Bool
    /// 用户刚刚才把跟随打开：终端未必再产生新事件，这一刻要按此刻的目录对齐。
    public var justEnabled: Bool
    /// 文件通道是否已经能读目录。
    public var channelReady: Bool
    /// 远端主目录的绝对路径，问到之前是 nil。
    public var remoteHome: String?
    /// 主目录已经问过、问不出来：再问也是同样的结果，不能继续要求解析。
    public var homeUnresolvable: Bool
    /// 终端上一次说过的目录（已经翻译成绝对路径）。
    public var targetBefore: String?
    public var filesystemRevisionBefore: Int
    /// 这个标签是否已经按终端目录对齐过一次。
    public var hasAligned: Bool
    /// 面板正在列表/传输，别打断。
    public var isBusy: Bool

    public init(
        terminal: TerminalContext,
        followEnabled: Bool,
        justEnabled: Bool = false,
        channelReady: Bool,
        remoteHome: String? = nil,
        homeUnresolvable: Bool = false,
        targetBefore: String? = nil,
        filesystemRevisionBefore: Int = 0,
        hasAligned: Bool = false,
        isBusy: Bool = false
    ) {
        self.terminal = terminal
        self.followEnabled = followEnabled
        self.justEnabled = justEnabled
        self.channelReady = channelReady
        self.remoteHome = remoteHome
        self.homeUnresolvable = homeUnresolvable
        self.targetBefore = targetBefore
        self.filesystemRevisionBefore = filesystemRevisionBefore
        self.hasAligned = hasAligned
        self.isBusy = isBusy
    }
}

public enum DirectoryFollowPlanner {
    /// 终端说的“在哪”，翻译成文件通道能读的绝对路径；信息不够时是 nil。
    public static func target(_ context: TerminalContext, remoteHome: String?) -> String? {
        if let directory = context.directory {
            return SFTPPath.normalize(directory)
        }
        guard let hint = context.promptHomeHint, let home = remoteHome else { return nil }
        return SFTPPath.normalize(hint.isEmpty ? home : home + "/" + hint)
    }

    public static func decide(_ facts: PanelFollowFacts) -> PanelFollowAction {
        // 通道还没起来（视图刚进窗口、或还没到 SSH 主机）时这次不算看过：
        // 否则终端在连接期间报上来的目录会被记成「已经跟上」，通道就绪后就不再对齐了。
        guard facts.channelReady else { return .channelNotReady }
        // 容器或嵌套机器里的路径属于另一套文件系统：即使跟随开着也不能动树，
        // 否则 SFTP 会拿宿主机去读容器内路径，只能报错。
        if facts.followEnabled, !facts.terminal.followAllowed {
            return .pause(reason: facts.terminal.mode.pauseReason ?? L10n.tr(.terminalModePauseRemote))
        }
        let target = target(facts.terminal, remoteHome: facts.remoteHome)
        // 问过一次没问出来就到此为止：面板解析失败后会重放同一条上下文，
        // 这里再给一次 .resolveHome 就成了自旋——实测一分钟转 24000 圈，
        // 把日志刷到截断上限、内存峰值顶到 325 MB。
        if facts.followEnabled, target == nil,
           facts.terminal.promptHomeHint != nil, facts.remoteHome == nil, !facts.homeUnresolvable {
            return .resolveHome
        }
        let moved = target != facts.targetBefore
        // 刚打开开关、或这个标签还没对齐过的时候，树还停在原地，这一次要真的动一下。
        let needsAlign = moved || facts.justEnabled || !facts.hasAligned
        if facts.followEnabled, let directory = target, needsAlign {
            return .jump(directory)
        }
        if facts.terminal.filesystemRevision != facts.filesystemRevisionBefore {
            return .reload
        }
        // 目录没变、文件也没动，但用户开着跟随却看不见树在跟：把原因说出来。
        if facts.followEnabled, target == nil, !facts.isBusy {
            return .explainMissingDirectory
        }
        return .idle
    }
}
