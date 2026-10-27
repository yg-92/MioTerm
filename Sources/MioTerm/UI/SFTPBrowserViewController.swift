import AppKit
import MioTermCore

/// 左侧远端文件列表：只展示当前目录的直接子项，双击目录进入下一层。
///
/// 面板本身不持有连接，只跟随当前标签的 `SFTPSession`；
/// 切标签时重新绑定，避免一份列表同时对着两台主机。
@MainActor
final class SFTPBrowserViewController: NSViewController {
    private static let nameColumn = NSUserInterfaceItemIdentifier("name")
    private static let jobColumn = NSUserInterfaceItemIdentifier("job")
    /// 行尾“大小”文字的宽度，和名称列固定一起排版，各行文件名起点才对得齐。
    private static let sizeColumnWidth: CGFloat = 62

    private let environment = AppEnvironment.shared
    private var session: SFTPSession?
    private var boundController: TerminalController?
    /// 只对当前标签的终端订阅上下文变化，切标签后旧标签的输出不能再惊动这份列表。
    private weak var contextController: TerminalController?
    private var contextToken: UUID?
    private var lastContext = TerminalContext()
    /// 这个标签是否已经按终端目录对齐过一次；没有的话第一次拿到目标就得动，
    /// 不能因为「和上次记的上下文一样」而谁都不动。
    private var hasAlignedWithTerminal = false
    /// 提示符只写 `~` 时用来换成绝对路径的远端主目录，向 SFTP 服务端问一次。
    private var remoteHome: String?
    private var isResolvingHome = false
    /// 问过一次没问出来就记下：换通道、用户点刷新之前不再问，否则跟随会原地自旋。
    private var homeUnresolvable = false

    private let fileTable = NSTableView()
    /// 名称列要靠 sizeLastColumnToFit() 铺满一次，之后才会跟着表格宽度自动伸缩。
    private var didFitNameColumn = false
    /// 当前目录的直接子项；进入下一层就是整份替换掉。
    private var entries: [SFTPFileEntry] = []
    private var currentDirectory: String?

    /// 当前目录的位置导航：操作按钮下面一条可点的面包屑。
    private let pathScroll = NSScrollView()
    private let pathBar = NSStackView()
    /// 面包屑每段代表的路径，按钮用 tag 索引它（NSButton 没有 representedObject）。
    private var breadcrumbPaths: [String] = []

