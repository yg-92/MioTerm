import Foundation
import MioTermCore
import Testing

@Suite("侧栏自动收起")
struct SidebarAutoCollapseTests {
    private let local = UUID()
    private let serial = UUID()
    private let ssh = UUID()

    @Test func sessionWithoutFilesCollapsesTheSidebarOnce() {
        var collapse = SidebarAutoCollapse()
        #expect(collapse.selectionChanged(sessionID: local, canBrowseFiles: false, isCollapsed: false) == true)
        // 同一次选中重复回调不该再动侧栏。
        #expect(collapse.selectionChanged(sessionID: local, canBrowseFiles: false, isCollapsed: true) == nil)
        // 换到另一个没有文件通道的会话，仍然要收起。
        #expect(collapse.selectionChanged(sessionID: serial, canBrowseFiles: false, isCollapsed: false) == true)
    }

    @Test func manualExpandIsNotTakenBack() {
        var collapse = SidebarAutoCollapse()
        #expect(collapse.selectionChanged(sessionID: local, canBrowseFiles: false, isCollapsed: false) == true)
        collapse.userToggled()
        // 用户手动展开后，同一会话的选中回调不能再把它收起。
        #expect(collapse.selectionChanged(sessionID: local, canBrowseFiles: false, isCollapsed: false) == nil)
        // 但偏好按手动状态记，不再是自动收起前那份。
        #expect(collapse.preferredCollapsed(current: false) == false)
    }

    @Test func sshSessionRestoresTheStateBeforeAutoCollapse() {
        var collapse = SidebarAutoCollapse()
        #expect(collapse.selectionChanged(sessionID: local, canBrowseFiles: false, isCollapsed: false) == true)
        #expect(collapse.selectionChanged(sessionID: ssh, canBrowseFiles: true, isCollapsed: true) == false)
        // 还原只发生一次，之后跟着用户的开合走。
        #expect(collapse.selectionChanged(sessionID: ssh, canBrowseFiles: true, isCollapsed: false) == nil)
    }

    @Test func alreadyCollapsedSidebarStaysCollapsed() {
        var collapse = SidebarAutoCollapse()
        #expect(collapse.selectionChanged(sessionID: serial, canBrowseFiles: false, isCollapsed: true) == true)
        #expect(collapse.selectionChanged(sessionID: ssh, canBrowseFiles: true, isCollapsed: true) == true)
    }

    @Test func homeDoesNotCollapseTheSidebar() {
        var collapse = SidebarAutoCollapse()
        // 主页没有会话，主机列表正是它的内容，不能收起。
        #expect(collapse.selectionChanged(sessionID: nil, canBrowseFiles: false, isCollapsed: false) == nil)
        #expect(collapse.selectionChanged(sessionID: local, canBrowseFiles: false, isCollapsed: false) == true)
        #expect(collapse.selectionChanged(sessionID: nil, canBrowseFiles: false, isCollapsed: true) == false)
    }

    @Test func autoCollapseIsNotPersistedAsPreference() {
        var collapse = SidebarAutoCollapse()
        _ = collapse.selectionChanged(sessionID: local, canBrowseFiles: false, isCollapsed: false)
        // 退出时侧栏是自动收起的，记进偏好的应该是收起前的“展开”。
        #expect(collapse.preferredCollapsed(current: true) == false)
        collapse.userToggled()
        #expect(collapse.preferredCollapsed(current: true) == true)
    }
}
