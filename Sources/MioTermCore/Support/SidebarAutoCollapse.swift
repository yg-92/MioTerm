import Foundation

/// 侧栏自动收起的状态机。
///
/// 本地 shell、串口、Telnet 都没有文件通道，侧栏只剩主机列表白占宽度，选中这类会话时
/// 自动收起；切回主页或能浏览文件的 SSH 会话时，还原自动收起之前的状态。
/// 每个会话只自动收起一次——用户手动展开后，同一次选中不该再把它抢回去。
public struct SidebarAutoCollapse {
    private var active = false
    private var restoreCollapsed = false
    private var collapsedSession: UUID?

    public init() {}

    /// 选中会话变化时调用。返回侧栏此刻应有的折叠态，`nil` 表示保持不动。
    /// - Parameters:
    ///   - sessionID: 当前会话；主页没有会话，传 nil。
    ///   - canBrowseFiles: 该会话能不能用文件面板。
    ///   - isCollapsed: 调用时侧栏的真实折叠态。
    public mutating func selectionChanged(sessionID: UUID?, canBrowseFiles: Bool, isCollapsed: Bool) -> Bool? {
        guard let sessionID, !canBrowseFiles else {
            guard active else { return nil }
            active = false
            collapsedSession = nil
            return restoreCollapsed
        }
        guard collapsedSession != sessionID else { return nil }
        collapsedSession = sessionID
        restoreCollapsed = isCollapsed
        active = true
        return true
    }

    /// 用户自己开合侧栏：还原值作废，之后以手动状态为准。
    /// 仍记着当前会话，免得同一次选中的后续回调又把它自动收回去。
    public mutating func userToggled() {
        active = false
    }

    /// 退出时要记住的偏好。自动收起是会话带来的临时状态，不能写进偏好，
    /// 否则下次启动侧栏就一直是收起的。
    public func preferredCollapsed(current: Bool) -> Bool {
        active ? restoreCollapsed : current
    }
}
