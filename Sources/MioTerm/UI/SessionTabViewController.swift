import AppKit
import MioTermCore

/// 右侧主区：顶部标签栏 + 内容。主页是第一个固定标签，
/// 点它回到欢迎页与主机列表，后台会话照常运行；会话标签承担切换与关闭。
/// 以前靠 NSTabViewController 的隐藏标签栏，只能从菜单切会话，
/// 自绘标签栏后才能把“主页 / 会话 / 新建”摆在同一个视线里。
@MainActor
final class SessionTabViewController: NSViewController {
    private var environment: AppEnvironment { .shared }

    /// 外层要同时知道“选中了哪个会话”和“还剩几个标签”：
    /// 侧栏模式、标题栏与工具栏都靠这一个回调。
    var onSessionsChange: ((TerminalController?) -> Void)?
    /// 断线后的“重新连接”：工作区负责重建传输，标签这边只负责把入口露出来。
    var onReconnect: ((TerminalController) -> Void)?
    private let tabBar = SessionTabBarView()
    private let content = ContainerViewController()
    private let statusBar = TerminalStatusBarView()
    private let welcome = WelcomeViewController()
    private var order: [TerminalController] = []
    private var tabControllers: [UUID: TerminalTabViewController] = [:]
    private var modeTokens: [UUID: UUID] = [:]
    private var selectedIndex: Int?

    private var contentTopToBar: NSLayoutConstraint!
    private var contentTopToRoot: NSLayoutConstraint!

    var selectedController: TerminalController? {
        guard let selectedIndex, order.indices.contains(selectedIndex) else { return nil }
        return order[selectedIndex]
    }

    var controllers: [TerminalController] { order }
    var isEmpty: Bool { order.isEmpty }
    var isShowingHome: Bool { selectedIndex == nil }

    override func loadView() {
        let root = AppearanceAwareView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.layerColor(Theme.background, for: root)
        root.onAppearanceChange = { [weak self] in self?.refreshAppearance() }
        view = root

        addChild(content)
        let contentView = content.view
        contentView.translatesAutoresizingMaskIntoConstraints = false
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentView)
        root.addSubview(tabBar)
        root.addSubview(statusBar)

