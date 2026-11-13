import AppKit
import MioTermCore

/// 连接编排：主机密钥确认 → 凭据读取 → 启动计划 → 会话控制器。
/// 把它单独拎出来是因为这条链上任何一步失败都要给出可读的中文提示，
/// 而侧栏、标签页、菜单三处都可能发起连接，逻辑不该重复三遍。
@MainActor
final class ConnectionCoordinator {
    private let environment: AppEnvironment
    private let runner = ProcessRunner()

    // 默认参数表达式不在 MainActor 上下文里求值，所以把 .shared 的读取放到方法体内。
    init(environment: AppEnvironment? = nil) {
        self.environment = environment ?? .shared
    }

    /// 返回已启动的会话控制器；返回 nil 表示用户取消或出错，错误已经弹给用户。
    func open(host rawHost: HostProfile, in window: NSWindow?) async -> TerminalController? {
        let host = resolved(environment.hosts.host(id: rawHost.id) ?? rawHost)
        guard host.protocolKind.usesHostKey else { return openByteStream(for: host, in: window) }
        do {
            guard try await ensureHostKeyTrusted(host: host, in: window) else { return nil }
            let context = SSHLaunchPlanner.Context.live()
            let launch = try SSHLaunchPlanner.terminalLaunch(
                host: host,
                secrets: environment.secrets(for: host),
                context: context
            )
            logX11Preflight(host, context: context)
            let controller = TerminalController(host: host, settings: environment.settings.settings)
            observe(controller, host: host)
            environment.register(controller)
            controller.start(launch)
            return controller
        } catch {
            AlertPresenter.fail(title: L10n.tr(.connectHostFailed, host.displayName), message: error.localizedDescription, in: window)
            return nil
        }
    }

    /// 没有子进程可依托的连接：Telnet 走 TCP，串口走 termios，失败原因由会话打印在终端里。
    private func openByteStream(for host: HostProfile, in window: NSWindow?) -> TerminalController? {
        guard let stream = makeStream(for: host) else {
            // SSH 有 OpenSSH 子进程可托管，不该走到这里。
            AlertPresenter.fail(title: L10n.tr(.connectHostFailed, host.displayName),
                                message: L10n.tr(.connectInternalSSH),
                                in: window)
            return nil
        }
        let controller = TerminalController(host: host, settings: environment.settings.settings)
        observe(controller, host: host)
        environment.register(controller)
        controller.start(stream)
        return controller
    }

    /// 主机表单里留空表示“跟随设置里的默认终端类型”，连接前一次性补上，
    /// 这样启动计划、Telnet 协商和终端模拟器看到的是同一个值。
    private func resolved(_ host: HostProfile) -> HostProfile {
        guard host.terminalType.isEmpty else { return host }
        var copy = host
        copy.terminalType = environment.settings.settings.terminalType
        return copy
    }

    /// 本机没有 X 服务时，ssh 不会失败也不报错，只是远端窗口永远连不上——
    /// 这种“参数全对但没效果”事后翻日志也看不出来，所以在连接这一刻说明白。
    private func logX11Preflight(_ host: HostProfile, context: SSHLaunchPlanner.Context) {
        guard let warning = SSHLaunchPlanner.x11PreflightWarning(host: host, context: context) else { return }
        environment.logger.warning("X11 转发：\(warning)")
    }

    private func makeStream(for host: HostProfile) -> (any TerminalStream)? {
        switch host.protocolKind {
        case .telnet:
            return TelnetStream(host: host.address,
                                port: host.port,
                                terminalType: host.terminalType,
                                connectTimeout: TimeInterval(max(1, host.connectTimeout)))
        case .serial:
            return SerialStream(configuration: host.serial)
        case .ssh:
            return nil
        }
    }

