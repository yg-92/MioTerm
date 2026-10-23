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
@MainActor
final class HostSidebarViewController: NSViewController {
    private enum Row {
        case group(name: String, hosts: [HostProfile])
        case host(HostProfile)

        var host: HostProfile? {
            if case .host(let profile) = self { return profile }
            return nil
        }
    }

    weak var delegate: HostSidebarDelegate?

    private let repository: HostRepository
    private let groupIdentifier = NSUserInterfaceItemIdentifier("GroupCell")
    private let hostIdentifier = NSUserInterfaceItemIdentifier("HostCell")

    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private let bottomBar = NSStackView()
    private let addButton = NSButton()
    private let localTerminalButton = NSButton()
    private var rows: [Row] = []

    init(repository: HostRepository) {
        self.repository = repository
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        view = root

        outlineView.headerView = nil
        outlineView.autoresizesOutlineColumn = false
        outlineView.indentationPerLevel = 8
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.allowsMultipleSelection = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.doubleAction = #selector(doubleClicked(_:))
        outlineView.menu = buildMenu()

        let column = NSTableColumn(identifier: hostIdentifier)
        column.title = "主机"
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        searchField.placeholderString = "搜索名称、地址或分组"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = false

        bottomBar.orientation = .horizontal
        bottomBar.spacing = 10
        configureBottomBar()

        for subview in [searchField, scrollView, bottomBar] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -4),
            bottomBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            bottomBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            bottomBar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])

        repository.onChange = { [weak self] in self?.reload() }
        reload()
    }

    private func configureBottomBar() {
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "新增主机")
        addButton.isBordered = false
        addButton.target = self
        addButton.action = #selector(addHost(_:))
        localTerminalButton.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "新建本地终端")
        localTerminalButton.isBordered = false
        localTerminalButton.target = self
        localTerminalButton.action = #selector(newLocalTerminal(_:))
        bottomBar.addArrangedSubview(addButton)
        bottomBar.addArrangedSubview(localTerminalButton)
        bottomBar.addArrangedSubview(NSView())
    }

    func reload() {
        rows = repository.groups(matching: searchField.stringValue).map { .group(name: $0.name, hosts: $0.hosts) }
        outlineView.reloadData()
        outlineView.expandItem(nil)
    }

    var selectedHost: HostProfile? {
        (outlineView.item(atRow: outlineView.selectedRow) as? Row)?.host
    }

    @objc private func searchChanged(_ sender: NSSearchField) { reload() }

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
    private func children(of item: Any?) -> [Row] {
        guard let row = item as? Row else { return rows }
        if case .group(_, let hosts) = row { return hosts.map { Row.host($0) } }
        return []
    }

    private func isGroup(_ item: Any?) -> Bool {
        if case .group = item as? Row { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        isGroup(item)
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        isGroup(item)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? Row)?.host != nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? Row else { return nil }
        switch row {
        case .group(let name, let hosts):
            let cell = dequeueCell(identifiedBy: groupIdentifier)
            cell.title.stringValue = name
            cell.title.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            cell.title.textColor = .secondaryLabelColor
            cell.detail.stringValue = "\(hosts.count) 台"
            return cell
        case .host(let host):
            let cell = dequeueCell(identifiedBy: hostIdentifier)
            cell.title.stringValue = host.favorite ? "★ \(host.displayName)" : host.displayName
            cell.title.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            cell.title.textColor = .labelColor
            cell.detail.stringValue = "\(host.protocolKind.displayName) · \(host.subtitle)"
            return cell
        }
    }

    private func dequeueCell(identifiedBy identifier: NSUserInterfaceItemIdentifier) -> SidebarCell {
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarCell {
            return reused
        }
        return SidebarCell(identifier: identifier)
    }
}

/// 侧栏单元格：NSTableCellView 只有主标题，副标题需要自己挂。
final class SidebarCell: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")

    var title: NSTextField { titleLabel }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        textField = titleLabel

        detail.lineBreakMode = .byTruncatingMiddle
        detail.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detail)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            detail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            detail.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }
}
