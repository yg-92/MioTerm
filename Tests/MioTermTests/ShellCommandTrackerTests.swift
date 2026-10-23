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
        #expect(tracker.consume([0x0D]) == "mkdir logs")
        // 提交后当前行必须清空，不能把上一条命令重复交给面板。
        #expect(tracker.consume([0x0D]) == nil)
    }

    @Test func editingKeysShapeTheLine() {
        var backspace = ShellCommandTracker()
        _ = backspace.consume(Array("pwdx".utf8))
        _ = backspace.consume([0x7F])
        #expect(backspace.consume([0x0A]) == "pwd")

        var killed = ShellCommandTracker()
        _ = killed.consume(Array("rm -rf /".utf8))
        _ = killed.consume([0x15])
        #expect(killed.consume([0x0D]) == nil)

        var interrupted = ShellCommandTracker()
        _ = interrupted.consume(Array("to".utf8))
        _ = interrupted.consume([0x03])
        #expect(interrupted.consume([0x0D]) == nil)
    }

    @Test func arrowKeysDoNotLeakEscapeBytesIntoTheLine() {
        var tracker = ShellCommandTracker()
        _ = tracker.consume(Array("cd /et".utf8))
        // 历史命令召回：ESC [ A
        _ = tracker.consume([0x1B, 0x5B, 0x41])
        _ = tracker.consume(Array("c".utf8))
        #expect(tracker.consume([0x0D]) == "cd /etc")
    }

    @Test func tabCompletionMakesTheLineUnpredictable() {
        var tracker = ShellCommandTracker()
        _ = tracker.consume(Array("ls /u".utf8))
        _ = tracker.consume([0x09])
        _ = tracker.consume(Array("ser".utf8))
        #expect(tracker.consume([0x0D]) == nil)
        // 下一行重新可预测。
        _ = tracker.consume(Array("touch a".utf8))
        #expect(tracker.consume([0x0D]) == "touch a")
    }

    @Test func classifiesDirectoryPredictions() {
        #expect(ShellCommandClassifier.classify("cd /var/log", currentDirectory: "/home/user").predictedDirectory == "/var/log")
        #expect(ShellCommandClassifier.classify("cd ..", currentDirectory: "/var/log").predictedDirectory == "/var")
        #expect(ShellCommandClassifier.classify("cd projects", currentDirectory: "/home/user").predictedDirectory == "/home/user/projects")
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
        #expect(ShellCommandClassifier.classify("vim notes.md", currentDirectory: nil).mayChangeFiles == false)
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
}
