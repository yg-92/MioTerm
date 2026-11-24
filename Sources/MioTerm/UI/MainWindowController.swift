import AppKit
import MioTermCore

/// 主窗口：工具栏 + 工作区。窗口关闭只断开当前会话，不影响其它窗口，
/// 因此这里不主动 terminate 应用。
/// 工具栏跟着右侧内容换：看终端时是“主页”，
/// 回到主页时才是“连接 / 新增主机”，避免在会话里点不到有用的动作。
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate {
    private let workspace = WorkspaceViewController()
    private let tintOverlayView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.isHidden = true
        return view
    }()
    private static let cgsMainConnectionID: (@convention(c) () -> UInt32)? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let sym = dlsym(handle, "CGSMainConnectionID") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) () -> UInt32).self)
    }()
    private static let cgsSetWindowBackgroundBlurRadius: (@convention(c) (UInt32, Int32, Int32) -> Int32)? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let sym = dlsym(handle, "CGSSetWindowBackgroundBlurRadius") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (UInt32, Int32, Int32) -> Int32).self)
    }()
    private static let pageActions = NSToolbarItem.Identifier("mio.pageActions")
    private static let actionsSpacer = NSToolbarItem.Identifier("mio.actionsSpacer")
    private static let windowActions = NSToolbarItem.Identifier("mio.windowActions")
    private var showingSession = false
    private var settingsObserver: NSObjectProtocol?
    private var opacityPreviewObserver: NSObjectProtocol?

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        if let opacityPreviewObserver {
            NotificationCenter.default.removeObserver(opacityPreviewObserver)
        }
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
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
        let rootController = MainWindowBackdropController(
            tintOverlay: tintOverlayView,
            content: workspace
        )
        rootController.onAppearanceChange = { [weak self] in
            guard let self else { return }
            let s = AppEnvironment.shared.settings.settings
            self.applyWindowOpacity(s.windowOpacity, blur: s.windowBackgroundBlur)
        }
        window.contentViewController = rootController
        // 赋 contentViewController 时窗口会缩到工作区的 fitting size，
        // 首次启动想要的是设计稿尺寸，已保存的窗口帧在后面恢复。
        window.setContentSize(NSSize(width: 1240, height: 780))
        window.title = "MioTerm"
        let initial = AppEnvironment.shared.settings.settings
        applyWindowOpacity(initial.windowOpacity, blur: initial.windowBackgroundBlur)
        workspace.onPresentationChange = { [weak self] controller in
            guard let self else { return }
            self.setSessionActive(controller != nil)
            let s = AppEnvironment.shared.settings.settings
            self.applyWindowOpacity(s.windowOpacity, blur: s.windowBackgroundBlur)
        }
        installToolbar()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .mioTermSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyToolbarItems()
                let s = AppEnvironment.shared.settings.settings
                self?.applyWindowOpacity(s.windowOpacity, blur: s.windowBackgroundBlur)
            }
        }
        opacityPreviewObserver = NotificationCenter.default.addObserver(
            forName: .mioTermWindowOpacityPreview,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let previewOpacity = notification.userInfo?["opacity"] as? Double
            let previewBlur = notification.userInfo?["blur"] as? Double
            MainActor.assumeIsolated {
                let s = AppEnvironment.shared.settings.settings
                let opacity = previewOpacity ?? s.windowOpacity
                let blur = previewBlur ?? s.windowBackgroundBlur
                self?.applyWindowOpacity(opacity, blur: blur)
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

    private func applyWindowOpacity(_ opacity: Double, blur: Double) {
        guard let window else { return }
        if opacity < 0.999 && blur > 0.001 {
            let effectiveAlpha = CGFloat(opacity)
            let radius = Int32(round(min(1.0, max(0.0, blur)) * 48.0))
            tintOverlayView.isHidden = false
            tintOverlayView.layer?.backgroundColor = Theme.layerColor(
                Theme.background.withAlphaComponent(effectiveAlpha),
                for: tintOverlayView
            )
            window.isOpaque = false
            window.backgroundColor = Theme.background.withAlphaComponent(0.001)
            window.alphaValue = 1.0
            workspace.applyFrameOpacity(effectiveAlpha, blur: CGFloat(blur))
            setWindowBlurRadius(radius)
            window.invalidateShadow()
            return
        }

        if workspace.isShowingDesktopSession {
            // 仅透明（无虚化）且处于 VNC/RDP 桌面会话时，保持远程桌面内部视图 100% 不透明，
            // 仅让外围框架继承透明度。
            setWindowBlurRadius(0)
            tintOverlayView.isHidden = true
            if opacity < 0.999 {
                window.alphaValue = 1.0
                window.isOpaque = false
                window.backgroundColor = Theme.background.withAlphaComponent(CGFloat(opacity))
                workspace.applyFrameOpacity(CGFloat(opacity), blur: 0)
            } else {
                window.isOpaque = true
                window.backgroundColor = Theme.background
                window.alphaValue = 1.0
                workspace.applyFrameOpacity(1.0, blur: 0)
            }
            window.invalidateShadow()
            return
        }

        setWindowBlurRadius(0)
        tintOverlayView.isHidden = true
        window.isOpaque = true
        window.backgroundColor = Theme.background
        window.alphaValue = CGFloat(opacity)
        workspace.applyFrameOpacity(1.0, blur: 0)
        window.invalidateShadow()
    }

    private func setWindowBlurRadius(_ radius: Int32) {
        guard let window, window.windowNumber > 0,
              let connFn = Self.cgsMainConnectionID,
              let blurFn = Self.cgsSetWindowBackgroundBlurRadius else { return }
        _ = blurFn(connFn(), Int32(window.windowNumber), radius)
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

    var workspaceController: WorkspaceViewController { workspace }

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
        let identifiers: [NSToolbarItem.Identifier] = [Self.pageActions, .flexibleSpace, Self.actionsSpacer, Self.windowActions]
        for (index, identifier) in identifiers.enumerated() {
            toolbar.insertItem(withItemIdentifier: identifier, at: index)
        }
    }

    // MARK: - NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.pageActions:
            return pageActionsItem(itemIdentifier)
        case Self.actionsSpacer:
            return spacerItem(itemIdentifier, width: 4)
        case Self.windowActions:
            return windowActionsItem(itemIdentifier)
        default:
            return nil
        }
    }

    private func spacerItem(_ identifier: NSToolbarItem.Identifier, width: CGFloat) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        view.heightAnchor.constraint(equalToConstant: 1).isActive = true
        item.view = view
        item.isEnabled = false
        item.autovalidates = false
        return item
    }

    /// 左侧：侧栏开关 + 随上下文变化的页面动作，统一收进一块玻璃。
    private func pageActionsItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 3
        row.addArrangedSubview(glassButton(
            symbol: "sidebar.left",
            label: L10n.tr(.toolbarToggleSidebar),
            action: #selector(NSSplitViewController.toggleSidebar(_:)),
            target: workspace
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
        }
        return glassItem(identifier, content: row, label: L10n.tr(.toolbarPageActionsGroup))
    }

    /// 右侧：新增主机、新建标签、命令库、设置和品牌图标放进同一块玻璃，避免一半有玻璃一半没有。
    private func windowActionsItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let newHost = glassButton(
            symbol: "plus",
            label: L10n.tr(.toolbarNewHost),
            action: #selector(WorkspaceViewController.newHost(_:)),
            target: workspace
        )
        let newTab = glassButton(
            symbol: "terminal",
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
        let credentials = glassButton(
            symbol: "key.fill",
            label: "凭据库",
            action: #selector(WorkspaceViewController.showCredentialLibrary(_:)),
            target: workspace
        )
        let preferences = glassButton(
            symbol: "gearshape",
            label: L10n.tr(.toolbarSettings),
            action: #selector(WorkspaceViewController.showPreferences(_:)),
            target: workspace
        )
        workspace.attachCommandAnchor(commands)
        let row = NSStackView(views: [newHost, newTab, commands, credentials, preferences, brandView()])
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

    /// 点击品牌图标返回主页。
    private func brandView() -> NSButton {
        // 复制一份再改尺寸：applicationIconImage 是全局对象，直接改会连带影响 Dock 与关于面板。
        let icon = NSApp.applicationIconImage?.copy() as? NSImage
        icon?.size = NSSize(width: 22, height: 22)
        let button = NSButton()
        button.image = icon
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyUpOrDown
        button.target = workspace
        button.action = #selector(WorkspaceViewController.showHome(_:))
        button.toolTip = L10n.tr(.toolbarHome)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 24),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
        return button
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.pageActions, .flexibleSpace, Self.actionsSpacer, Self.windowActions]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.pageActions, Self.actionsSpacer, Self.windowActions, .space, .flexibleSpace]
    }
}

/// 将全窗背景虚化视图铺在工作区下方，不干扰 `WorkspaceViewController` 的分栏布局。
@MainActor
private final class MainWindowBackdropController: NSViewController {
    private let tintOverlay: NSView
    private let content: NSViewController
    var onAppearanceChange: (() -> Void)?

    init(tintOverlay: NSView, content: NSViewController) {
        self.tintOverlay = tintOverlay
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    override func loadView() {
        let root = AppearanceAwareView(frame: NSRect(x: 0, y: 0, width: 1240, height: 780))
        root.onAppearanceChange = { [weak self] in self?.onAppearanceChange?() }
        addChild(content)
        tintOverlay.translatesAutoresizingMaskIntoConstraints = false
        content.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tintOverlay)
        root.addSubview(content.view)
        NSLayoutConstraint.activate([
            tintOverlay.topAnchor.constraint(equalTo: root.topAnchor),
            tintOverlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            tintOverlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tintOverlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            content.view.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            content.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        view = root
    }
}