        contentTopToBar = contentView.topAnchor.constraint(equalTo: tabBar.bottomAnchor)
        contentTopToRoot = contentView.topAnchor.constraint(equalTo: root.topAnchor)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: SessionTabBarView.height),
            contentView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: TerminalStatusBarView.height),
        ])
        contentTopToBar.isActive = false
        contentTopToRoot.isActive = true

        tabBar.onSelect = { [weak self] index in self?.select(index) }
        tabBar.onClose = { [weak self] index in _ = self?.closeTab(at: index) }
        tabBar.onNew = { [weak self] in self?.newLocalTerminal() }
        content.show(welcome)
        updateChrome()
    }

    func append(_ controller: TerminalController) {
        order.append(controller)
        let tab = TerminalTabViewController(controller: controller)
        tab.onReconnect = { [weak self] controller in self?.onReconnect?(controller) }
        tabControllers[controller.sessionID] = tab
        controller.onTitleChange = { [weak self] _ in self?.refreshTabs() }
        controller.onStateChange = { [weak self, weak controller] _ in
            guard let self else { return }
            self.refreshTabs()
            // 断线提示条跟着状态走：会话一起来就收起，不要等用户切标签。
            if let controller {
                self.tabControllers[controller.sessionID]?.updateConnectionState()
            }
        }
        // 顶部模式徽标跟着“当前选中标签”走：别的标签在后台进出容器不该改这里的显示。
        modeTokens[controller.sessionID] = controller.addContextObserver { [weak self, weak controller] context in
            guard let self, let controller, self.selectedController === controller else { return }
            self.tabBar.update(mode: context.mode)
            self.updateStatusBar()
        }
        select(order.count - 1)
    }

    /// 关闭当前选中的会话。主页上没有“当前会话”，所以什么都不做。
    @discardableResult
    func closeSelectedTab() -> Bool {
        guard let selectedIndex else { return false }
        return closeTab(at: selectedIndex)
    }

    func closeTab(at index: Int) -> Bool {
        guard order.indices.contains(index) else { return false }
        let controller = order[index]
        controller.stop()
        controller.removeContextObserver(modeTokens.removeValue(forKey: controller.sessionID))
        environment.unregister(controller)
        order.remove(at: index)
        tabControllers[controller.sessionID] = nil

        if order.isEmpty {
            select(nil)
            return true
        }
        if let selectedIndex {
            if index < selectedIndex {
                select(selectedIndex - 1)
            } else if index == selectedIndex {
                select(min(index, order.count - 1))
            } else {
                refreshTabs()
            }
        } else {
            refreshTabs()
        }
        return true
    }

    func closeAll() {
        for controller in order {
            controller.stop()
            controller.removeContextObserver(modeTokens.removeValue(forKey: controller.sessionID))
            environment.unregister(controller)
        }
        modeTokens.removeAll()
        order.removeAll()
        tabControllers.removeAll()
        select(nil)
    }

    func selectNextTab() {
        guard !order.isEmpty else { return }
        select(((selectedIndex ?? -1) + 1) % order.count)
    }

    func selectPreviousTab() {
        guard !order.isEmpty else { return }
        select(selectedIndex == nil ? order.count - 1 : ((selectedIndex ?? 0) - 1 + order.count) % order.count)
    }

    /// ⌘1…⌘9：序号从 0 开始，越界时什么都不做。
    func selectTab(at index: Int) {
        guard order.indices.contains(index) else { return }
        select(index)
    }

    /// 回到欢迎页 + 主机列表，标签与后台会话原样保留。
    func showHome() {
        select(nil)
    }

    func select(controller: TerminalController) {
        guard let index = order.firstIndex(where: { $0 === controller }) else { return }
        select(index)
    }

    private func select(_ index: Int?) {
        selectedIndex = index
        if let index, order.indices.contains(index) {
            let controller = order[index]
            if let tab = tabControllers[controller.sessionID] {
                content.show(tab)
            }
            updateChrome()
            controller.focus()
            onSessionsChange?(controller)
        } else {
            clearTerminalFocus()
            content.show(welcome)
            updateChrome()
            onSessionsChange?(nil)
        }
    }

    /// 收起终端时把第一响应者摘掉，否则键盘事件还会往已经离开层级的视图里送。
    private func clearTerminalFocus() {
        guard let responder = view.window?.firstResponder as? NSView,
              tabControllers.values.contains(where: { $0.controller.terminalView === responder })
        else { return }
        view.window?.makeFirstResponder(nil)
    }

    private func refreshTabs() {
        updateChrome()
    }

    private func updateChrome() {
        let entries = order.map { controller in
            SessionTabBarView.Tab(
                title: controller.state.isAlive ? controller.title : "\(controller.title) — \(controller.state.label)",
                state: controller.state,
                tooltip: controller.tooltip
            )
        }
        tabBar.update(tabs: entries, selected: selectedIndex)
        // 主页没有“终端环境”，徽标收起来；选中会话时显示它此刻在哪种 shell 里。
        tabBar.update(mode: selectedController?.context.mode)
        let hasTabs = !order.isEmpty
        tabBar.isHidden = !hasTabs
        contentTopToBar.isActive = hasTabs
        contentTopToRoot.isActive = !hasTabs
        updateStatusBar()
    }

    /// 脚部常驻，主页上只留右下角的版本号；选中会话后补上连接状态、主机与目录。
    private func updateStatusBar() {
        statusBar.update(selectedController)
    }

    private func newLocalTerminal() {
        let controller = TerminalController(host: nil, settings: environment.settings.settings)
        environment.register(controller)
        controller.startLocalShell()
        append(controller)
    }

    /// 图层颜色在赋值时就固化成 CGColor，深浅切换后要重新取一次。
    private func refreshAppearance() {
        view.layer?.backgroundColor = Theme.layerColor(Theme.background, for: view)
        tabBar.refreshAppearance()
        statusBar.refreshAppearance()
    }
}

// MARK: - 标签栏

/// 标签栏只能横向滚动，而普通鼠标滚轮只产生纵向增量，NSScrollView 会直接忽略，
/// 标签一多后半排就永远够不着。这里把主导轴的增量换成横向位移。
@MainActor
private final class TabBarScrollView: NSScrollView {
    var onScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        let clip = contentView
        let maxX = max(0, (documentView?.frame.width ?? 0) - clip.bounds.width)
        guard maxX > 0 else { return super.scrollWheel(with: event) }
        let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX
            : event.scrollingDeltaY
        guard delta != 0 else { return super.scrollWheel(with: event) }
        let x = min(max(clip.bounds.origin.x - delta, 0), maxX)
        clip.scroll(to: NSPoint(x: x, y: 0))
        reflectScrolledClipView(clip)
        onScroll?()
    }
}

