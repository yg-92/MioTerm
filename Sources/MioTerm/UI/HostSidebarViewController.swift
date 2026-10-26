import AppKit
import MioTermCore

/// 侧栏发起的操作交给工作区处理，侧栏自己不做连接编排，
/// 这样工具栏按钮、双击与右键菜单能共用同一条路径。
@MainActor
protocol HostSidebarDelegate: AnyObject {
    func hostSidebar(_ sidebar: HostSidebarViewController, didRequestConnect host: HostProfile)
    func hostSidebar(_ sidebar: HostSidebarViewController, didRequestEdit host: HostProfile)
    func hostSidebar(_ sidebar: HostSidebarViewController, didRequestDuplicate host: HostProfile)
    func hostSidebar(_ sidebar: HostSidebarViewController, didRequestDelete host: HostProfile)
    func hostSidebar(_ sidebar: HostSidebarViewController, didRequestFavorite host: HostProfile)
    func hostSidebar(_ sidebar: HostSidebarViewController, didRequestFingerprintRefresh host: HostProfile)
    func hostSidebar(_ sidebar: HostSidebarViewController, didRequestTest host: HostProfile)
    func hostSidebarDidRequestNewHost(_ sidebar: HostSidebarViewController)
    func hostSidebarDidRequestNewLocalTerminal(_ sidebar: HostSidebarViewController)
}

/// 主机列表：按分组展示，支持搜索，数据直接来自 HostRepository。
/// 分组标题整行可点：不用瞄准左侧的小箭头，展开状态会记住。
@MainActor
final class HostSidebarViewController: NSViewController {
    private enum Row {
        case group(name: String, hosts: [HostProfile])
        case host(HostProfile)

        var host: HostProfile? {
            if case .host(let profile) = self { return profile }
            return nil
        }

        var groupName: String? {
            if case .group(let name, _) = self { return name }
            return nil
        }
    }

    weak var delegate: HostSidebarDelegate?

    private let repository: HostRepository
    private let groupIdentifier = NSUserInterfaceItemIdentifier("GroupCell")
    private let hostIdentifier = NSUserInterfaceItemIdentifier("HostCell")

    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let outlineView = HostOutlineView()
    private let bottomBar = NSStackView()
    private let addButton = NSButton()
    private let localTerminalButton = NSButton()
    private let countLabel = NSTextField(labelWithString: "")
    private let footerDivider = NSView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var rows: [Row] = []
    private var collapsedGroups: Set<String> = []
    /// 搜索时分组默认全部展开，收起动作单独记一份，退出搜索后恢复原状态。
    private var searchCollapsedGroups: Set<String> = []

