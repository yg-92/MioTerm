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
}