/// 顶部标签栏：主页 + 会话标签 + 新建按钮。标签多时可以横向滚动。
@MainActor
final class SessionTabBarView: NSView {
    struct Tab {
        let title: String
        let state: TerminalController.State
        let tooltip: String
    }

    static let height: CGFloat = 44

    var onSelect: ((Int?) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNew: (() -> Void)?

    private let scrollView = TabBarScrollView()
    private let documentView = NSView()
    private let stack = NSStackView()
    private let plusButton = NSButton()
    private let modeBadge = TerminalModeBadge()
    private let rightStack = NSStackView()
    private let leftStack = NSStackView()
    private let leftScrollButton = NSButton()
    private let rightScrollButton = NSButton()
    private let separator = NSView()
    private var documentWidth: NSLayoutConstraint!
    private lazy var homeChip = SessionTabChip(
        title: "主页", symbol: "house.fill", symbolColor: Theme.accent,
        closable: false, fixedWidth: 84
    )
    private var chips: [SessionTabChip] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.layerColor(Theme.tabBar, for: self)
        build()
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    private func build() {
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.onScroll = { [weak self] in self?.updateScrollButtons() }
        addSubview(scrollView)

        for (button, symbol, tip, action) in [
            (leftScrollButton, "chevron.left", "向左滚动标签", #selector(scrollTabsLeft(_:))),
            (rightScrollButton, "chevron.right", "向右滚动标签", #selector(scrollTabsRight(_:))),
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.isBordered = false
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = Theme.textSecondary
            button.toolTip = tip
            button.target = self
            button.action = action
            button.isHidden = true
            button.translatesAutoresizingMaskIntoConstraints = false
        }

        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.spacing = 4
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        // 主页固定在标签栏最左侧：标签再多、滚得再远，回主页的入口始终在第一格。
        leftStack.addArrangedSubview(homeChip)
        leftStack.addArrangedSubview(leftScrollButton)
        addSubview(leftStack)

        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.wantsLayer = true
        scrollView.documentView = documentView

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        homeChip.onSelect = { [weak self] in self?.onSelect?(nil) }

        plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "新建本地终端")
        plusButton.isBordered = false
        plusButton.imageScaling = .scaleProportionallyDown
        plusButton.contentTintColor = Theme.textSecondary
        plusButton.toolTip = "新建本地终端"
        plusButton.target = self
        plusButton.action = #selector(newTab(_:))
        plusButton.translatesAutoresizingMaskIntoConstraints = false

        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = 6
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.addArrangedSubview(rightScrollButton)
        rightStack.addArrangedSubview(modeBadge)
        rightStack.addArrangedSubview(plusButton)
        addSubview(rightStack)

        separator.wantsLayer = true
        separator.layer?.backgroundColor = Theme.layerColor(Theme.border, for: self)
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            leftStack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            leftScrollButton.widthAnchor.constraint(equalToConstant: 22),
            leftScrollButton.heightAnchor.constraint(equalToConstant: 26),

            scrollView.leadingAnchor.constraint(equalTo: leftStack.trailingAnchor, constant: 4),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rightStack.leadingAnchor, constant: -6),

            rightStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            rightStack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            rightScrollButton.widthAnchor.constraint(equalToConstant: 22),
            rightScrollButton.heightAnchor.constraint(equalToConstant: 26),
            plusButton.widthAnchor.constraint(equalToConstant: 24),
            plusButton.heightAnchor.constraint(equalToConstant: 24),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            documentView.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),

            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 4),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -7),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor, constant: -8),
        ])
        documentWidth = documentView.widthAnchor.constraint(equalToConstant: 0)
        documentWidth.isActive = true
    }

    /// 标签总宽超过可视区域才让文档视图变宽，不够时铺满，避免整条栏抖动。
    override func layout() {
        super.layout()
        let needed = stack.fittingSize.width + 16
        let target = max(needed, scrollView.contentView.bounds.width)
        if abs(documentWidth.constant - target) > 0.5 {
            documentWidth.constant = target
        }
        updateScrollButtons()
    }

    /// 只在溢出时露出两端箭头；不溢出就把宽度还给标签。
    /// 判定用“箭头收起后”的宽度：否则箭头一旦出现，可视区变窄，刚够放下的标签
    /// 也会一直判成溢出，箭头再也收不回去。
    private func updateScrollButtons() {
        let visible = scrollView.contentView.bounds.width
        let needed = stack.fittingSize.width + 16
        let arrowRoom: CGFloat = 22 + 4 + 22 + 6
        let room = visible + (leftScrollButton.isHidden ? 0 : arrowRoom)
        let scrollable = needed > room + 0.5
        if leftScrollButton.isHidden == scrollable {
            leftScrollButton.isHidden = !scrollable
            rightScrollButton.isHidden = !scrollable
        }
        guard scrollable else {
            // 关掉标签后可能不再溢出，滚过头的位移要收回，否则会剩一片空白。
            let clip = scrollView.contentView
            if clip.bounds.origin.x != 0 {
                clip.scroll(to: .zero)
                scrollView.reflectScrolledClipView(clip)
            }
            return
        }
        let maxX = max(0, (scrollView.documentView?.frame.width ?? 0) - visible)
        let x = scrollView.contentView.bounds.origin.x
        leftScrollButton.isEnabled = x > 0.5
        rightScrollButton.isEnabled = x < maxX - 0.5
    }

    @objc private func scrollTabsLeft(_ sender: Any?) {
        scrollTabs(by: -1)
    }

    @objc private func scrollTabsRight(_ sender: Any?) {
        scrollTabs(by: 1)
    }

    /// 一次翻过大约一屏，保留一点重叠，用户不会瞬间失去当前位置。
    private func scrollTabs(by direction: CGFloat) {
        let clip = scrollView.contentView
        let maxX = max(0, (scrollView.documentView?.frame.width ?? 0) - clip.bounds.width)
        guard maxX > 0 else { return }
        let step = max(160, clip.bounds.width * 0.72)
        let target = min(max(clip.bounds.origin.x + direction * step, 0), maxX)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(NSPoint(x: target, y: 0))
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.updateScrollButtons() }
        }
    }

    func update(tabs: [Tab], selected: Int?) {
        for chip in chips {
            stack.removeArrangedSubview(chip)
            chip.removeFromSuperview()
        }
        chips = tabs.enumerated().map { index, tab in
            let chip = SessionTabChip(
                title: tab.title, symbol: nil, symbolColor: Theme.color(for: tab.state),
                closable: true, fixedWidth: nil
            )
            chip.toolTip = "\(tab.tooltip)\n单击切换，× 关闭"
            chip.onSelect = { [weak self] in self?.onSelect?(index) }
            chip.onClose = { [weak self] in self?.onClose?(index) }
            chip.setSelected(index == selected)
            stack.addArrangedSubview(chip)
            return chip
        }
        homeChip.setSelected(selected == nil)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let selected, self.chips.indices.contains(selected) {
                let chip = self.chips[selected]
                chip.scrollToVisible(chip.bounds)
            }
            self.updateScrollButtons()
        }
    }

    @objc private func newTab(_ sender: Any?) {
        onNew?()
    }

    /// nil 表示主页：没有终端环境可显示，徽标收起。
    func update(mode: TerminalMode?) {
        modeBadge.update(mode)
    }

    func refreshAppearance() {
        layer?.backgroundColor = Theme.layerColor(Theme.tabBar, for: self)
        separator.layer?.backgroundColor = Theme.layerColor(Theme.border, for: self)
        plusButton.contentTintColor = Theme.textSecondary
        leftScrollButton.contentTintColor = Theme.textSecondary
        rightScrollButton.contentTintColor = Theme.textSecondary
        homeChip.refreshAppearance()
        for chip in chips {
            chip.refreshAppearance()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }
}

