import AppKit
import MioTermCore

/// 应用级依赖的组装点。UI 层通过它拿到仓库、设置、Keychain 与主机密钥守卫，
/// 避免每个视图各自 new 一份导致状态不一致。
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let hosts: HostRepository
    let credentials: CredentialRepository
    let settings: SettingsStore
    let vault: KeychainVault
    let hostKeyGuard: HostKeyGuard
    let logger: FileLogger
    /// 命令统计、收藏与忽略清单。终端每提交一条命令就写一次库，界面靠它的 onChange 刷新。
    let commands: CommandLibraryStore

    /// 会话集中登记，退出应用时才能统一销毁 askpass 临时文件并回收子进程。
    private(set) var sessions: [UUID: any SessionControlling] = [:]
    /// 文件通道按终端会话一对一持有：切标签不重连，关标签才收进程。
    private(set) var sftpSessions: [UUID: SFTPSession] = [:]

    private init() {
        do {
            try AppPaths.ensureDirectories()
        } catch {
            FileLogger.shared.error("应用支持目录创建失败：\(error.localizedDescription)")
        }
        logger = .shared
        hosts = HostRepository()
        credentials = CredentialRepository()
        settings = SettingsStore()
        L10n.configure(preference: settings.settings.language)
        vault = KeychainVault()
        hostKeyGuard = HostKeyGuard()
        commands = CommandLibraryStore()
        hosts.load()
        credentials.load()
        commands.load()
        applyAppearance()
        settings.onChange = { [weak self] next in
            guard let self else { return }
            let languageChanged = L10n.resolveLanguageCode(preference: next.language) != L10n.currentLanguageCode
            L10n.configure(preference: next.language)
            if languageChanged {
                MenuBuilder.install()
            }
            self.applyAppearance()
            for controller in self.sessions.values {
                controller.apply(next)
            }
            // 文件树的字号/图标与界面语言更改只影响侧栏与各窗口，
            // 用通知让已经打开的视图就地重排，不必等切标签或重连。
            NotificationCenter.default.post(name: .mioTermSettingsDidChange, object: next)
        }
    }

    func register(_ controller: any SessionControlling) {
        sessions[controller.sessionID] = controller
        guard let terminal = controller as? TerminalController else { return }
        // 命令库挂在会话上：只有回车提交的那一行才入库，逐字节不进这里。
        terminal.onCommand = { [weak self, weak terminal] line in
            guard let self, let terminal else { return }
            self.commands.record(scope: terminal.commandScope, command: line)
        }
    }

    func unregister(_ controller: any SessionControlling) {
        sessions.removeValue(forKey: controller.sessionID)
        if let terminal = controller as? TerminalController {
            closeSFTPSession(for: terminal)
        }
    }

    /// 懒建文件通道；非 SSH 主机返回 nil，文件面板据此显示占位文案。
    func sftpSession(for controller: TerminalController) -> SFTPSession? {
        guard let host = controller.host, host.supportsSFTP else { return nil }
        if let existing = sftpSessions[controller.sessionID] { return existing }
        let session = SFTPSession(host: resolvedHost(host), environment: self)
        sftpSessions[controller.sessionID] = session
        return session
    }

    /// 合并凭据库引用与默认终端类型，确保 SSH / SFTP / RDP / VNC 拿到的用户名和终端类型始终与最新配置同步。
    func resolvedHost(_ host: HostProfile) -> HostProfile {
        var copy = host
        if let credID = host.credentialID,
           let cred = credentials.credential(id: credID),
           !cred.username.isEmpty {
            copy.username = cred.username
        }
        if copy.terminalType.isEmpty {
            copy.terminalType = settings.settings.terminalType
        }
        return copy
    }

    func closeSFTPSession(for controller: TerminalController) {
        sftpSessions.removeValue(forKey: controller.sessionID)?.shutdown()
    }

    /// 界面外观跟随设置；终端配色由远端程序决定，只有底色与 ANSI 调色板属于本机，
    /// 所以要跟着深浅模式一起换掉。
    func applyAppearance() {
        let current = settings.settings
        Theme.configure(contrast: current.contrast, accent: current.accent, customization: current.themeCustomization)
        switch current.appearance {
        case .system: NSApp.appearance = nil
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        }
        for controller in sessions.values {
            controller.applyTheme()
        }
        // 只换配色档位时系统外观没变，AppKit 不会回调外观变化，
        // 手动沿视图树走一遍，图层色才会按新调色板重新解析。
        for window in NSApp.windows {
            window.contentView?.applyThemeChangeRecursively()
        }
    }

    /// 读取主机凭据。若主机绑定了凭据库条目，优先从凭据库对应的 Keychain 条目读取密码，
    /// 凭据库改密码后所有关联主机自动生效。
    func secrets(for host: HostProfile) -> TerminalSecrets? {
        var secrets = TerminalSecrets()
        do {
            if host.protocolKind == .vnc || host.protocolKind == .rdp {
                secrets.password = try passwordSecret(for: host)
                return secrets.hasContent ? secrets : nil
            }
            switch host.authMethod {
            case .password:
                secrets.password = try passwordSecret(for: host)
            case .privateKey:
                secrets.passphrase = try vault.secret(hostID: host.id, kind: .passphrase)
            case .automatic:
                secrets.password = try passwordSecret(for: host)
                secrets.passphrase = try vault.secret(hostID: host.id, kind: .passphrase)
            }
        } catch {
            logger.warning("读取 \(host.displayName) 凭据失败：\(error.localizedDescription)")
            return nil
        }
        return secrets.hasContent ? secrets : nil
    }

    private func passwordSecret(for host: HostProfile) throws -> String? {
        if let credID = host.credentialID,
           credentials.credential(id: credID) != nil,
           let shared = try vault.secret(hostID: CredentialProfile.vaultKey(for: credID), kind: .password) {
            return shared
        }
        return try vault.secret(hostID: host.id, kind: .password)
    }

    func terminateAllSessions() {
        for controller in sessions.values { controller.stop() }
        // 退出时已经没有 await 的机会，逐个把 ssh 子进程与 askpass 当场收掉。
        for session in sftpSessions.values { session.shutdown() }
        sftpSessions.removeAll()
    }
}

extension Notification.Name {
    static let mioTermSettingsDidChange = Notification.Name("MioTermSettingsDidChange")
    static let mioTermWindowOpacityPreview = Notification.Name("MioTermWindowOpacityPreview")
}
