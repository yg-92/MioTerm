import AppKit
import Carbon.HIToolbox
import SwiftTerm

/// 数字小键盘 → 主键盘等价键。
///
/// 为什么宿主里要改写：zsh/oh-my-zsh 的 `zle-line-init` 会发 `smkx` 打开
/// application keypad 模式，终端于是把数字键盘编码成 `ESC O p`…`ESC O y`、
/// `ESC O M` 这类 SS3 序列。可 zsh 只发模式、并没有绑定这些序列，于是按数字键
/// 只会响铃，按小键盘回车也不会执行命令。把数字键盘还原成主键盘上的同名键，
/// 按键就总能打出字符；主键盘的 Shift/Control/Option 语义也一并沿用。
public enum TerminalKeypad {
    /// 小键盘键码 → 主键盘上打出同一字符的键码。
    /// 乘号、加号在主键盘上要 Shift，但这里只借用键位，字符仍取事件自带的。
    private static let mainKeyCode: [Int: Int] = [
        kVK_ANSI_Keypad0: kVK_ANSI_0,
        kVK_ANSI_Keypad1: kVK_ANSI_1,
        kVK_ANSI_Keypad2: kVK_ANSI_2,
        kVK_ANSI_Keypad3: kVK_ANSI_3,
        kVK_ANSI_Keypad4: kVK_ANSI_4,
        kVK_ANSI_Keypad5: kVK_ANSI_5,
        kVK_ANSI_Keypad6: kVK_ANSI_6,
        kVK_ANSI_Keypad7: kVK_ANSI_7,
        kVK_ANSI_Keypad8: kVK_ANSI_8,
        kVK_ANSI_Keypad9: kVK_ANSI_9,
        kVK_ANSI_KeypadDecimal: kVK_ANSI_Period,
        kVK_ANSI_KeypadDivide: kVK_ANSI_Slash,
        kVK_ANSI_KeypadMultiply: kVK_ANSI_8,
        kVK_ANSI_KeypadMinus: kVK_ANSI_Minus,
        kVK_ANSI_KeypadPlus: kVK_ANSI_Equal,
        kVK_ANSI_KeypadEquals: kVK_ANSI_Equal,
        kVK_ANSI_KeypadEnter: kVK_Return,
    ]

    /// 换成主键盘等价键；不是数字键盘、或带 Command/Option/Control 时原样交给视图。
    public static func mainKeyboardEvent(for event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let keyCode = mainKeyCode[Int(event.keyCode)] else { return nil }
        return NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags.subtracting(.numericPad),
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: event.context,
            characters: event.characters ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: UInt16(keyCode)
        )
    }
}

/// 在事件进入终端视图前改写数字小键盘。
///
/// 只在 application keypad 模式开着时改写：这时 SwiftTerm 本会把按键编成 SS3 序列，
/// 而多数 shell 收到后只会响铃；模式关着时视图本来就发字符，不必插手。
/// 和 `TerminalKeyboardMonitor` 一样只监听终端窗口里的按键，别处的数字键盘不受影响。
@MainActor
public final class TerminalKeypadNormalizer {
    private weak var view: TerminalView?
    private var monitor: Any?

    public init(view: TerminalView) {
        self.view = view
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let view = self.view,
                      event.window === view.window,
                      view.window?.firstResponder === view,
                      view.terminalInputStateSnapshot()?.applicationKeypad == true,
                      let replacement = TerminalKeypad.mainKeyboardEvent(for: event)
                else { return event }
                return replacement
            }
        }
    }

    public func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
