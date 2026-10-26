import AppKit
import MioTermCore

/// 主窗口：工具栏 + 工作区。窗口关闭只断开当前会话，不影响其它窗口，
/// 因此这里不主动 terminate 应用。
/// 工具栏跟着右侧内容换：看终端时是“主页”，
/// 回到主页时才是“连接 / 新增主机”，避免在会话里点不到有用的动作。
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate {
    private let workspace = WorkspaceViewController()
    private static let actions = NSToolbarItem.Identifier("mio.actions")
    private static let home = NSToolbarItem.Identifier("mio.home")
    private static let connect = NSToolbarItem.Identifier("mio.connect")
    private static let newHost = NSToolbarItem.Identifier("mio.newHost")
    private static let toggleSidebar = NSToolbarItem.Identifier("mio.toggleSidebar")
    private static let appIcon = NSToolbarItem.Identifier("mio.appIcon")
    private var showingSession = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 780, height: 460)
        window.setFrameAutosaveName("MioTermMainWindow")
        window.backgroundColor = Theme.background
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        self.init(window: window)
        window.contentViewController = workspace
        // 赋 contentViewController 时窗口会缩到工作区的 fitting size，
        // 首次启动想要的是设计稿尺寸，已保存的窗口帧在后面恢复。
        window.setContentSize(NSSize(width: 1240, height: 780))
        window.title = "MioTerm"
        workspace.onPresentationChange = { [weak self] controller in
            self?.setSessionActive(controller != nil)
        }
        installToolbar()
        // 首次启动按设计尺寸来，但屏幕装不下时先缩到 visibleFrame 内，
        // 否则窗口底部（文件面板的跟随开关/状态行）会被屏幕边缘裁掉。
        if !window.setFrameUsingName("MioTermMainWindow") {
            let fitted = Self.fittedFrame(window.frame)
            if fitted != window.frame {
                window.setFrame(fitted, display: false)
            }
            window.center()
        } else {
            let fitted = Self.fittedFrame(window.frame)
            if fitted != window.frame {
                window.setFrame(fitted, display: false)
            }
        }
    }

    /// 把窗口框限制在这块屏幕的可视区域内，尺寸不够时整体缩小而不是露到屏幕外。
    private static func fittedFrame(_ frame: NSRect) -> NSRect {
        guard let visible = NSScreen.main?.visibleFrame else { return frame }
        var fitted = frame
        fitted.size.width = min(frame.width, visible.width)
        fitted.size.height = min(frame.height, visible.height)
        fitted.origin.x = min(max(frame.minX, visible.minX), visible.maxX - fitted.width)
        fitted.origin.y = min(max(frame.minY, visible.minY), visible.maxY - fitted.height)
        return fitted
    }

    private func installToolbar() {
        guard let window else { return }
        let toolbar = NSToolbar(identifier: "MioTermMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        applyToolbarItems(showSession: false)
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeSessions() { workspace.prepareForClose() }

    private func setSessionActive(_ active: Bool) {
        guard active != showingSession else { return }
        showingSession = active
        applyToolbarItems(showSession: active)
    }

    /// `NSToolbarItem` 没有“隐藏”，只能按当前上下文重建条目。
    private func applyToolbarItems(showSession: Bool) {
        guard let toolbar = window?.toolbar else { return }
        while !toolbar.items.isEmpty {
            toolbar.removeItem(at: 0)
        }
        let identifiers: [NSToolbarItem.Identifier] = showSession
            ? [Self.toggleSidebar, Self.home, .flexibleSpace, Self.actions, Self.appIcon]
            : [Self.toggleSidebar, Self.connect, Self.newHost, .flexibleSpace, Self.actions, Self.appIcon]
        for (index, identifier) in identifiers.enumerated() {
            toolbar.insertItem(withItemIdentifier: identifier, at: index)
        }
    }

    // MARK: - NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.actions:
            return actionClusterItem(itemIdentifier)
        case Self.home:
            return button(itemIdentifier, symbol: "house", label: "主页", action: #selector(WorkspaceViewController.showHome(_:)))
        case Self.connect:
            return button(itemIdentifier, symbol: "bolt", label: "连接所选主机", action: #selector(WorkspaceViewController.connectSelectedHost(_:)))
        case Self.newHost:
            return button(itemIdentifier, symbol: "plus.circle", label: "新增主机", action: #selector(WorkspaceViewController.newHost(_:)))
        case Self.toggleSidebar:
            let item = paletteItem(itemIdentifier, symbol: "sidebar.left", label: "显示/隐藏侧栏")
            item.action = #selector(NSSplitViewController.toggleSidebar(_:))
            return item
        case Self.appIcon:
            return brandItem(itemIdentifier)
        default:
            return nil
        }
    }

    /// 右上角动作合成一条玻璃胶囊：新建标签和设置都装进同一块系统材质里。
    private func actionClusterItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let newTabButton = glassButton(
            symbol: "plus",
            label: "新建标签",
            action: #selector(WorkspaceViewController.newLocalTerminal(_:))
        )
        let preferencesButton = glassButton(
            symbol: "gearshape",
            label: "设置",
            action: #selector(WorkspaceViewController.showPreferences(_:))
        )
        let row = NSStackView(views: [newTabButton, preferencesButton])
        row.orientation = .horizontal
        row.spacing = 3

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = GlassBarView(
            content: row,
            padding: NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        )
        item.label = "新建标签 / 设置"
        item.paletteLabel = "新建标签 / 设置"
        item.toolTip = "新建标签 / 设置"
        item.autovalidates = false
        return item
    }

    private func glassButton(symbol: String, label: String, action: Selector) -> GlassActionButton {
        let button = GlassActionButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.restingTint = Theme.textSecondary
        button.target = workspace
        button.action = action
        button.toolTip = label
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
        return button
    }

    /// 右上角的品牌图标只作标识，不参与点击与键盘导航。
    private func brandItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        // 复制一份再改尺寸：applicationIconImage 是全局对象，直接改会连带影响 Dock 与关于面板。
        let icon = NSApp.applicationIconImage?.copy() as? NSImage
        icon?.size = NSSize(width: 26, height: 26)
        let imageView = NSImageView()
        imageView.image = icon
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setFrameSize(NSSize(width: 26, height: 26))
        // 也套一层玻璃，让右上角整条都落在同一种材质上。
        item.view = GlassBarView(
            content: imageView,
            padding: NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        )
        item.label = "MioTerm"
        item.paletteLabel = "MioTerm"
        item.toolTip = "MioTerm"
        // 不设 isEnabled = false：禁用态会把图标压暗，反而显得灰扑扑的。
        item.autovalidates = false
        return item
    }

    private func button(_ identifier: NSToolbarItem.Identifier, symbol: String, label: String, action: Selector) -> NSToolbarItem {
        let item = paletteItem(identifier, symbol: symbol, label: label)
        item.target = workspace
        item.action = action
        return item
    }

    private func paletteItem(_ identifier: NSToolbarItem.Identifier, symbol: String, label: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.toggleSidebar, Self.connect, Self.newHost, .flexibleSpace, Self.actions, Self.appIcon]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.toggleSidebar, Self.home, Self.actions, Self.connect, Self.newHost, Self.appIcon, .space, .flexibleSpace]
    }
}
