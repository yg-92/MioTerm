import AppKit
import MioTermCore

/// 命令库面板：当前会话（或本地终端）的命令统计、收藏与忽略清单。
///
/// 行为对齐 webterm：单击只把命令填进终端、不回车，是否执行由用户决定；
/// 忽略命中即不记录，规则分“本机”与“全局”两层。
@MainActor
final class CommandLibraryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    private enum Row {
        case group(String)
        case command(CommandRecord)
        case ignore(IgnoredCommand)

        var isGroup: Bool { if case .group = self { return true }; return false }
    }

    private enum Sort: Int {
        case mostUsed = 0
        case mostRecent = 1
    }

    private static let cellIdentifier = NSUserInterfaceItemIdentifier("CommandLibraryCell")
    private static let columnIdentifier = NSUserInterfaceItemIdentifier("command")

    private let environment = AppEnvironment.shared
    private let tableView = CommandTableView()
    private let scopeLabel = NSTextField(labelWithString: "未选择会话")
    private let hintLabel = NSTextField(labelWithString: "单击填入终端，不会自动回车")
    private let sortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var rows: [Row] = []
    private var sort: Sort = .mostUsed
    private var session: TerminalController?

    override func loadView() {
        scopeLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        scopeLabel.textColor = .secondaryLabelColor
        scopeLabel.lineBreakMode = .byTruncatingHead

        sortPopup.addItems(withTitles: ["按次数", "按最近"])
        sortPopup.target = self
        sortPopup.action = #selector(sortChanged(_:))

        let ignoreButton = NSButton(title: "忽略…", target: self, action: #selector(addIgnoreManually(_:)))
        ignoreButton.bezelStyle = .rounded
        ignoreButton.toolTip = "把一条命令加入忽略清单，之后不再记录"
        let clearButton = NSButton(title: "清空", target: self, action: #selector(clearScope(_:)))
        clearButton.bezelStyle = .rounded
        clearButton.toolTip = "清掉这个作用域的历史与本机忽略清单"

        let header = NSStackView(views: [scopeLabel, NSView(), sortPopup])
        header.orientation = .horizontal
        header.spacing = 8
        let footer = NSStackView(views: [hintLabel, NSView(), ignoreButton, clearButton])
        footer.orientation = .horizontal
        footer.spacing = 6
        hintLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.textColor = .tertiaryLabelColor

        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.rowSizeStyle = .small
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.menu = rowMenu
        tableView.target = self
        tableView.action = #selector(rowClicked(_:))
        let column = NSTableColumn(identifier: Self.columnIdentifier)
        column.title = "命令"
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 460))
        for view in [header, scroll, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            sortPopup.widthAnchor.constraint(equalToConstant: 78),
        ])
        view = root

        // 终端里每记一条都要刷新面板；这里只有一个持有者，直接占住回调。
        environment.commands.onChange = { [weak self] in self?.reload() }
        reload()
    }

    /// 跟随当前标签。bind 可能早于视图加载，所以先把会话记下来。
    func bind(to controller: TerminalController?) {
        session = controller
        guard isViewLoaded else { return }
        reload()
    }

    private var scopeKey: String? { session?.commandScope }

    private func reload() {
        guard isViewLoaded else { return }
        rows.removeAll()
        if let session {
            scopeLabel.stringValue = session.host.map { "· \($0.displayName)" } ?? "· 本地终端"
            let scope = session.commandScope
            let favorites = environment.commands.favorites(scope: scope)
            if !favorites.isEmpty {
                rows.append(.group("收藏"))
                rows.append(contentsOf: favorites.map { Row.command($0) })
            }
            let tracked = sort == .mostUsed
                ? environment.commands.mostUsed(scope: scope)
                : environment.commands.mostRecent(scope: scope)
            let rest = tracked.filter { !$0.favorite }
            if !rest.isEmpty {
                rows.append(.group(sort == .mostUsed ? "常用" : "最近"))
                rows.append(contentsOf: rest.map { Row.command($0) })
            }
            let ignored = environment.commands.ignoredCommands(scope: scope)
            if !ignored.isEmpty {
                rows.append(.group("忽略"))
                rows.append(contentsOf: ignored.map { Row.ignore($0) })
            }
        } else {
            scopeLabel.stringValue = "未选择会话"
        }
        tableView.reloadData()
        hintLabel.stringValue = rows.isEmpty
            ? (session == nil ? "先连上一台主机或开一个本地终端" : "还没有记录：敲过的命令会按主机累计在这里")
            : "单击填入终端，不会自动回车"
    }

    @objc private func sortChanged(_ sender: NSPopUpButton) {
        sort = Sort(rawValue: sender.indexOfSelectedItem) ?? .mostUsed
        reload()
    }

    // MARK: - 单击注入

    @objc private func rowClicked(_ sender: NSTableView) {
        // 右键只用来选中与弹菜单，注入留给左键。
        if let event = NSApp.currentEvent, event.type == .rightMouseUp || event.type == .rightMouseDown { return }
        guard case .command(let record)? = row(at: sender.clickedRow) else { return }
        session?.injectInput(record.command)
    }

    // MARK: - 右键动作

    private lazy var rowMenu: NSMenu = {
        let menu = NSMenu()
        menu.addItem(menuItem("填入终端", #selector(injectSelected(_:))))
        menu.addItem(.separator())
        menu.addItem(menuItem("收藏", #selector(toggleFavorite(_:))))
        menu.addItem(menuItem("加入忽略清单…", #selector(ignoreSelectedFromMenu(_:))))
        menu.addItem(menuItem("提升为全局忽略", #selector(promoteSelectedIgnore(_:))))
        menu.addItem(menuItem("移出忽略清单", #selector(unignoreSelected(_:))))
        menu.addItem(menuItem("删除这条记录", #selector(deleteSelected(_:))))
        return menu
    }()

    /// 面板内的菜单项一律显式指向本控制器，避免右键时靠响应链撞到终端视图。
    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func row(at index: Int) -> Row? {
        guard index >= 0, index < rows.count else { return nil }
        return rows[index]
    }

    private var selectedCommand: String? {
        guard case .command(let record)? = row(at: tableView.clickedRow) else { return nil }
        return record.command
    }

    private var selectedIgnore: IgnoredCommand? {
        guard case .ignore(let rule)? = row(at: tableView.clickedRow) else { return nil }
        return rule
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let action = menuItem.action
        let command = selectedCommand
        let ignore = selectedIgnore
        switch action {
        case #selector(injectSelected(_:)): return command != nil
        case #selector(toggleFavorite(_:)): return command != nil
        case #selector(ignoreSelectedFromMenu(_:)): return command != nil
        case #selector(promoteSelectedIgnore(_:)): return ignore?.global == false
        case #selector(unignoreSelected(_:)): return ignore != nil
        case #selector(deleteSelected(_:)): return command != nil
        default: return true
        }
    }

    @objc private func injectSelected(_ sender: NSMenuItem) {
        guard let command = selectedCommand else { return }
        session?.injectInput(command)
    }

    @objc private func toggleFavorite(_ sender: NSMenuItem) {
        guard let scope = scopeKey, let command = selectedCommand else { return }
        let favorite = environment.commands.entry(scope: scope, command: command)?.favorite != true
        environment.commands.setFavorite(command, scope: scope, favorite: favorite)
    }

    @objc private func deleteSelected(_ sender: NSMenuItem) {
        guard let scope = scopeKey, let command = selectedCommand else { return }
        environment.commands.remove(command: command, scope: scope)
    }

    @objc private func ignoreSelectedFromMenu(_ sender: NSMenuItem) {
        guard let command = selectedCommand else { return }
        confirmIgnore(command: command)
    }

    @objc private func addIgnoreManually(_ sender: NSButton) {
        guard scopeKey != nil else {
            AlertPresenter.notify(title: "未选择会话", message: "先连上一台主机，再添加忽略规则。", in: view.window)
            return
        }
        let alert = NSAlert()
        alert.messageText = "添加忽略规则"
        alert.informativeText = "这条命令之后不再记录（含粘贴与带变量的整行原文）："
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "添加")
        alert.addButton(withTitle: "取消")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        confirmIgnore(command: field.stringValue)
    }

    /// 忽略分两层：本机只挡当前主机，全局挡所有主机。默认按本机处理，避免误伤别的机器。
    private func confirmIgnore(command: String) {
        guard let scope = scopeKey else { return }
        let alert = NSAlert()
        alert.messageText = "忽略 “\(command)”？"
        alert.informativeText = "已有记录会被删除，之后这条命令不再计入统计。"
        alert.addButton(withTitle: "只忽略这台主机")
        alert.addButton(withTitle: "忽略所有主机")
        alert.addButton(withTitle: "取消")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: environment.commands.addIgnore(command, scope: scope)
        case .alertSecondButtonReturn: environment.commands.addIgnore(command, scope: nil)
        default: break
        }
    }

    @objc private func promoteSelectedIgnore(_ sender: NSMenuItem) {
        guard let scope = scopeKey, let rule = selectedIgnore, !rule.global else { return }
        environment.commands.promoteIgnoreToGlobal(rule.command, scope: scope)
    }

    @objc private func unignoreSelected(_ sender: NSMenuItem) {
        guard let rule = selectedIgnore else { return }
        environment.commands.removeIgnore(rule.command, scope: rule.global ? nil : scopeKey)
    }

    @objc private func clearScope(_ sender: NSButton) {
        guard let scope = scopeKey else { return }
        let alert = NSAlert()
        alert.messageText = "清空这个作用域的命令库？"
        alert.informativeText = "统计、收藏与本机忽略规则都会删除，全局规则保留。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        environment.commands.clear(scope: scope)
    }

    // MARK: - 表格数据源与代理

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        rows[row].isGroup
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !rows[row].isGroup
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, tableColumn.identifier == Self.columnIdentifier else { return nil }
        switch rows[row] {
        case .group(let title):
            return makeGroupCell(title)
        case .command(let record):
            let cell = makeCell()
            cell.icon.image = Self.symbol(record.favorite ? "star.fill" : "star")
            cell.icon.contentTintColor = record.favorite ? .systemYellow : .tertiaryLabelColor
            cell.title.stringValue = record.command
            cell.trailing.stringValue = "\(record.executionCount) 次"
            cell.toolTip = "\(record.command)\n共 \(record.executionCount) 次 · 最后使用 \(Self.dateFormatter.string(from: record.lastExecutedAt))"
            return cell
        case .ignore(let rule):
            let cell = makeCell()
            cell.icon.image = Self.symbol("nosign")
            cell.icon.contentTintColor = .secondaryLabelColor
            cell.title.stringValue = rule.command
            cell.trailing.stringValue = rule.global ? "全局" : "本机"
            cell.toolTip = "不记录：\(rule.command)"
            return cell
        }
    }

    private func makeCell() -> CommandCell {
        if let reused = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? CommandCell {
            return reused
        }
        let cell = CommandCell()
        cell.identifier = Self.cellIdentifier
        return cell
    }

    private func makeGroupCell(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        let container = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])
        return container
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .regular))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

/// 命令行：图标 + 命令文本 + 右侧次数或规则层级。
@MainActor
private final class CommandCell: NSTableCellView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let trailing = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        title.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        title.lineBreakMode = .byTruncatingMiddle
        title.textColor = .labelColor
        trailing.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        trailing.textColor = .secondaryLabelColor
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true

        let stack = NSStackView(views: [icon, title, trailing])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        self.textField = title
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }
}

/// 窗口不是活动状态时，第一次点击也要直接落到命令行上；
/// 否则用户点完命令再按回车，按键还留在列表里，终端看起来毫无反应。
@MainActor
private final class CommandTableView: NSTableView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
