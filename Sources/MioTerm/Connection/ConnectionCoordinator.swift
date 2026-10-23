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
        let host = environment.hosts.host(id: rawHost.id) ?? rawHost
        guard host.protocolKind.usesHostKey else { return openByteStream(for: host, in: window) }
        do {
            guard try await ensureHostKeyTrusted(host: host, in: window) else { return nil }
            let launch = try SSHLaunchPlanner.terminalLaunch(
                host: host,
                secrets: environment.secrets(for: host),
                context: .live()
            )
            let controller = TerminalController(host: host, settings: environment.settings.settings)
            observe(controller, host: host, in: window)
            environment.register(controller)
            controller.start(launch)
            return controller
        } catch {
            AlertPresenter.fail(title: "连接 \(host.displayName) 失败", message: error.localizedDescription, in: window)
            return nil
        }
    }

    /// 没有子进程可依托的连接：Telnet 走 TCP，串口走 termios，失败原因由会话打印在终端里。
    private func openByteStream(for host: HostProfile, in window: NSWindow?) -> TerminalController? {
        let stream: any TerminalStream
        switch host.protocolKind {
        case .telnet:
            stream = TelnetStream(host: host.address,
                                  port: host.port,
                                  terminalType: host.terminalType,
                                  connectTimeout: TimeInterval(max(1, host.connectTimeout)))
        case .serial:
            stream = SerialStream(configuration: host.serial)
        case .ssh:
            // SSH 有 OpenSSH 子进程可托管，不该走到这里。
            AlertPresenter.fail(title: "连接 \(host.displayName) 失败",
                                message: "SSH 会话应通过子进程启动，这里是内部错误。",
                                in: window)
            return nil
        }
        let controller = TerminalController(host: host, settings: environment.settings.settings)
        observe(controller, host: host, in: window)
        environment.register(controller)
        controller.start(stream)
        return controller
    }

    /// 会话状态统一登记：失败要弹窗，其余只记日志。
    private func observe(_ controller: TerminalController, host: HostProfile, in window: NSWindow?) {
        controller.onStateChange = { [weak self] state in
            if case .failed(let reason) = state {
                AlertPresenter.fail(title: "无法连接 \(host.displayName)", message: reason, in: window)
            }
            self?.environment.logger.info("会话 \(host.displayName) 状态：\(state.label)")
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
                AlertPresenter.notify(title: "\(host.displayName) 连接成功", message: "认证与握手均通过。", in: window)
            } else {
                let detail = [result.errorText.trimmingCharacters(in: .whitespacesAndNewlines),
                              "退出码 \(result.exitStatus)"]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                AlertPresenter.fail(title: "\(host.displayName) 连接失败", message: detail, in: window)
            }
        } catch {
            AlertPresenter.fail(title: "测试连接失败", message: error.localizedDescription, in: window)
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
                    AlertPresenter.notify(title: "\(host.displayName) 设备就绪",
                                          message: "\(device) 已被系统识别。打开终端即可，测试不会占用设备。",
                                          in: window)
                } else {
                    AlertPresenter.fail(title: "\(host.displayName) 找不到设备",
                                        message: "\(device) 不在系统串口列表里，请检查连线与驱动后在表单里刷新设备列表。",
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
                    AlertPresenter.fail(title: "\(host.displayName) 不可达", message: outcome, in: window)
                } else {
                    AlertPresenter.notify(title: "\(host.displayName) 端口可达",
                                          message: "\(address):\(port) 能建立 TCP 连接。登录请在终端里完成。",
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
            alert.messageText = "\(host.displayName) 当前指纹"
            alert.informativeText = Self.fingerprintList(keys)
            alert.alertStyle = .informational
            alert.addButton(withTitle: "记录该指纹")
            alert.addButton(withTitle: "取消")
            let response = await AlertPresenter.present(alert, in: window)
            if response == .alertFirstButtonReturn {
                let updated = try environment.hostKeyGuard.confirm(host: host, keys: keys)
                try environment.hosts.recordHostKey(id: host.id, algorithm: updated.hostKeyAlgorithm, fingerprint: updated.hostKeyFingerprint)
            }
        } catch {
            AlertPresenter.fail(title: "获取指纹失败", message: error.localizedDescription, in: window)
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
            alert.messageText = "首次连接 \(host.address):\(host.port)"
            alert.informativeText = """
            请核对服务器指纹，确认无误后再信任。指纹不符时应当取消，\
            因为无法区分“没见过这台机器”和“链路被中间人劫持”。

            \(Self.fingerprintList(keys))
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "信任并连接")
            alert.addButton(withTitle: "取消")
            alert.buttons.last?.keyEquivalent = "\u{1b}"
            guard await AlertPresenter.present(alert, in: window) == .alertFirstButtonReturn else { return false }
            let updated = try environment.hostKeyGuard.confirm(host: host, keys: keys)
            try environment.hosts.recordHostKey(id: host.id, algorithm: updated.hostKeyAlgorithm, fingerprint: updated.hostKeyFingerprint)
            return true
        case .changed(let stored, let current):
            let alert = NSAlert()
            alert.messageText = "服务器身份已变化"
            alert.informativeText = """
            \(host.address):\(host.port) 的宿主密钥与已记录的指纹不一致。

            已记录：\(stored)
            当前（\(current.algorithm) \(current.bits) 位）：\(current.fingerprint)

            这可能意味着中间人攻击，也可能是服务器重装或换了密钥。\
            若无法确认原因，请取消并联系管理员。
            """
            alert.alertStyle = .critical
            alert.addButton(withTitle: "取消连接")
            alert.addButton(withTitle: "我确认服务器更换了密钥")
            alert.buttons.first?.keyEquivalent = "\u{1b}"
            guard await AlertPresenter.present(alert, in: window) == .alertSecondButtonReturn else { return false }
            let updated = try environment.hostKeyGuard.confirm(host: host, keys: [current])
            try environment.hosts.recordHostKey(id: host.id, algorithm: updated.hostKeyAlgorithm, fingerprint: updated.hostKeyFingerprint)
            return true
        }
    }

    static func fingerprintList(_ keys: [ScannedHostKey]) -> String {
        keys.map { "\($0.algorithm) \($0.bits) 位\n\($0.fingerprint)" }.joined(separator: "\n\n")
    }
}