/// 正圆状态点。`circle.fill` 这类符号的对齐矩形不是正方形，小尺寸下会被画扁；
/// 直接铺一层圆形图层，圆角跟着实际尺寸走，任何大小都是正圆。
@MainActor
final class StatusDotView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }
}

/// 单个标签：状态点或图标 + 标题 + 关闭按钮。选中与悬停各有自己的底色。
@MainActor
final class SessionTabChip: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let icon = NSImageView()
    private let statusDot = StatusDotView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let closable: Bool
    private let symbol: String?
    private let symbolColor: NSColor
    private var selected = false
    private var hovering = false
    private var trackingArea: NSTrackingArea?

    init(title: String, symbol: String?, symbolColor: NSColor, closable: Bool, fixedWidth: CGFloat?) {
        self.closable = closable
        self.symbol = symbol
        self.symbolColor = symbolColor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        icon.image = symbol.flatMap { Self.iconImage(symbol: $0, color: symbolColor) }
        icon.contentTintColor = symbolColor
        icon.imageScaling = .scaleProportionallyDown
        icon.isHidden = symbol == nil
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        statusDot.isHidden = symbol != nil
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusDot)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭标签")
        closeButton.isBordered = false
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.contentTintColor = Theme.textTertiary
        closeButton.target = self
        closeButton.action = #selector(closeTapped(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),
            // 圆点占住图标原本的视觉中心，标题的起点不用跟着变。
            statusDot.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            statusDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])

        if closable {
            NSLayoutConstraint.activate([
                widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
                widthAnchor.constraint(lessThanOrEqualToConstant: 230),
                titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
                closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            ])
        } else {
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: fixedWidth ?? 84),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            ])
        }
        closeButton.isHidden = true
        refreshAppearance()
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    func setSelected(_ selected: Bool) {
        self.selected = selected
        updateAppearance()
    }

    func refreshAppearance() {
        icon.image = symbol.flatMap { Self.iconImage(symbol: $0, color: symbolColor) }
        icon.contentTintColor = symbolColor
        statusDot.layer?.backgroundColor = Theme.layerColor(symbolColor, for: self)
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.backgroundColor = selected
            ? Theme.layerColor(Theme.selectedTab, for: self)
            : (hovering ? Theme.layerColor(Theme.hoverFill, for: self) : NSColor.clear.cgColor)
        titleLabel.textColor = selected ? Theme.textPrimary : Theme.textSecondary
        closeButton.isHidden = !closable || !(selected || hovering)
        closeButton.contentTintColor = hovering ? Theme.textPrimary : Theme.textTertiary
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    @objc private func closeTapped(_ sender: Any?) {
        onClose?()
    }

    private static func iconImage(symbol: String, color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return nil }
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return base.withSymbolConfiguration(configuration) ?? base
    }
}

