import AppKit
import MioTermCore
import SwiftTerm
import Testing

/// 用户现场实录：银河麒麟的 bash，提示符 `root@target:/opt#`（冒号紧贴、`#` 前没有空格）。
/// 这段字节流是从他贴出来的会话里逐行抄的，包括那条敲错、由 Tab 补全展开成列表的 cd。
@MainActor
struct KylinPromptSessionTests {
    private final class Probe: TerminalViewDelegate {
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }

    @Test func everyPromptInTheSessionIsRead() {
        let lines = [
            "root@target:~#",
            "root@target:/opt#",
            "root@target:/#",
            "root@target:/var/local#",
            "root@target:~/logs#",
        ]
        let expected: [PromptFact?] = [
            PromptFact(host: "target", hint: "~"),
            PromptFact(host: "target", hint: "/opt"),
            PromptFact(host: "target", hint: "/"),
            PromptFact(host: "target", hint: "/var/local"),
            PromptFact(host: "target", hint: "~/logs"),
        ]
        for (line, want) in zip(lines, expected) {
            #expect(TerminalPrompt.parse(line) == want, "读不出 \(line)")
        }
        #expect(TerminalPrompt.parse("root@target:~#")?.homeRelativePath == "")
        #expect(TerminalPrompt.parse("root@target:/#")?.absoluteDirectory == "/")
        #expect(TerminalPrompt.parse("root@target:/var/local#")?.absoluteDirectory == "/var/local")
    }

    /// 整条通路：真实字节进终端，回车后读屏，目录一路跟着 cd 走。
    @Test func followsEveryCdInTheRealSession() {
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            options: TerminalOptions()
        )
        view.terminalDelegate = Probe()
        let pipeline = TerminalFollowPipeline()
        pipeline.isLive = true
        pipeline.setScreenLineProvider { [weak view] in
            guard let view,
                  let snapshot = view.terminalContentSnapshot(region: .history(maximumScrollbackRows: -1))
            else { return nil }
            for row in snapshot.rows.reversed() {
                let text = row.text.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { return text }
            }
            return nil
        }

        // 登录横幅： kylin 的公告行里带 “/”，不能把网址当目录。
        view.feed(text: "\u{1B}[1;32m* Management:     http://www.kylinos.cn/ \u{1B}[0m\r\n")
        view.feed(text: "\u{1B}[1;32m* Support:        http://www.kylinos.cn/service.aspx\u{1B}[0m\r\n")
        view.feed(text: "Last login: Fri Oct 23 17:03:51 2026 from 192.168.30.233\r\n")
        view.feed(text: "root@target:~# ")
        pipeline.sessionDidOpen()
        #expect(pipeline.settleNow(idleFor: 1, inAlternateScreen: false))
        #expect(pipeline.context.promptHomeHint == "")

        func typeAndSettle(_ text: String, _ remoteOutput: String) {
            let bytes = ArraySlice(Array(text.utf8))
            view.feed(text: text)
            pipeline.userInput(bytes, inAlternateScreen: false)
            view.feed(text: remoteOutput)
            _ = pipeline.settleNow(idleFor: 1, inAlternateScreen: false)
        }

        typeAndSettle("cd /opt\r", "\r\nroot@target:/opt# ")
        #expect(pipeline.context.directory == "/opt")

        typeAndSettle("cd /\r", "\r\nroot@target:/# ")
        #expect(pipeline.context.directory == "/")

        // Tab 补全把 /var/l 展开成候选列表，命令行还原不出来，屏幕上仍是 /
        typeAndSettle("cd /var/l\u{09}", "\u{08}\u{09}\r\nlib/   local/ lock/  log/   \r\nroot@target:/# ")
        #expect(pipeline.context.directory == "/")

        typeAndSettle("\r", "-bash: cd: /var/l: 没有那个文件或目录\r\nroot@target:/# ")
        #expect(pipeline.context.directory == "/")

        typeAndSettle("cd /var/local/\r", "\r\nroot@target:/var/local# ")
        #expect(pipeline.context.directory == "/var/local")

        pipeline.stop()
    }
}
