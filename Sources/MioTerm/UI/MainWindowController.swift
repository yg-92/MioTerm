import AppKit
import MioTermCore

/// 主窗口：工具栏 + 工作区。窗口关闭只断开当前会话，不影响其它窗口，
/// 因此这里不主动 terminate 应用。
/// 工具栏跟着右侧内容换：看终端时是“主页”，
/// 回到主页时才是“连接 / 新增主机”，避免在会话里点不到有用的动作。
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate {
    private let workspace = WorkspaceViewController()
    private static let pageActions = NSToolbarItem.Identifier("mio.pageActions")
    private static let windowActions = NSToolbarItem.Identifier("mio.windowActions")
    private var showingSession = false
    private var settingsObserver: NSObjectProtocol?

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

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
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .mioTermSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyToolbarItems()
            }
        }
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
        applyToolbarItems()
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
        applyToolbarItems()
    }

    /// `NSToolbarItem` 没有“隐藏”，只能按当前上下文重建条目。
    private func applyToolbarItems() {
        guard let toolbar = window?.toolbar else { return }
        while !toolbar.items.isEmpty {
            toolbar.removeItem(at: 0)
        }
        let identifiers: [NSToolbarItem.Identifier] = [Self.pageActions, .flexibleSpace, Self.windowActions]
        for (index, identifier) in identifiers.enumerated() {
            toolbar.insertItem(withItemIdentifier: identifier, at: index)
        }
    }

    // MARK: - NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.pageActions:
            return pageActionsItem(itemIdentifier)
        case Self.windowActions:
            return windowActionsItem(itemIdentifier)
        default:
            return nil
        }
    }

    /// 左侧：侧栏开关 + 随上下文变化的页面动作，统一收进一块玻璃。
    private func pageActionsItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 3
        row.addArrangedSubview(glassButton(
            symbol: "sidebar.left",
            label: L10n.tr(.toolbarToggleSidebar),
            action: #selector(NSSplitViewController.toggleSidebar(_:))
        ))
        if showingSession {
            row.addArrangedSubview(glassButton(
                symbol: "house",
                label: L10n.tr(.toolbarHome),
                action: #selector(WorkspaceViewController.showHome(_:)),
                target: workspace
            ))
        } else {
            row.addArrangedSubview(glassButton(
                symbol: "bolt",
                label: L10n.tr(.toolbarConnect),
                action: #selector(WorkspaceViewController.connectSelectedHost(_:)),
                target: workspace
            ))
            row.addArrangedSubview(glassButton(
                symbol: "plus.circle",
                label: L10n.tr(.toolbarNewHost),
                action: #selector(WorkspaceViewController.newHost(_:)),
                target: workspace
            ))
        }
        return glassItem(identifier, content: row, label: L10n.tr(.toolbarPageActionsGroup))
    }

    /// 右侧：命令库、新建标签、设置和品牌图标放进同一块玻璃，避免一半有玻璃一半没有。
    private func windowActionsItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let newTab = glassButton(
            symbol: "plus",
            label: L10n.tr(.toolbarLocalTerminal),
            action: #selector(WorkspaceViewController.newLocalTerminal(_:)),
            target: workspace
        )
        let commands = glassButton(
            symbol: "command",
            label: L10n.tr(.toolbarCommandLibrary),
            action: #selector(WorkspaceViewController.showCommandLibrary(_:)),
            target: workspace
        )
        let preferences = glassButton(
            symbol: "gearshape",
            label: L10n.tr(.toolbarSettings),
            action: #selector(WorkspaceViewController.showPreferences(_:)),
            target: workspace
        )
        workspace.attachCommandAnchor(commands)
        let row = NSStackView(views: [newTab, commands, preferences, brandView()])
        row.orientation = .horizontal
        row.spacing = 3
        row.setCustomSpacing(7, after: preferences)
        return glassItem(identifier, content: row, label: L10n.tr(.toolbarWindowActionsGroup))
    }

    private func glassItem(
        _ identifier: NSToolbarItem.Identifier,
        content: NSView,
        label: String
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = GlassBarView(
            content: content,
            padding: NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        )
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.autovalidates = false
        return item
    }

    private func glassButton(
        symbol: String,
        label: String,
        action: Selector,
        target: AnyObject? = nil
    ) -> GlassActionButton {
        let button = GlassActionButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.restingTint = Theme.textSecondary
        button.target = target
        button.action = action
        button.toolTip = label
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
        return button
    }

    /// 品牌图标只作标识，不参与点击与键盘导航。
    private func brandView() -> NSImageView {
        // 复制一份再改尺寸：applicationIconImage 是全局对象，直接改会连带影响 Dock 与关于面板。
        let icon = NSApp.applicationIconImage?.copy() as? NSImage
        icon?.size = NSSize(width: 22, height: 22)
        let imageView = NSImageView()
        imageView.image = icon
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.toolTip = "MioTerm"
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 22),
            imageView.heightAnchor.constraint(equalToConstant: 22),
        ])
        return imageView
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.pageActions, .flexibleSpace, Self.windowActions]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.pageActions, Self.windowActions, .space, .flexibleSpace]
    }
}
