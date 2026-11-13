import AppKit
import MioTermCore

/// NSAlert 的 async 包装：有窗口时用模态表单，没有窗口（例如启动阶段）
/// 才退回阻塞式 runModal。
@MainActor
enum AlertPresenter {
    static func present(_ alert: NSAlert, in window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    /// 只有说明作用的提示，不等待用户。
    static func notify(title: String, message: String, `in` window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.tr(.commonOK))
        if let window {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }

    static func fail(title: String, message: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: L10n.tr(.commonOK))
        if let window {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }
}
