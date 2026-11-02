import Testing
import Foundation
@testable import MioTermCore

private func makeContext(knownHosts: URL = URL(fileURLWithPath: "/tmp/mio test/known_hosts"),
                         display: String? = nil) -> SSHLaunchPlanner.Context {
    var inherited = [
        "HOME": "/Users/yanggang",
        "USER": "yanggang",
        "PATH": "/usr/bin:/bin",
        "SSH_AUTH_SOCK": "/tmp/ssh-agent/sock",
    ]
    if let display { inherited["DISPLAY"] = display }
    return SSHLaunchPlanner.Context(
        knownHostsURL: knownHosts,
        askpassLauncherURL: URL(fileURLWithPath: "/tmp/mio test/askpass.sh"),
        inheritedEnvironment: inherited
    )
}

struct SSHLaunchPlannerTests {
    @Test func terminalLaunchForcesPTYAndIsolatesKnownHosts() throws {
        let host = HostProfile(name: "web", address: "10.0.0.5", username: "root", authMethod: .automatic)
        let launch = try SSHLaunchPlanner.terminalLaunch(host: host, secrets: nil, context: makeContext())

        #expect(launch.executable == "/usr/bin/ssh")
        #expect(launch.arguments.contains("-tt"))
        #expect(launch.arguments.contains("-l"))
        #expect(launch.arguments.contains("10.0.0.5"))
        #expect(launch.arguments.contains("-o"))
        #expect(launch.arguments.contains("StrictHostKeyChecking=yes"))
        #expect(launch.arguments.contains("EscapeChar=none"))
        #expect(launch.arguments.contains("UserKnownHostsFile=\"/tmp/mio test/known_hosts\""))
        #expect(launch.arguments.contains("GlobalKnownHostsFile=/dev/null"))
        // 默认端口不重复传 -p，避免覆盖 ssh_config 里的 PerPortForwarding 之类设定。
        #expect(!launch.arguments.contains("-p"))
        #expect(launch.askpassFile == nil)
    }

    @Test func nonDefaultPortIsPassedThrough() throws {
        var host = HostProfile(name: "odd", address: "host.example", username: "deploy")
        host.port = 2222
        let launch = try SSHLaunchPlanner.terminalLaunch(host: host, secrets: nil, context: makeContext())
        #expect(launch.arguments.contains("-p"))
        #expect(launch.arguments.contains("2222"))
    }

    /// 主机指定了终端类型就要原样传给远端；没指定时由 passwordAuth… 用例守着兜底值。
    @Test func hostTerminalTypeReachesEnvironment() throws {
        var host = HostProfile(name: "vt", address: "h", username: "u")
        host.terminalType = "vt220"
        let launch = try SSHLaunchPlanner.terminalLaunch(host: host, secrets: nil, context: makeContext())
        #expect(launch.environment.contains("TERM=vt220"))
        #expect(launch.environment.contains("COLORTERM=truecolor"))
    }

    @Test func passwordAuthRestrictsMethodsAndFailsFast() throws {
        var host = HostProfile(name: "pw", address: "h", username: "u", authMethod: .password)
        host.connectTimeout = 5
        host.keepaliveInterval = 45
        let launch = try SSHLaunchPlanner.terminalLaunch(
            host: host,
            secrets: TerminalSecrets(password: "hunter2"),
            context: makeContext()
        )
        #expect(launch.arguments.contains("PreferredAuthentications=password,keyboard-interactive"))
        #expect(launch.arguments.contains("PubkeyAuthentication=no"))
        #expect(launch.arguments.contains("NumberOfPasswordPrompts=1"))
        #expect(launch.arguments.contains("ConnectTimeout=5"))
        #expect(launch.arguments.contains("ServerAliveInterval=45"))

        let environment = launch.environment
        #expect(environment.contains { $0.hasPrefix("SSH_ASKPASS_REQUIRE=force") })
        #expect(environment.contains { $0.hasPrefix("SSH_ASKPASS=/tmp/mio test/askpass.sh") })
        #expect(environment.contains { $0.hasPrefix("MIOTERM_ASKPASS_FILE=") })
        #expect(environment.contains("TERM=xterm-256color"))
        #expect(environment.contains("PATH=/usr/bin:/bin"))
        // agent 套接字必须透传，否则 automatic 模式下用不了用户的 keychain agent。
        #expect(environment.contains("SSH_AUTH_SOCK=/tmp/ssh-agent/sock"))
        try? FileManager.default.removeItem(at: launch.askpassFile!)
    }

