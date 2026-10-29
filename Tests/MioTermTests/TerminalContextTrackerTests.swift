import Foundation
import Testing
@testable import MioTermCore

/// 目录跟随的判定规则。这套逻辑原先只在实机上试过，每条证据链在此固定下来。
struct TerminalContextTrackerTests {
    private func trackerAfterTyping(_ command: String?, promptLine: String?,
                                   alternate: Bool = false) -> TerminalContext {
        var tracker = TerminalContextTracker()
        tracker.submit(command: command)
        _ = tracker.settle(promptLine: promptLine, inAlternateScreen: alternate)
        return tracker.context
    }

    /// 用户最爱按 Tab：补全之后的命令行还原不出来，但回车确实发生了。
    /// 这一条断了，整条跟随链路就停在那儿不动。
    @Test func tabCompletedCommandStillMovesThePanel() {
        let context = trackerAfterTyping(nil, promptLine: "[root@134 /var/log]#")
        #expect(context.directory == "/var/log")
    }

    @Test func homePromptIsHandedToTheFileChannel() {
        let context = trackerAfterTyping(nil, promptLine: "[root@134 ~]#")
        #expect(context.directory == nil)
        #expect(context.promptHomeHint == "")
    }

    @Test func homeRelativePromptKeepsTheTail() {
        let context = trackerAfterTyping(nil, promptLine: "root@134:~/code$")
        #expect(context.promptHomeHint == "code")
    }

    /// PS1 用 `\W` 的机器只报末级目录名，够不着绝对路径，此时退回 cd 的预测。
    @Test func basenamePromptConfirmsTheCdPrediction() {
        #expect(trackerAfterTyping("cd /var/log", promptLine: "[root@134 log]#").directory == "/var/log")
    }

    @Test func promptWithoutAnyPathFallsBackToTheCdPrediction() {
        #expect(trackerAfterTyping("cd /var/log", promptLine: "bash-4.2$").directory == "/var/log")
    }

    /// 提示符和预测打架时听提示符：它是终端此刻真实显示的东西。
    @Test func promptOutrulesTheCdPrediction() {
        let context = trackerAfterTyping("cd /tmp", promptLine: "[root@134 /var/log]#")
        #expect(context.directory == "/var/log")
    }

    @Test func oscSevenWinsOverEverythingAfterIt() {
        var tracker = TerminalContextTracker()
        tracker.submit(command: "cd /tmp")
        let reported = tracker.reportOSC7("file://134/var/log")
        #expect(reported)
        _ = tracker.settle(promptLine: "[root@134 /etc]#", inAlternateScreen: false)
        #expect(tracker.context.directory == "/var/log")
    }

    /// 会话里再 ssh 到别处，内层目录属于另一台机器，SFTP 那边读不到，必须冻结。
    @Test func nestedShellFreezesTheDirectory() {
        var tracker = TerminalContextTracker()
        tracker.submit(command: nil)
        _ = tracker.settle(promptLine: "[root@134 /var/log]#", inAlternateScreen: false)
        tracker.submit(command: "ssh 10.0.0.8")
        _ = tracker.settle(promptLine: "[root@other /etc]#", inAlternateScreen: false)
        #expect(tracker.isNested)
        #expect(tracker.context.followAllowed == false)
        #expect(tracker.context.directory == "/var/log")
    }

    /// 退出嵌套后要自己解冻，否则用户回到本机目录树还钉在原地。
    @Test func comingBackFromTheNestedShellUnfreezes() {
        var tracker = TerminalContextTracker()
        tracker.submit(command: nil)
        _ = tracker.settle(promptLine: "[root@134 /var/log]#", inAlternateScreen: false)
        tracker.submit(command: nil)
        _ = tracker.settle(promptLine: "[root@other /etc]#", inAlternateScreen: false)
        tracker.submit(command: "exit")
        _ = tracker.settle(promptLine: "[root@134 /root]#", inAlternateScreen: false)
        #expect(tracker.context.followAllowed)
        #expect(tracker.context.directory == "/root")
    }

    @Test func oscSevenFromTheHomeMachineClearsTheNestedGuess() {
        var tracker = TerminalContextTracker()
        tracker.submit(command: nil)
        _ = tracker.settle(promptLine: "[root@134 /var/log]#", inAlternateScreen: false)
        tracker.submit(command: nil)
        _ = tracker.settle(promptLine: "[root@other /etc]#", inAlternateScreen: false)
        let reported = tracker.reportOSC7("file://134/root")
        #expect(reported)
        #expect(tracker.context.followAllowed)
        #expect(tracker.context.directory == "/root")
    }

    /// vim、less 里的“提示符”是编辑器界面，不能当目录。
    @Test func alternateScreenNeverMovesTheDirectory() {
        let context = trackerAfterTyping(nil, promptLine: "[root@134 /var/log]#", alternate: true)
        #expect(context.directory == nil)
    }

    /// 改过文件系统的命令要通知面板重读，而且一次回车只算一次。
    @Test func fileChangeBumpsTheRevisionOnce() {
        var tracker = TerminalContextTracker()
        tracker.submit(command: "mkdir logs")
        let first = tracker.settle(promptLine: "[root@134 /var]#", inAlternateScreen: false)
        #expect(first)
        #expect(tracker.context.filesystemRevision == 1)
        tracker.submit(command: nil)
        let second = tracker.settle(promptLine: "[root@134 /var]#", inAlternateScreen: false)
        #expect(second == false)
        #expect(tracker.context.filesystemRevision == 1)
    }

