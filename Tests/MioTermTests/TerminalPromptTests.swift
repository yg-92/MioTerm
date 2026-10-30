import Foundation
import MioTermCore
import Testing

/// 跟随不能只指望远端配好 OSC 7：多数机器的 root shell 什么都不报，
/// 那时提示符是唯一的事实来源，所以解析必须既能读出目录，也不会把普通输出行读成目录。
struct TerminalPromptTests {
    @Test func readsDirectoryFromBracketedPrompt() {
        #expect(TerminalPrompt.parse("[root@134 /var/log/nginx]# ") == PromptFact(host: "134", hint: "/var/log/nginx"))
        #expect(TerminalPrompt.parse("[root@134 /data]#") == PromptFact(host: "134", hint: "/data"))
        #expect(TerminalPrompt.parse("[guest@box /tmp]$") == PromptFact(host: "box", hint: "/tmp"))
        #expect(TerminalPrompt.parse("[root@134 /var]%") == PromptFact(host: "134", hint: "/var"))
        #expect(TerminalPrompt.parse("[root@134 /var/log/nginx]#")?.absoluteDirectory == "/var/log/nginx")
    }

    @Test func readsDirectoryFromColonPrompt() {
        #expect(TerminalPrompt.parse("root@134:/var/log #") == PromptFact(host: "134", hint: "/var/log"))
        #expect(TerminalPrompt.parse("(venv) yanggang@server:/app$ ") == PromptFact(host: "server", hint: "/app"))
    }

    @Test func homeHintIsKeptRelativeBecauseTheAppDoesNotKnowWhereHomeIs() {
        #expect(TerminalPrompt.parse("[yanggang@Mac ~]$")?.homeRelativePath == "")
        #expect(TerminalPrompt.parse("yanggang@Mac:~/work$")?.homeRelativePath == "work")
        #expect(TerminalPrompt.parse("[yanggang@Mac ~/code/a]#")?.homeRelativePath == "code/a")
        #expect(TerminalPrompt.parse("[yanggang@Mac ~]$")?.absoluteDirectory == nil)
    }

    /// PS1 里用 `\W` 的机器只报末级目录名，够不着绝对路径，只能拿来核对预测。
    @Test func bareNameHintIsReportedAsBaseNameOnly() {
        let fact = TerminalPrompt.parse("[root@134 nginx]#")
        #expect(fact?.baseName == "nginx")
        #expect(fact?.absoluteDirectory == nil)
        #expect(fact?.homeRelativePath == nil)
    }

    @Test func ordinaryOutputLinesAreNotPrompts() {
        for line in [
            "total 12",
            "-rw-r--r-- 1 root root 0 Oct 23 12:00 note.txt",
            "drwxr-xr-x 2 root root 4096 Oct 1 09:00 .",
            "Connection to 192.168.30.134 closed.",
            "scp: /var/log/x: No such file",
            "",
        ] {
            #expect(TerminalPrompt.parse(line) == nil, "\(line) 不该被当成提示符")
        }
    }

    /// 回显行是「提示符 + 命令」。粘贴进来的路径本端一个字节都没收到，
    /// 只有这一行能说清楚刚才去了哪。
    @Test func commandIsReadBackFromTheEchoAfterThePrompt() {
        #expect(TerminalPrompt.commandAfterPrompt(in: "[root@localhost ~]# cd /home/jenkins_home/")
                == "cd /home/jenkins_home/")
        #expect(TerminalPrompt.commandAfterPrompt(in: "root@134:/var/log# ls -la") == "ls -la")
        #expect(TerminalPrompt.commandAfterPrompt(in: "root@134:/var/log/build#1# cd /opt") == "cd /opt")
        #expect(TerminalPrompt.commandAfterPrompt(in: "(venv) yanggang@server:/app$ git status") == "git status")
    }

    /// 光秃秃的提示符后面没有命令，不能凭空编一条出来。
    @Test func emptyPromptHasNoCommandAfterIt() {
        #expect(TerminalPrompt.commandAfterPrompt(in: "[root@134 ~]#") == nil)
        #expect(TerminalPrompt.commandAfterPrompt(in: "[root@134 /var/log]# ") == nil)
        #expect(TerminalPrompt.commandAfterPrompt(in: "total 12") == nil)
        #expect(TerminalPrompt.commandAfterPrompt(in: nil) == nil)
    }
}
