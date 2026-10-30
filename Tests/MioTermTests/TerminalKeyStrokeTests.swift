import Testing
@testable import MioTermCore

/// SSH/本地 shell 的键盘字节由 SwiftTerm 内部直接写进 pty，应用只能从窗口事件
/// 旁听按键。这一层负责把按键事实翻回命令还原器认识的字节或「不可信」标记。
struct TerminalKeyStrokeTests {
    private func key(
        _ text: String?,
        code: UInt16 = 0,
        modifiers: TerminalKeyStroke.Modifiers = []
    ) -> TerminalKeyEffect {
        TerminalKeyTranslator.translate(
            TerminalKeyStroke(characters: text, keyCode: code, modifiers: modifiers)
        )
    }

    @Test func printableTextIsUtf8() {
        #expect(key("l") == .bytes([0x6C]))
        #expect(key("L") == .bytes([0x4C]))
        #expect(key(" ") == .bytes([0x20]))
        #expect(key("中") == .bytes(Array("中".utf8)))
    }

    @Test func returnAndKeypadEnterSubmit() {
        #expect(key("\r", code: 36) == .bytes([0x0D]))
        #expect(key("\r", code: 76) == .bytes([0x0D]))
        #expect(key(nil, code: 36) == .bytes([0x0D]))
    }

    @Test func editingKeysKeepTheLineInSync() {
        #expect(key("\u{7F}", code: 51) == .bytes([0x7F]))
        #expect(key("\u{08}", code: 51, modifiers: [.control]) == .bytes([0x08]))
        #expect(key("\u{09}", code: 48) == .bytes([0x09]))
        #expect(key("\u{03}", code: 8, modifiers: [.control]) == .bytes([0x03]))
        #expect(key("\u{0C}", code: 37, modifiers: [.control]) == .bytes([0x0C]))
        #expect(key("\u{15}", code: 32, modifiers: [.control]) == .bytes([0x15]))
    }

    @Test func markedTextDuringIMECompositionInvalidatesAndNeverSubmits() {
        #expect(
            TerminalKeyTranslator.translate(
                TerminalKeyStroke(characters: "z", keyCode: 6, hasMarkedText: true)
            ) == .invalidatesLine
        )
        // 输入法预编辑状态下按回车只是把英文串上屏，不能当成 shell 回车提交。
        #expect(
            TerminalKeyTranslator.translate(
                TerminalKeyStroke(characters: "\r", keyCode: 36, hasMarkedText: true)
            ) == .invalidatesLine
        )
    }

    @Test func lineRewritingActionsInvalidateTheLine() {
        // 上下键换历史、左右键挪光标、向前删除：本端记的行跟着脱节。
        #expect(key("\u{F700}", code: 126) == .invalidatesLine)
        #expect(key("\u{F702}", code: 123) == .invalidatesLine)
        #expect(key("\u{F728}", code: 117) == .invalidatesLine)
        // Ctrl+A 把光标挪到行首，后续键入的位置对不上。
        #expect(key("\u{01}", code: 0, modifiers: [.control]) == .invalidatesLine)
        // Option 在终端里编成 ESC 前缀，屏幕回显与字符本身不一致。
        #expect(key("å", code: 0, modifiers: [.option]) == .invalidatesLine)
        // 输入法合成中的空按键。
        #expect(key("", code: 0) == .invalidatesLine)
    }

    @Test func applicationShortcutsAreNotTerminalInput() {
        #expect(key("c", code: 8, modifiers: [.command]) == .ignored)
        #expect(key("q", code: 12, modifiers: [.command]) == .ignored)
        // 粘贴会悄悄改写命令行，但内容拿不到。
        #expect(key("v", code: 9, modifiers: [.command]) == .invalidatesLine)
    }

    @Test func escapeAndFunctionKeysDoNotTouchTheLine() {
        #expect(key("\u{1B}", code: 53) == .ignored)
        #expect(key("\u{F704}", code: 122) == .ignored)
    }
}