    private let refreshButton = GlassActionButton()
    private let goToButton = GlassActionButton()
    private let newFolderButton = GlassActionButton()
    private let uploadButton = GlassActionButton()
    private let downloadButton = GlassActionButton()
    private let hiddenToggle = GlassActionButton()
    /// 每个标签单独的跟随开关：全局设置管默认，临时不想被终端拽走时在这里关掉。
    private let followToggle = FollowToggleButton()
    private let retryButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "未选择 SSH 会话")
    /// 远端拒绝 SFTP 子系统时，在列表的位置给出说明；这种情况不该弹错误框。
    private let noticeStack = NSStackView()
    private let noticeTitle = NSTextField(labelWithString: "服务器未启用 SFTP 文件服务")
    private let noticeDetail = NSTextField(wrappingLabelWithString: "")
    private let transferTable = NSTableView()
    private let transferScroll = NSScrollView()

    private var transfers: [UUID: SFTPTransferProgress] = [:]
    private var transferOrder: [UUID] = []
    private var showHidden = false
    private var isBusy = false
    /// 状态行当前显示的是不是“终端环境导致的暂停”，退出容器后要收回去。
    private var isPausedByTerminal = false
    /// 下一次要读的目录。读取中来了新请求就顶掉旧的，读完立刻换过去，
    /// 这样跟随和手动浏览都不会因为“正忙”被整条丢掉。
    private var listingTarget: String?
    /// 上一次生效的“跟随终端目录”开关，用来认出用户刚在设置里把它打开。
    private var lastFollowSetting = false
    /// 按标签覆盖全局设置的选择；会话 ID 每次连接都是新的，所以只活在本次运行里，不必落盘。
    private var followOverrides: [UUID: Bool] = [:]
    /// 上传落点记下来，传完后只有落在当前目录才需要重读列表。
    private var lastUploadDirectory: String?

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        configureChrome()
        configurePathBar()
        configureTables()
        configureNotice()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: .mioTermSettingsDidChange,
            object: nil
        )
        applyTreeMetrics()

        // 跟随开关放在顶部操作行：底部状态行在矮窗口里会被裁掉，
        // 而“现在到底跟不跟随”是用户最需要一眼确认的信息。
        // 整条操作行跟着文件面板宽度伸缩，窄的时候按钮间距和宽度自动收紧。
        let actionRow = FileActionRow(
            buttons: [refreshButton, goToButton, newFolderButton, uploadButton, downloadButton, hiddenToggle],
            accessory: followToggle
        )
        let actionBar = GlassBarView(
            content: actionRow,
            padding: NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        )
        actionBar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        let actions = NSView()
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.addSubview(actionBar)
        NSLayoutConstraint.activate([
            actionBar.leadingAnchor.constraint(equalTo: actions.leadingAnchor, constant: 8),
            actionBar.trailingAnchor.constraint(equalTo: actions.trailingAnchor, constant: -8),
            actionBar.topAnchor.constraint(equalTo: actions.topAnchor, constant: 6),
            actionBar.bottomAnchor.constraint(equalTo: actions.bottomAnchor, constant: -2),
        ])

        let statusRow = NSStackView(views: [statusLabel, retryButton])
        statusRow.orientation = .horizontal
        statusRow.spacing = 6
        statusRow.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 6, right: 8)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let treeScroll = NSScrollView()
        treeScroll.documentView = fileTable
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

        let body = NSStackView(views: [actions, pathScroll, treeScroll, statusRow, transferScroll])
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
            pathScroll.widthAnchor.constraint(equalTo: body.widthAnchor),
            pathScroll.heightAnchor.constraint(equalToConstant: 22),
            statusRow.widthAnchor.constraint(equalTo: body.widthAnchor),
            treeScroll.widthAnchor.constraint(equalTo: body.widthAnchor),
            transferScroll.widthAnchor.constraint(equalTo: body.widthAnchor),
            treeScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            transferScroll.heightAnchor.constraint(equalToConstant: 128),
        ])
        treeScroll.setContentHuggingPriority(.init(1), for: .vertical)
        root.addSubview(noticeStack)
        NSLayoutConstraint.activate([
            noticeStack.centerXAnchor.constraint(equalTo: treeScroll.centerXAnchor),
            noticeStack.centerYAnchor.constraint(equalTo: treeScroll.centerYAnchor, constant: -6),
            noticeStack.leadingAnchor.constraint(greaterThanOrEqualTo: treeScroll.leadingAnchor, constant: 16),
            noticeStack.trailingAnchor.constraint(lessThanOrEqualTo: treeScroll.trailingAnchor, constant: -16),
        ])
        view = root
    }

    private func configureChrome() {
        for (button, symbol, tip, action) in [
            (refreshButton, "arrow.clockwise", "重新读取当前目录", #selector(reloadTree)),
            (goToButton, "arrow.right.circle", "打开指定目录…", #selector(goToDirectory)),
            (newFolderButton, "folder.badge.plus", "在选中目录下新建文件夹", #selector(createDirectory)),
            (uploadButton, "arrow.up.doc", "上传文件到选中目录", #selector(uploadFiles)),
            (downloadButton, "arrow.down.doc", "下载选中文件到本地", #selector(downloadSelected)),
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            button.imagePosition = .imageOnly
            Self.applyActionAppearance(to: button)
            button.target = self
            button.action = action
            button.toolTip = tip
        }
        hiddenToggle.setButtonType(.pushOnPushOff)
        Self.applyActionAppearance(to: hiddenToggle)
        hiddenToggle.target = self
        hiddenToggle.action = #selector(toggleHidden)
        hiddenToggle.toolTip = "显示 / 隐藏以点开头的文件"
        updateHiddenToggleAppearance()

        followToggle.target = self
        followToggle.action = #selector(toggleFollow)
        followToggle.toolTip = "文件列表跟着终端的 cd 走；关掉后终端再换目录也不影响这里"

        retryButton.title = "重试"
        retryButton.bezelStyle = .recessed
        retryButton.controlSize = .mini
        retryButton.target = self
        retryButton.action = #selector(reconnectChannel)
        retryButton.toolTip = "重新建立文件通道"
        retryButton.isHidden = true
    }

    /// 玻璃栏里的按钮只画图标，尺寸由 FileActionRow 按面板宽度分配。
    private static func applyActionAppearance(to button: GlassActionButton) {
        button.isBordered = false
        button.restingTint = Theme.textSecondary
    }

    private func updateHiddenToggleAppearance() {
        hiddenToggle.image = NSImage(
            systemSymbolName: showHidden ? "eye" : "eye.slash",
            accessibilityDescription: "显示隐藏文件"
        )
        hiddenToggle.restingTint = showHidden ? Theme.accent : Theme.textSecondary
    }

    private func configureNotice() {
        noticeStack.orientation = .vertical
        noticeStack.alignment = .centerX
        noticeStack.spacing = 8
        noticeStack.isHidden = true
        noticeStack.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "externaldrive.badge.questionmark", accessibilityDescription: nil)
        icon.contentTintColor = Theme.textTertiary
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        noticeTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        noticeTitle.textColor = Theme.textPrimary
        noticeTitle.alignment = .center

        noticeDetail.stringValue = """
        当前服务器拒绝了 SFTP 子系统请求，文件列表无法读取。
        你仍可以在右侧终端里直接操作文件。

        若需要文件面板，请在服务器上启用 sftp-server
        （OpenSSH 通常自带，配置 Subsystem sftp 即可），
        然后点状态行的「重试」。
        """
        noticeDetail.font = .systemFont(ofSize: 11)
        noticeDetail.textColor = Theme.textSecondary
        noticeDetail.alignment = .center
        noticeDetail.maximumNumberOfLines = 0
        noticeDetail.translatesAutoresizingMaskIntoConstraints = false

        noticeStack.addArrangedSubview(icon)
        noticeStack.addArrangedSubview(noticeTitle)
        noticeStack.addArrangedSubview(noticeDetail)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            noticeDetail.widthAnchor.constraint(lessThanOrEqualToConstant: 250),
        ])
    }

    private func setNoticeVisible(_ visible: Bool) {
        noticeStack.isHidden = !visible
    }

    /// 面包屑横放在侧栏里必然超宽，交给横向滚动，重建后滚到最右端露出当前目录。
    private func configurePathBar() {
        pathBar.orientation = .horizontal
        pathBar.alignment = .centerY
        pathBar.distribution = .fill
        pathBar.spacing = 1
        pathBar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        pathBar.translatesAutoresizingMaskIntoConstraints = false

        pathScroll.documentView = pathBar
        pathScroll.hasHorizontalScroller = true
        pathScroll.hasVerticalScroller = false
        pathScroll.autohidesScrollers = true
        pathScroll.borderType = .noBorder
        pathScroll.drawsBackground = false
        pathScroll.scrollerStyle = .overlay
        pathScroll.isHidden = true

        NSLayoutConstraint.activate([
            // 文档视图钉在可视区的左、上、下，宽度由栈的固有尺寸决定并钉死：
            // 路径再长也只是滚出去，不会把每段按钮压成省略号。
            pathBar.leadingAnchor.constraint(equalTo: pathScroll.contentView.leadingAnchor),
            pathBar.topAnchor.constraint(equalTo: pathScroll.contentView.topAnchor),
            pathBar.bottomAnchor.constraint(equalTo: pathScroll.contentView.bottomAnchor),
        ])
        pathBar.setContentHuggingPriority(.required, for: .horizontal)
    }

    /// `/usr/local/bin` → [`/`][`usr`][`local`][`bin`]，点前缀就回到那一层。
    private func renderBreadcrumbs(_ directory: String?) {
        for view in pathBar.arrangedSubviews {
            pathBar.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard let directory else {
            pathScroll.isHidden = true
            return
        }
        pathScroll.isHidden = false
        let ancestors = SFTPPath.ancestors(directory)
        breadcrumbPaths = ancestors
        for (index, path) in ancestors.enumerated() {
            if index > 0 {
                pathBar.addArrangedSubview(separator())
            }
            let button = NSButton(title: SFTPPath.lastComponent(path), target: self, action: #selector(selectBreadcrumb(_:)))
            button.bezelStyle = .recessed
            button.controlSize = .mini
            button.font = .systemFont(ofSize: 11, weight: .medium)
            // 能点的层级用强调色，当前目录用次要色：一眼看出导航条不是静态文字。
            button.attributedTitle = NSAttributedString(
                string: SFTPPath.lastComponent(path),
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: path == directory ? Theme.textSecondary : Theme.accent,
                ]
            )
            button.lineBreakMode = .byTruncatingMiddle
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            button.toolTip = path
            // 每一级都能点，包括正在看的这一级：读取失败后点它就是一个就地重试。
            button.tag = index
            pathBar.addArrangedSubview(button)
        }
        DispatchQueue.main.async {
            self.pathBar.layoutSubtreeIfNeeded()
            let overflow = max(0, self.pathBar.bounds.width - self.pathScroll.contentView.bounds.width)
            self.pathScroll.contentView.scroll(to: NSPoint(x: overflow, y: 0))
            self.pathScroll.reflectScrolledClipView(self.pathScroll.contentView)
        }
    }

    private func separator() -> NSTextField {
        // 分隔符不用 “/”：根目录那一段本身就叫 “/”，两种斜杠混在一排读不出层次。
        let mark = NSTextField(labelWithString: "›")
        mark.font = .systemFont(ofSize: 11)
        mark.textColor = .tertiaryLabelColor
        return mark
    }

    @objc private func selectBreadcrumb(_ sender: NSButton) {
        guard breadcrumbPaths.indices.contains(sender.tag) else { return }
        let path = breadcrumbPaths[sender.tag]
        Task {
            guard let session else { return }
            do {
                let client = try await session.ensureClient()
                requestListing(try await client.realpath(path))
            } catch {
                AlertPresenter.fail(title: "打开目录失败", message: error.localizedDescription, in: view.window)
            }
        }
    }

    private func configureTables() {
        fileTable.headerView = nil
        fileTable.style = .sourceList
        fileTable.usesAlternatingRowBackgroundColors = false
        fileTable.allowsMultipleSelection = true
        // 行高由字号/图标尺寸算出来，必须用 custom，否则 small 会把内容压回系统行高。
        fileTable.rowSizeStyle = .custom
        fileTable.dataSource = self
        fileTable.delegate = self
        fileTable.menu = fileMenu
        fileTable.doubleAction = #selector(handleDoubleClick)
        // 双击动作不写 target 就得沿响应链找接收者：第一响应者是终端时一路走到窗口
        // 都碰不到本控制器，双击就静默没反应。钉死在这里，不赌响应链。
        fileTable.target = self
        fileTable.registerForDraggedTypes([.fileURL])

        let name = NSTableColumn(identifier: Self.nameColumn)
        name.title = "名称"
        name.minWidth = 80
        name.resizingMask = .autoresizingMask
        fileTable.addTableColumn(name)
        // 大小文字并进名称单元格，名称列就是唯一的列：它会铺满表格宽度，
        // 面板拉宽就多显示几个字，变窄时 label 自己打省略号。
        fileTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

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

    override func viewDidLayout() {
        super.viewDidLayout()
        // 必须等滚动视图真正有宽度再铺满；之后列宽由 AppKit 跟着表格伸缩，
        // 自己改 column.width 反而会让表格 frame 反过来变大，不能走那条路。
        guard !didFitNameColumn, fileTable.bounds.width > 1 else { return }
        didFitNameColumn = true
        fileTable.sizeLastColumnToFit()
    }

    private lazy var fileMenu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(menuItem("下载", #selector(downloadSelected)))
        menu.addItem(menuItem("复制路径", #selector(copyPaths)))
        menu.addItem(menuItem("路径填入终端", #selector(insertPathsIntoTerminal)))
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

    /// 字号与图标尺寸都是用户可调的，单元格每次重建都按当前设置取，
    /// 改设置后只需要重载数据，不用重建整份列表。
    private var treeFontSize: CGFloat { CGFloat(environment.settings.settings.fileTreeFontSize) }
    private var treeIconSize: CGFloat { CGFloat(environment.settings.settings.fileTreeIconSize) }

    private func applyTreeMetrics() {
        fileTable.rowHeight = max(treeFontSize, treeIconSize) + 6
        fileTable.reloadData()
    }

    @objc private func settingsDidChange() {
        guard isViewLoaded else { return }
        applyTreeMetrics()
    }

    // MARK: - 绑定会话

    /// 跟随当前标签；传 nil 解绑并清空列表。
    func bind(to controller: TerminalController?) {
        // 先落 boundController：setContextSource 里要按这个标签读跟随开关，
        // 晚一步就会拿上一个标签的覆盖值来初始化。
        boundController = controller
        setContextSource(controller)
        guard controller != nil else {
            detach()
            entries = []
            currentDirectory = nil
            lastUploadDirectory = nil
            resetContent("未选择会话")
            return
        }
        // 视图没进窗口就建通道等于白起一个 ssh 子进程，等 viewDidAppear 再连。
        guard isViewLoaded, view.window != nil else {
            FileLogger.shared.info("文件面板未上屏，暂不建通道（跟随要等面板显示后补齐）")
            return
        }
        applyBinding()
    }

    /// 终端里的 cd 与增删改要立刻反映到列表上，所以每个标签只订阅自己那个控制器。
    /// 上下文回调是多播的：工作区也在同一条会话上挂了一个订阅用来更新标题。
    private func setContextSource(_ controller: TerminalController?) {
        guard controller !== contextController else { return }
        contextController?.removeContextObserver(contextToken)
        contextToken = nil
        contextController = controller
        remoteHome = nil
        isResolvingHome = false
        homeUnresolvable = false
        hasAlignedWithTerminal = false
        lastContext = controller?.context ?? TerminalContext()
        lastFollowSetting = followsTerminalDirectory
        listingTarget = nil
        refreshFollowToggle()
        contextToken = controller?.addContextObserver { [weak self] context in
            // 切走标签后旧标签还在输出，靠身份比对挡掉。
            guard let self, self.contextController === controller else { return }
            self.applyTerminalContext(context)
        }
        FileLogger.shared.info(controller == nil ? "文件面板：解绑会话上下文" : "文件面板：接上会话上下文")
    }

    /// 跟随开关：这个标签上临时改过就用标签的，否则跟全局设置。
    private var followsTerminalDirectory: Bool {
        guard let id = boundController?.sessionID, let override = followOverrides[id] else {
            return environment.settings.settings.followTerminalDirectory
        }
        return override
    }

    /// 复选框显示的是当前标签实际生效的值；全局设置改了也要在这儿跟上。
    private func refreshFollowToggle() {
        followToggle.state = followsTerminalDirectory ? .on : .off
    }

    @objc private func toggleFollow() {
        let enabled = followToggle.state == .on
        if let id = boundController?.sessionID {
            followOverrides[id] = enabled
        }
        lastFollowSetting = enabled
        guard enabled, let context = contextController?.context, context.followAllowed,
              let directory = terminalTarget(context) else { return }
        // 刚打开就跟着终端此刻的目录走，不必等用户再敲一条 cd。
        followTerminal(directory)
    }

    /// 决策结果写成一句人话，日志里看得懂列表为什么没动。
    private func describe(_ action: PanelFollowAction) -> String {
        switch action {
        case .jump(let directory): return "跳到 \(directory)"
        case .reload: return "重读当前这一层"
        case .resolveHome: return "先问远端主目录的绝对路径"
        case .pause(let reason): return reason
        case .explainMissingDirectory: return "拿不到目录，不动"
        case .channelNotReady: return "文件通道还没就绪，这次不算跟上"
        case .idle: return "没有变化，不动"
        }
    }

    /// 终端上下文变了要不要换目录，判断只看「这次和上次比有什么不同」：
    /// 电平触发会让用户手动浏览到的别处，被终端随后的一条 `ls` 抢回当前目录。
    /// 规则本身在 DirectoryFollowPlanner，这里只把动作做出来。
    private func applyTerminalContext(_ context: TerminalContext) {
        let follow = followsTerminalDirectory
        let action = DirectoryFollowPlanner.decide(
            PanelFollowFacts(
                terminal: context,
                followEnabled: follow,
                justEnabled: follow && !lastFollowSetting,
                channelReady: session != nil,
                remoteHome: remoteHome,
                homeUnresolvable: homeUnresolvable,
                targetBefore: terminalTarget(lastContext),
                filesystemRevisionBefore: lastContext.filesystemRevision,
                hasAligned: hasAlignedWithTerminal,
                isBusy: isBusy
            )
        )
        // 跟随不出结果时，用户能看到的只有「列表不动」；把每次判断的原因留在日志里。
        let subject = context.displayDirectory ?? "未上报"
        FileLogger.shared.info("文件面板：终端在 \(subject)，\(describe(action))")
        // 这两种情况都别把上下文记成「已经跟上」：连接期间终端报上来的目录，
        // 要等通道就绪、主目录问到之后再来一遍，否则跟随永远差那一步。
        if case .channelNotReady = action { return }
        if case .resolveHome = action {
            resolveHomeThenReplay()
            return
        }
        defer {
            lastContext = context
            lastFollowSetting = follow
        }
        switch action {
        case .jump(let directory):
            isPausedByTerminal = false
            followTerminal(directory)
        case .reload:
            isPausedByTerminal = false
            // 目录没变但终端动了文件：重读当前这一层，展开的子层会跟着重新点开。
            requestReload()
        case .pause(let reason):
            isPausedByTerminal = true
            statusLabel.stringValue = reason
        case .explainMissingDirectory:
            isPausedByTerminal = true
            // 远端 shell 既不报 OSC 7、提示符里也没有路径时，跟随确实无从下手，
            // 与其默默不动，不如把原因说出来。主目录问不出来是另一种情况，别混为一谈。
            statusLabel.stringValue = homeUnresolvable && context.promptHomeHint != nil
                ? "问不出远端主目录，`~` 跟随不了（点刷新可重试）"
                : "终端未上报目录，暂时无法跟随"
        case .idle:
            // 从容器里 exit 回来时目录往往没变，但状态行还挂着“暂停跟随”，
            // 必须换回普通状态，否则看起来像列表卡住了。
            if isPausedByTerminal, context.followAllowed {
                isPausedByTerminal = false
                statusLabel.stringValue = session?.state == .ready ? "已连接" : "未连接"
            }
        case .channelNotReady, .resolveHome:
            break
        }
    }

    /// 把列表挪到终端此刻的目录。
    ///
    /// 第一次对齐不要求“目录变过”，否则用户刚切到文件面板时永远差那一步。
    private func followTerminal(_ directory: String) {
        hasAlignedWithTerminal = true
        guard directory != currentDirectory else { return }
        FileLogger.shared.info("跟随终端目录：\(currentDirectory ?? "—") → \(directory)")
        requestListing(directory)
    }

    /// 终端说的“在哪”，翻译成文件通道能读的绝对路径；信息不够时是 nil。
    private func terminalTarget(_ context: TerminalContext) -> String? {
        DirectoryFollowPlanner.target(context, remoteHome: remoteHome)
    }

    private func resolveHomeThenReplay() {
        guard !isResolvingHome else { return }
        isResolvingHome = true
        Task {
            _ = await self.ensureRemoteHome()
            self.isResolvingHome = false
            guard let context = self.contextController?.context else { return }
            self.applyTerminalContext(context)
        }
    }

    /// SFTP 服务端的登录目录就是远端用户的主目录，问一次存下来。
    ///
    /// 老一些的 sftp-server 不接受相对路径的 realpath，所以 `.` 失败还要试 `~`；
    /// 两个都问不出来时提示符里的 `~` 就翻译不成绝对路径，必须在日志里留下原因。
    private func ensureRemoteHome() async -> String? {
        if let remoteHome { return remoteHome }
        guard let session else { return nil }
        do {
            let client = try await session.ensureClient()
            for probe in [".", "~"] {
                if let home = try? await client.realpath(probe), home.hasPrefix("/") {
                    remoteHome = home
                    homeUnresolvable = false
                    FileLogger.shared.info("远端主目录：\(home)（realpath \(probe)）")
                    return home
                }
            }
            homeUnresolvable = true
            FileLogger.shared.warning("问不出远端主目录：realpath(. 和 ~) 都没有应答，本次连接内不再重试")
        } catch {
            homeUnresolvable = true
            FileLogger.shared.warning("问不出远端主目录：\(error.localizedDescription)，本次连接内不再重试")
        }
        return nil
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        applyBinding()
        refreshFollowToggle()
        // 在设置里刚打开“跟随终端目录”时，终端未必再产生新事件，回来这一刻补一次对齐。
        if let context = contextController?.context {
            applyTerminalContext(context)
        }
    }

    private func applyBinding() {
        guard let controller = boundController,
              let host = controller.host,
              host.protocolKind.supportsSFTP,
              let next = environment.sftpSession(for: controller) else {
            detach()
            entries = []
            currentDirectory = nil
            resetContent(Self.placeholder(for: boundController, host: boundController?.host))
            return
        }
        guard next !== session else {
            if currentDirectory == nil, next.state == .ready {
                requestReload()
            }
            updateControls()
            return
        }
        detach()
        session = next
        lastUploadDirectory = nil
        currentDirectory = nil
        listingTarget = nil
        next.onStateChange = { [weak self] state in self?.render(state: state) }
        next.onTransferUpdate = { [weak self] progress in self?.update(progress) }
        clearTransfers()
        render(state: next.state)
        switch next.state {
        case .ready: requestReload()
        case .connecting: break
        case .unsupported: break
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
        remoteHome = nil
        homeUnresolvable = false
    }

    private func resetContent(_ status: String) {
        fileTable.reloadData()
        clearTransfers()
        renderBreadcrumbs(nil)
        statusLabel.stringValue = status
        retryButton.isHidden = true
        setNoticeVisible(false)
        updateControls()
    }

    private func render(state: SFTPSession.State) {
        setNoticeVisible(false)
        switch state {
        case .closed: statusLabel.stringValue = "未连接"
        case .connecting: statusLabel.stringValue = "正在打开文件通道…"
        case .ready:
            statusLabel.stringValue = "已连接"
            // 通道没建好之前攒下的请求（跟随、面包屑）这时补做；
            // 队列空但列表还没内容，说明连接期间没排上队，这里补一次。
            if currentDirectory == nil, listingTarget == nil {
                requestReload()
            } else {
                drainListing()
            }
        case .unsupported:
            // 服务器拒绝 SFTP 不是异常：清掉可能残留的旧列表，原地给出说明，
            // 不弹错误框，也不把目标路径和传输队列留在半成品状态。
            entries = []
            currentDirectory = nil
            listingTarget = nil
            fileTable.reloadData()
            renderBreadcrumbs(nil)
            clearTransfers()
            statusLabel.stringValue = "文件通道不可用"
            setNoticeVisible(true)
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
        // 重连是用户主动要求「再试一次」：主目录问过失败的标记一并清掉。
        homeUnresolvable = false
        Task { await connectAndBrowse() }
    }

    @objc private func reloadTree() {
        homeUnresolvable = false
        if currentDirectory == nil, let context = contextController?.context {
            // 树还没落到任何目录，多半是主目录没问出来：借这次刷新再问一遍。
            applyTerminalContext(context)
            return
        }
        requestReload()
    }

    @objc private func toggleHidden() {
        showHidden = hiddenToggle.state == .on
        updateHiddenToggleAppearance()
        requestReload()
    }

    /// 列表只显示一层，没有这个入口就出不了登录目录。
    @objc private func goToDirectory() {
        guard let session else { return }
        guard let raw = pathPrompt(value: currentDirectory ?? ".") else { return }
        Task {
            do {
                let client = try await session.ensureClient()
                requestListing(try await client.realpath(raw))
            } catch {
                guard session.state != .unsupported else { return }
                AlertPresenter.fail(title: "打开目录失败", message: error.localizedDescription, in: view.window)
            }
        }
    }

    private func connectAndBrowse() async {
        do {
            guard let session else { return }
            let client = try await session.ensureClient()
            requestListing(try await client.realpath(startPath(for: session.host)))
        } catch {
            // “服务器没开 SFTP”已经在列表的位置说明了，不必再弹一个错误框。
            guard session?.state != .unsupported else { return }
            AlertPresenter.fail(title: "打开文件面板失败", message: error.localizedDescription, in: view.window)
        }
    }

    /// 起始目录：开了“跟随终端目录”就用终端此刻的目录，
    /// 其次主机配置的起始目录，最后服务端登录目录。
    private func startPath(for host: HostProfile) -> String {
        if followsTerminalDirectory,
           let context = boundController?.context,
           let directory = terminalTarget(context) {
            return SFTPPath.normalize(directory)
        }
        return SFTPPath.normalize(host.startupDirectory.isEmpty ? "." : host.startupDirectory)
    }

    /// 重读当前目录。
    private func requestReload() {
        guard let host = session?.host else { return }
        requestListing(currentDirectory ?? startPath(for: host))
    }

    /// 把列表切到 `directory`：请求先入队，真正的读取由 drainListing 串行发起。
    private func requestListing(_ directory: String) {
        listingTarget = directory
        drainListing()
    }

    /// 一次只读一层。置位必须在交给 Task 之前：Task 体要等下一个主循环才跑，
    /// 到那时才检查忙闲，同一批里的两个请求会挤进同一个空档，后一个静默丢失。
    private func drainListing() {
        guard !isBusy, let directory = listingTarget else { return }
        guard session?.client != nil else {
            FileLogger.shared.info("文件面板：通道未就绪，\(directory) 排队等待")
            return
        }
        listingTarget = nil
        isBusy = true
        updateControls()
        Task { await self.read(directory) }
    }

    /// 把 `directory` 的直接子项铺成列表。
    private func read(_ directory: String) async {
        guard let client = session?.client else {
            isBusy = false
            updateControls()
            return
        }
        defer {
            isBusy = false
            updateControls()
            // 读取期间攒下的最新请求，读完立刻跟上。
            drainListing()
        }
        var failure: String?
        do {
            entries = try await client.list(directory, showHidden: showHidden)
        } catch {
            entries = []
            failure = "读取 \(directory) 失败：\(error.localizedDescription)"
        }
        // 换目录后旧的行号指向的是另一批文件，留着选区会让删除作用到错误的项。
        let directoryChanged = directory != currentDirectory
        currentDirectory = directory
        renderBreadcrumbs(directory)
        statusLabel.stringValue = failure ?? "已连接"
        if let failure {
            FileLogger.shared.warning("文件面板：\(failure)")
        } else {
            FileLogger.shared.info("文件面板：读取 \(directory) 完成，\(entries.count) 项")
        }
        if directoryChanged {
            fileTable.deselectAll(nil)
        }
        fileTable.reloadData()
    }

    // MARK: - 选择

    private var selectedEntries: [SFTPFileEntry] {
        fileTable.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
    }

    private var targetEntry: SFTPFileEntry? {
        let row = fileTable.clickedRow >= 0 ? fileTable.clickedRow : fileTable.selectedRow
        if entries.indices.contains(row) { return entries[row] }
        return selectedEntries.first
    }

    /// 上传落点：选中目录用目录，选中文件用它的父目录，都没选就落在当前这一层。
    private var uploadDirectory: String {
        guard let entry = targetEntry else { return currentDirectory ?? "/" }
        return entry.isDirectory ? entry.path : SFTPPath.parent(entry.path)
    }

    @objc private func handleDoubleClick() {
        switch FilePanelDoubleClick.decide(clicked: targetEntry, selected: selectedEntries) {
        case .open(let path):
            requestListing(path)
        case .download(let files):
            download(files)
        case .nothing:
            // 双击落空要留证据：能分清是行没解析出来，还是压根没收到双击。
            FileLogger.shared.info("文件面板：双击落空 clickedRow=\(fileTable.clickedRow) 选中 \(selectedEntries.count) 项")
        }
    }

    // MARK: - 路径搬运

    /// 远端路径手敲容易错，也能直接给别的程序用，所以给的是原文而不是带引号的版本。
    @objc private func copyPaths() {
        let paths = selectedEntries.map(\.path)
        guard !paths.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
    }

    /// 对应 webterm 的“把列表里的路径拖进终端”：填进当前会话但不回车，
    /// 带空格的路径自动补引号，用户可以接着敲命令。
    @objc private func insertPathsIntoTerminal() {
        let paths = selectedEntries.map(\.path)
        guard !paths.isEmpty else { return }
        guard let controller = boundController, controller.state.isAlive else {
            AlertPresenter.notify(title: "没有可用的终端", message: "当前会话已断开，先重新连接再填路径。", in: view.window)
            return
        }
        controller.injectInput(paths.map(ShellQuoting.quoteIfNeeded).joined(separator: " "))
    }

    // MARK: - 目录操作

    @objc private func createDirectory() {
        let parent = uploadDirectory
        guard let name = prompt(title: "新建文件夹", message: "在 \(parent) 下创建：", value: "新建文件夹") else { return }
        let target = SFTPPath.join(parent, name)
        Task {
            do {
                try await session?.client?.makeDirectory(target)
                requestReload()
            } catch {
                AlertPresenter.fail(title: "新建文件夹失败", message: error.localizedDescription, in: view.window)
            }
        }
    }

    @objc private func renameSelected() {
        guard let entry = targetEntry else { return }
        guard let name = prompt(title: "重命名 “\(entry.name)”", message: "新名称：", value: entry.name) else { return }
        let parent = SFTPPath.parent(entry.path)
        let target = SFTPPath.join(parent, name)
        Task {
            do {
                try await session?.client?.move(from: entry.path, to: target)
                requestReload()
            } catch {
                AlertPresenter.fail(title: "重命名失败", message: error.localizedDescription, in: view.window)
            }
        }
    }

    @objc private func deleteSelected() {
        let targets = selectedEntries
        guard !targets.isEmpty else { return }
        let hasDirectory = targets.contains(where: \.isDirectory)
        let alert = NSAlert()
        alert.messageText = "删除 \(targets.count) 项？"
        alert.informativeText = targets.map(\.name).joined(separator: "、")
            + (hasDirectory
                ? "\n\n目录会连同其中的所有内容一起删除，且无法恢复。"
                : "\n\n删除后无法恢复。")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            for entry in targets {
                do {
                    if entry.isDirectory {
                        try await session?.client?.removeTree(entry.path)
                    } else {
                        try await session?.client?.removeFile(entry.path)
                    }
                } catch {
                    AlertPresenter.fail(title: "删除 \(entry.name) 失败", message: error.localizedDescription, in: view.window)
                }
            }
            requestReload()
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

    /// 从 Finder 拖文件到列表即上传，和 webterm 的拖拽上传一致。
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
        download(selectedEntries.filter { !$0.isDirectory })
    }

    private func download(_ files: [SFTPFileEntry]) {
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
        if progress.isFinished, progress.state == .completed, progress.kind == .upload,
           lastUploadDirectory == currentDirectory {
            requestReload()
        }
        transferScroll.isHidden = transferOrder.isEmpty
        transferTable.reloadData()
    }

    private func clearTransfers() {
        transfers.removeAll()
        transferOrder.removeAll()
        transferScroll.isHidden = true
        transferTable.reloadData()
    }

    @objc private func clearFinishedTransfers() {
        for id in transferOrder where transfers[id]?.isFinished == true {
            removeTransferRow(id)
        }
        Task { await session?.transfers?.clearFinished() }
    }

    /// 行尾的移除按钮：只抹掉列表里的这条记录，远端文件和本地文件都不动。
    @objc private func dismissTransfer(_ sender: TransferDismissButton) {
        guard let id = sender.transferID else { return }
        removeTransferRow(id)
        Task { await session?.transfers?.dismiss(id) }
    }

    private func removeTransferRow(_ id: UUID) {
        transfers.removeValue(forKey: id)
        transferOrder.removeAll { $0 == id }
        transferScroll.isHidden = transferOrder.isEmpty
        transferTable.reloadData()
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

extension SFTPBrowserViewController: NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation, NSMenuDelegate {
    private func nameCell(for entry: SFTPFileEntry) -> NSView {
        return iconCell(
            text: entry.name,
            fullName: entry.name,
            detail: entry.isDirectory ? "" : entry.sizeText,
            symbol: entry.isDirectory ? "folder.fill" : "doc",
            tint: entry.isDirectory ? .controlAccentColor : .secondaryLabelColor,
            hidden: entry.isHidden
        )
    }

    private func textCell(_ text: String, secondary: Bool = false, align: NSTextAlignment = .left) -> NSTextField {
        // 行尾的大小文字比名称小一号，和字号设置一起缩放。
        let size = secondary ? max(10, treeFontSize - 1) : treeFontSize
        let cell = NSTextField(labelWithString: text)
        cell.font = .systemFont(ofSize: size)
        // 宽度够时完整显示，不够才在末尾省略；中间截断会先把扩展名吃掉。
        cell.lineBreakMode = .byTruncatingTail
        cell.usesSingleLineMode = true
        cell.maximumNumberOfLines = 1
        cell.alignment = align
        cell.textColor = secondary ? .secondaryLabelColor : .labelColor
        return cell
    }

    /// NSTextField 没有 image 属性，名称列的图标只能自己拼。
    /// 大小文字挂在同一格里右对齐，名称列才能独占整行宽度、随面板宽窄伸缩。
    private func iconCell(text: String, fullName: String, detail: String, symbol: String, tint: NSColor, hidden: Bool) -> NSView {
        let icon = NSImageView()
        let configuration = NSImage.SymbolConfiguration(pointSize: treeIconSize, weight: .regular)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = tint
        // 隐藏项（点文件）把图标压暗：仍看得出类型，又能和普通项一眼区分。
        icon.alphaValue = hidden ? 0.35 : 1
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = textCell(text)
        // 名称被截断时，悬停整行都能看到完整名字。
        label.toolTip = fullName
        label.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        let detailLabel = textCell(detail, secondary: true, align: .right)
        detailLabel.setContentHuggingPriority(.required, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSTableCellView()
        cell.toolTip = fullName
        cell.textField = label
        cell.addSubview(icon)
        cell.addSubview(label)
        cell.addSubview(detailLabel)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: treeIconSize),
            icon.heightAnchor.constraint(equalToConstant: treeIconSize),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            // 名称给不出宽度时由它自己打省略号，不能顶掉大小文字或撑出单元格。
            label.trailingAnchor.constraint(equalTo: detailLabel.leadingAnchor, constant: -6),
            detailLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            detailLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            detailLabel.widthAnchor.constraint(equalToConstant: Self.sizeColumnWidth),
        ])
        return cell
    }

    // MARK: 传输队列

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === transferTable ? transferOrder.count : entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === transferTable {
            guard tableColumn?.identifier == Self.jobColumn,
                  transferOrder.indices.contains(row),
                  let progress = transfers[transferOrder[row]] else { return nil }
            return jobCell(progress)
        }
        guard tableColumn?.identifier == Self.nameColumn, entries.indices.contains(row) else { return nil }
        return nameCell(for: entries[row])
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        tableView === transferTable ? 46 : max(treeFontSize, treeIconSize) + 6
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

        // 行尾：完成时给一个绿色对号，结束的记录再给一个移除按钮。
        // 还在传的行不留按钮，取消走右键菜单，避免误点。
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 2
        actions.translatesAutoresizingMaskIntoConstraints = false

        let status = NSImageView()
        status.imageScaling = .scaleProportionallyDown
        status.translatesAutoresizingMaskIntoConstraints = false
        if progress.state == .completed {
            status.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "传输完成")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
            status.contentTintColor = Theme.success
            status.toolTip = "传输完成"
        } else {
            status.isHidden = true
        }
        actions.addArrangedSubview(status)

        let dismiss = TransferDismissButton()
        dismiss.transferID = progress.id
        dismiss.target = self
        dismiss.action = #selector(dismissTransfer(_:))
        dismiss.isHidden = !progress.isFinished
        actions.addArrangedSubview(dismiss)

        let cell = NSTableCellView()
        cell.addSubview(title)
        cell.addSubview(detail)
        cell.addSubview(bar)
        cell.addSubview(actions)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            title.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -6),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 3),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            bar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            bar.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 3),
            actions.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            actions.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            // 状态列宽度固定，进度刷新换行尾图标时标题不会被重新排版。
            actions.widthAnchor.constraint(equalToConstant: 32),
            status.widthAnchor.constraint(equalToConstant: 14),
            status.heightAnchor.constraint(equalToConstant: 14),
            dismiss.widthAnchor.constraint(equalToConstant: 16),
            dismiss.heightAnchor.constraint(equalToConstant: 16),
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
        let row = fileTable.clickedRow
        guard row >= 0, !fileTable.selectedRowIndexes.contains(row) else { return }
        fileTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(downloadSelected):
            return selectedEntries.contains { !$0.isDirectory }
        case #selector(copyPaths):
            return !selectedEntries.isEmpty
        case #selector(insertPathsIntoTerminal):
            return !selectedEntries.isEmpty && boundController?.state.isAlive == true
        case #selector(renameSelected):
            return targetEntry != nil
        case #selector(deleteSelected):
            return !selectedEntries.isEmpty
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

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard tableView === fileTable, session?.transfers != nil,
              info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) else { return [] }
        // 拖到目录行上就传进这个目录；落在空白处或文件行上则传进当前目录。
        if dropOperation != .on, entries.indices.contains(row), entries[row].isDirectory {
            tableView.setDropRow(row, dropOperation: .on)
        }
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard tableView === fileTable else { return false }
        let urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        if dropOperation == .on, entries.indices.contains(row), entries[row].isDirectory {
            scheduleUploads(urls, to: entries[row].path)
        } else {
            uploadDroppedFiles(urls)
        }
        return true
    }
}

/// 文件操作行：胶囊宽度跟着面板走，按钮宽度与间距按可用空间收缩，窄面板也不会溢出。
@MainActor
private final class FileActionRow: NSView {
    private let buttons: [GlassActionButton]
    private let accessory: NSView

    init(buttons: [GlassActionButton], accessory: NSView) {
        self.buttons = buttons
        self.accessory = accessory
        super.init(frame: .zero)
        // 子视图全部用 frame 排版，关掉自动转换约束，避免 Auto Layout 把宽度抢回去。
        accessory.translatesAutoresizingMaskIntoConstraints = false
        for button in buttons {
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
        }
        addSubview(accessory)
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 26)
    }

    override func layout() {
        super.layout()
        guard !buttons.isEmpty else { return }
        let spacing: CGFloat = bounds.width < 260 ? 2 : 3
        let accessoryWidth = min(46, max(36, accessory.intrinsicContentSize.width))
        let available = max(0, bounds.width - accessoryWidth - 8 - spacing * CGFloat(buttons.count - 1))
        let buttonWidth = min(28, max(20, available / CGFloat(buttons.count)))
        var x: CGFloat = 0
        for button in buttons {
            button.frame = NSRect(x: x, y: (bounds.height - 26) / 2, width: buttonWidth, height: 26)
            x += buttonWidth + spacing
        }
        let accessoryHeight = min(22, bounds.height)
        accessory.frame = NSRect(
            x: max(x, bounds.width - accessoryWidth),
            y: (bounds.height - accessoryHeight) / 2,
            width: accessoryWidth,
            height: accessoryHeight
        )
    }
}

/// 文件面板的“跟随”开关：和胶囊切换器同一套强调色胶囊，不用系统复选框。
@MainActor
private final class FollowToggleButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private var hovering = false {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: .zero)
        title = "跟随"
        isBordered = false
        setButtonType(.toggle)
        toolTip = "文件列表跟着终端的 cd 走；关掉后终端再换目录也不影响这里"
        setAccessibilityLabel("跟随终端目录")
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    override var intrinsicContentSize: NSSize { NSSize(width: 46, height: 22) }

    override var state: NSControl.StateValue {
        didSet { needsDisplay = true }
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
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
    }

    override func draw(_ dirtyRect: NSRect) {
        let on = state == .on
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let pill = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        if on {
            Theme.accent.withAlphaComponent(0.16).setFill()
            pill.fill()
            Theme.accent.withAlphaComponent(hovering ? 0.48 : 0.38).setStroke()
        } else {
            Theme.hoverFill.setFill()
            pill.fill()
            (hovering ? Theme.borderStrong : Theme.border).setStroke()
        }
        pill.lineWidth = 1
        pill.stroke()

        let text = title as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: on ? .semibold : .medium),
            .foregroundColor: on ? Theme.accent : Theme.textSecondary,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            in: NSRect(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
            ),
            withAttributes: attributes
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// 传输行尾的移除按钮：NSButton 没地方挂任务号，用子类把 UUID 带进 action。
private final class TransferDismissButton: NSButton {
    var transferID: UUID?
    private var hoverArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        imageScaling = .scaleProportionallyDown
        contentTintColor = Theme.textTertiary
        image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "从列表移除")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        toolTip = "只从列表移除这条记录，不会删除远端或本地文件"
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        contentTintColor = Theme.textPrimary
    }

    override func mouseExited(with event: NSEvent) {
        contentTintColor = Theme.textTertiary
    }
}
