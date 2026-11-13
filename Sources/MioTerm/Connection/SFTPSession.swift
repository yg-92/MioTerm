import AppKit
import MioTermCore

/// 一个 SSH 会话对应的 SFTP 通道与传输队列。
///
/// 通道按需建立：只有打开文件面板才起第二条 `ssh -s sftp` 连接，
/// 纯敲终端的用户不该多付一个子进程的代价。
@MainActor
final class SFTPSession {
    enum State: Equatable {
        case closed
        case connecting
        case ready
        /// 远端没有可用的 SFTP 子系统。这是配置问题，不是网络故障，
        /// 面板应当提示原因而不是当异常处理。
        case unsupported
        case failed(String)

        var label: String {
            switch self {
            case .closed: return L10n.tr(.sftpStateClosed)
            case .connecting: return L10n.tr(.terminalStateStarting)
            case .ready: return L10n.tr(.terminalStateRunning)
            case .unsupported: return L10n.tr(.sftpNoticeTitle)
            case .failed: return L10n.tr(.tabConnectFailed)
            }
        }

        /// 带关联值的失败态没法直接 == 比较，面板靠它决定要不要给“重试”。
        var isFailed: Bool {
            switch self {
            case .failed, .unsupported: return true
            default: return false
            }
        }
    }

    enum SessionError: LocalizedError {
        case notSupported(ConnectionProtocol)
        case disabled

        var errorDescription: String? {
            switch self {
            case .disabled: return L10n.tr(.sftpErrorDisabled)
            case .notSupported(let kind): return L10n.tr(.sftpErrorNotSupported, kind.displayName)
            }
        }
    }

    let host: HostProfile
    private let environment: AppEnvironment

    private(set) var state: State = .closed {
        didSet {
            guard state != oldValue else { return }
            // 文件面板的一切动作都以这条通道为前提：它没就绪，跟随就不可能动。
            // 状态变化不写日志，出问题时就只剩「面板一声不吭」这一种现象。
            switch state {
            case .failed(let reason):
                environment.logger.warning("SFTP 通道 \(host.displayName) 失败：\(reason)")
            default:
                environment.logger.info("SFTP 通道 \(host.displayName)：\(state.label)")
            }
            onStateChange?(state)
        }
    }
    private(set) var client: SFTPClient?
    private(set) var transfers: SFTPTransferCoordinator?
    private var transport: SSHSubsystemTransport?
    /// 并发点开面板时只建一条通道。
    private var attempt: Task<SFTPClient, Error>?

    var onStateChange: ((State) -> Void)?
    var onTransferUpdate: ((SFTPTransferProgress) -> Void)?

    init(host: HostProfile, environment: AppEnvironment) {
        self.host = host
        self.environment = environment
    }

    /// 复用已有通道，否则建一条；失败会把原因（含 ssh stderr）抛回调用方。
    func ensureClient() async throws -> SFTPClient {
        if let client, state == .ready { return client }
        if let attempt { return try await attempt.value }
        state = .connecting
        let task = Task { [self] in try await open() }
        attempt = task
        do {
            let client = try await task.value
            attempt = nil
            self.client = client
            transfers = makeTransfers(client)
            state = .ready
            return client
        } catch {
            attempt = nil
            if Self.indicatesMissingSubsystem(error) {
                environment.logger.warning("SFTP 通道 \(host.displayName) 未启用子系统：\(error.localizedDescription)")
                state = .unsupported
            } else {
                state = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    private static func indicatesMissingSubsystem(_ error: Error) -> Bool {
        if let connection = error as? SFTPConnection.ConnectionError {
            return connection.indicatesMissingSubsystem
        }
        if let session = error as? SessionError, case .notSupported = session {
            return true
        }
        return false
    }

    private func makeTransfers(_ client: SFTPClient) -> SFTPTransferCoordinator {
        let settings = environment.settings.settings
        return SFTPTransferCoordinator(
            client: client,
            bufferBytes: settings.uploadChunkBytes,
            maxConcurrent: settings.maxConcurrentTransfers
        ) { [weak self] progress in
            Task { @MainActor in self?.onTransferUpdate?(progress) }
        }
    }

    private func open() async throws -> SFTPClient {
        guard host.protocolKind.supportsSFTP else { throw SessionError.notSupported(host.protocolKind) }
        guard host.sftpEnabled else { throw SessionError.disabled }
        let launch = try SSHLaunchPlanner.sftpLaunch(
            host: host,
            secrets: environment.secrets(for: host),
            context: .live()
        )
        let transport = SSHSubsystemTransport(launch: launch)
        self.transport = transport
        environment.logger.info("打开 SFTP 通道 \(host.displayName)：\(launch.redactedDescription)")
        do {
            // 握手要等远端起 sftp-server，比交互登录更慢，超时给足余量。
            return try await SFTPClient.connect(
                transport: transport,
                handshakeTimeout: TimeInterval(max(10, host.connectTimeout) + 15)
            )
        } catch {
            let detail = transport.errorText
            throw SFTPConnection.ConnectionError.closed(detail.isEmpty ? error.localizedDescription : detail)
        }
    }

    func retry() async throws -> SFTPClient {
        shutdown()
        return try await ensureClient()
    }

    /// 全同步收尾：关标签与退出应用都不允许再 await，
    /// 先把子进程与 askpass 断掉，挂起的请求会被连接层以错误唤醒。
    func shutdown() {
        let transfers = self.transfers
        self.transfers = nil
        client = nil
        transport?.terminateNow()
        transport = nil
        state = .closed
        if let transfers {
            Task { await transfers.cancelAll() }
        }
    }
}
