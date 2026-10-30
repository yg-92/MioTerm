import Foundation
import Testing
@testable import MioTermCore

/// 文件面板要跟着终端走，前提是把“用户按了什么”还原成一条命令。
/// 这里只验还原与判定，不碰真实 shell。
struct ShellCommandTrackerTests {
    @Test func assemblesAcrossChunksAndSubmitsOnEnter() {
        var tracker = ShellCommandTracker()
        #expect(tracker.consume(Array("mkd".utf8)) == nil)
        #expect(tracker.consume(Array("ir logs".utf8)) == nil)
        #expect(tracker.consume([0x0D])?.command == "mkdir logs")
        // 提交后当前行必须清空，不能把上一条命令重复交给面板；但空回车仍是一次提交。
        #expect(tracker.consume([0x0D])?.command == nil)
    }

    @Test func editingKeysShapeTheLine() {
        var backspace = ShellCommandTracker()
        _ = backspace.consume(Array("pwdx".utf8))
        _ = backspace.consume([0x7F])
        #expect(backspace.consume([0x0A])?.command == "pwd")

        var killed = ShellCommandTracker()
        _ = killed.consume(Array("rm -rf /".utf8))
        _ = killed.consume([0x15])
        #expect(killed.consume([0x0D])?.command == nil)

        var interrupted = ShellCommandTracker()
        _ = interrupted.consume(Array("to".utf8))
        _ = interrupted.consume([0x03])
        #expect(interrupted.consume([0x0D])?.command == nil)
    }

    @Test func arrowKeysDoNotLeakEscapeBytesIntoTheLine() {
        var tracker = ShellCommandTracker()
        _ = tracker.consume(Array("cd /et".utf8))
        // 历史命令召回：ESC [ A
        _ = tracker.consume([0x1B, 0x5B, 0x41])
        _ = tracker.consume(Array("c".utf8))
        #expect(tracker.consume([0x0D])?.command == "cd /etc")
    }

    /// Tab 补全后 shell 会改写文本，本端攒下来的那行已经不作数了；
    /// 但回车本身必须照样交到上层，否则目录跟随整条停摆。
    @Test func tabCompletionHidesTheCommandButNotTheSubmit() {
        var tracker = ShellCommandTracker()
        _ = tracker.consume(Array("ls /u".utf8))
        _ = tracker.consume([0x09])
        _ = tracker.consume(Array("ser".utf8))
        let submission = tracker.consume([0x0D])
        #expect(submission?.command == nil)
        // 文本不可信的回车要带上标记：上层据此按“可能改了文件”重读目录。
        #expect(submission?.isTextUnreliable == true)
        // 下一行重新可预测。
        _ = tracker.consume(Array("touch a".utf8))
        #expect(tracker.consume([0x0D])?.command == "touch a")
    }

    /// Tab 之后用户没再按键：补全出来的那一段只出现在屏幕回显里。
    /// 但用户已经敲下的前缀必须留着，上层要靠它从回显里认出完整命令。
    @Test func tabCompletionKeepsTheTypedPrefix() {
        var tracker = ShellCommandTracker()
        _ = tracker.consume(Array("cd /var/lo".utf8))
        _ = tracker.consume([0x09])
        let submission = tracker.consume([0x0D])
        #expect(submission?.command == nil)
        #expect(submission?.partialLine == "cd /var/lo")
        #expect(submission?.isTextUnreliable == true)
    }

    /// 连续两次 Tab（`cd /var/lo<Tab>ng<Tab>`）：第一次 Tab 之后敲的 `ng` 隔着补全结果，
    /// 不能直接拼到 `cd /var/lo` 后面，否则会变成屏幕上根本不存在的 `cd /var/long`。
    @Test func multiStageTabCompletionPreservesInitialPrefix() {
        var tracker = ShellCommandTracker()
        _ = tracker.consume(Array("cd /var/lo".utf8))
        _ = tracker.consume([0x09])
        _ = tracker.consume(Array("ng".utf8))
        _ = tracker.consume([0x09])
        let submission = tracker.consume([0x0D])
        #expect(submission?.command == nil)
        #expect(submission?.partialLine == "cd /var/lo")
        #expect(submission?.isTextUnreliable == true)
    }

    @Test func markLineUnreliableClearsStalePrefix() {
        var tracker = ShellCommandTracker()
        _ = tracker.consume(Array("cd z".utf8))
        tracker.markLineUnreliable()
        let submission = tracker.consume([0x0D])
        #expect(submission?.command == nil)
        #expect(submission?.partialLine == nil)
        #expect(submission?.isTextUnreliable == true)
    }

    @Test("括号粘贴的标记不进命令，粘贴内容照常记账")
    func bracketedPasteKeepsOnlyThePastedText() {
        var tracker = ShellCommandTracker()
        // shell 开了 2004，粘贴 `ls -la` 时线上走的是 ESC[200~ … ESC[201~。
        _ = tracker.consume([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])
        _ = tracker.consume(Array("ls -la".utf8))
        _ = tracker.consume([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])
        #expect(tracker.consume([0x0D])?.command == "ls -la")
    }

    @Test("粘贴标记跨多次喂入也不会漏字节")
    func pasteMarkerSplitAcrossChunks() {
        let startMarker: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
        let endMarker: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
        var tracker = ShellCommandTracker()
        for byte in startMarker { _ = tracker.consume([byte]) }
        _ = tracker.consume(Array("pwd".utf8))
        for byte in endMarker { _ = tracker.consume([byte]) }
        #expect(tracker.consume([0x0D])?.command == "pwd")
    }

