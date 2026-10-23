import AppKit
import MioTermCore

/// 左侧远端文件树：顶层就是当前目录的内容，目录按需展开。
///
/// 面板本身不持有连接，只跟随当前标签的 `SFTPSession`；
/// 切标签时重新绑定，避免一棵树同时对着两台主机。
@MainActor
final class SFTPBrowserViewController: NSViewController {
    private static let nameColumn = NSUserInterfaceItemIdentifier("name")
    private static let sizeColumn = NSUserInterfaceItemIdentifier("size")
    private static let jobColumn = NSUserInterfaceItemIdentifier("job")

    /// 树上的一行。children 为 nil 表示还没读过该目录，展开时才发读取请求。
    private final class Node: Hashable {
        let entry: SFTPFileEntry
        var children: [Node]?
        var loaded = false
        var failed: String?

        init(_ entry: SFTPFileEntry) {
            self.entry = entry
        }

        static func == (lhs: Node, rhs: Node) -> Bool { lhs === rhs }
        func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    }

    /// 展开/折叠要触发远程读取，委托方法名在不同 SDK 上写法不一，直接拦 expandItem 更可靠。
    private final class FileOutlineView: NSOutlineView {
        var onExpand: ((Any?) -> Void)?
        var onCollapse: ((Any?) -> Void)?

        override func expandItem(_ item: Any?, expandChildren: Bool) {
            onExpand?(item)
            super.expandItem(item, expandChildren: expandChildren)
        }

        override func collapseItem(_ item: Any?, collapseChildren: Bool) {
            if let item { onCollapse?(item) }
            super.collapseItem(item, collapseChildren: collapseChildren)
        }
    }

    private let environment = AppEnvironment.shared
    private var session: SFTPSession?
    private var boundController: TerminalController?
    /// 只对当前标签的终端订阅上下文变化，切标签后旧标签的输出不能再惊动这棵树。
    private weak var contextController: TerminalController?
    private var lastContext = TerminalContext()

    private let outlineView = FileOutlineView()
    /// 树的第一层 = 这个目录的直接子项；不再套一层主机名节点。
    private var roots: [Node] = []
    private var currentDirectory: String?

    /// 当前目录的位置导航：操作按钮下面一条可点的面包屑。
    private let pathScroll = NSScrollView()
    private let pathBar = NSStackView()

