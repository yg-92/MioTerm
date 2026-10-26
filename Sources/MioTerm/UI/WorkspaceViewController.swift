import AppKit
import MioTermCore

/// 工作区：左侧是主机列表/远端文件树双模面板，右侧是欢迎页或终端标签。
/// 两侧内容都随会话状态切换：没连接时看主机、看欢迎页，进入主机后看文件树、看终端。
/// 所有连接与配置操作的入口都在这里，菜单项与工具栏按钮用 nil target 走响应链命中本控制器。
@MainActor
final class WorkspaceViewController: NSSplitViewController {
    private let environment = AppEnvironment.shared
    private let sessions = SessionTabViewController()
    private let mainArea = ContainerViewController()
    private let sidePanel = SidePanelViewController()
    private let commands = CommandLibraryViewController()
    private var commandPopover: NSPopover?
    /// 右上角命令按钮的位置：菜单或快捷键触发时也贴在它下面弹出。
    private(set) weak var commandAnchorView: NSView?
    private lazy var coordinator = ConnectionCoordinator(environment: environment)

    /// 主机列表相关代码沿用旧名字，实际视图由侧栏面板持有。
    private var sidebar: HostSidebarViewController { sidePanel.hosts }

    private var hostForm: HostFormWindowController?
    private var preferences: PreferencesWindowController?
    /// 连接是异步的，同一主机连点两次会开出两个会话，用这个集合去重。
    private var pendingConnects: Set<String> = []
    /// 重连也要去重：指纹确认期间连点会同时拉起两条 ssh。
    private var reconnectingSessions: Set<UUID> = []
    /// 当前是否停在某个终端上：工具栏据此在“主机动作”和“主页”之间切换。
    var onPresentationChange: ((TerminalController?) -> Void)?

    /// 侧栏折叠态与分栏宽度都要跨启动保留，对齐 webterm 记住面板布局的行为。
    private static let splitAutosaveName = "MioTermWorkspaceSplit"
    private static let sidebarCollapsedDefault = "MioTerm.sidebarCollapsed"
    private var panelItem: NSSplitViewItem?

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        // NSSplitView 只认带 identifier 的子视图存宽度，缺了就每次回到默认比例。
        sidePanel.view.identifier = NSUserInterfaceItemIdentifier("mio.sidebar")
        mainArea.view.identifier = NSUserInterfaceItemIdentifier("mio.main")
        splitView.autosaveName = Self.splitAutosaveName

        let panelItem = NSSplitViewItem(sidebarWithViewController: sidePanel)
        panelItem.canCollapse = true
        panelItem.minimumThickness = 220
        panelItem.maximumThickness = 420
        panelItem.preferredThicknessFraction = 0.24
        addSplitViewItem(panelItem)
        self.panelItem = panelItem
        panelItem.isCollapsed = UserDefaults.standard.bool(forKey: Self.sidebarCollapsedDefault)

        let mainItem = NSSplitViewItem(viewController: mainArea)
        mainItem.minimumThickness = 480
        addSplitViewItem(mainItem)