    @Test("方向键、带参数的序列与 OSC 都整段跳过")
    func longerSequencesDoNotLeak() {
        var ss3 = ShellCommandTracker()
        _ = ss3.consume(Array("top".utf8))
        // application cursor keys：ESC O A
        _ = ss3.consume([0x1B, 0x4F, 0x41])
        #expect(ss3.consume([0x0D])?.command == "top")

        var parameterised = ShellCommandTracker()
        _ = parameterised.consume(Array("pwd".utf8))
        // Shift+右：ESC [ 1 ; 2 C；kitty 键盘查询应答：ESC [ ? u
        _ = parameterised.consume([0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x43])
        _ = parameterised.consume([0x1B, 0x5B, 0x3F, 0x75])
        #expect(parameterised.consume([0x0D])?.command == "pwd")

        var osc = ShellCommandTracker()
        _ = osc.consume(Array("echo".utf8))
        // 粘贴进日志文本时常见的 OSC 标题序列，BEL 收尾
        var oscSequence: [UInt8] = [0x1B]
        oscSequence.append(contentsOf: Array("]0;title".utf8))
        oscSequence.append(0x07)
        _ = osc.consume(oscSequence)
        _ = osc.consume(Array(" hi".utf8))
        #expect(osc.consume([0x0D])?.command == "echo hi")
    }

    @Test("序列中途断开时，回车仍然提交已键入的内容")
    func abortedSequenceStillSubmits() {
        var tracker = ShellCommandTracker()
        _ = tracker.consume(Array("ls".utf8))
        // ESC [ 后面直接来了回车：CSI 断了，不能把这条命令吞掉。
        _ = tracker.consume([0x1B, 0x5B])
        #expect(tracker.consume([0x0D])?.command == "ls")
    }

    @Test func classifiesDirectoryPredictions() {
        #expect(ShellCommandClassifier.classify("cd /var/log", currentDirectory: "/home/user").predictedDirectory == "/var/log")
        #expect(ShellCommandClassifier.classify("cd ..", currentDirectory: "/var/log").predictedDirectory == "/var")
        #expect(ShellCommandClassifier.classify("cd projects", currentDirectory: "/home/user").predictedDirectory == "/home/user/projects")
        #expect(ShellCommandClassifier.classify("cd \"/var/log/my app\"", currentDirectory: "/home/user").predictedDirectory == "/var/log/my app")
        #expect(ShellCommandClassifier.classify("cd /var/log/my\\ app", currentDirectory: "/home/user").predictedDirectory == "/var/log/my app")
        #expect(ShellCommandClassifier.classify("cd -- /var/log", currentDirectory: "/home/user").predictedDirectory == "/var/log")
        // 这些写法本地算不出来，只能等 OSC 7 报真实目录。
        #expect(ShellCommandClassifier.classify("cd", currentDirectory: "/home/user").predictedDirectory == nil)
        #expect(ShellCommandClassifier.classify("cd -", currentDirectory: "/home/user").predictedDirectory == nil)
        #expect(ShellCommandClassifier.classify("cd ~/work", currentDirectory: "/home/user").predictedDirectory == nil)
        #expect(ShellCommandClassifier.classify("cd $TARGET", currentDirectory: "/home/user").predictedDirectory == nil)
        #expect(ShellCommandClassifier.classify("cd /a; rm -rf b", currentDirectory: nil).predictedDirectory == nil)
    }

    @Test func classifiesFilesystemChanges() {
        for line in ["rm -rf tmp", "mkdir logs", "touch note.txt", "tar czf a.tgz .", "git checkout main", "sudo rm -f /etc/x"] {
            #expect(ShellCommandClassifier.classify(line, currentDirectory: "/home/user").mayChangeFiles, "\(line) 应当触发重读")
        }
        #expect(ShellCommandClassifier.classify("echo hi > out.txt", currentDirectory: nil).mayChangeFiles)
        #expect(ShellCommandClassifier.classify("ls -la", currentDirectory: nil).mayChangeFiles == false)
        #expect(ShellCommandClassifier.classify("cat README.md", currentDirectory: nil).mayChangeFiles == false)
        // 编辑器退出时可能已经新建、改名或删掉了文件，面板必须重读。
        #expect(ShellCommandClassifier.classify("vim notes.md", currentDirectory: nil).mayChangeFiles)
        #expect(ShellCommandClassifier.classify("sudo nano /etc/hosts", currentDirectory: nil).mayChangeFiles)
        #expect(ShellCommandClassifier.classify("ls -la", currentDirectory: nil).mayChangeFiles == false)
    }

    @Test func readsThePathOutOfOSCPayloads() {
        #expect(OSC7.path(from: "file://134/var/log/nginx") == "/var/log/nginx")
        #expect(OSC7.path(from: "file:///etc/ssh") == "/etc/ssh")
        #expect(OSC7.path(from: "file://host/my projects/app") == "/my projects/app")
        #expect(OSC7.path(from: "file://host/my%20projects/app") == "/my projects/app")
        #expect(OSC7.path(from: "/plain/path") == "/plain/path")
        #expect(OSC7.path(from: "not a uri") == nil)
        #expect(OSC7.path(from: "") == nil)
        #expect(OSC7.path(from: nil) == nil)
    }

    @Test func splitsTheReportingHostOffTheOSCPayload() {
        // 会话里再 ssh 到别处，内层 shell 报的是另一台机器：靠这段主机名分辨，别跟着走出当前主机。
        #expect(OSC7.host(from: "file://web01/var/log") == "web01")
        #expect(OSC7.host(from: "file://db.internal/data") == "db.internal")
        #expect(OSC7.host(from: "file:///etc/ssh") == nil)
        #expect(OSC7.host(from: "/plain/path") == nil)
        #expect(OSC7.host(from: nil) == nil)
    }
}
