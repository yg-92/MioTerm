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
    private let newHostButton = NSButton()
    private lazy var newHostGlassBar = GlassBarView(
        content: newHostButton,
        padding: NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
    )
    private let scrollView = NSScrollView()
    private let outlineView = HostOutlineView()
    private let bottomBar = NSStackView()
    private let countLabel = NSTextField(labelWithString: "")
    private let footerDivider = NSView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private static let collapsedGroupsDefault = "MioTerm.collapsedHostGroups"

    private var rows: [Row] = []
    private var collapsedGroups: Set<String> = []
    /// 搜索时分组默认全部展开，收起动作单独记一份，退出搜索后恢复原状态。
    private var searchCollapsedGroups: Set<String> = []
    private var settingsObserver: NSObjectProtocol?

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    init(repository: HostRepository) {
        self.repository = repository
        self.collapsedGroups = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedGroupsDefault) ?? [])
        super.init(nibName: nil, bundle: nil)
    }

    private func saveCollapsedGroups() {
        UserDefaults.standard.set(Array(collapsedGroups).sorted(), forKey: Self.collapsedGroupsDefault)
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
        // sourceList 样式会用一整行 NSVisualEffectView 画选中背景，绕过 drawSelection；
        // 这里关掉它，选中态只留 SidebarRowView 自己的细色条。
        outlineView.selectionHighlightStyle = .none
        outlineView.floatsGroupRows = false
        outlineView.allowsMultipleSelection = true
        outlineView.backgroundColor = .clear
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.doubleAction = #selector(doubleClicked(_:))
        // 同文件树：双击动作显式指向本控制器，别让它沿响应链去撞终端视图。
        outlineView.target = self
        outlineView.menu = buildMenu()
        outlineView.isGroupRow = { item in (item as? Row)?.groupName != nil }
        outlineView.onToggleGroup = { [weak self] item in self?.toggleGroup(item) }

        let column = NSTableColumn(identifier: hostIdentifier)
        column.title = L10n.tr(.sidePanelHosts)
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        searchField.placeholderString = L10n.tr(.sidebarSearchPlaceholder)
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.controlSize = .large
        searchField.font = .systemFont(ofSize: 13)

        newHostButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: L10n.tr(.toolbarNewHost))
        newHostButton.bezelStyle = .accessoryBarAction
        newHostButton.isBordered = false
        newHostButton.contentTintColor = Theme.textSecondary
        newHostButton.toolTip = L10n.tr(.toolbarNewHost)
        newHostButton.target = self
        newHostButton.action = #selector(newHostTapped(_:))

        bottomBar.orientation = .horizontal
        bottomBar.spacing = 6
        configureBottomBar()

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = Theme.textTertiary
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 2
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.isHidden = true

        for subview in [searchField, newHostGlassBar, scrollView, emptyLabel, footerDivider, bottomBar] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: newHostGlassBar.leadingAnchor, constant: -6),
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 11),

            newHostGlassBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            newHostGlassBar.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            newHostGlassBar.widthAnchor.constraint(equalToConstant: 28),
            newHostGlassBar.heightAnchor.constraint(equalToConstant: 28),

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
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .mioTermSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.searchField.placeholderString = L10n.tr(.sidebarSearchPlaceholder)
                self.newHostButton.toolTip = L10n.tr(.toolbarNewHost)
                self.outlineView.menu = self.buildMenu()
                self.reload()
            }
        }
    }

    private func configureBottomBar() {
        countLabel.font = .systemFont(ofSize: 10)
        countLabel.textColor = Theme.textTertiary
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        bottomBar.addArrangedSubview(NSView())
        bottomBar.addArrangedSubview(countLabel)
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
        countLabel.stringValue = L10n.tr(.sidebarHostCount, hosts)
        emptyLabel.isHidden = hosts > 0
        emptyLabel.stringValue = query.isEmpty ? L10n.tr(.sidebarEmptyNoHost) : L10n.tr(.sidebarEmptyNoMatch)
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
            saveCollapsedGroups()
        } else {
            collapsedGroups.insert(name)
            saveCollapsedGroups()
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
        selectedHosts.first
    }

    var selectedHosts: [HostProfile] {
        outlineView.selectedRowIndexes.compactMap { row in
            guard row >= 0, let item = outlineView.item(atRow: row) as? Row else { return nil }
            return item.host
        }
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

    // MARK: - 右键菜单

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    private func populateHostMenu(_ menu: NSMenu) {
        let titles: [(String, Selector)] = [
            (L10n.tr(.sidebarMenuConnect), #selector(connectSelected(_:))),
            (L10n.tr(.sidebarMenuTest), #selector(testSelected(_:))),
            (L10n.tr(.sidebarMenuEdit), #selector(editSelected(_:))),
            (L10n.tr(.sidebarMenuDuplicate), #selector(duplicateSelected(_:))),
            (L10n.tr(.sidebarMenuFavorite), #selector(toggleFavoriteSelected(_:))),
            (L10n.tr(.sidebarMenuRefreshFingerprint), #selector(refreshFingerprintSelected(_:))),
            (L10n.tr(.sidebarMenuDelete), #selector(deleteSelected(_:))),
        ]
        for (title, action) in titles {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        let iconMenuItem = NSMenuItem(title: L10n.tr(.hostMenuChangeSystemIcon), action: nil, keyEquivalent: "")
        let iconSubmenu = NSMenu()
        for iconKind in SSHSystemIcon.allCases {
            let sub = NSMenuItem(title: iconKind.displayName, action: #selector(changeSystemIcon(_:)), keyEquivalent: "")
            sub.target = self
            sub.representedObject = iconKind.rawValue
            sub.image = Theme.iconImage(for: iconKind)
            iconSubmenu.addItem(sub)
        }
        iconMenuItem.submenu = iconSubmenu
        menu.insertItem(iconMenuItem, at: 3)
    }

    @objc private func newHostTapped(_ sender: Any?) {
        delegate?.hostSidebarDidRequestNewHost(self)
    }

    @objc private func changeSystemIcon(_ sender: NSMenuItem) {
        guard let host = menuHost, host.protocolKind == .ssh,
              let raw = sender.representedObject as? String,
              let iconKind = SSHSystemIcon(rawValue: raw) else { return }
        var updated = host
        updated.systemIcon = iconKind
        _ = try? repository.save(updated)
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(renameGroupSelected(_:)) {
            return menuGroupName != nil
        }
        if menuItem.action == #selector(changeSystemIcon(_:)) {
            guard let host = menuHost, host.protocolKind == .ssh else { return false }
            let raw = menuItem.representedObject as? String
            menuItem.state = (raw == host.systemIcon.rawValue) ? .on : .off
            return true
        }
        return menuHost != nil
    }

    /// 右键命中行优先于当前选中行，否则在同组内右键时会误操作上一行选中的主机。
    private var menuHost: HostProfile? {
        let index = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard index >= 0 else { return nil }
        return (outlineView.item(atRow: index) as? Row)?.host
    }

    private var menuGroupName: String? {
        let index = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard index >= 0 else { return nil }
        return (outlineView.item(atRow: index) as? Row)?.groupName
    }

    @objc private func renameGroupSelected(_ sender: NSMenuItem) {
        guard let oldName = menuGroupName else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr(.sidebarRenameGroupTitle)
        alert.informativeText = L10n.tr(.sidebarRenameGroupMessage, oldName)
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.tr(.commonOK))
        alert.addButton(withTitle: L10n.tr(.commonCancel))

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = L10n.tr(.sidebarRenameGroupPlaceholder)
        input.stringValue = (oldName == L10n.tr(.hostGroupUngrouped)) ? "" : oldName
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        Task { @MainActor [weak self] in
            guard let self else { return }
            let response = await AlertPresenter.present(alert, in: self.view.window)
            guard response == .alertFirstButtonReturn else { return }
            let rawNew = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let targetDisplay = rawNew.isEmpty ? L10n.tr(.hostGroupUngrouped) : rawNew
            do {
                let count = try self.repository.renameGroup(from: oldName, to: rawNew)
                if count > 0 {
                    if self.collapsedGroups.remove(oldName) != nil {
                        self.collapsedGroups.insert(targetDisplay)
                        self.saveCollapsedGroups()
                    }
                    if self.searchCollapsedGroups.remove(oldName) != nil {
                        self.searchCollapsedGroups.insert(targetDisplay)
                    }
                    self.reload()
                }
            } catch {
                AlertPresenter.fail(
                    title: L10n.tr(.sidebarRenameGroupFailedTitle),
                    message: error.localizedDescription,
                    in: self.view.window
                )
            }
        }
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

// MARK: - NSMenuDelegate

extension HostSidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menuGroupName != nil {
            let renameItem = NSMenuItem(
                title: L10n.tr(.sidebarMenuRenameGroup),
                action: #selector(renameGroupSelected(_:)),
                keyEquivalent: ""
            )
            renameItem.target = self
            menu.addItem(renameItem)
        } else if menuHost != nil {
            populateHostMenu(menu)
        }
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

/// 选中行只在左侧留一条细色条；悬停给一层很淡的底色，和整体扁平风格一致。
@MainActor
private final class SidebarRowView: NSTableRowView {
    private let hoverBackground = NSView()
    private let selectedMarker = NSView()
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        hoverBackground.wantsLayer = true
        hoverBackground.layer?.cornerRadius = 7
        hoverBackground.layer?.cornerCurve = .continuous
        hoverBackground.layer?.backgroundColor = Theme.layerColor(Theme.hoverFill, for: self)
        hoverBackground.isHidden = true
        addSubview(hoverBackground, positioned: .below, relativeTo: nil)

        selectedMarker.wantsLayer = true
        selectedMarker.layer?.cornerRadius = 1.5
        selectedMarker.isHidden = true
        addSubview(selectedMarker)

        updateMarker()
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    override var isSelected: Bool {
        didSet { updateMarker() }
    }

    override func layout() {
        super.layout()
        hoverBackground.frame = bounds.insetBy(dx: 6, dy: 2)
        let height = min(18, max(0, bounds.height - 10))
        selectedMarker.frame = NSRect(
            x: 3,
            y: (bounds.height - height) / 2,
            width: 3,
            height: height
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hoverBackground.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        hoverBackground.isHidden = true
    }

    /// 选中不再铺色块，只留左侧细条，避免列表整行变成蓝色背景。
    private func updateMarker() {
        selectedMarker.isHidden = !isSelected
        selectedMarker.layer?.backgroundColor = Theme.layerColor(Theme.accent, for: self)
        needsDisplay = true
    }

    override func drawSelection(in dirtyRect: NSRect) {}

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        hoverBackground.layer?.backgroundColor = Theme.layerColor(Theme.hoverFill, for: self)
        updateMarker()
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
            accessibilityDescription: expanded ? L10n.tr(.sidebarCollapseGroup) : L10n.tr(.sidebarExpandGroup)
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

        star.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: L10n.tr(.sidebarFavorited))
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
        let tint = Theme.tint(for: host)
        badge.layer?.backgroundColor = Theme.layerColor(tint.withAlphaComponent(0.16), for: self)
        icon.image = Theme.iconImage(for: host)
        icon.contentTintColor = tint
        titleLabel.stringValue = host.displayName
        detailLabel.stringValue = "\(host.protocolKind.displayName) · \(host.subtitle)"
        star.isHidden = !host.favorite
    }
}
