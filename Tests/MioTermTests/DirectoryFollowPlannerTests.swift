import MioTermCore
import Testing

/// 面板这一侧的跟随规则：树到底动还是不动。
/// 这些判断以前住在视图控制器里，出过「连接期报上来的目录被吞掉」
/// 「第一次进面板差一步不动」两类问题，却没有任何测试拦得住。
@Suite("文件面板跟随决策")
struct DirectoryFollowPlannerTests {
    private func context(
        directory: String? = nil,
        homeHint: String? = nil,
        revision: Int = 0,
        followAllowed: Bool = true
    ) -> TerminalContext {
        TerminalContext(directory: directory, promptHomeHint: homeHint,
                        filesystemRevision: revision, followAllowed: followAllowed)
    }

    /// 通道还没就绪（视图刚进窗口、SSH 还在握手）时不能把这次算成「已经跟上」。
    @Test func ignoresUntilTheChannelIsReady() {
        let action = DirectoryFollowPlanner.decide(
            PanelFollowFacts(terminal: context(directory: "/var/log"), followEnabled: true, channelReady: false)
        )
        #expect(action == .channelNotReady)
    }

    /// 提示符只说得出「在主目录」，绝对路径还得问文件通道。
    @Test func asksForHomeWhenThePromptOnlySaysTilde() {
        let action = DirectoryFollowPlanner.decide(
            PanelFollowFacts(terminal: context(homeHint: "logs"), followEnabled: true, channelReady: true)
        )
        #expect(action == .resolveHome)
    }

    /// 问到主目录之后，`~/logs` 就是 `/root/logs`。
    @Test func joinsTheHomeHintOnceHomeIsKnown() {
        let action = DirectoryFollowPlanner.decide(
            PanelFollowFacts(terminal: context(homeHint: "logs"), followEnabled: true,
                             channelReady: true, remoteHome: "/root", hasAligned: true)
        )
        #expect(action == .jump("/root/logs"))
    }

    /// 问不出来就不能一直要求重问：面板解析失败后会重放同一条上下文，
    /// 再给一次 .resolveHome 就是自旋——实测一分钟两万四千圈，日志刷到截断上限、
    /// 内存峰值 325 MB。
    @Test func stopsAskingForHomeOnceTheProbeFailed() {
        let stuck = PanelFollowFacts(terminal: context(homeHint: "logs"), followEnabled: true,
                                     channelReady: true, homeUnresolvable: true, hasAligned: true)
        #expect(DirectoryFollowPlanner.decide(stuck) == .explainMissingDirectory)
        // 换通道或用户点刷新会把标记清掉，那时可以再问一次。
        let retry = PanelFollowFacts(terminal: context(homeHint: "logs"), followEnabled: true,
                                     channelReady: true, hasAligned: true)
        #expect(DirectoryFollowPlanner.decide(retry) == .resolveHome)
    }

    @Test func emptyHomeHintIsTheHomeItself() {
        let target = DirectoryFollowPlanner.target(context(homeHint: ""), remoteHome: "/home/ops")
        #expect(target == "/home/ops")
    }

    /// 终端目录和用户手动翻到的位置相同时，第一次仍然要真的对齐一次。
    @Test func alignsOnTheFirstChance() {
        let facts = PanelFollowFacts(terminal: context(directory: "/var/log"), followEnabled: true,
                                     channelReady: true, targetBefore: "/var/log")
        #expect(DirectoryFollowPlanner.decide(facts) == .jump("/var/log"))
    }

    /// 对齐过之后，同一个目录不再重复刷屏：用户手动浏览别处不会被抢回去。
    @Test func leavesTheUserAloneAfterAligningOnce() {
        let facts = PanelFollowFacts(terminal: context(directory: "/var/log"), followEnabled: true,
                                     channelReady: true, targetBefore: "/var/log", hasAligned: true)
        #expect(DirectoryFollowPlanner.decide(facts) == .idle)
    }

    /// 刚在设置里打开跟随：终端未必再产生新事件，这一刻就要跟上此刻的目录。
    @Test func jumpsWhenFollowWasJustEnabled() {
        let steady = PanelFollowFacts(terminal: context(directory: "/etc"), followEnabled: true,
                                      channelReady: true, targetBefore: "/etc", hasAligned: true)
        #expect(DirectoryFollowPlanner.decide(steady) == .idle)
        let justOn = PanelFollowFacts(terminal: context(directory: "/etc"), followEnabled: true,
                                      justEnabled: true, channelReady: true,
                                      targetBefore: "/etc", hasAligned: true)
        #expect(DirectoryFollowPlanner.decide(justOn) == .jump("/etc"))
    }

    /// 目录没变但终端建了个文件：重读当前这一层，别整层跳转。
    @Test func reloadsOnFileSystemChange() {
        let facts = PanelFollowFacts(terminal: context(directory: "/var/log", revision: 3), followEnabled: true,
                                     channelReady: true, targetBefore: "/var/log",
                                     filesystemRevisionBefore: 2, hasAligned: true)
        #expect(DirectoryFollowPlanner.decide(facts) == .reload)
    }

    /// 关了跟随也不能漏掉文件变动，树照样要重读。
    @Test func stillReloadsWithoutFollow() {
        let facts = PanelFollowFacts(terminal: context(directory: "/var/log", revision: 1), followEnabled: false,
                                     channelReady: true, targetBefore: "/var/log", filesystemRevisionBefore: 0)
        #expect(DirectoryFollowPlanner.decide(facts) == .reload)
    }

    /// 会话里 ssh 到别处：内层目录属于另一台机器，SFTP 读不到，只能暂停并说明。
    @Test func pausesWhenTheTerminalLeftThisMachine() {
        let facts = PanelFollowFacts(terminal: context(directory: "/etc", followAllowed: false),
                                     followEnabled: true, channelReady: true, targetBefore: "/var/log")
        guard case .pause(let reason) = DirectoryFollowPlanner.decide(facts) else {
            Issue.record("应暂停跟随")
            return
        }
        #expect(reason.contains("别的机器"))
    }

    /// 既没 OSC 7 也不认得提示符：把「无从下手」说出来，而不是默默不动。
    @Test func explainsWhenThereIsNothingToFollow() {
        let facts = PanelFollowFacts(terminal: context(), followEnabled: true, channelReady: true, hasAligned: true)
        #expect(DirectoryFollowPlanner.decide(facts) == .explainMissingDirectory)
        // 面板正在忙就别抢状态条。
        let busy = PanelFollowFacts(terminal: context(), followEnabled: true, channelReady: true,
                                   hasAligned: true, isBusy: true)
        #expect(DirectoryFollowPlanner.decide(busy) == .idle)
    }

    /// 绝对路径要先归一：`/var//log/` 与 `/var/log` 是同一个地方，不该反复跳转。
    @Test func comparesNormalizedPaths() {
        let target = DirectoryFollowPlanner.target(context(directory: "/var//log/"), remoteHome: nil)
        #expect(target == "/var/log")
        let facts = PanelFollowFacts(terminal: context(directory: "/var//log/"), followEnabled: true,
                                     channelReady: true, targetBefore: "/var/log", hasAligned: true)
        #expect(DirectoryFollowPlanner.decide(facts) == .idle)
    }
}