    /// 掉线后原地重连：标签、终端视图和已有输出都保留，只重建传输通道。
    /// 主机密钥与凭据按当前配置重新取，主机在列表里被改过也能生效。
    func reconnect(_ controller: TerminalController, in window: NSWindow?) async {
        guard !controller.state.isAlive, let stored = controller.host else { return }
        let host = resolved(environment.hosts.host(id: stored.id) ?? stored)
        do {
            if host.protocolKind.usesHostKey {
                // 重连同样走一遍指纹确认：服务器换过密钥时要在这里拦住。
                guard try await ensureHostKeyTrusted(host: host, in: window) else { return }
                let context = SSHLaunchPlanner.Context.live()
                let launch = try SSHLaunchPlanner.terminalLaunch(
                    host: host,
                    secrets: environment.secrets(for: host),
                    context: context
                )
                logX11Preflight(host, context: context)
                controller.start(launch)
            } else if let stream = makeStream(for: host) {
                controller.start(stream)
            }
        } catch {
            AlertPresenter.fail(title: L10n.tr(.connectReconnectFailed, host.displayName),
                                message: error.localizedDescription,
                                in: window)
        }
    }

    /// 会话状态统一登记。
    ///
    /// 失败原因已经用红字画在终端里、也浮在断线提示条上，这里不再叠一个模态窗；
    /// 补的是日志——重连不成时要能从日志看出会话停在哪一步。
    private func observe(_ controller: TerminalController, host: HostProfile) {
        let logger = environment.logger
        _ = controller.addStateObserver { state in
            logger.info("会话 \(host.displayName) 状态：\(state.label)")
        }
    }

    /// 只做认证与握手，对应 webterm 的“测试连接”。
    /// Telnet 与串口没有认证可言，退化成连通性检查。
    func test(host: HostProfile, in window: NSWindow?) async {
        guard host.protocolKind.usesHostKey else {
            testTransport(host: host, in: window)
            return
        }
        do {
            let launch = try SSHLaunchPlanner.probeLaunch(
                host: host,
                secrets: environment.secrets(for: host),
                context: .live()
            )
            let result = try await runner.run(
                executable: launch.executable,
                arguments: launch.arguments,
                environment: launch.environmentDictionary,
                timeout: TimeInterval(max(5, host.connectTimeout) + 15)
            )
            AskpassHelper.destroy(fileAt: launch.askpassFile)
            if result.succeeded {
                AlertPresenter.notify(title: L10n.tr(.connectTestSuccessTitle, host.displayName), message: L10n.tr(.connectTestSuccessMsg), in: window)
            } else {
                let detail = [result.errorText.trimmingCharacters(in: .whitespacesAndNewlines),
                              L10n.tr(.terminalProcessExitCode, result.exitStatus)]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                AlertPresenter.fail(title: L10n.tr(.connectTestFailedTitle, host.displayName), message: detail, in: window)
            }
        } catch {
            AlertPresenter.fail(title: L10n.tr(.connectTestErrorTitle), message: error.localizedDescription, in: window)
        }
    }

