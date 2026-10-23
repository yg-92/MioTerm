import AppKit
import MioTermCore
import SwiftTerm
import Testing

/// 真实事件分发：合成的按键交给 NSApplication，监听器必须认得出终端窗口里的键入。
/// 这一条钉住的是「SSH 会话按键根本不进跟随」的那个缺口。
@MainActor
struct TerminalKeyboardMonitorTests {
    private func makeWindow() -> (NSWindow, TerminalView) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let view = TerminalView(
            frame: window.contentView!.bounds,
            font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            options: TerminalOptions()
        )
        window.contentView!.addSubview(view)
        return (window, view)
    }

    private func keyEvent(_ text: String, key: UInt16 = 0, in window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: key
        )
    }

    private func press(_ text: String, key: UInt16 = 0, in window: NSWindow) {
        guard let event = keyEvent(text, key: key, in: window) else {
            Issue.record("构造不出按键事件：\(text)")
            return
        }
        NSApplication.shared.sendEvent(event)
    }

    @Test func typedKeysFormTheCommandThatEnterSubmits() {
        let (window, view) = makeWindow()
        #expect(window.makeFirstResponder(view))
        var strokes: [TerminalKeyStroke] = []
        let monitor = TerminalKeyboardMonitor(view: view) { strokes.append($0) }
        defer { monitor.stop() }

        for character in "cd /opt" {
            press(String(character), in: window)
        }
        press("\r", key: 36, in: window)

        var tracker = ShellCommandTracker()
        var submission: ShellSubmission?
        for stroke in strokes {
            if case .bytes(let bytes) = TerminalKeyTranslator.translate(stroke) {
                if let result = tracker.consume(bytes[...]) { submission = result }
            }
        }
        #expect(submission?.command == "cd /opt")
    }

    /// 旁听不是拦截：本地进程视图收到同样的按键后，字节照常写进 pty。
    @Test func processViewStillReceivesTheBytes() async throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let view = LocalProcessTerminalView(
            frame: window.contentView!.bounds,
            font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            options: TerminalOptions()
        )
        window.contentView!.addSubview(view)
        #expect(window.makeFirstResponder(view))
        defer { view.process?.terminate() }

        view.startProcess(executable: "/bin/cat", args: [])
        let startup = Date().addingTimeInterval(2)
        while Date() < startup, view.process?.running != true {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(view.process?.running == true)

        for character in "cd /opt\r" {
            guard let event = keyEvent(String(character), key: character == "\r" ? 36 : 0, in: window) else {
                Issue.record("构造不出按键事件")
                return
            }
            view.keyDown(with: event)
        }

        // cat 会把输入原样回显：屏幕上出现这行字就证明字节确实到了 pty。
        var screen = ""
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            screen = view.terminalContentSnapshot(region: .history(maximumScrollbackRows: -1))?
                .rows.map(\.text).joined(separator: "\n") ?? ""
            if screen.contains("cd /opt") { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(screen.contains("cd /opt"), "屏幕上是：\(screen)")
    }

    /// 焦点在别的控件上时不能偷按键：命令面板、重命名输入框都在这条线上。
    @Test func keysOutsideTheTerminalAreIgnored() {
        let (window, view) = makeWindow()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        window.contentView!.addSubview(field)
        #expect(window.makeFirstResponder(field))
        var strokes: [TerminalKeyStroke] = []
        let monitor = TerminalKeyboardMonitor(view: view) { strokes.append($0) }
        defer { monitor.stop() }

        press("a", in: window)
        #expect(strokes.isEmpty)
    }
}