    @Test func secretsWithoutContentDoNotEnableAskpass() throws {
        let host = HostProfile(name: "pw", address: "h", username: "u", authMethod: .password)
        let launch = try SSHLaunchPlanner.terminalLaunch(
            host: host,
            secrets: TerminalSecrets(password: ""),
            context: makeContext()
        )
        #expect(launch.askpassFile == nil)
        #expect(!launch.environment.contains { $0.hasPrefix("SSH_ASKPASS") })
    }

    @Test func missingIdentityFileFailsBeforeLaunch() {
        var host = HostProfile(name: "key", address: "h", username: "u", authMethod: .privateKey)
        host.identityFile = "/tmp/definitely-missing-key"
        #expect(throws: SSHLaunchError.identityFileMissing("/tmp/definitely-missing-key")) {
            try SSHLaunchPlanner.terminalLaunch(host: host, secrets: TerminalSecrets(passphrase: "x"), context: makeContext())
        }
    }

    @Test func startupDirectoryIsQuotedForRemoteShell() throws {
        var host = HostProfile(name: "start", address: "h", username: "u")
        host.startupDirectory = "/opt/it's here"
        let launch = try SSHLaunchPlanner.terminalLaunch(host: host, secrets: nil, context: makeContext())
        let command = try #require(launch.arguments.last)
        #expect(command.hasPrefix("cd '/opt/it'\\''s here'"))
        #expect(command.contains("exec \"${SHELL:-/bin/sh}\" -l"))
    }

    @Test func sftpChannelRequestsSubsystemWithoutTTY() throws {
        let host = HostProfile(name: "sftp", address: "h", username: "u")
        let launch = try SSHLaunchPlanner.sftpLaunch(host: host, secrets: nil, context: makeContext())
        #expect(launch.arguments.contains("-T"))
        #expect(launch.arguments.contains("-s"))
        #expect(launch.arguments.last == "sftp")
        #expect(!launch.arguments.contains("-tt"))
    }

    @Test func probeWithoutSecretsIsNonInteractive() throws {
        let host = HostProfile(name: "probe", address: "h", username: "u")
        let launch = try SSHLaunchPlanner.probeLaunch(host: host, secrets: nil, context: makeContext())
        #expect(launch.arguments.contains("BatchMode=yes"))
        #expect(launch.arguments.contains("NumberOfPasswordPrompts=0"))
        #expect(launch.arguments.last == "true")
    }

    @Test func redactedDescriptionHidesAskpassPath() throws {
        let host = HostProfile(name: "pw", address: "h", username: "u", authMethod: .password)
        let launch = try SSHLaunchPlanner.terminalLaunch(
            host: host,
            secrets: TerminalSecrets(password: "hunter2"),
            context: makeContext()
        )
        #expect(launch.redactedDescription.contains("MIOTERM_ASKPASS_FILE=<hidden>"))
        #expect(!launch.redactedDescription.contains("hunter2"))
        try? FileManager.default.removeItem(at: launch.askpassFile!)
    }

    @Test func environmentArrayConvertsToDictionaryForOneShotCommands() {
        let launch = ProcessLaunch(
            executable: "/usr/bin/ssh",
            arguments: [],
            environment: ["PATH=/usr/bin:/bin", "TERM=xterm-256color", "WEIRD=a=b"]
        )
        let dictionary = launch.environmentDictionary
        #expect(dictionary["PATH"] == "/usr/bin:/bin")
        #expect(dictionary["TERM"] == "xterm-256color")
        // 值里含等号时只能按第一个等号切分，否则 agent 路径会被截断。
        #expect(dictionary["WEIRD"] == "a=b")
    }

    // MARK: - X11 转发

    /// 受限档就是 `ssh -X`：只要求 ForwardX11，不带 Trusted。
    @Test func restrictedX11RequestsUntrustedForwarding() throws {
        var host = HostProfile(name: "x", address: "h", username: "u")
        host.x11Forwarding = .restricted
        let launch = try SSHLaunchPlanner.terminalLaunch(host: host, secrets: nil, context: makeContext())
        #expect(launch.arguments.contains("ForwardX11=yes"))
        #expect(!launch.arguments.contains("ForwardX11Trusted=yes"))
    }

    @Test func trustedX11AddsTheTrustedOption() throws {
        var host = HostProfile(name: "x", address: "h", username: "u")
        host.x11Forwarding = .trusted
        let launch = try SSHLaunchPlanner.terminalLaunch(host: host, secrets: nil, context: makeContext())
        #expect(launch.arguments.contains("ForwardX11=yes"))
        #expect(launch.arguments.contains("ForwardX11Trusted=yes"))
    }

    @Test func x11IsOffByDefaultAndLeavesNoTrace() throws {
        let host = HostProfile(name: "x", address: "h", username: "u")
        let launch = try SSHLaunchPlanner.terminalLaunch(host: host, secrets: nil, context: makeContext())
        #expect(!launch.arguments.contains { $0.hasPrefix("ForwardX11") })
    }

    /// 文件面板那条 `ssh -T -s` 不转 X11：否则每次开面板都会在远端 ~/.Xauthority
    /// 里多塞一枚没人用的 cookie；连通性测试同理。
    @Test func otherChannelsNeverForwardX11() throws {
        var host = HostProfile(name: "x", address: "h", username: "u")
        host.x11Forwarding = .trusted
        let sftp = try SSHLaunchPlanner.sftpLaunch(host: host, secrets: nil, context: makeContext())
        let probe = try SSHLaunchPlanner.probeLaunch(host: host, secrets: nil, context: makeContext())
        #expect(!sftp.arguments.contains { $0.hasPrefix("ForwardX11") })
        #expect(!probe.arguments.contains { $0.hasPrefix("ForwardX11") })
        #expect(!sftp.environment.contains { $0.hasPrefix("DISPLAY=") })
    }

    /// 环境是按白名单重建的，转发时 DISPLAY 必须一起给，否则 ssh 只能造假 cookie。
    @Test func displayIsPassedThroughOnlyWhenForwarding() throws {
        var host = HostProfile(name: "x", address: "h", username: "u")
        host.x11Forwarding = .restricted
        let context = makeContext(display: "/tmp/.X11-unix/X0")
        let launch = try SSHLaunchPlanner.terminalLaunch(host: host, secrets: nil, context: context)
        #expect(launch.environment.contains("DISPLAY=/tmp/.X11-unix/X0"))

        host.x11Forwarding = .off
        let plain = try SSHLaunchPlanner.terminalLaunch(host: host, secrets: nil, context: context)
        #expect(!plain.environment.contains { $0.hasPrefix("DISPLAY=") })
    }

    /// 本机没有 X 服务时 ssh 不报错，只是窗口永远连不上，所以要在连接前说明白。
    @Test func preflightNamesTheMissingLocalPiece() {
        var host = HostProfile(name: "x", address: "h", username: "u")
        host.x11Forwarding = .restricted
        let noDisplay = makeContext()
        let missingDisplay = SSHLaunchPlanner.x11PreflightWarning(host: host, context: noDisplay,
                                                                  xauthExists: { _ in true })
        #expect(missingDisplay?.contains("DISPLAY") ?? false)
        let missingXauth = SSHLaunchPlanner.x11PreflightWarning(host: host, context: makeContext(display: ":0"),
                                                                xauthExists: { _ in false })
        #expect(missingXauth?.contains("XQuartz") ?? false)
        // 条件齐了就不该再唠叨；没开转发的会话更与此无关。
        #expect(SSHLaunchPlanner.x11PreflightWarning(host: host, context: makeContext(display: ":0"),
                                                     xauthExists: { _ in true }) == nil)
        host.x11Forwarding = .off
        #expect(SSHLaunchPlanner.x11PreflightWarning(host: host, context: noDisplay,
                                                     xauthExists: { _ in false }) == nil)
    }

    /// 老 hosts.json 里没有 x11Forwarding 这一键：整份列表不能因此被判废。
    @Test func legacyHostFileWithoutX11KeyStillLoads() throws {
        let legacy = """
        {"id":"h1","name":"老机器","group":"","tags":[],"protocolKind":"ssh","address":"10.0.0.9",\
        "port":22,"username":"root","authMethod":"password","identityFile":"","connectTimeout":10,\
        "keepaliveInterval":30,"startupDirectory":"","terminalType":"xterm-256color","favorite":false,\
        "notes":"","hostKeyAlgorithm":"ssh-ed25519","hostKeyFingerprint":"AAAA",\
        "serial":{"device":"","baudRate":115200},"createdAt":"2026-01-01T00:00:00Z",\
        "updatedAt":"2026-01-01T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let host = try decoder.decode(HostProfile.self, from: Data(legacy.utf8))
        #expect(host.name == "老机器")
        #expect(host.x11Forwarding == .off)

        var modern = host
        modern.x11Forwarding = .trusted
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let roundTrip = try decoder.decode(HostProfile.self, from: encoder.encode(modern))
        #expect(roundTrip == modern)
    }

    /// Telnet/串口没有 ssh 可以转发，档位规范化时必须归零。
    @Test func nonSSHProtocolsDropTheForwardingSetting() {
        var telnet = HostProfile(name: "t", protocolKind: .telnet, address: "h", username: "u")
        telnet.x11Forwarding = .trusted
        #expect(telnet.normalized().x11Forwarding == .off)

        var ssh = HostProfile(name: "s", address: "h", username: "u")
        ssh.x11Forwarding = .trusted
        #expect(ssh.normalized().x11Forwarding == .trusted)
    }
}
