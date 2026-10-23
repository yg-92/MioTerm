import AppKit
import MioTermCore

/// 工作区：左侧是主机列表/远端文件树双模面板，右侧是欢迎页或终端标签。
/// 两侧内容都随会话状态切换：没连接时看主机、看欢迎页，进入主机后看文件树、看终端。
/// 所有连接与配置操作的入口都在这里，菜单项与工具栏按钮用 nil target 走响应链命中本控制器。
@MainActor
final class WorkspaceViewController: NSSplitViewController {
    private let environment = AppEnvironment.shared
    private let sessions = SessionTabViewController()
    private let welcome = WelcomeViewController()
    private let mainArea = ContainerViewController()
    private let sidePanel = SidePanelViewController()
    private lazy var coordinator = ConnectionCoordinator(environment: environment)

    /// 主机列表相关代码沿用旧名字，实际视图由侧栏面板持有。
    private var sidebar: HostSidebarViewController { sidePanel.hosts }

    private var hostForm: HostFormWindowController?
    private var preferences: PreferencesWindowController?
    /// 连接是异步的，同一主机连点两次会开出两个会话，用这个集合去重。
    private var pendingConnects: Set<String> = []

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        let panelItem = NSSplitViewItem(sidebarWithViewController: sidePanel)
        panelItem.canCollapse = true
        panelItem.minimumThickness = 220
        panelItem.maximumThickness = 420
        panelItem.preferredThicknessFraction = 0.24
        addSplitViewItem(panelItem)

        let mainItem = NSSplitViewItem(viewController: mainArea)
        mainItem.minimumThickness = 480
        addSplitViewItem(mainItem)

        sidebar.delegate = self
        sessions.onSessionsChange = { [weak self] controller in
            self?.apply(selected: controller)
        }
        // 启动停在欢迎页 + 主机列表，用户自己决定开终端还是连主机。
        mainArea.show(welcome)
    }

    /// 会话增删与选中变化统一走这里，保证左右两侧的状态一次到位。
    private func apply(selected controller: TerminalController?) {
        if let controller {
            mainArea.show(sessions)
            sidePanel.bind(to: controller)
        } else {
            sidePanel.bind(to: nil)
            mainArea.show(welcome)
        }
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

    @objc func closeTerminalTab(_ sender: Any?) {
        guard let controller = sessions.selectedController else { return }
        if environment.settings.settings.confirmBeforeClose, controller.state.isAlive {
            let alert = NSAlert()
            alert.messageText = "关闭 “\(controller.title)”？"
            alert.informativeText = "会话仍在进行中，关闭标签会终止连接。"
            alert.addButton(withTitle: "关闭")
            alert.addButton(withTitle: "取消")
            alert.buttons.last?.keyEquivalent = "\u{1b}"
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        sessions.closeSelectedTab()
    }

    @objc func reconnectTerminal(_ sender: Any?) {
        guard let controller = sessions.selectedController else { return }
        if controller.state.isAlive {
            AlertPresenter.notify(title: "会话仍在运行", message: "先关闭当前标签或等它结束，再重新连接。", in: view.window)
            return
        }
        guard let host = controller.host else {
            let replacement = TerminalController(host: nil, settings: environment.settings.settings)
            environment.register(replacement)
            replacement.startLocalShell()
            replaceSelectedTab(with: replacement)
            return
        }
        sessions.closeSelectedTab()
        connect(host: host)
    }

    private func replaceSelectedTab(with controller: TerminalController) {
        sessions.closeSelectedTab()
        sessions.append(controller)
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
        case #selector(reconnectTerminal(_:)), #selector(closeTerminalTab(_:)),
             #selector(selectNextTerminalTab(_:)), #selector(selectPreviousTerminalTab(_:)):
            return !sessions.isEmpty
        default:
            return true
        }
    }
}
