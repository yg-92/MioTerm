import AppKit
import MioTermCore

/// 应用级依赖的组装点。UI 层通过它拿到仓库、设置、Keychain 与主机密钥守卫，
/// 避免每个视图各自 new 一份导致状态不一致。
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let hosts: HostRepository
    let settings: SettingsStore
    let vault: KeychainVault
    let hostKeyGuard: HostKeyGuard
    let logger: FileLogger

    /// 会话集中登记，退出应用时才能统一销毁 askpass 临时文件并回收子进程。
    private(set) var sessions: [UUID: TerminalController] = [:]
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
        settings = SettingsStore()
        vault = KeychainVault()
        hostKeyGuard = HostKeyGuard()
        hosts.load()
        applyAppearance()
        settings.onChange = { [weak self] next in
            guard let self else { return }
            self.applyAppearance()
            for controller in self.sessions.values {
                controller.apply(next)
            }
        }
    }

    func register(_ controller: TerminalController) {
        sessions[controller.sessionID] = controller
    }

    func unregister(_ controller: TerminalController) {
        sessions.removeValue(forKey: controller.sessionID)
        closeSFTPSession(for: controller)
    }

    /// 懒建文件通道；非 SSH 主机返回 nil，文件面板据此显示占位文案。
    func sftpSession(for controller: TerminalController) -> SFTPSession? {
        guard let host = controller.host, host.protocolKind.supportsSFTP else { return nil }
        if let existing = sftpSessions[controller.sessionID] { return existing }
        let session = SFTPSession(host: host, environment: self)
        sftpSessions[controller.sessionID] = session
        return session
    }

    func closeSFTPSession(for controller: TerminalController) {
        sftpSessions.removeValue(forKey: controller.sessionID)?.shutdown()
    }

    /// 与 webterm 的外观设置等价：只切换界面主题，终端配色由远端程序自己决定。
    func applyAppearance() {
        switch settings.settings.appearance {
        case .system: NSApp.appearance = nil
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        }
    }

    /// 读取主机凭据。Keychain 访问被拒时返回 nil，让 ssh 在终端里照常提示输入，
    /// 而不是直接掐断连接。
    func secrets(for host: HostProfile) -> TerminalSecrets? {
        var secrets = TerminalSecrets()
        do {
            switch host.authMethod {
            case .password:
                secrets.password = try vault.secret(hostID: host.id, kind: .password)
            case .privateKey:
                secrets.passphrase = try vault.secret(hostID: host.id, kind: .passphrase)
            case .automatic:
                secrets.password = try vault.secret(hostID: host.id, kind: .password)
                secrets.passphrase = try vault.secret(hostID: host.id, kind: .passphrase)
            }
        } catch {
            logger.warning("读取 \(host.displayName) 凭据失败：\(error.localizedDescription)")
            return nil
        }
        return secrets.hasContent ? secrets : nil
    }

    func terminateAllSessions() {
        for controller in sessions.values { controller.stop() }
        // 退出时已经没有 await 的机会，逐个把 ssh 子进程与 askpass 当场收掉。
        for session in sftpSessions.values { session.shutdown() }
        sftpSessions.removeAll()
    }
}
