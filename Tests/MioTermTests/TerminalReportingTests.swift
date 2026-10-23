import AppKit
import MioTermCore
import SwiftTerm
import Testing

/// 跟随的全部前提：远端 shell 报上来的 OSC 7 能穿过 SwiftTerm 到委托，并且视图里的文本读得到。
/// 这两条一旦断，目录树就只能靠手输 `cd` 的预测兜底，用户看到的就是「跟随没反应」。
@MainActor
struct TerminalReportingTests {
    private final class Probe: TerminalViewDelegate {
        var directories: [String?] = []

        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            directories.append(directory)
        }
    }

    private func makeView(_ probe: Probe) -> TerminalView {
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            options: TerminalOptions()
        )
        view.terminalDelegate = probe
        return view
    }

    @Test func oscSevenReachesTheDelegateWithItsRawPayload() async {
        let probe = Probe()
        let view = makeView(probe)
        view.feed(text: "\u{1B}]7;file://134/var/log/nginx\u{07}")
        // 回调是投递到主队列的，测试里得等这一轮跑完。
        await settleMainQueue()
        #expect(probe.directories == ["file://134/var/log/nginx"])
        // 委托收到的是原始载荷：主机段还在，嵌套会话的甄别才有依据。
        #expect(OSC7.host(from: probe.directories.first ?? nil) == "134")
        #expect(OSC7.path(from: probe.directories.first ?? nil) == "/var/log/nginx")
    }

    /// 让主队列把已经投递出去的回调跑完。
    private func settleMainQueue() async {
        for _ in 0..<50 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    @Test func promptLineIsReadableFromTheScreen() {
        let probe = Probe()
        let view = makeView(probe)
        view.feed(text: "last output\r\n[root@134 /var/log/nginx]# \r\n")
        let lastLine = lastTextLine(of: view)
        #expect(lastLine.contains("[root@134 /var/log/nginx]#"))
        #expect(TerminalPrompt.parse(lastLine)?.absoluteDirectory == "/var/log/nginx")
    }

    /// 真机上的 PS1 普遍带颜色码；快照给的是净化后的文本，解析仍要认得出来。
    @Test func coloredPromptIsReadFromTheScreenAsWell() {
        let probe = Probe()
        let view = makeView(probe)
        view.feed(text: "\u{1B}[1;32m[root@134\u{1B}[0m \u{1B}[1;33m/etc/ssh\u{1B}[0m\u{1B}[1;32m]#\u{1B}[0m ")
        let fact = TerminalPrompt.parse(lastTextLine(of: view))
        #expect(fact?.host == "134")
        #expect(fact?.absoluteDirectory == "/etc/ssh")
    }

    @Test func homePromptIsReadAsHomeRelative() {
        let probe = Probe()
        let view = makeView(probe)
        view.feed(text: "[root@134 ~]# ")
        #expect(TerminalPrompt.parse(lastTextLine(of: view))?.homeRelativePath == "")
    }

    /// 屏幕最下面一行非空文本——命令跑完之后，它就是当前提示符。
    private func lastTextLine(of view: TerminalView) -> String {
        guard let snapshot = view.terminalContentSnapshot(region: .history(maximumScrollbackRows: -1)) else {
            Issue.record("读不到屏幕内容，跟随只能靠 OSC 7")
            return ""
        }
        return snapshot.rows.compactMap { row in
            row.text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : row.text
        }.last ?? ""
    }
}
