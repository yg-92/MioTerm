import AppKit
import MioTermCore

/// 统一会话控制接口：终端（SSH / Telnet / 串口 / 本地 Shell）与图形桌面（VNC）
/// 共同遵循此协议，从而共用标签页、左右分屏、底部状态栏与重连提示条。
@MainActor
protocol SessionControlling: AnyObject {
    var sessionID: UUID { get }
    var host: HostProfile? { get }
    var sessionView: NSView { get }
    var state: TerminalController.State { get }
    var title: String { get }
    var tooltip: String { get }
    var context: TerminalContext { get }
    var workingDirectory: String? { get }
    var onTitleChange: ((String) -> Void)? { get set }
    var onFocus: (() -> Void)? { get set }

    func addStateObserver(_ observer: @escaping (TerminalController.State) -> Void) -> UUID
    func removeStateObserver(_ token: UUID?)
    func addContextObserver(_ observer: @escaping (TerminalContext) -> Void) -> UUID
    func removeContextObserver(_ token: UUID?)

    func applyTheme()
    func apply(_ settings: AppSettings)
    func focus()
    func stop()
    func failStart(reason: String)
}