    init(repository: HostRepository) {
        self.repository = repository
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    override func loadView() {
        let root = AppearanceAwareView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        root.onAppearanceChange = { [weak self] in self?.refreshAppearance() }
        view = root

        outlineView.headerView = nil
        outlineView.autoresizesOutlineColumn = false
        outlineView.indentationPerLevel = 14
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.allowsMultipleSelection = false
        outlineView.backgroundColor = .clear
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.doubleAction = #selector(doubleClicked(_:))
        outlineView.menu = buildMenu()
        outlineView.isGroupRow = { item in (item as? Row)?.groupName != nil }
        outlineView.onToggleGroup = { [weak self] item in self?.toggleGroup(item) }

        let column = NSTableColumn(identifier: hostIdentifier)
        column.title = "主机"
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        searchField.placeholderString = "搜索名称、地址或分组"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.controlSize = .large
        searchField.font = .systemFont(ofSize: 13)

        bottomBar.orientation = .horizontal
        bottomBar.spacing = 6
        configureBottomBar()

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = Theme.textTertiary
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.isHidden = true

        for subview in [searchField, scrollView, emptyLabel, footerDivider, bottomBar] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 11),

            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 9),
            scrollView.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -40),

            footerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footerDivider.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -6),
            footerDivider.heightAnchor.constraint(equalToConstant: 1),

            bottomBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            bottomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            bottomBar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -7),
        ])
        footerDivider.wantsLayer = true
        footerDivider.layer?.backgroundColor = Theme.layerColor(Theme.border, for: footerDivider)

        repository.onChange = { [weak self] in self?.reload() }
        reload()
    }

    private func configureBottomBar() {
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "新增主机")
        addButton.isBordered = false
        addButton.contentTintColor = Theme.textSecondary
        addButton.imageScaling = .scaleProportionallyDown
        addButton.toolTip = "新增主机"
        addButton.target = self
        addButton.action = #selector(addHost(_:))
        addButton.translatesAutoresizingMaskIntoConstraints = false

        localTerminalButton.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "新建本地终端")
        localTerminalButton.isBordered = false
        localTerminalButton.contentTintColor = Theme.textSecondary
        localTerminalButton.imageScaling = .scaleProportionallyDown
        localTerminalButton.toolTip = "新建本地终端"
        localTerminalButton.target = self
        localTerminalButton.action = #selector(newLocalTerminal(_:))
        localTerminalButton.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .systemFont(ofSize: 10)
        countLabel.textColor = Theme.textTertiary
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        // 两个图标按钮合成一条玻璃胶囊，和文件面板的操作栏保持同一种材质。
        let tools = NSStackView(views: [addButton, localTerminalButton])
        tools.orientation = .horizontal
        tools.spacing = 3
        let toolBar = GlassBarView(
            content: tools,
            padding: NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        )
        toolBar.setContentHuggingPriority(.required, for: .horizontal)

        bottomBar.addArrangedSubview(toolBar)
        bottomBar.addArrangedSubview(NSView())
        bottomBar.addArrangedSubview(countLabel)
        NSLayoutConstraint.activate([
            addButton.widthAnchor.constraint(equalToConstant: 26),
            addButton.heightAnchor.constraint(equalToConstant: 24),
            localTerminalButton.widthAnchor.constraint(equalToConstant: 26),
            localTerminalButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    func reload() {
        let selectedID = selectedHost?.id
        rebuildRows()
        restoreSelection(id: selectedID)
    }

    /// 展开状态完全由自己管：分组收起时干脆不把它的主机放进列表。
    /// 交给 NSOutlineView 的 expand/collapse 不行——隐藏了系统箭头后
    /// （shouldShowOutlineCellForItem 返回 false），collapseItem 会静默失效。
    private func rebuildRows() {
        let query = searchField.stringValue
        let groups = repository.groups(matching: query)
        var visible: [Row] = []
        for group in groups {
            visible.append(.group(name: group.name, hosts: group.hosts))
            if isExpanded(group.name) {
                visible.append(contentsOf: group.hosts.map { Row.host($0) })
            }
        }
        rows = visible
        outlineView.reloadData()

        let hosts = groups.reduce(0) { $0 + $1.hosts.count }
        countLabel.stringValue = "\(hosts) 台主机"
        emptyLabel.isHidden = hosts > 0
        emptyLabel.stringValue = query.isEmpty ? "还没有主机\n点左下角 + 添加一台" : "没有匹配的主机"
    }

    private var isSearching: Bool {
        !searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isExpanded(_ name: String) -> Bool {
        if isSearching { return !searchCollapsedGroups.contains(name) }
        return !collapsedGroups.contains(name)
    }

    private func toggleGroup(_ item: Any) {
        guard let name = (item as? Row)?.groupName else { return }
        let selectedID = selectedHost?.id
        if isSearching {
            if searchCollapsedGroups.contains(name) {
                searchCollapsedGroups.remove(name)
            } else {
                searchCollapsedGroups.insert(name)
            }
        } else if collapsedGroups.contains(name) {
            collapsedGroups.remove(name)
        } else {
            collapsedGroups.insert(name)
        }
        rebuildRows()
        restoreSelection(id: selectedID)
    }

    /// 行内标记的底色是图层色，切换深浅外观后要重配一遍。
    private func refreshAppearance() {
        footerDivider.layer?.backgroundColor = Theme.layerColor(Theme.border, for: footerDivider)
        reload()
    }

    var selectedHost: HostProfile? {
        (outlineView.item(atRow: outlineView.selectedRow) as? Row)?.host
    }

    private func restoreSelection(id: String?) {
        guard let id else { return }
        for row in 0..<outlineView.numberOfRows {
            guard let host = (outlineView.item(atRow: row) as? Row)?.host, host.id == id else { continue }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            return
        }
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        let selectedID = selectedHost?.id
        searchCollapsedGroups.removeAll()
        rebuildRows()
        restoreSelection(id: selectedID)
    }

    @objc private func doubleClicked(_ sender: NSOutlineView) {
        guard let host = selectedHost else { return }
        delegate?.hostSidebar(self, didRequestConnect: host)
    }

    @objc private func addHost(_ sender: NSButton) {
        delegate?.hostSidebarDidRequestNewHost(self)
    }

    @objc private func newLocalTerminal(_ sender: NSButton) {
        delegate?.hostSidebarDidRequestNewLocalTerminal(self)
    }

    // MARK: - 右键菜单

    private func buildMenu() -> NSMenu {
        let titles: [(String, Selector)] = [
            ("连接", #selector(connectSelected(_:))),
            ("测试连接", #selector(testSelected(_:))),
            ("编辑…", #selector(editSelected(_:))),
            ("创建副本", #selector(duplicateSelected(_:))),
            ("收藏 / 取消收藏", #selector(toggleFavoriteSelected(_:))),
            ("刷新指纹…", #selector(refreshFingerprintSelected(_:))),
            ("删除", #selector(deleteSelected(_:))),
        ]
        let menu = NSMenu()
        for (title, action) in titles {
            menu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: ""))
        }
        for item in menu.items { item.target = self }
        return menu
    }

    /// 右键命中行优先于当前选中行，否则在同组内右键时会误操作上一行选中的主机。
    private var menuHost: HostProfile? {
        let index = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard index >= 0 else { return nil }
        return (outlineView.item(atRow: index) as? Row)?.host
    }

    @objc private func connectSelected(_ sender: NSMenuItem) {
        guard let host = menuHost else { return }
        delegate?.hostSidebar(self, didRequestConnect: host)
    }

    @objc private func testSelected(_ sender: NSMenuItem) {
        guard let host = menuHost else { return }
        delegate?.hostSidebar(self, didRequestTest: host)
    }

    @objc private func editSelected(_ sender: NSMenuItem) {
        guard let host = menuHost else { return }
        delegate?.hostSidebar(self, didRequestEdit: host)
    }

    @objc private func duplicateSelected(_ sender: NSMenuItem) {
        guard let host = menuHost else { return }
        delegate?.hostSidebar(self, didRequestDuplicate: host)
    }

    @objc private func toggleFavoriteSelected(_ sender: NSMenuItem) {
        guard let host = menuHost else { return }
        delegate?.hostSidebar(self, didRequestFavorite: host)
    }

    @objc private func refreshFingerprintSelected(_ sender: NSMenuItem) {
        guard let host = menuHost else { return }
        delegate?.hostSidebar(self, didRequestFingerprintRefresh: host)
    }

    @objc private func deleteSelected(_ sender: NSMenuItem) {
        guard let host = menuHost else { return }
        delegate?.hostSidebar(self, didRequestDelete: host)
    }
}

// MARK: - NSOutlineViewDataSource / Delegate

extension HostSidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// 列表是扁平的：分组与它的主机都作为顶层行出现，展开与否由 rebuildRows 决定。
    private func children(of item: Any?) -> [Row] {
        item == nil ? rows : []
    }

    private func isGroup(_ item: Any?) -> Bool {
        (item as? Row)?.groupName != nil
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? Row)?.host != nil
    }

    /// 分组不再使用系统的整行样式，改用自绘单元格；系统箭头也一并藏掉。
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        isGroup(item) ? 30 : 46
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        SidebarRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? Row else { return nil }
        switch row {
        case .group(let name, let hosts):
            let cell = dequeueGroupCell()
            cell.configure(
                name: name,
                count: hosts.count,
                expanded: isExpanded(name)
            )
            return cell
        case .host(let host):
            let cell = dequeueHostCell()
            cell.configure(host: host)
            return cell
        }
    }

    private func dequeueGroupCell() -> HostGroupCell {
        if let reused = outlineView.makeView(withIdentifier: groupIdentifier, owner: self) as? HostGroupCell {
            return reused
        }
        return HostGroupCell(identifier: groupIdentifier)
    }

    private func dequeueHostCell() -> HostRowCell {
        if let reused = outlineView.makeView(withIdentifier: hostIdentifier, owner: self) as? HostRowCell {
            return reused
        }
        return HostRowCell(identifier: hostIdentifier)
    }
}

/// 分组整行可点：鼠标落在分组行任意位置都切换展开，不必瞄准系统箭头。
@MainActor
final class HostOutlineView: NSOutlineView {
    var isGroupRow: ((Any) -> Bool)?
    /// 分组行不交给 NSOutlineView 展开：收起系统箭头后它的状态机就不可用了，
    /// 改由控制器重建可见行。
    var onToggleGroup: ((Any) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clicked = row(at: point)
        if clicked >= 0, let item = item(atRow: clicked), isGroupRow?(item) == true {
            // 只认第一下：双击的第二下不再重复切换。
            if event.clickCount == 1 {
                onToggleGroup?(item)
                window?.invalidateCursorRects(for: self)
            }
            return
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for row in 0..<numberOfRows {
            guard let item = item(atRow: row), isGroupRow?(item) == true else { continue }
            addCursorRect(rect(ofRow: row), cursor: .pointingHand)
        }
    }
}

/// 选中行画成圆角块，比系统整行蓝条更贴合深色侧栏。
@MainActor
private final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 6, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        Theme.accent.withAlphaComponent(isEmphasized ? 0.22 : 0.12).setFill()
        path.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - 单元格

/// 分组标题：自绘箭头 + 名称 + 数量。
@MainActor
final class HostGroupCell: NSTableCellView {
    private let chevron = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        chevron.contentTintColor = Theme.textTertiary
        chevron.imageScaling = .scaleProportionallyDown
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        countLabel.font = .systemFont(ofSize: 10, weight: .medium)
        countLabel.textColor = Theme.textTertiary
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)

        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 11),
            chevron.heightAnchor.constraint(equalToConstant: 11),
            titleLabel.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 7),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -8),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
        ])
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    func configure(name: String, count: Int, expanded: Bool) {
        chevron.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: expanded ? "收起分组" : "展开分组"
        )
        titleLabel.attributedStringValue = NSAttributedString(
            string: name,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: Theme.textSecondary,
                .kern: 0.6,
            ]
        )
        countLabel.stringValue = "\(count)"
    }
}

