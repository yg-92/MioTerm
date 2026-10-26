import AppKit
import MioTermCore
import SwiftTerm
import Testing

/// 数字小键盘在本地终端里必须打出字符。
///
/// zsh/oh-my-zsh 的 `zle-line-init` 会发 `smkx` 打开 application keypad 模式，
/// SwiftTerm 于是把数字键盘编成 `ESC O p`…`ESC O M` 这类 SS3 序列；zsh 只开模式、
/// 不绑定这些序列，按键就只剩响铃。`TerminalKeypadNormalizer` 在事件进视图前
/// 把小键盘换成主键盘等价键，这两条测试钉住改写本身和真实分发路径。
@MainActor
struct TerminalKeypadTests {
    private func keypadEvent(_ text: String, key: UInt16) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.numericPad], timestamp: 0,
            windowNumber: 0, context: nil,
            characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: key
        )
    }

    @Test func keypadKeysMapToTheMainKeyboard() {
        let digits: [(String, UInt16, UInt16)] = [
            ("0", 82, 29), ("1", 83, 18), ("2", 84, 19), ("3", 85, 20), ("4", 86, 21),
            ("5", 87, 23), ("6", 88, 22), ("7", 89, 26), ("8", 91, 28), ("9", 92, 25),
            ("1", 83, 18),
        ]
        for (text, keypad, main) in digits {
            guard let event = keypadEvent(text, key: keypad) else {
                Issue.record("构造不出小键盘事件：\(text)")
                return
            }
            let replacement = TerminalKeypad.mainKeyboardEvent(for: event)
            #expect(replacement?.keyCode == main, "\(text) 应该落到主键盘键 \(main)")
            #expect(replacement?.characters == text)
            #expect(replacement?.modifierFlags.contains(.numericPad) == false)
        }

        let operators: [(String, UInt16, UInt16)] = [
            (".", 65, 47), ("/", 75, 44), ("*", 67, 28),
            ("-", 78, 27), ("+", 69, 24), ("=", 81, 24),
        ]
        for (text, keypad, main) in operators {
            guard let event = keypadEvent(text, key: keypad) else {
                Issue.record("构造不出小键盘事件：\(text)")
                return
            }
            #expect(TerminalKeypad.mainKeyboardEvent(for: event)?.keyCode == main, "\(text)")
        }

        guard let enter = keypadEvent("\r", key: 76) else {
            Issue.record("构造不出小键盘回车")
            return
        }
        // 主键盘 Return 的键码是 36：命令还原与 SwiftTerm 都按它认回车。
        #expect(TerminalKeypad.mainKeyboardEvent(for: enter)?.keyCode == 36)
    }

    @Test func ordinaryKeysAndModifiedKeypadKeysAreUntouched() {
        guard let letter = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil,
            characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0
        ), let commandDigit = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.numericPad, .command], timestamp: 0,
            windowNumber: 0, context: nil,
            characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 83
        ) else {
            Issue.record("构造不出按键事件")
            return
        }
        #expect(TerminalKeypad.mainKeyboardEvent(for: letter) == nil)
        // Command 组合是应用快捷键，交给菜单/视图，不在这里改写。
        #expect(TerminalKeypad.mainKeyboardEvent(for: commandDigit) == nil)
    }
}

/// 真实分发路径：窗口 + 第一响应者 + 本地监听，按键最终变成什么字节。
@MainActor
struct TerminalKeypadDispatchTests {
    private final class Probe: TerminalViewDelegate {
        var sent: [UInt8] = []
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            sent.append(contentsOf: data)
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    private func makeWindow(_ probe: Probe) -> (NSWindow, TerminalView) {
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
        view.terminalDelegate = probe
        window.contentView!.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(view))
        return (window, view)
    }

    private func keypadEvent(_ text: String, key: UInt16, in window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.numericPad], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: key
        )
    }

    /// 先确认诊断：模式开着时，SwiftTerm 自己会把数字键盘编成 SS3。
    @Test func applicationKeypadModeEncodesSS3WithoutTheNormalizer() {
        let probe = Probe()
        let (window, view) = makeWindow(probe)
        view.feed(text: "\u{1B}[?1h\u{1B}=")
        #expect(view.terminalInputStateSnapshot()?.applicationKeypad == true)

        guard let event = keypadEvent("5", key: 87, in: window) else {
            Issue.record("构造不出小键盘事件")
            return
        }
        NSApplication.shared.sendEvent(event)
        #expect(probe.sent == Array("\u{1B}Ou".utf8))
    }

    /// 装上限定器后，同一个按键按普通字符送到 pty。
    @Test func normalizerSendsPlainDigitsAndEnter() {
        let probe = Probe()
        let (window, view) = makeWindow(probe)
        let normalizer = TerminalKeypadNormalizer(view: view)
        defer { normalizer.stop() }
        view.feed(text: "\u{1B}[?1h\u{1B}=")
        #expect(view.terminalInputStateSnapshot()?.applicationKeypad == true)
        probe.sent.removeAll()

        for (text, key) in [("1", UInt16(83)), ("2", 84), ("3", 85), ("+", 69), (".", 65)] {
            guard let event = keypadEvent(text, key: key, in: window) else {
                Issue.record("构造不出小键盘事件：\(text)")
                return
            }
            NSApplication.shared.sendEvent(event)
        }
        #expect(probe.sent == Array("123+.".utf8))

        probe.sent.removeAll()
        guard let enter = keypadEvent("\r", key: 76, in: window) else {
            Issue.record("构造不出小键盘回车")
            return
        }
        NSApplication.shared.sendEvent(enter)
        #expect(probe.sent == [0x0D])
    }

    /// 模式关着时行为不变；主键盘也不该被改写。
    @Test func normalizerLeavesTheMainKeyboardAlone() {
        let probe = Probe()
        let (window, view) = makeWindow(probe)
        let normalizer = TerminalKeypadNormalizer(view: view)
        defer { normalizer.stop() }
        view.feed(text: "\u{1B}>")

        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0
        ) else {
            Issue.record("构造不出按键事件")
            return
        }
        NSApplication.shared.sendEvent(event)
        #expect(probe.sent == [0x61])
    }
}