/// 承载单个终端视图的标签内容控制器。
/// 断线后终端顶部浮出一条“重新连接”，入口跟着会话走，不用去菜单里找。
@MainActor
final class TerminalTabViewController: NSViewController {
    let controller: TerminalController
    var onReconnect: ((TerminalController) -> Void)?

    private let banner = ReconnectBannerView()

    init(controller: TerminalController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    override func loadView() {
        let container = AppearanceAwareView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        container.wantsLayer = true
        container.layer?.backgroundColor = Theme.layerColor(Theme.terminalBackground, for: container)
        container.onAppearanceChange = { [weak self] in self?.refreshAppearance() }
        controller.terminalView.frame = container.bounds
        controller.terminalView.autoresizingMask = [.width, .height]
        container.addSubview(controller.terminalView)

        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.isHidden = true
        banner.onReconnect = { [weak self] in
            guard let self else { return }
            self.onReconnect?(self.controller)
        }
        container.addSubview(banner)
        // 主区最窄也有 480pt，360 的提示条放得下；万一被压得更窄，让它让步而不是报冲突。
        let preferredWidth = banner.widthAnchor.constraint(equalToConstant: 360)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            banner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            preferredWidth,
            banner.heightAnchor.constraint(equalToConstant: 38),
            banner.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -24),
        ])
        view = container
        updateConnectionState()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        controller.focus()
        updateConnectionState()
    }

    /// 只在主机会话结束时提示；本地 shell 的 `exit` 是用户主动结束，不该劝人重连。
    func updateConnectionState() {
        guard isViewLoaded else { return }
        guard controller.host != nil else {
            banner.isHidden = true
            return
        }
        switch controller.state {
        case .exited(let code):
            banner.show(title: code == 0 ? "会话已结束" : "连接已断开",
                        detail: code.flatMap { $0 == 0 ? nil : "退出码 \($0)" })
            banner.isHidden = false
        case .failed(let reason):
            banner.show(title: "连接失败", detail: reason)
            banner.isHidden = false
        default:
            banner.isHidden = true
        }
    }

    private func refreshAppearance() {
        view.layer?.backgroundColor = Theme.layerColor(Theme.terminalBackground, for: view)
        banner.refreshAppearance()
        controller.applyTheme()
    }
}

