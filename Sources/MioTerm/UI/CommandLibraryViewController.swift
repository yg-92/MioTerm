import AppKit
import MioTermCore

/// 命令库面板：当前会话（或本地终端）的命令统计、收藏与忽略清单。
///
/// 行为对齐 webterm：单击只把命令填进终端、不回车，是否执行由用户决定；
/// 忽略命中即不记录，规则分“本机”与“全局”两层。
@MainActor
final class CommandLibraryViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation, NSMenuDelegate {
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
    private let searchField = NSSearchField()
    private let scopeLabel = NSTextField(labelWithString: "未选择会话")
    private let hintLabel = NSTextField(labelWithString: "单击填入终端，不会自动回车")
    private let sortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let ignoreButton = NSButton()
    private let clearButton = NSButton()
    private var rows: [Row] = []
    private var sort: Sort = .mostUsed
    private var query = ""
    private var session: TerminalController?

    override func loadView() {
        scopeLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        scopeLabel.textColor = .secondaryLabelColor
        scopeLabel.lineBreakMode = .byTruncatingHead

        sortPopup.addItems(withTitles: ["按次数", "按最近"])
        sortPopup.target = self
        sortPopup.action = #selector(sortChanged(_:))

        searchField.placeholderString = "搜索命令"
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.toolTip = "按命令文本过滤，忽略规则也会一起搜索"

        ignoreButton.title = "忽略…"
        ignoreButton.target = self
        ignoreButton.action = #selector(addIgnoreManually(_:))
        ignoreButton.bezelStyle = .rounded
        ignoreButton.controlSize = .small
        ignoreButton.toolTip = "把一条命令加入忽略清单，之后不再记录"
        clearButton.title = "清空"
        clearButton.target = self
        clearButton.action = #selector(clearScope(_:))
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.toolTip = "清掉这个作用域的历史与本机忽略清单"

        let header = NSStackView(views: [scopeLabel, NSView(), sortPopup])
        header.orientation = .horizontal
        header.spacing = 8
        let footer = NSStackView(views: [hintLabel, NSView(), ignoreButton, clearButton])
        footer.orientation = .horizontal
        footer.spacing = 6
        hintLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.textColor = .tertiaryLabelColor
        // 侧栏很窄时优先保住按钮，提示文字在尾部省略。
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        ignoreButton.setContentHuggingPriority(.required, for: .horizontal)
        clearButton.setContentHuggingPriority(.required, for: .horizontal)

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
        tableView.onReturn = { [weak self] in self?.injectSelectedRow() }
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
        for view in [header, searchField, scroll, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            searchField.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
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
        let switched = session !== controller
        session = controller
        guard isViewLoaded else { return }
        // 换标签时清掉搜索：否则新主机的列表看起来像空的。
        if switched, !query.isEmpty {
            query = ""
            searchField.stringValue = ""
        }
        reload()
    }

    private var scopeKey: String? { session?.commandScope }

    private func reload() {
        guard isViewLoaded else { return }
        // 终端每执行一条命令都会刷新列表；选区跟着同一条命令走，别让它跳回顶部。
        let previous = targetCommand
        rows.removeAll()
        var hasContent = false
        var hasClearable = false
        if let session {
            scopeLabel.stringValue = session.host.map { "主机 · \($0.displayName)" } ?? "本地终端"
            let scope = session.commandScope
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            func matches(_ text: String) -> Bool {
                needle.isEmpty || text.localizedCaseInsensitiveContains(needle)
            }

            let favorites = environment.commands.favorites(scope: scope)
            let tracked = sort == .mostUsed
                ? environment.commands.mostUsed(scope: scope)
                : environment.commands.mostRecent(scope: scope)
            let ignored = environment.commands.ignoredCommands(scope: scope)
            hasContent = !favorites.isEmpty || !tracked.isEmpty || !ignored.isEmpty
            // 清空只删统计/收藏与本机忽略；只剩全局规则时点了也什么都不会变。
            hasClearable = !favorites.isEmpty || !tracked.isEmpty || ignored.contains { !$0.global }

            let visibleFavorites = favorites.filter { matches($0.command) }
            if !visibleFavorites.isEmpty {
                rows.append(.group("收藏"))
                rows.append(contentsOf: visibleFavorites.map { Row.command($0) })
            }
            let rest = tracked.filter { !$0.favorite && matches($0.command) }
            if !rest.isEmpty {
                rows.append(.group(sort == .mostUsed ? "常用" : "最近"))
                rows.append(contentsOf: rest.map { Row.command($0) })
            }
            // 本机规则和全局规则分开展示：两者影响的范围不同，混在一起容易误删。
            let visibleIgnores = ignored.filter { matches($0.command) }
            let localIgnores = visibleIgnores.filter { !$0.global }
            let globalIgnores = visibleIgnores.filter { $0.global }
            if !localIgnores.isEmpty {
                rows.append(.group("本机忽略"))
                rows.append(contentsOf: localIgnores.map { Row.ignore($0) })
            }
            if !globalIgnores.isEmpty {
                rows.append(.group("全局忽略"))
                rows.append(contentsOf: globalIgnores.map { Row.ignore($0) })
            }

            let commandCount = rows.reduce(0) { count, row in
                if case .command = row { return count + 1 }
                return count
            }
            if rows.isEmpty, !needle.isEmpty {
                hintLabel.stringValue = "没有匹配 “\(needle)” 的内容"
            } else if !needle.isEmpty, commandCount == 0 {
                hintLabel.stringValue = "只匹配到忽略规则"
            } else if !needle.isEmpty {
                hintLabel.stringValue = "找到 \(commandCount) 条命令 · 单击填入终端"
            } else if !hasContent {
                hintLabel.stringValue = "还没有记录：敲过的命令会按主机累计在这里"
            } else {
                hintLabel.stringValue = "单击填入终端，不会自动回车"
            }
        } else {
            scopeLabel.stringValue = "未选择会话"
            hintLabel.stringValue = "先连上一台主机或开一个本地终端"
        }
        tableView.reloadData()
        restoreSelection(previous)
        updateControls(hasClearable: hasClearable)
    }

    /// 重排后把选区放回同一条命令上；没有选区时保持用户当前的滚动位置不动。
    private func restoreSelection(_ command: String?) {
        guard let command,
              let index = rows.firstIndex(where: {
                  if case .command(let record) = $0 { return record.command == command }
                  return false
              }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }

    private func updateControls(hasClearable: Bool) {
        let connected = session != nil
        ignoreButton.isEnabled = connected
        clearButton.isEnabled = connected && hasClearable
        sortPopup.isEnabled = connected
        searchField.isEnabled = connected
    }

    @objc private func sortChanged(_ sender: NSPopUpButton) {
        sort = Sort(rawValue: sender.indexOfSelectedItem) ?? .mostUsed
        reload()
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        query = sender.stringValue
        reload()
    }

    // MARK: - 单击注入

    @objc private func rowClicked(_ sender: NSTableView) {
        // 右键只用来选中与弹菜单，注入留给左键；双击的第二下不重复填入。
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.type == .rightMouseDown || event.clickCount > 1 {
            return
        }
        guard case .command(let record)? = row(at: sender.clickedRow) else { return }
        inject(record.command)
    }

    private func injectSelectedRow() {
        guard case .command(let record)? = row(at: tableView.selectedRow) else { return }
        inject(record.command)
    }

    private func inject(_ command: String) {
        guard let session else { return }
        guard session.state.isAlive else {
            hintLabel.stringValue = "会话已断开，命令无法填入"
            return
        }
        session.injectInput(command)
    }

    // MARK: - 右键动作

    private lazy var rowMenu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
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

    private var targetRowIndex: Int {
        // 右键菜单会先选中指针下的行，所以选中行优先；键盘操作也走这里。
        tableView.selectedRow >= 0 ? tableView.selectedRow : tableView.clickedRow
    }

    private var targetCommand: String? {
        guard case .command(let record)? = row(at: targetRowIndex) else { return nil }
        return record.command
    }

    private var targetIgnore: IgnoredCommand? {
        guard case .ignore(let rule)? = row(at: targetRowIndex) else { return nil }
        return rule
    }

    /// 菜单按指针下的行现场重建：已收藏的命令显示“取消收藏”，
    /// 本机忽略才提供“提升为全局”，避免点了与字面相反的动作。
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === rowMenu else { return }
        menu.removeAllItems()
        if tableView.clickedRow >= 0, !rows.isEmpty, tableView.clickedRow < rows.count,
           !rows[tableView.clickedRow].isGroup {
            tableView.selectRowIndexes(IndexSet(integer: tableView.clickedRow), byExtendingSelection: false)
        }
        switch row(at: tableView.clickedRow) {
        case .command(let record):
            menu.addItem(menuItem("填入终端", #selector(injectSelected(_:))))
            menu.addItem(menuItem("复制命令", #selector(copySelected(_:))))
            menu.addItem(.separator())
            menu.addItem(menuItem(record.favorite ? "取消收藏" : "收藏", #selector(toggleFavorite(_:))))
            menu.addItem(menuItem("加入忽略清单…", #selector(ignoreSelectedFromMenu(_:))))
            menu.addItem(.separator())
            menu.addItem(menuItem("删除这条记录", #selector(deleteSelected(_:))))
        case .ignore(let rule):
            menu.addItem(menuItem(rule.global ? "移出全局忽略" : "移出忽略清单", #selector(unignoreSelected(_:))))
            if !rule.global {
                menu.addItem(menuItem("提升为全局忽略", #selector(promoteSelectedIgnore(_:))))
            }
        default:
            let empty = NSMenuItem(title: "没有可用的操作", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let action = menuItem.action
        let command = targetCommand
        let ignore = targetIgnore
        switch action {
        case #selector(injectSelected(_:)): return command != nil
        case #selector(copySelected(_:)): return command != nil
        case #selector(toggleFavorite(_:)): return command != nil
        case #selector(ignoreSelectedFromMenu(_:)): return command != nil
        case #selector(promoteSelectedIgnore(_:)): return ignore?.global == false
        case #selector(unignoreSelected(_:)): return ignore != nil
        case #selector(deleteSelected(_:)): return command != nil
        default: return true
        }
    }

    @objc private func injectSelected(_ sender: NSMenuItem) {
        guard let command = targetCommand else { return }
        inject(command)
    }

    @objc private func copySelected(_ sender: NSMenuItem) {
        guard let command = targetCommand else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
    }

    @objc private func toggleFavorite(_ sender: NSMenuItem) {
        guard let command = targetCommand else { return }
        toggleFavoriteCommand(command)
    }

    /// 行首星标与右键菜单走同一条路径：收藏状态一变，列表会在收藏/常用两组之间重排。
    private func toggleFavoriteCommand(_ command: String) {
        guard let scope = scopeKey else { return }
        let favorite = environment.commands.entry(scope: scope, command: command)?.favorite != true
        environment.commands.setFavorite(command, scope: scope, favorite: favorite)
    }

    @objc private func deleteSelected(_ sender: NSMenuItem) {
        guard let scope = scopeKey, let command = targetCommand else { return }
        environment.commands.remove(command: command, scope: scope)
    }

    @objc private func ignoreSelectedFromMenu(_ sender: NSMenuItem) {
        guard let command = targetCommand else { return }
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
        guard CommandLibraryStore.normalize(field.stringValue) != nil else {
            AlertPresenter.notify(
                title: "命令不能为空",
                message: "忽略规则需要一条完整命令，且不能包含换行等控制字符。",
                in: view.window
            )
            return
        }
        confirmIgnore(command: field.stringValue)
    }

    /// 忽略分两层：本机只挡当前主机，全局挡所有主机。默认按本机处理，避免误伤别的机器。
    private func confirmIgnore(command: String) {
        guard let scope = scopeKey else { return }
        let alert = NSAlert()
        // 长命令不能把确认框撑到屏幕外，显示时只留开头一段。
        let shown = command.count > 48 ? String(command.prefix(48)) + "…" : command
        alert.messageText = "忽略 “\(shown)”？"
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
        guard let scope = scopeKey, let rule = targetIgnore, !rule.global else { return }
        environment.commands.promoteIgnoreToGlobal(rule.command, scope: scope)
    }

    @objc private func unignoreSelected(_ sender: NSMenuItem) {
        guard let rule = targetIgnore else { return }
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
        guard rows.indices.contains(row) else { return false }
        return rows[row].isGroup
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        return !rows[row].isGroup
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, tableColumn.identifier == Self.columnIdentifier,
              rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .group(let title):
            return makeGroupCell(title)
        case .command(let record):
            let cell = makeCell()
            cell.icon.image = Self.symbol(record.favorite ? "star.fill" : "star")
            cell.icon.contentTintColor = record.favorite ? .systemYellow : .tertiaryLabelColor
            cell.icon.isEnabled = true
            cell.icon.toolTip = record.favorite ? "取消收藏" : "收藏"
            cell.onToggleFavorite = { [weak self] in self?.toggleFavoriteCommand(record.command) }
            cell.title.stringValue = record.command
            cell.trailing.stringValue = "\(record.executionCount) 次"
            cell.toolTip = "\(record.command)\n共 \(record.executionCount) 次 · 最后使用 \(Self.dateFormatter.string(from: record.lastExecutedAt))"
            return cell
        case .ignore(let rule):
            let cell = makeCell()
            cell.icon.image = Self.symbol("nosign")
            cell.icon.contentTintColor = .secondaryLabelColor
            cell.icon.isEnabled = false
            cell.icon.toolTip = nil
            cell.onToggleFavorite = nil
            cell.title.stringValue = rule.command
            // 分组标题已经写明本机/全局，这里不再重复。
            cell.trailing.stringValue = ""
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

/// 命令行：星标按钮 + 命令文本 + 右侧次数或规则层级。
@MainActor
private final class CommandCell: NSTableCellView {
    let icon = NSButton()
    let title = NSTextField(labelWithString: "")
    let trailing = NSTextField(labelWithString: "")
    /// 点星标只切换收藏，不触发整行的“填入终端”。
    var onToggleFavorite: (() -> Void)?

    init() {
        super.init(frame: .zero)
        // 星标做成无边框按钮：它看起来就该能点，实际也确实能点。
        icon.isBordered = false
        icon.bezelStyle = .inline
        icon.imagePosition = .imageOnly
        icon.imageScaling = .scaleProportionallyDown
        icon.focusRingType = .none
        icon.setButtonType(.momentaryChange)
        icon.target = self
        icon.action = #selector(toggleFavoriteClicked)

        title.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        title.lineBreakMode = .byTruncatingMiddle
        title.textColor = .labelColor
        trailing.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        trailing.textColor = .secondaryLabelColor
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let stack = NSStackView(views: [icon, title, trailing])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        self.textField = title
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    @objc private func toggleFavoriteClicked() {
        onToggleFavorite?()
    }
}

/// 窗口不是活动状态时，第一次点击也要直接落到命令行上；
/// 否则用户点完命令再按回车，按键还留在列表里，终端看起来毫无反应。
@MainActor
private final class CommandTableView: NSTableView {
    /// 列表获得焦点时回车即刻填入，和鼠标单击同义。
    var onReturn: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }
}
