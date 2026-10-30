import Foundation

/// 一个按键里应用层能拿到的事实。
///
/// 为什么不让 SwiftTerm 回调字节：`LocalProcessTerminalView` 把键盘输入直接
/// 写进 pty（`inputSender.replaceDelivery`），不再经过 `TerminalViewDelegate.send`，
/// 宿主拿不到那些字节。SSH 与本地 shell 恰好都走这条路径，于是目录跟随与命令库
/// 曾整条静默——只有 Telnet/串口的会话还看得见键入。现在在窗口事件层旁听按键，
/// 把「这一下改了什么」翻译成命令还原器认识的字节。
public struct TerminalKeyStroke: Equatable, Sendable {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }

        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    /// 按键产生的文本；方向键、功能键之类可能为空。
    public var characters: String?
    /// AppKit 的虚拟键码，纯文本用不到，回车/退格/方向键靠它识别。
    public var keyCode: UInt16
    public var modifiers: Modifiers
    /// 输入法是否正处于预编辑（marked text）状态：此时按键与回车都归输入法消费，不能当成 shell 输入。
    public var hasMarkedText: Bool

    public init(
        characters: String?,
        keyCode: UInt16,
        modifiers: Modifiers = [],
        hasMarkedText: Bool = false
    ) {
        self.characters = characters
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.hasMarkedText = hasMarkedText
    }
}

public enum TerminalKeyEffect: Equatable {
    /// 可以当作真实键入喂给命令还原器。
    case bytes([UInt8])
    /// 这一下改了命令行，但改成了什么这里还原不出来：粘贴、历史、光标移动、输入法。
    case invalidatesLine
    /// 与命令行无关：复制等快捷键、Esc、功能键。
    case ignored
}

public enum TerminalKeyTranslator {
    /// AppKit 的键码：方向、翻页、Home/End 与向前删除。
    private static let navigationKeys: Set<UInt16> = [115, 116, 117, 119, 121, 123, 124, 125, 126]
    /// 私有区里的功能键（F1…F35、Insert、Help 等）。
    private static let functionKeyRange: ClosedRange<UInt32> = 0xF700...0xF8FF

    public static func translate(_ stroke: TerminalKeyStroke) -> TerminalKeyEffect {
        // 输入法正在合成候选词：字母键是拼音/字根，空格/回车是选词上屏，都不能当成直接发给终端的命令。
        if stroke.hasMarkedText {
            return .invalidatesLine
        }
        // Command 组合是应用快捷键，不是终端输入。只有粘贴会悄悄改写命令行。
        if stroke.modifiers.contains(.command) {
            return stroke.keyCode == 9 ? .invalidatesLine : .ignored
        }
        // Option 在终端里通常编码成 ESC 前缀，屏幕上的回显与字符本身对不上。
        if stroke.modifiers.contains(.option) {
            return .invalidatesLine
        }
        if navigationKeys.contains(stroke.keyCode) {
            // 上下键换历史、左右键挪光标、向前删除，都会让本端记的行脱节。
            return .invalidatesLine
        }
        if stroke.keyCode == 53 {
            return .ignored
        }
        if stroke.keyCode == 36 || stroke.keyCode == 76 {
            return .bytes([0x0D])
        }

        let text = stroke.characters ?? ""
        guard !text.isEmpty else { return .invalidatesLine }
        if text == "\r" || text == "\n" { return .bytes([0x0D]) }
        if let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1 {
            let value = scalar.value
            if functionKeyRange.contains(value) { return .ignored }
            if value < 0x20 {
                switch value {
                case 0x03, 0x04, 0x08, 0x0C, 0x15, 0x09:
                    return .bytes([UInt8(value)])
                default:
                    return .invalidatesLine
                }
            }
            if value == 0x7F { return .bytes([0x7F]) }
        }
        return .bytes(Array(text.utf8))
    }
}