/// 断线提示条：浮在终端顶部，不占终端尺寸，也不挡底部最后几行输出。
@MainActor
private final class ReconnectBannerView: NSView {
    var onReconnect: (() -> Void)?

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let action = ReconnectActionButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        icon.image = NSImage(systemSymbolName: "bolt.slash.fill", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        for label in [titleLabel, detailLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.isHidden = true

        action.onTap = { [weak self] in self?.onReconnect?() }
        action.toolTip = "重新建立连接，保留当前标签与输出历史"
        action.translatesAutoresizingMaskIntoConstraints = false
        addSubview(action)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 7),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -10),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            action.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            action.centerYAnchor.constraint(equalTo: centerYAnchor),
            action.widthAnchor.constraint(equalToConstant: 96),
            action.heightAnchor.constraint(equalToConstant: 24),
        ])
        refreshAppearance()
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    func show(title: String, detail: String?) {
        titleLabel.stringValue = title
        let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty
        refreshAppearance()
    }

    func refreshAppearance() {
        icon.contentTintColor = Theme.warning
        titleLabel.textColor = Theme.textPrimary
        detailLabel.textColor = Theme.textSecondary
        layer?.backgroundColor = Theme.layerColor(Theme.surfaceRaised, for: self)
        layer?.borderColor = Theme.layerColor(Theme.warning.withAlphaComponent(0.38), for: self)
        action.refreshAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }
}

/// 提示条里的“重新连接”。系统按钮在深色底上太抢眼，这里自绘一个跟随主题的胶囊。
@MainActor
private final class ReconnectActionButton: NSView {
    var onTap: (() -> Void)?

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "重新连接")
    private var hovering = false
    private var trackingAreaRef: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("重新连接")

        icon.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 11),
            icon.heightAnchor.constraint(equalToConstant: 11),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refreshAppearance()
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    func refreshAppearance() {
        let tint = Theme.accent
        icon.contentTintColor = tint
        label.textColor = tint
        layer?.backgroundColor = Theme.layerColor(tint.withAlphaComponent(hovering ? 0.24 : 0.14), for: self)
        layer?.borderColor = Theme.layerColor(tint.withAlphaComponent(hovering ? 0.55 : 0.34), for: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    /// 图标和文字都是这个按钮的子视图，命中测试直接交还按钮本身，
    /// 否则点在文字上没反应。
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refreshAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refreshAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        onTap?()
    }
}

/// 顶部右侧的环境徽标：普通 Shell、Docker、其他容器或远程 Shell。
/// 容器里的路径属于另一套文件系统，这个徽标同时是“为什么文件树不再跟随”的提示。
@MainActor
final class TerminalModeBadge: NSView {
    private let dot = StatusDotView()
    private let label = NSTextField(labelWithString: "")
    private var mode: TerminalMode = .shell

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 18),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 5),
            dot.heightAnchor.constraint(equalToConstant: 5),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        update(nil)
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    func update(_ mode: TerminalMode?) {
        guard let mode else {
            isHidden = true
            return
        }
        isHidden = false
        self.mode = mode
        label.stringValue = mode.shortName
        toolTip = mode.detail.map { "\(mode.shortName) · \($0)" } ?? mode.shortName
        refreshAppearance()
    }

    private func refreshAppearance() {
        let tint: NSColor
        let fill: NSColor
        switch mode {
        case .shell:
            tint = Theme.textSecondary
            fill = Theme.surfaceRaised
        case .docker:
            tint = Theme.accent
            fill = Theme.accentSoft
        case .container:
            tint = Theme.teal
            fill = Theme.teal.withAlphaComponent(0.14)
        case .remoteShell:
            tint = Theme.warning
            fill = Theme.warning.withAlphaComponent(0.14)
        }
        label.textColor = tint
        dot.layer?.backgroundColor = Theme.layerColor(tint, for: self)
        layer?.backgroundColor = Theme.layerColor(fill, for: self)
        layer?.borderColor = Theme.layerColor(Theme.border, for: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }
}

/// 终端脚部状态条：连接状态、主机身份与当前目录，右下角固定显示版本号。
/// 顺带给终端内容与窗口底边之间留出一条分界，命令不再直接顶到边上。
@MainActor
final class TerminalStatusBarView: NSView {
    static let height: CGFloat = 26