    @Test func plainEnterOnlyReReadsThePrompt() {
        var tracker = TerminalContextTracker()
        tracker.submit(command: nil)
        let changed = tracker.settle(promptLine: "[root@134 /etc/ssh]#", inAlternateScreen: false)
        #expect(changed)
        #expect(tracker.context.directory == "/etc/ssh")
        #expect(tracker.context.filesystemRevision == 0)
    }

    /// 底栏显示的是“此刻在哪”。远端只给了 `~` 时也得说清是在家目录，不能落到未知。
    @Test func displayDirectoryRendersHomePrompts() {
        #expect(trackerAfterTyping(nil, promptLine: "[root@134 ~]#").displayDirectory == "~")
        #expect(trackerAfterTyping(nil, promptLine: "root@134:~/code$").displayDirectory == "~/code")
    }

    @Test func displayDirectoryPrefersTheAbsolutePath() {
        #expect(trackerAfterTyping(nil, promptLine: "[root@134 /var/log]#").displayDirectory == "/var/log")
        #expect(TerminalContext().displayDirectory == nil)
    }

    // MARK: - 末级目录名与 cd 预测打架

    /// 先让跟踪器确认自己在某个绝对路径上，再模拟一次提交。
    private func tracker(startingAt directory: String) -> TerminalContextTracker {
        var tracker = TerminalContextTracker()
        tracker.submit(command: nil)
        _ = tracker.settle(promptLine: "[root@134 \(directory)]#", inAlternateScreen: false)
        return tracker
    }

    /// 实机事故：PS1 是 `\W` 的机器上，`cd ../` 从 `/home` 预测出 `/`，
    /// 而提示符明明报的是 `jenkins_home`。旧代码把“上下文没变”当成“提示符没说话”，
    /// 于是采纳了 `/`；之后每个 `cd` 都从这个错路径往下算，最后停在根本不存在的
    /// `/project-execute` 上，树上一片“文件或目录不存在”。
    @Test func basenameThatContradictsThePredictionVoidsIt() {
        var tracker = tracker(startingAt: "/home")
        #expect(tracker.context.directory == "/home")
        tracker.submit(command: "cd ../")
        _ = tracker.settle(promptLine: "[root@134 jenkins_home]#", inAlternateScreen: false)
        #expect(tracker.context.directory == nil)
        #expect(tracker.context.promptBasename == "jenkins_home")
        #expect(tracker.lostTrackAtLastSettle)
    }

    /// `cd` 的目标不存在时 shell 留在原地，提示符还是原来那个末级名。
    /// 这不叫“丢了定位”，已知目录要保住。
    @Test func failedCdKeepsTheKnownDirectory() {
        var tracker = tracker(startingAt: "/home")
        tracker.submit(command: "cd nope")
        _ = tracker.settle(promptLine: "[root@134 home]#", inAlternateScreen: false)
        #expect(tracker.context.directory == "/home")
        #expect(!tracker.lostTrackAtLastSettle)
    }

    /// 执行的不是 `cd`：没有预测可核对，更不该把已知目录清掉。
    @Test func ordinaryCommandKeepsTheKnownDirectory() {
        var tracker = tracker(startingAt: "/home")
        tracker.submit(command: "ls -la")
        _ = tracker.settle(promptLine: "[root@134 home]#", inAlternateScreen: false)
        #expect(tracker.context.directory == "/home")
        #expect(!tracker.lostTrackAtLastSettle)
    }

    /// 丢掉定位之后的 `cd` 不再瞎猜：预测需要基底，基底没了就什么都不给。
    @Test func followingStaysQuietOnceTrackIsLost() {
        var tracker = tracker(startingAt: "/home")
        tracker.submit(command: "cd ../")
        _ = tracker.settle(promptLine: "[root@134 jenkins_home]#", inAlternateScreen: false)
        tracker.submit(command: "cd project-execute")
        _ = tracker.settle(promptLine: "[root@134 project-execute]#", inAlternateScreen: false)
        #expect(tracker.context.directory == nil)
    }

    /// 末级名只是“说清为什么停住”的线索，一旦读到绝对路径就该收起来。
    @Test func absolutePromptClearsTheBasenameHint() {
        var tracker = tracker(startingAt: "/home")
        tracker.submit(command: "cd ../")
        _ = tracker.settle(promptLine: "[root@134 jenkins_home]#", inAlternateScreen: false)
        #expect(tracker.context.promptBasename == "jenkins_home")
        tracker.submit(command: nil)
        _ = tracker.settle(promptLine: "[root@134 /home/jenkins_home]#", inAlternateScreen: false)
        #expect(tracker.context.directory == "/home/jenkins_home")
        #expect(tracker.context.promptBasename == nil)
    }

    @Test func oscSevenClearsTheBasenameHint() {
        var tracker = tracker(startingAt: "/home")
        tracker.submit(command: "cd ../")
        _ = tracker.settle(promptLine: "[root@134 jenkins_home]#", inAlternateScreen: false)
        tracker.reportOSC7("file://134/home/jenkins_home")
        #expect(tracker.context.directory == "/home/jenkins_home")
        #expect(tracker.context.promptBasename == nil)
    }
}
