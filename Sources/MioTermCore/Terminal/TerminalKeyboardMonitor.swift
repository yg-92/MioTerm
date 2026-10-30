import AppKit

extension NSEvent {
    public var terminalKeyStroke: TerminalKeyStroke? {
        guard type == .keyDown else { return nil }
        var modifiers: TerminalKeyStroke.Modifiers = []
        if modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if modifierFlags.contains(.control) { modifiers.insert(.control) }
        if modifierFlags.contains(.option) { modifiers.insert(.option) }
        if modifierFlags.contains(.command) { modifiers.insert(.command) }
        return TerminalKeyStroke(characters: characters, keyCode: keyCode, modifiers: modifiers)
    }
}

/// 旁听终端窗口里的按键。
///
/// 不用 `TerminalViewDelegate.send`：新版 SwiftTerm 的本地进程视图把键盘字节
/// 直接写进 pty，委托回调收不到。事件监听只观察、不改写事件本身。
@MainActor
public final class TerminalKeyboardMonitor {
    private weak var view: NSView?
    private var monitor: Any?

    public init(view: NSView, onStroke: @escaping (TerminalKeyStroke) -> Void) {
        self.view = view
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let view = self.view,
                      event.window === view.window,
                      view.window?.firstResponder === view,
                      var stroke = event.terminalKeyStroke
                else { return }
                if let inputClient = view as? NSTextInputClient, inputClient.hasMarkedText() {
                    stroke.hasMarkedText = true
                }
                onStroke(stroke)
            }
            return event
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
