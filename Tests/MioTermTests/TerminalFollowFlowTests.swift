import AppKit
import MioTermCore
import SwiftTerm
import Testing

/// 端到端一段最真实的通路：远端吐出来的字节（带颜色码、带回车换行）先进 SwiftTerm，
/// 再从屏幕把提示符读回来交给判定器。中间任何一环掉链子，用户看到的就是「跟随没反应」。
@MainActor
struct TerminalFollowFlowTests {
    private final class Probe: TerminalViewDelegate {
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }

    private func makeView() -> TerminalView {
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 320),
            font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            options: TerminalOptions()
        )
        view.terminalDelegate = Probe()
        return view
    }

    /// 屏幕最下面一行非空文本，取法与 TerminalController 一致。
    private func lastScreenLine(_ view: TerminalView) -> String? {
        guard let snapshot = view.terminalContentSnapshot(region: .history(maximumScrollbackRows: -1)) else { return nil }
        for row in snapshot.rows.reversed() {
            let text = row.text.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { return text }
        }
        return nil
    }

    @Test func coloredHomePromptBecomesAHomeHint() {
        let view = makeView()
        view.feed(text: "Last login: Thu Oct 23 10:00:00 2026\r\n")
        view.feed(text: "\u{1B}[1;32m[root@134 \u{1B}[0m\u{1B}[1;33m~\u{1B}[0m\u{1B}[1;32m]\u{1B}[0m\u{1B}[1;32m#\u{1B}[0m ")
        var tracker = TerminalContextTracker()
        tracker.submit(command: nil)
        let changed = tracker.settle(promptLine: lastScreenLine(view), inAlternateScreen: false)
        #expect(changed)
        #expect(tracker.context.promptHomeHint == "")
    }

    /// 用户敲 `cd /var/log<Tab>`：命令行交不上来，屏幕上换成的新提示符得把目录接住。
    @Test func tabCompletedCdIsRecoveredFromTheScreen() {
        let view = makeView()
        view.feed(text: "\u{1B}[1;32m[root@134 ~]\u{1B}[0m# cd /var/lo\u{1B}[9D\u{1B}[C\u{1B}[C\u{1B}[C\u{1B}[Cg\r\n")
        view.feed(text: "\u{1B}[1;32m[root@134 /var/log]\u{1B}[0m# ")
        var tracker = TerminalContextTracker()
        tracker.submit(command: nil)
        _ = tracker.settle(promptLine: "[root@134 ~]#", inAlternateScreen: false)
        tracker.submit(command: nil)
        let changed = tracker.settle(promptLine: lastScreenLine(view), inAlternateScreen: false)
        #expect(changed)
        #expect(tracker.context.directory == "/var/log")
    }

    /// zsh 的 `user@host:~/code %` 与 bash 的空格式提示符都要认得。
    @Test func zshStylePromptIsReadFromTheScreen() {
        let view = makeView()
        view.feed(text: "\u{1B}[32muser@mac\u{1B}[34m:\u{1B}[0m\u{1B}[35m~/code\u{1B}[0m \u{1B}[31m%\u{1B}[0m ")
        let fact = TerminalPrompt.parse(lastScreenLine(view) ?? "")
        #expect(fact?.host == "mac")
        #expect(fact?.homeRelativePath == "code")
    }

    @Test func plainBashPromptWithSpaceIsReadAsWell() {
        let view = makeView()
        view.feed(text: "root@134 /etc/ssh # ")
        let fact = TerminalPrompt.parse(lastScreenLine(view) ?? "")
        #expect(fact?.absoluteDirectory == "/etc/ssh")
    }

    /// 长路径把提示符挤到下一行时，读到的只是半截；这时候宁可退回 `cd` 的预测。
    @Test func wrappedPromptFallsBackToThePrediction() {
        let view = makeView()
        view.feed(text: "[root@134 /a\r\nvery/long/path/that/wraps]# ")
        let line = lastScreenLine(view) ?? ""
        #expect(TerminalPrompt.parse(line) == nil)
        var tracker = TerminalContextTracker()
        tracker.submit(command: "cd /a/very/long/path/that/wraps")
        _ = tracker.settle(promptLine: line, inAlternateScreen: false)
        #expect(tracker.context.directory == "/a/very/long/path/that/wraps")
    }
}