        sidebar.delegate = self
        sessions.onSessionsChange = { [weak self] controller in
            self?.apply(selected: controller)
        }
        // 标签里的“重新连接”和工作区菜单走同一条路径：原地重连，不换标签。
        sessions.onReconnect = { [weak self] controller in
            self?.reconnect(controller)
        }
        // 标签栏与主页都归会话控制器管：没有选中会话时它自己显示欢迎页。
        mainArea.show(sessions)
    }

    /// viewDidLoad 时视图还没进窗口，折叠态只能等 appear 以后再挂关闭钩子。
    /// ⌘Q 不一定走窗口 close，所以退出通知也听一份。
    private var collapseObserverInstalled = false

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !collapseObserverInstalled, let window = view.window else { return }
        collapseObserverInstalled = true
        // 选择器形式的观察者会在本控制器释放时自动摘掉，不会把窗口吊在通知中心上。
        NotificationCenter.default.addObserver(
            self, selector: #selector(noteSidebarCollapse),
            name: NSWindow.willCloseNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(noteSidebarCollapse),
            name: NSApplication.willTerminateNotification, object: nil
        )
    }

    @objc private func noteSidebarCollapse() {
        guard let panelItem else { return }
        UserDefaults.standard.set(panelItem.isCollapsed, forKey: Self.sidebarCollapsedDefault)
    }

    /// 会话增删与选中变化统一走这里，保证左右两侧的状态一次到位。
    private func apply(selected controller: TerminalController?) {
        mainArea.show(sessions)
        commands.bind(to: controller)
        if let controller {
            sidePanel.bind(to: controller)
        } else {
            sidePanel.bind(to: nil)
            // 主页就是“欢迎页 + 主机列表”，不再把主机藏在分段控件后面。
            sidePanel.showHosts()
        }
        observeContext(of: controller)
        onPresentationChange?(controller)
    }

    // MARK: - 标题栏

    private var contextController: TerminalController?
    private var contextToken: UUID?

    /// 只订阅当前标签：其余标签还在输出，不能拿来改标题。
    private func observeContext(of controller: TerminalController?) {
        guard controller !== contextController else {
            updateTitlebar(for: controller)
            return
        }
        contextController?.removeContextObserver(contextToken)
        contextToken = nil
        contextController = controller
        contextToken = controller?.addContextObserver { [weak self] _ in
            guard let self, self.contextController === controller else { return }
            self.updateTitlebar(for: controller)
        }
        updateTitlebar(for: controller)
    }

    /// 标签页自己已经带了主机名与状态点，标题栏补的是“此刻在哪个目录”。
    private func updateTitlebar(for controller: TerminalController?) {
        guard let window = view.window else { return }
        guard let controller else {
            window.title = "MioTerm"
            window.subtitle = "主页 · 主机列表"
            return
        }
        window.title = controller.title
        window.subtitle = controller.context.displayDirectory
            ?? controller.workingDirectory
            ?? controller.state.label
    }

    @objc func showFilePanel(_ sender: Any?) {
        guard SidePanelViewController.supportsFiles(sessions.selectedController) else {
            AlertPresenter.notify(title: "没有可用的文件通道", message: "先连接一台 SSH 主机，再打开文件树。", in: view.window)
            return
        }
        mainArea.show(sessions)
        sidePanel.bind(to: sessions.selectedController)
        sidePanel.select(.files)
    }

    @objc func showHostList(_ sender: Any?) {
        sidePanel.showHosts()
    }

    /// 主页：欢迎页 + 主机列表。后台会话不关闭，标签栏里点回来即可。
    @objc func showHome(_ sender: Any?) {
        sessions.showHome()
        sidePanel.showHosts()
    }

    /// 命令库从左侧面板移到了右上角按钮：点击后在按钮下方弹出，选完即关。
    @objc func showCommandLibrary(_ sender: Any?) {
        if let popover = commandPopover, popover.isShown {
            popover.performClose(sender)
            return
        }
        let anchor = (sender as? NSView) ?? commandAnchorView
        guard let anchor, anchor.window != nil else { return }
        if commandPopover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.contentViewController = commands
            popover.contentSize = NSSize(width: 320, height: 440)
            commandPopover = popover
        }
        commands.bind(to: sessions.selectedController)
        commandPopover?.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    /// 工具栏每次重建都会换新按钮，这里记下最新位置供菜单触发时复用。
    func attachCommandAnchor(_ view: NSView) {
        commandAnchorView = view
    }

    /// 关闭整个工作区前回收所有子进程，避免残留 ssh 与 askpass 临时文件。
    func prepareForClose() {
        sessions.closeAll()
    }

    var hasActiveSessions: Bool {
        sessions.controllers.contains { $0.state.isAlive }
    }

    @objc func selectNextTerminalTab(_ sender: Any?) {
        sessions.selectNextTab()
    }

    @objc func selectPreviousTerminalTab(_ sender: Any?) {
        sessions.selectPreviousTab()
    }

    /// 菜单项的 tag 从 1 开始，对应标签栏里的第 1…9 个会话。
    @objc func selectTerminalTab(_ sender: NSMenuItem) {
        sessions.selectTab(at: sender.tag - 1)
    }

    @objc func testSelectedHost(_ sender: Any?) {
        guard let host = sidebar.selectedHost else { return }
        Task { @MainActor in
            await coordinator.test(host: host, in: view.window)
        }
    }

    @objc func refreshFingerprintSelectedHost(_ sender: Any?) {
        guard let host = sidebar.selectedHost else { return }
        Task { @MainActor in
            await coordinator.refreshFingerprint(host: host, in: view.window)
        }
    }

    @objc func adjustTerminalFontSize(_ sender: NSMenuItem) {
        let step = sender.tag > 0 ? 1.0 : -1.0
        try? environment.settings.update { settings in
            settings.terminalFontSize += step
        }
    }

    @objc func resetTerminalFontSize(_ sender: Any?) {
        try? environment.settings.update { settings in
            settings.terminalFontSize = AppSettings.default.terminalFontSize
        }
    }

    // MARK: - 会话动作

    @objc func newLocalTerminal(_ sender: Any?) {
        let controller = TerminalController(host: nil, settings: environment.settings.settings)
        environment.register(controller)
        controller.startLocalShell()
        sessions.append(controller)
    }

    @objc func connectSelectedHost(_ sender: Any?) {
        guard let host = sidebar.selectedHost else {
            AlertPresenter.notify(title: "未选择主机", message: "先在左侧列表里选中一台主机。", in: view.window)
            return
        }
        connect(host: host)
    }

    /// 串口控制台的 BREAK：交换机与老设备靠它唤出提示符。
    @objc func sendSerialBreak(_ sender: Any?) {
        sessions.selectedController?.sendBreak()
    }

    @objc func closeTerminalTab(_ sender: Any?) {
        sessions.closeSelectedTab()
    }

    @objc func reconnectTerminal(_ sender: Any?) {
        guard let controller = sessions.selectedController else { return }
        reconnect(controller)
    }

    /// 断线后原地重连：标签位置、滚动历史和当前目录都不动，换掉的只有传输通道。
    private func reconnect(_ controller: TerminalController) {
        guard !controller.state.isAlive else {
            AlertPresenter.notify(title: "会话仍在运行",
                                  message: "先关闭当前标签或等它结束，再重新连接。",
                                  in: view.window)
            return
        }
        guard !reconnectingSessions.contains(controller.sessionID) else { return }
        // 本地 shell 没有远端可连：同一个视图里重开一个登录 shell 就够。
        guard controller.host != nil else {
            controller.startLocalShell()
            return
        }
        reconnectingSessions.insert(controller.sessionID)
        Task { @MainActor [weak self, weak controller] in
            guard let self, let controller else { return }
            defer { self.reconnectingSessions.remove(controller.sessionID) }
            await self.coordinator.reconnect(controller, in: self.view.window)
            guard controller.state.isAlive else { return }
            // 旧文件通道挂在已经断开的那条 ssh 上，重连成功后换一条新的。
            self.environment.closeSFTPSession(for: controller)
            self.sidePanel.bind(to: controller)
        }
    }

    private func connect(host: HostProfile) {
        guard !pendingConnects.contains(host.id) else { return }
        pendingConnects.insert(host.id)
        Task { @MainActor [weak self] in
            defer { self?.pendingConnects.remove(host.id) }
            guard let self else { return }
            if let controller = await self.coordinator.open(host: host, in: self.view.window) {
                self.sessions.append(controller)
            }
        }
    }

    // MARK: - 主机配置动作

    @objc func newHost(_ sender: Any?) {
        presentHostForm(HostProfile(connectTimeout: environment.settings.settings.defaultConnectTimeout,
                                    keepaliveInterval: environment.settings.settings.defaultKeepaliveInterval))
    }

    @objc func editSelectedHost(_ sender: Any?) {
        guard let host = sidebar.selectedHost else { return }
        presentHostForm(host)
    }

    @objc func duplicateSelectedHost(_ sender: Any?) {
        guard let host = sidebar.selectedHost else { return }
        duplicate(host: host)
    }

    @objc func deleteSelectedHost(_ sender: Any?) {
        guard let host = sidebar.selectedHost else { return }
        delete(host: host)
    }

    @objc func showPreferences(_ sender: Any?) {
        if preferences == nil {
            preferences = PreferencesWindowController(store: environment.settings)
        }
        preferences?.showWindow(nil)
        preferences?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentHostForm(_ host: HostProfile) {
        let controller = HostFormWindowController(host: host, environment: environment)
        hostForm = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func duplicate(host: HostProfile) {
        do {
            guard let copy = try environment.hosts.duplicate(id: host.id) else { return }
            copySecrets(from: host.id, to: copy.id)
            sidebar.reload()
            presentHostForm(copy)
        } catch {
            AlertPresenter.fail(title: "创建副本失败", message: error.localizedDescription, in: view.window)
        }
    }

    /// 副本沿用同一套凭据，省掉重新输入；Keychain 写失败只记日志，
    /// 因为副本本身已经可用。
    private func copySecrets(from sourceID: String, to targetID: String) {
        for kind in KeychainVault.CredentialKind.allCases {
            if let value = try? environment.vault.secret(hostID: sourceID, kind: kind), !value.isEmpty {
                try? environment.vault.setSecret(value, hostID: targetID, kind: kind)
            }
        }
    }

    private func delete(host: HostProfile) {
        let alert = NSAlert()
        alert.messageText = "删除 “\(host.displayName)”？"
        alert.informativeText = "主机配置与保存在 Keychain 里的凭据都会一并清除，known_hosts 中的记录保留。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try environment.hosts.delete(id: host.id)
            environment.vault.removeSecrets(hostID: host.id)
            // 主机没了，它的命令统计与本机忽略规则就成了孤儿数据。
            environment.commands.prune(validScopes: Set(environment.hosts.hosts.map(\.id)))
            sidebar.reload()
        } catch {
            AlertPresenter.fail(title: "删除失败", message: error.localizedDescription, in: view.window)
        }
    }

    private func toggleFavorite(host: HostProfile) {
        try? environment.hosts.setFavorite(id: host.id, !host.favorite)
        sidebar.reload()
    }
}