/// 主机行：协议图标 + 名称 + 地址，收藏的星标贴在右侧。
@MainActor
final class HostRowCell: NSTableCellView {
    private let badge = NSView()
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let star = NSImageView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        badge.wantsLayer = true
        badge.layer?.cornerRadius = 8
        badge.layer?.cornerCurve = .continuous
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)

        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(icon)

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        detailLabel.font = .systemFont(ofSize: 10.5)
        detailLabel.textColor = Theme.textSecondary
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailLabel)

        star.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "已收藏")
        star.contentTintColor = Theme.warning
        star.imageScaling = .scaleProportionallyDown
        star.translatesAutoresizingMaskIntoConstraints = false
        addSubview(star)

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 28),
            badge.heightAnchor.constraint(equalToConstant: 28),
            icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: star.leadingAnchor, constant: -6),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),

            star.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            star.centerYAnchor.constraint(equalTo: centerYAnchor),
            star.widthAnchor.constraint(equalToConstant: 11),
            star.heightAnchor.constraint(equalToConstant: 11),
        ])
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    func configure(host: HostProfile) {
        let tint = Theme.tint(for: host.protocolKind)
        badge.layer?.backgroundColor = Theme.layerColor(tint.withAlphaComponent(0.16), for: self)
        icon.image = NSImage(systemSymbolName: Theme.symbol(for: host.protocolKind), accessibilityDescription: host.protocolKind.displayName)
        icon.contentTintColor = tint
        titleLabel.stringValue = host.displayName
        detailLabel.stringValue = "\(host.protocolKind.displayName) · \(host.subtitle)"
        star.isHidden = !host.favorite
    }
}