    private let refreshButton = NSButton()
    private let goToButton = NSButton()
    private let newFolderButton = NSButton()
    private let uploadButton = NSButton()
    private let downloadButton = NSButton()
    private let hiddenToggle = NSButton()
    private let retryButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "未选择 SSH 会话")
    private let transferTable = NSTableView()
    private let transferScroll = NSScrollView()

    private var transfers: [UUID: SFTPTransferProgress] = [:]
    private var transferOrder: [UUID] = []
    private var showHidden = false
    private var isBusy = false
    /// 上传落点记下来，传输结束后只重读这一层，不用整棵树回到根目录。
    private var lastUploadDirectory: String?

    override func loadView() {
        configureChrome()
        configureTables()

        let actions = NSStackView(views: [refreshButton, goToButton, newFolderButton, uploadButton, downloadButton, hiddenToggle])
        actions.orientation = .horizontal
        actions.spacing = 4
        actions.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 2, right: 8)

        let statusRow = NSStackView(views: [statusLabel, retryButton])
        statusRow.orientation = .horizontal
        statusRow.spacing = 6
        statusRow.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 6, right: 8)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let treeScroll = NSScrollView()
        treeScroll.documentView = outlineView
        treeScroll.hasVerticalScroller = true
        treeScroll.autohidesScrollers = true
        treeScroll.borderType = .noBorder
        treeScroll.drawsBackground = false

        transferScroll.documentView = transferTable
        transferScroll.hasVerticalScroller = true
        transferScroll.autohidesScrollers = true
        transferScroll.borderType = .noBorder
        transferScroll.drawsBackground = false
        transferScroll.isHidden = true

        let body = NSStackView(views: [actions, treeScroll, statusRow, transferScroll])
        body.orientation = .vertical
        body.alignment = .leading
        body.distribution = .fill
        body.spacing = 0
        body.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 640))
        root.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.topAnchor.constraint(equalTo: root.topAnchor),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            // 竖排栈按 leading 对齐时行宽只由内容决定，需要撑满的行要显式钉住。
            actions.widthAnchor.constraint(equalTo: body.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: body.widthAnchor),
            treeScroll.widthAnchor.constraint(equalTo: body.widthAnchor),
            transferScroll.widthAnchor.constraint(equalTo: body.widthAnchor),
            treeScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            transferScroll.heightAnchor.constraint(equalToConstant: 128),
        ])
        treeScroll.setContentHuggingPriority(.init(1), for: .vertical)
        view = root
    }

    private func configureChrome() {
        for (button, symbol, action) in [
            (refreshButton, "arrow.clockwise", #selector(reloadTree)),
            (goToButton, "arrow.right.circle", #selector(goToDirectory)),
            (newFolderButton, "folder.badge.plus", #selector(createDirectory)),
            (uploadButton, "arrow.up.doc", #selector(uploadFiles)),
            (downloadButton, "arrow.down.doc", #selector(downloadSelected)),
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageOnly
            button.bezelStyle = .texturedRounded
            button.controlSize = .small
            button.target = self
            button.action = action
            button.toolTip = tooltip(for: button)
        }
        hiddenToggle.setButtonType(.pushOnPushOff)
        hiddenToggle.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "显示隐藏文件")
        hiddenToggle.imagePosition = .imageOnly
        hiddenToggle.bezelStyle = .texturedRounded
        hiddenToggle.controlSize = .small
        hiddenToggle.target = self
        hiddenToggle.action = #selector(toggleHidden)

        retryButton.title = "重试"
        retryButton.bezelStyle = .recessed
        retryButton.controlSize = .mini
        retryButton.target = self
        retryButton.action = #selector(reconnectChannel)
        retryButton.isHidden = true
    }

    private func tooltip(for button: NSButton) -> String {
        switch button {
        case refreshButton: return "重新读取当前目录"
        case goToButton: return "打开指定目录…"
        case newFolderButton: return "在选中目录下新建文件夹"
        case uploadButton: return "上传文件到选中目录"
        case downloadButton: return "下载选中文件到本地"
        default: return "显示/隐藏点文件"
        }
    }

    private func configureTables() {
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.indentationPerLevel = 10
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.allowsMultipleSelection = true
        outlineView.rowSizeStyle = .small
        outlineView.autoresizesOutlineColumn = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.menu = fileMenu
        outlineView.doubleAction = #selector(handleDoubleClick)
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.onExpand = { [weak self] item in self?.loadChildren(of: item) }
        outlineView.onCollapse = { [weak self] item in self?.forgetChildren(of: item) }

        let name = NSTableColumn(identifier: Self.nameColumn)
        name.title = "名称"
        name.resizingMask = .autoresizingMask
        outlineView.addTableColumn(name)
        outlineView.outlineTableColumn = name

        let size = NSTableColumn(identifier: Self.sizeColumn)
        size.title = "大小"
        size.width = 62
        size.minWidth = 44
        outlineView.addTableColumn(size)

        transferTable.headerView = nil
        transferTable.usesAlternatingRowBackgroundColors = false
        transferTable.rowSizeStyle = .small
        transferTable.dataSource = self
        transferTable.delegate = self
        transferTable.menu = transferMenu
        let job = NSTableColumn(identifier: Self.jobColumn)
        job.title = "任务"
        job.resizingMask = .autoresizingMask
        transferTable.addTableColumn(job)
    }

    private lazy var fileMenu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(menuItem("展开/折叠", #selector(toggleExpansion)))
        menu.addItem(menuItem("下载", #selector(downloadSelected)))
        menu.addItem(.separator())
        menu.addItem(menuItem("新建文件夹…", #selector(createDirectory)))
        menu.addItem(menuItem("重命名…", #selector(renameSelected)))
        menu.addItem(menuItem("删除", #selector(deleteSelected)))
        return menu
    }()

    private lazy var transferMenu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(menuItem("暂停", #selector(pauseTransfer(_:))))
        menu.addItem(menuItem("继续", #selector(resumeTransfer(_:))))
        menu.addItem(.separator())
        menu.addItem(menuItem("取消", #selector(cancelTransfer(_:))))
        menu.addItem(menuItem("清除已完成", #selector(clearFinishedTransfers)))
        return menu
    }()

    /// 面板内的菜单项一律显式指向本控制器，避免右键时靠响应链撞到终端视图。
    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - 绑定会话

    /// 跟随当前标签；传 nil 解绑并清空树。
    func bind(to controller: TerminalController?) {
        boundController = controller
        guard controller != nil else {
            detach()
            roots = []
            currentDirectory = nil
            lastUploadDirectory = nil
            resetContent("未选择会话")
            return
        }
        // 视图没进窗口就建通道等于白起一个 ssh 子进程，等 viewDidAppear 再连。
        guard isViewLoaded, view.window != nil else { return }
        applyBinding()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applyBinding()
    }

    private func applyBinding() {
        guard let controller = boundController,
              let host = controller.host,
              host.protocolKind.supportsSFTP,
              let next = environment.sftpSession(for: controller) else {
            detach()
            roots = []
            currentDirectory = nil
            resetContent(Self.placeholder(for: boundController, host: boundController?.host))
            return
        }
        guard next !== session else {
            if currentDirectory == nil, next.state == .ready {
                Task { await self.reloadCurrentDirectory() }
            }
            updateControls()
            return
        }
        detach()
        session = next
        lastUploadDirectory = nil
        currentDirectory = nil
        next.onStateChange = { [weak self] state in self?.render(state: state) }
        next.onTransferUpdate = { [weak self] progress in self?.update(progress) }
        clearTransfers()
        render(state: next.state)
        switch next.state {
        case .ready: Task { await self.reloadCurrentDirectory() }
        case .connecting: break
        default: Task { await self.connectAndBrowse() }
        }
    }

    private static func placeholder(for controller: TerminalController?, host: HostProfile?) -> String {
        if controller == nil { return "未选择会话" }
        guard let host else { return "本地终端没有文件通道" }
        return "\(host.protocolKind.displayName) 连接不提供文件面板"
    }

    private func detach() {
        session?.onStateChange = nil
        session?.onTransferUpdate = nil
        session = nil
    }

    private func resetContent(_ status: String) {
        outlineView.reloadData()
        clearTransfers()
        statusLabel.stringValue = status
        retryButton.isHidden = true
        updateControls()
    }

    private func render(state: SFTPSession.State) {
        switch state {
        case .closed: statusLabel.stringValue = "未连接"
        case .connecting: statusLabel.stringValue = "正在打开文件通道…"
        case .ready: statusLabel.stringValue = currentDirectory ?? "已连接"
        case .failed(let reason): statusLabel.stringValue = "连接失败：\(reason)"
        }
        retryButton.isHidden = !state.isFailed
        updateControls()
    }

    private func updateControls() {
        let interactive = session?.state == .ready && !isBusy
        for button in [refreshButton, goToButton, newFolderButton, uploadButton, downloadButton, hiddenToggle] {
            button.isEnabled = interactive
        }
    }

    // MARK: - 目录读取

    @objc private func reconnectChannel() {
        Task { await connectAndBrowse() }
    }

    @objc private func reloadTree() {
        Task { await reloadCurrentDirectory() }
    }

    @objc private func toggleHidden() {
        showHidden = hiddenToggle.state == .on
        Task { await reloadCurrentDirectory() }
    }

    /// 树只会向下展开，没有这个入口就出不了登录目录。
    @objc private func goToDirectory() {
        guard let session else { return }
        guard let raw = pathPrompt(value: currentDirectory ?? ".") else { return }
        Task {
            do {
                let client = try await session.ensureClient()
                await open(directory: try await client.realpath(raw))
            } catch {
                AlertPresenter.fail(title: "打开目录失败", message: error.localizedDescription, in: view.window)
            }
        }
    }

    private func connectAndBrowse() async {
        do {
            guard let session else { return }
            let client = try await session.ensureClient()
            await open(directory: try await client.realpath(startPath(for: session.host)))
        } catch {
            AlertPresenter.fail(title: "打开文件面板失败", message: error.localizedDescription, in: view.window)
        }
    }

    /// 起始目录：开了“跟随终端目录”就用 OSC 7 报上来的当前目录，
    /// 其次主机配置的起始目录，最后服务端登录目录。
    private func startPath(for host: HostProfile) -> String {
        if environment.settings.settings.followTerminalDirectory,
           let cwd = Self.remoteDirectory(of: boundController?.workingDirectory) {
            return SFTPPath.normalize(cwd)
        }
        return SFTPPath.normalize(host.startupDirectory.isEmpty ? "." : host.startupDirectory)
    }

    /// OSC 7 的载荷形如 file://主机/路径，SFTP 服务端只认路径部分。
    private static func remoteDirectory(of osc7: String?) -> String? {
        guard let osc7, !osc7.isEmpty else { return nil }
        if osc7.hasPrefix("file://"), let path = URL(string: osc7)?.path, !path.isEmpty { return path }
        return osc7.hasPrefix("/") ? osc7 : nil
    }

    /// 重读当前这一层；已经展开的子层跟着重新点开。
    private func reloadCurrentDirectory() async {
        guard session?.client != nil, let host = session?.host else { return }
        await open(directory: currentDirectory ?? startPath(for: host))
    }

    /// 把 `directory` 的直接子项铺成树的第一层，不再套主机名节点。
    private func open(directory: String) async {
        guard !isBusy, let client = session?.client else { return }
        isBusy = true
        updateControls()
        defer {
            isBusy = false
            updateControls()
        }
        let expanded = expandedPaths()
        var failure = ""
        do {
            roots = try await client.list(directory, showHidden: showHidden).map { Node($0) }
        } catch {
            roots = []
            failure = "：\(error.localizedDescription)"
        }
        currentDirectory = directory
        statusLabel.stringValue = directory + failure
        outlineView.reloadData()
        restoreExpansion(expanded)
    }

    private func expandedPaths() -> Set<String> {
        var paths: Set<String> = []
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? Node, outlineView.isItemExpanded(node) {
                paths.insert(node.entry.path)
            }
        }
        return paths
    }

    private func restoreExpansion(_ paths: Set<String>) {
        for path in paths {
            if let node = findNode(path: path) {
                outlineView.expandItem(node)
            }
        }
    }

    private func loadChildren(of item: Any?) {
        guard let node = item as? Node, !node.loaded else { return }
        Task { await loadChildren(of: node) }
    }

    private func loadChildren(of node: Node) async {
        guard let client = session?.client else { return }
        do {
            let listed = try await client.list(node.entry.path, showHidden: showHidden)
            node.children = listed.map { Node($0) }
            node.failed = nil
        } catch {
            node.children = []
            node.failed = error.localizedDescription
            statusLabel.stringValue = "读取 \(node.entry.path) 失败：\(error.localizedDescription)"
        }
        node.loaded = true
        outlineView.reloadItem(node, reloadChildren: true)
    }

    /// 折叠即忘：再点开时重新读，避免树里留着早已不存在的文件。
    private func forgetChildren(of item: Any?) {
        guard let node = item as? Node, node.loaded else { return }
        node.children = nil
        node.loaded = false
    }

    private func findNode(path: String) -> Node? {
        search(roots, path: path)
    }

    private func search(_ nodes: [Node], path: String) -> Node? {
        for node in nodes {
            if node.entry.path == path { return node }
            if let hit = search(node.children ?? [], path: path) { return hit }
        }
        return nil
    }

    // MARK: - 选择

    private var selectedNodes: [Node] {
        outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? Node }
    }

    private var targetNode: Node? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        if row >= 0, let node = outlineView.item(atRow: row) as? Node { return node }
        return selectedNodes.first
    }

    /// 上传落点：选中目录用目录，选中文件用它的父目录，都没选就落在当前这一层。
    private var uploadDirectory: String {
        guard let node = targetNode else { return currentDirectory ?? "/" }
        return node.entry.isDirectory ? node.entry.path : SFTPPath.parent(node.entry.path)
    }

    @objc private func handleDoubleClick() {
        guard let node = targetNode else { return }
        if node.entry.isDirectory {
            toggleExpansion()
        } else {
            downloadSelected()
        }
    }

    @objc private func toggleExpansion() {
        guard let node = targetNode, node.entry.isDirectory else { return }
        if outlineView.isItemExpanded(node) {
            outlineView.collapseItem(node)
        } else {
            outlineView.expandItem(node)
        }
    }

    // MARK: - 目录操作

    @objc private func createDirectory() {
        let parent = uploadDirectory
        guard let name = prompt(title: "新建文件夹", message: "在 \(parent) 下创建：", value: "新建文件夹") else { return }
        let target = SFTPPath.join(parent, name)
        Task {
            do {
                try await session?.client?.makeDirectory(target)
                await reread(parent)
            } catch {
                AlertPresenter.fail(title: "新建文件夹失败", message: error.localizedDescription, in: view.window)
            }
        }
    }

    @objc private func renameSelected() {
        guard let node = targetNode else { return }
        guard let name = prompt(title: "重命名 “\(node.entry.name)”", message: "新名称：", value: node.entry.name) else { return }
        let parent = SFTPPath.parent(node.entry.path)
        let target = SFTPPath.join(parent, name)
        Task {
            do {
                try await session?.client?.move(from: node.entry.path, to: target)
                await reread(parent)
            } catch {
                AlertPresenter.fail(title: "重命名失败", message: error.localizedDescription, in: view.window)
            }
        }
    }

    @objc private func deleteSelected() {
        let targets = selectedNodes
        guard let first = targets.first else { return }
        let alert = NSAlert()
        alert.messageText = "删除 \(targets.count) 项？"
        alert.informativeText = targets.map { $0.entry.name }.joined(separator: "、")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let parent = SFTPPath.parent(first.entry.path)
        Task {
            for node in targets {
                do {
                    if node.entry.isDirectory {
                        try await session?.client?.removeDirectory(node.entry.path)
                    } else {
                        try await session?.client?.removeFile(node.entry.path)
                    }
                } catch {
                    AlertPresenter.fail(title: "删除 \(node.entry.name) 失败", message: error.localizedDescription, in: view.window)
                }
            }
            await reread(parent)
        }
    }

    /// 只重读受影响的那一层，整棵树回到起点会让人找不到刚才在哪。
    private func reread(_ path: String) async {
        guard session?.client != nil else { return }
        guard path != currentDirectory else {
            await open(directory: path)
            return
        }
        guard let node = findNode(path: path) else {
            await reloadCurrentDirectory()
            return
        }
        node.loaded = false
        node.children = nil
        await loadChildren(of: node)
        if !outlineView.isItemExpanded(node) {
            outlineView.expandItem(node)
        }
    }

    private func prompt(title: String, message: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("/") else {
            AlertPresenter.fail(title: "名称不合法", message: "名称不能为空，也不能包含 “/”。", in: view.window)
            return nil
        }
        return text
    }

    /// 目录输入不能套文件名的校验：路径当然有 “/”。
    private func pathPrompt(value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "打开远端目录"
        alert.informativeText = "输入绝对路径；相对路径按服务端登录目录解析："
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: "打开")
        alert.addButton(withTitle: "取消")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - 上传下载

    @objc private func uploadFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "上传"
        panel.message = "上传到 \(uploadDirectory)"
        guard panel.runModal() == .OK else { return }
        scheduleUploads(panel.urls)
    }

    /// 从 Finder 拖文件到树即上传，和 webterm 的拖拽上传一致。
    func uploadDroppedFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        scheduleUploads(urls)
    }

    private func scheduleUploads(_ urls: [URL], to directory: String? = nil) {
        guard let transfers = session?.transfers else {
            AlertPresenter.fail(title: "文件通道未就绪", message: "等文件连接建立后再传输，或点状态行的“重试”重连。", in: view.window)
            return
        }
        let target = directory ?? uploadDirectory
        lastUploadDirectory = target
        Task { await transfers.enqueueUploads(urls, to: target) }
    }

    @objc private func downloadSelected() {
        let files = selectedNodes.filter { !$0.entry.isDirectory }.map(\.entry)
        guard !files.isEmpty else {
            AlertPresenter.notify(title: "未选择文件", message: "先选中要下载的文件（目录暂不支持整目录下载）。", in: view.window)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "下载到这里"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        guard let transfers = session?.transfers else {
            AlertPresenter.fail(title: "文件通道未就绪", message: "等文件连接建立后再传输。", in: view.window)
            return
        }
        Task { await transfers.enqueueDownloads(files, to: directory) }
    }

    private func update(_ progress: SFTPTransferProgress) {
        if transfers[progress.id] == nil {
            transferOrder.append(progress.id)
        }
        // 完成后先留在队列里让人看清结果，需要清理走右键“清除已完成”。
        transfers[progress.id] = progress
        if progress.isFinished, progress.state == .completed, progress.kind == .upload {
            Task { await self.rereadUploadedDirectory() }
        }
        transferScroll.isHidden = transferOrder.isEmpty
        transferTable.reloadData()
    }

    private func rereadUploadedDirectory() async {
        guard let directory = lastUploadDirectory,
              directory == currentDirectory || findNode(path: directory) != nil else { return }
        await reread(directory)
    }

    private func clearTransfers() {
        transfers.removeAll()
        transferOrder.removeAll()
        transferScroll.isHidden = true
        transferTable.reloadData()
    }

    @objc private func clearFinishedTransfers() {
        let finished = transferOrder.filter { transfers[$0]?.isFinished == true }
        for id in finished {
            transfers.removeValue(forKey: id)
            transferOrder.removeAll { $0 == id }
        }
        transferScroll.isHidden = transferOrder.isEmpty
        transferTable.reloadData()
        Task { await session?.transfers?.clearFinished() }
    }

    private var targetedTransfer: SFTPTransferProgress? {
        let row = transferTable.clickedRow >= 0 ? transferTable.clickedRow : transferTable.selectedRow
        guard transferOrder.indices.contains(row) else { return nil }
        return transfers[transferOrder[row]]
    }

    @objc private func pauseTransfer(_ sender: Any?) {
        guard let id = targetedTransfer?.id else { return }
        Task { await session?.transfers?.pause(id) }
    }

    @objc private func resumeTransfer(_ sender: Any?) {
        guard let id = targetedTransfer?.id else { return }
        Task { await session?.transfers?.resume(id) }
    }

    @objc private func cancelTransfer(_ sender: Any?) {
        guard let id = targetedTransfer?.id else { return }
        Task { await session?.transfers?.cancel(id) }
    }
}

// MARK: - 数据源、代理与菜单校验

extension SFTPBrowserViewController: NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation, NSMenuDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return roots.count }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let children = (item as? Node)?.children ?? roots
        if children.indices.contains(index) { return children[index] }
        // 异步读取替换 children 的瞬间可能读到旧行号，返回父节点等下一次 reload 修正。
        return (item as? Node) ?? roots.first ?? Node(SFTPFileEntry(path: "/", name: "…", isDirectory: true, size: 0, modifiedAt: nil))
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.entry.isDirectory == true
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        switch tableColumn?.identifier {
        case Self.nameColumn: return nameCell(for: node)
        case Self.sizeColumn: return textCell(node.entry.isDirectory ? "" : node.entry.sizeText, secondary: true, align: .right)
        default: return nil
        }
    }

    private func nameCell(for node: Node) -> NSView {
        let symbol: String
        if !node.entry.isDirectory {
            symbol = "doc"
        } else {
            symbol = outlineView.isItemExpanded(node) ? "folder" : "folder.fill"
        }
        let title = node.entry.name + (node.failed != nil ? " · 读取失败" : "")
        return iconCell(text: title, symbol: symbol, tint: node.entry.isDirectory ? .controlAccentColor : .secondaryLabelColor)
    }

    private func textCell(_ text: String, secondary: Bool = false, align: NSTextAlignment = .left) -> NSTextField {
        let cell = NSTextField(labelWithString: text)
        cell.font = secondary ? .systemFont(ofSize: 11) : .systemFont(ofSize: 12)
        cell.lineBreakMode = .byTruncatingMiddle
        cell.alignment = align
        cell.textColor = secondary ? .secondaryLabelColor : .labelColor
        return cell
    }

    /// NSTextField 没有 image 属性，名称列的图标只能自己拼。
    private func iconCell(text: String, symbol: String, tint: NSColor) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = textCell(text)
        label.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSTableCellView()
        cell.textField = label
        cell.addSubview(icon)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: 传输队列

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView == transferTable ? transferOrder.count : 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tableColumn?.identifier == Self.jobColumn,
              transferOrder.indices.contains(row),
              let progress = transfers[transferOrder[row]] else { return nil }
        return jobCell(progress)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        46
    }

    private func jobCell(_ progress: SFTPTransferProgress) -> NSView {
        let title = NSTextField(labelWithString: "\(progress.kind.displayName) · \(progress.name)")
        title.font = .systemFont(ofSize: 11)
        title.lineBreakMode = .byTruncatingMiddle
        title.translatesAutoresizingMaskIntoConstraints = false
        let detail = NSTextField(labelWithString: "\(progress.detailText) · \(progress.state.displayName)")
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.translatesAutoresizingMaskIntoConstraints = false
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = progress.fraction
        bar.controlSize = .mini
        bar.translatesAutoresizingMaskIntoConstraints = false

        let cell = NSTableCellView()
        cell.addSubview(title)
        cell.addSubview(detail)
        cell.addSubview(bar)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 3),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            bar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            bar.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 3),
        ])
        return cell
    }

    // MARK: 菜单

    /// 右键不会自动把指针下的行选上，这里补选，否则“下载/删除”会作用在旧选区。
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu == transferMenu {
            let row = transferTable.clickedRow
            guard row >= 0, !transferTable.selectedRowIndexes.contains(row) else { return }
            transferTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            return
        }
        let row = outlineView.clickedRow
        guard row >= 0, !outlineView.selectedRowIndexes.contains(row) else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleExpansion):
            return targetNode?.entry.isDirectory == true
        case #selector(downloadSelected):
            return !selectedNodes.filter { !$0.entry.isDirectory }.isEmpty
        case #selector(renameSelected):
            return targetNode != nil
        case #selector(deleteSelected):
            return !selectedNodes.isEmpty
        case #selector(pauseTransfer(_:)):
            return targetedTransfer?.state == .running
        case #selector(resumeTransfer(_:)):
            return targetedTransfer?.state == .paused
        case #selector(cancelTransfer(_:)):
            return targetedTransfer != nil
        case #selector(clearFinishedTransfers):
            return transferOrder.contains { transfers[$0]?.isFinished == true }
        default:
            return true
        }
    }

    // MARK: 拖放上传

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard session?.transfers != nil, index == -1 || index == 0 else { return [] }
        return info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) ? .copy : []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        if let node = item as? Node, node.entry.isDirectory {
            scheduleUploads(urls, to: node.entry.path)
        } else {
            uploadDroppedFiles(urls)
        }
        return true
    }
}