// MARK: - HostSidebarDelegate

extension WorkspaceViewController: HostSidebarDelegate {
    func hostSidebar(_ sidebar: HostSidebarViewController, didRequestConnect host: HostProfile) {
        connect(host: host)
    }

    func hostSidebar(_ sidebar: HostSidebarViewController, didRequestEdit host: HostProfile) {
        presentHostForm(host)
    }

    func hostSidebar(_ sidebar: HostSidebarViewController, didRequestDuplicate host: HostProfile) {
        duplicate(host: host)
    }

    func hostSidebar(_ sidebar: HostSidebarViewController, didRequestDelete host: HostProfile) {
        delete(host: host)
    }

    func hostSidebar(_ sidebar: HostSidebarViewController, didRequestFavorite host: HostProfile) {
        toggleFavorite(host: host)
    }

    func hostSidebar(_ sidebar: HostSidebarViewController, didRequestFingerprintRefresh host: HostProfile) {
        Task { @MainActor in
            await coordinator.refreshFingerprint(host: host, in: view.window)
        }
    }

    func hostSidebar(_ sidebar: HostSidebarViewController, didRequestTest host: HostProfile) {
        Task { @MainActor in
            await coordinator.test(host: host, in: view.window)
        }
    }

    func hostSidebarDidRequestNewHost(_ sidebar: HostSidebarViewController) {
        newHost(nil)
    }