    /// 不建会话的连通性检查：Telnet 探端口，串口只看设备在不在。
    private func testTransport(host: HostProfile, in window: NSWindow?) {
        switch host.protocolKind {
        case .ssh:
            break
        case .serial:
            let device = host.serial.device
            Task {
                // 只枚举、不打开：很多开发板在 DTR/RTS 跳变时复位，测试连接不该有副作用。
                let present = await Task.detached(priority: .userInitiated) { SerialDevices.isAvailable(device) }.value
                if present {
                    AlertPresenter.notify(title: L10n.tr(.connectSerialReadyTitle, host.displayName),
                                          message: L10n.tr(.connectSerialReadyMsg, device),
                                          in: window)
                } else {
                    AlertPresenter.fail(title: L10n.tr(.connectSerialMissingTitle, host.displayName),
                                        message: L10n.tr(.connectSerialMissingMsg, device),
                                        in: window)
                }
            }
        case .telnet:
            let address = host.address
            let port = host.port
            let timeout = TimeInterval(max(1, host.connectTimeout))
            Task {
                // 端口探测是阻塞调用，必须离开主线程；界面引用留在主线程。
                let outcome = await Task.detached(priority: .userInitiated) { () -> String? in
                    do {
                        try TCPSocket.probe(host: address, port: port, timeout: timeout)
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }.value
                if let outcome {
                    AlertPresenter.fail(title: L10n.tr(.connectUnreachableTitle, host.displayName), message: outcome, in: window)
                } else {
                    AlertPresenter.notify(title: L10n.tr(.connectPortReachableTitle, host.displayName),
                                          message: L10n.tr(.connectPortReachableMsg, address, port),
                                          in: window)
                }
            }
        }
    }

    /// 主动重新探测指纹，用于服务器换密钥后的手工更新。
    func refreshFingerprint(host: HostProfile, in window: NSWindow?) async {
        do {
            let keys = try await HostKeyProber().probe(host: host.address, port: host.port, timeout: max(3, host.connectTimeout))
            let alert = NSAlert()
            alert.messageText = L10n.tr(.connectCurrentFingerprintTitle, host.displayName)
            alert.informativeText = Self.fingerprintList(keys)
            alert.alertStyle = .informational
            alert.addButton(withTitle: L10n.tr(.connectRecordFingerprint))
            alert.addButton(withTitle: L10n.tr(.commonCancel))
            let response = await AlertPresenter.present(alert, in: window)
            if response == .alertFirstButtonReturn {
                let updated = try environment.hostKeyGuard.confirm(host: host, keys: keys)
                try environment.hosts.recordHostKey(id: host.id, algorithm: updated.hostKeyAlgorithm, fingerprint: updated.hostKeyFingerprint)
            }
        } catch {
            AlertPresenter.fail(title: L10n.tr(.connectFetchFingerprintFailed), message: error.localizedDescription, in: window)
        }
    }

    /// 首连确认、指纹变更告警。返回 false 表示用户拒绝继续。
    private func ensureHostKeyTrusted(host: HostProfile, in window: NSWindow?) async throws -> Bool {
        let decision: HostKeyDecision
        do {
            decision = try await environment.hostKeyGuard.evaluate(host: host)
        } catch let error as HostKeyProbeError {
            throw error
        }
        switch decision {
        case .trusted:
            return true
        case .unconfirmed(let keys):
            guard !keys.isEmpty else { return false }
            let alert = NSAlert()
            alert.messageText = L10n.tr(.connectFirstTimeTitle, host.address, host.port)
            alert.informativeText = L10n.tr(.connectFirstTimeMsg, Self.fingerprintList(keys))
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.tr(.connectTrustAndConnect))
            alert.addButton(withTitle: L10n.tr(.commonCancel))
            alert.buttons.last?.keyEquivalent = "\u{1b}"
            guard await AlertPresenter.present(alert, in: window) == .alertFirstButtonReturn else { return false }
            let updated = try environment.hostKeyGuard.confirm(host: host, keys: keys)
            try environment.hosts.recordHostKey(id: host.id, algorithm: updated.hostKeyAlgorithm, fingerprint: updated.hostKeyFingerprint)
            return true
        case .changed(let stored, let current):
            let alert = NSAlert()
            alert.messageText = L10n.tr(.connectKeyChangedTitle)
            alert.informativeText = L10n.tr(
                .connectKeyChangedDetailMsg,
                host.address,
                host.port,
                stored,
                current.algorithm,
                current.bits,
                current.fingerprint
            )
            alert.alertStyle = .critical
            alert.addButton(withTitle: L10n.tr(.connectCancelConnection))
            alert.addButton(withTitle: L10n.tr(.connectConfirmKeyRotation))
            alert.buttons.first?.keyEquivalent = "\u{1b}"
            guard await AlertPresenter.present(alert, in: window) == .alertSecondButtonReturn else { return false }
            let updated = try environment.hostKeyGuard.confirm(host: host, keys: [current])
            try environment.hosts.recordHostKey(id: host.id, algorithm: updated.hostKeyAlgorithm, fingerprint: updated.hostKeyFingerprint)
            return true
        }
    }

    static func fingerprintList(_ keys: [ScannedHostKey]) -> String {
        keys.map { L10n.tr(.connectKeyBitsFormat, $0.algorithm, $0.bits, $0.fingerprint) }.joined(separator: "\n\n")
    }
}