    private let topBorder = NSView()
    private let dot = StatusDotView()
    private let stateLabel = NSTextField(labelWithString: "")
    private let identityLabel = NSTextField(labelWithString: "")
    private let pathIcon = NSImageView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private var pathTrailingToVersion: NSLayoutConstraint!
    private var pathTrailingToEdge: NSLayoutConstraint!
    private var stateColor: NSColor = Theme.textTertiary
    private var hasDirectory = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        topBorder.wantsLayer = true
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBorder)

        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)

        stateLabel.font = .systemFont(ofSize: 11, weight: .medium)
        stateLabel.setContentHuggingPriority(.required, for: .horizontal)
        stateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stateLabel)

        identityLabel.font = .systemFont(ofSize: 11)
        identityLabel.textColor = Theme.textSecondary
        identityLabel.lineBreakMode = .byTruncatingTail
        identityLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        identityLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(identityLabel)

        pathIcon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        pathIcon.contentTintColor = Theme.textTertiary
        pathIcon.imageScaling = .scaleProportionallyDown
        pathIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pathIcon)

        pathLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.textColor = Theme.textSecondary
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pathLabel)

        versionLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        versionLabel.setContentHuggingPriority(.required, for: .horizontal)
        versionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(versionLabel)

        pathTrailingToVersion = pathLabel.trailingAnchor.constraint(
            equalTo: versionLabel.leadingAnchor, constant: -14
        )
        pathTrailingToEdge = pathLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)

        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 1),

            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),

            stateLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            stateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            identityLabel.leadingAnchor.constraint(equalTo: stateLabel.trailingAnchor, constant: 10),
            identityLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            pathIcon.trailingAnchor.constraint(equalTo: pathLabel.leadingAnchor, constant: -5),
            pathIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathIcon.widthAnchor.constraint(equalToConstant: 11),
            pathIcon.heightAnchor.constraint(equalToConstant: 11),

            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathLabel.leadingAnchor.constraint(greaterThanOrEqualTo: identityLabel.trailingAnchor, constant: 16),

            versionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            versionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        configureVersion()
        update(nil)
        refreshAppearance()
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    /// 版本号取自 app bundle；直接跑裸可执行文件时没有 Info.plist，就把这一格收起来。
    private func configureVersion() {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        let hasVersion = !short.isEmpty
        versionLabel.isHidden = !hasVersion
        versionLabel.stringValue = hasVersion ? "v\(short)" : ""
        versionLabel.toolTip = hasVersion
            ? (build.isEmpty ? "MioTerm \(short)" : "MioTerm \(short)（build \(build)）")
            : nil
        pathTrailingToVersion.isActive = hasVersion
        pathTrailingToEdge.isActive = !hasVersion
    }

    func update(_ controller: TerminalController?) {
        let hasSession = controller != nil
        for view in [dot, stateLabel, identityLabel, pathIcon, pathLabel] {
            view.isHidden = !hasSession
        }
        guard let controller else {
            toolTip = nil
            applyColors()
            return
        }
        stateColor = Theme.color(for: controller.state)
        stateLabel.stringValue = controller.state.label

        if let host = controller.host {
            identityLabel.stringValue = "\(host.displayName) · \(host.protocolKind.displayName) · \(host.subtitle)"
        } else {
            identityLabel.stringValue = "本地终端"
        }

        let directory = controller.context.displayDirectory ?? controller.workingDirectory
        hasDirectory = directory != nil
        pathLabel.stringValue = directory ?? "目录未知"
        pathLabel.toolTip = directory
        pathIcon.isHidden = directory == nil
        toolTip = controller.tooltip
        applyColors()
    }

    private func applyColors() {
        dot.layer?.backgroundColor = Theme.layerColor(stateColor, for: self)
        stateLabel.textColor = stateColor
        identityLabel.textColor = Theme.textSecondary
        pathIcon.contentTintColor = Theme.textTertiary
        pathLabel.textColor = hasDirectory ? Theme.textSecondary : Theme.textTertiary
        versionLabel.textColor = Theme.textTertiary
    }

    func refreshAppearance() {
        layer?.backgroundColor = Theme.layerColor(Theme.tabBar, for: self)
        topBorder.layer?.backgroundColor = Theme.layerColor(Theme.border, for: self)
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }
}