    func hostSidebarDidRequestNewLocalTerminal(_ sidebar: HostSidebarViewController) {
        newLocalTerminal(nil)
    }
}

// MARK: - 菜单可用性

extension WorkspaceViewController: NSMenuItemValidation {
    /// 只有 SSH 会话才配得上文件树，其余时候把菜单项灰掉而不是弹窗。
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(showFilePanel(_:)):
            return SidePanelViewController.supportsFiles(sessions.selectedController)
        case #selector(connectSelectedHost(_:)), #selector(editSelectedHost(_:)),
             #selector(duplicateSelectedHost(_:)), #selector(deleteSelectedHost(_:)),
             #selector(testSelectedHost(_:)), #selector(refreshFingerprintSelectedHost(_:)):
            return sidebar.selectedHost != nil
        case #selector(reconnectTerminal(_:)):
            // 只有在跑完了才给重连；运行中的会话不该被 ⌘R 悄悄换掉。
            return sessions.selectedController.map { !$0.state.isAlive } ?? false
        case #selector(closeTerminalTab(_:)):
            return sessions.selectedController != nil
        case #selector(selectNextTerminalTab(_:)), #selector(selectPreviousTerminalTab(_:)):
            return !sessions.isEmpty
        case #selector(selectTerminalTab(_:)):
            return sessions.controllers.count >= menuItem.tag
        case #selector(sendSerialBreak(_:)):
            return sessions.selectedController?.supportsBreak == true
        case #selector(showCommandLibrary(_:)):
            return !sessions.isEmpty
        default:
            return true
        }
    }
}
