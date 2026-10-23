import AppKit
import MioTermCore

/// 主窗口：工具栏 + 工作区。窗口关闭只断开当前会话，不影响其它窗口，
/// 因此这里不主动 terminate 应用。
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate {
    private let workspace = WorkspaceViewController()
    private static let newTab = NSToolbarItem.Identifier("mio.newTab")
    private static let connect = NSToolbarItem.Identifier("mio.connect")
    private static let newHost = NSToolbarItem.Identifier("mio.newHost")
    private static let preferences = NSToolbarItem.Identifier("mio.preferences")
    private static let toggleSidebar = NSToolbarItem.Identifier("mio.toggleSidebar")
    private static let filePanel = NSToolbarItem.Identifier("mio.filePanel")

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 760, height: 420)
        window.setFrameAutosaveName("MioTermMainWindow")
        self.init(window: window)
        window.contentViewController = workspace
        window.title = "MioTerm"
        window.titleVisibility = .visible
        installToolbar()
        window.center()
    }

    private func installToolbar() {
        guard let window else { return }
        let toolbar = NSToolbar(identifier: "MioTermMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.selectedItemIdentifier = Self.newTab
        window.toolbar = toolbar
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var sessionsAreActive: Bool { workspace.hasActiveSessions }

    func closeSessions() { workspace.prepareForClose() }

    // MARK: - NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.newTab:
            return button(itemIdentifier, symbol: "plus", label: "新建标签", action: #selector(WorkspaceViewController.newLocalTerminal(_:)))
        case Self.connect:
            return button(itemIdentifier, symbol: "bolt", label: "连接所选主机", action: #selector(WorkspaceViewController.connectSelectedHost(_:)))
        case Self.newHost:
            return button(itemIdentifier, symbol: "smallcircle.filled.circle", label: "新增主机", action: #selector(WorkspaceViewController.newHost(_:)))
        case Self.preferences:
            return button(itemIdentifier, symbol: "gearshape", label: "设置", action: #selector(WorkspaceViewController.showPreferences(_:)))
        case Self.toggleSidebar:
            return button(itemIdentifier, symbol: "sidebar.left", label: "显示/隐藏侧栏", action: #selector(NSSplitViewController.toggleSidebar(_:)))
        case Self.filePanel:
            return button(itemIdentifier, symbol: "folder", label: "文件树", action: #selector(WorkspaceViewController.showFilePanel(_:)))
        default:
            return nil
        }
    }

    private func button(_ identifier: NSToolbarItem.Identifier, symbol: String, label: String, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
                             target: workspace,
                             action: action)
        button.bezelStyle = .texturedRounded
        button.setButtonType(.momentaryPushIn)
        item.view = button
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.toggleSidebar, Self.filePanel, .flexibleSpace, Self.newTab, Self.connect, Self.newHost, Self.preferences]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.toggleSidebar, Self.filePanel, Self.newTab, Self.connect, Self.newHost, Self.preferences, .space, .flexibleSpace]
    }
}
