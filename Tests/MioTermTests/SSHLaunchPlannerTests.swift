import Testing
import Foundation
@testable import MioTermCore

private func makeContext(knownHosts: URL = URL(fileURLWithPath: "/tmp/mio test/known_hosts")) -> SSHLaunchPlanner.Context {
    SSHLaunchPlanner.Context(
        knownHostsURL: knownHosts,
        askpassLauncherURL: URL(fileURLWithPath: "/tmp/mio test/askpass.sh"),
        inheritedEnvironment: [
            "HOME": "/Users/yanggang",
            "USER": "yanggang",
            "PATH": "/usr/bin:/bin",
            "SSH_AUTH_SOCK": "/tmp/ssh-agent/sock",
        ]
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
}
