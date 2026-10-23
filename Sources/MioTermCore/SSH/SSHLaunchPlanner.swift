import Foundation

/// 本次连接要注入的机密。为空时不启用 askpass，口令提示会照常出现在终端里，
/// 由用户自己输入 —— 这也是原生终端该有的行为。
public struct TerminalSecrets: Equatable, Sendable {
    public var password: String?
    public var passphrase: String?

    public init(password: String? = nil, passphrase: String? = nil) {
        self.password = password
        self.passphrase = passphrase
    }

    public var hasContent: Bool {
        !(password ?? "").isEmpty || !(passphrase ?? "").isEmpty
    }
}

/// 一次子进程启动计划。`askpassFile` 需要在进程退出后销毁。
public struct ProcessLaunch: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    /// SwiftTerm 的 startProcess 接收 `KEY=VALUE` 形式的数组。
    public var environment: [String]
    public var askpassFile: URL?

    public init(executable: String, arguments: [String], environment: [String], askpassFile: URL? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.askpassFile = askpassFile
    }

    /// 一次性外部命令（连接测试）用字典形式的环境变量，
    /// SwiftTerm 的 PTY 需要 `KEY=VALUE` 数组，这里做一次转换。
    public var environmentDictionary: [String: String] {
        var result: [String: String] = [:]
        for entry in environment {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            result[String(entry[entry.startIndex..<separator])] = String(entry[entry.index(after: separator)...])
        }
        return result
    }

    /// 日志里绝不出现口令：askpass 相关文件路径本身不含机密，但为了省事
    /// 统一屏蔽掉带 askpass 关键字的环境项。
    public var redactedDescription: String {
        "\(executable) \(arguments.joined(separator: " ")) | env " + environment
            .map { $0.hasPrefix(AskpassHelper.fileEnvironmentKey) ? "\(AskpassHelper.fileEnvironmentKey)=<hidden>" : $0 }
            .joined(separator: " ")
    }
}

public enum SSHLaunchError: LocalizedError, Equatable {
    case identityFileMissing(String)

    public var errorDescription: String? {
        switch self {
        case .identityFileMissing(let path): return "私钥文件不存在：\(path)"
        }
    }
}

/// 把主机配置翻成 `/usr/bin/ssh` 的命令行。加密、认证与主机密钥校验都交给
/// 系统 OpenSSH，这里只负责拼装选项。
public enum SSHLaunchPlanner {
    public static let sshPath = "/usr/bin/ssh"

    public struct Context: Sendable {
        public var knownHostsURL: URL
        public var askpassLauncherURL: URL
        public var inheritedEnvironment: [String: String]

        public init(knownHostsURL: URL, askpassLauncherURL: URL, inheritedEnvironment: [String: String]) {
            self.knownHostsURL = knownHostsURL
            self.askpassLauncherURL = askpassLauncherURL
            self.inheritedEnvironment = inheritedEnvironment
        }

        public static func live() -> Context {
            Context(
                knownHostsURL: AppPaths.knownHostsFile,
                askpassLauncherURL: AskpassLauncher.url,
                inheritedEnvironment: ProcessInfo.processInfo.environment
            )
        }
    }

    /// 交互式终端：强制分配远端 PTY。
    public static func terminalLaunch(host: HostProfile, secrets: TerminalSecrets?, context: Context) throws -> ProcessLaunch {
        var arguments = commonOptions(for: host, context: context)
        arguments.append("-tt")
        arguments.append(contentsOf: destinationArguments(for: host))
        // 指定启动目录时改用 “带命令的登录”：先 cd 再执行登录 shell，
        // 效果与手动登录后 cd 一致，且不会把命令回显进终端。
        if !host.startupDirectory.isEmpty {
            arguments.append(startupCommand(directory: host.startupDirectory))
        }
        return try make(arguments: arguments, host: host, secrets: secrets, context: context)
    }

    /// SFTP 子系统通道：`ssh -T -s host sftp`，无 PTY、纯二进制管道，
    /// 与 sftp(1) 内部机制相同，因此不必在远端查找 sftp-server 路径。
    public static func sftpLaunch(host: HostProfile, secrets: TerminalSecrets?, context: Context) throws -> ProcessLaunch {
        var arguments = commonOptions(for: host, context: context)
        arguments.append(contentsOf: ["-T", "-s"])
        arguments.append(contentsOf: destinationArguments(for: host))
        arguments.append("sftp")
        return try make(arguments: arguments, host: host, secrets: secrets, context: context)
    }

    /// 只做认证与密钥交换、不开 shell 的连通性测试。
    public static func probeLaunch(host: HostProfile, secrets: TerminalSecrets?, context: Context) throws -> ProcessLaunch {
        var arguments = commonOptions(for: host, context: context)
        arguments.append("-T")
        if secrets?.hasContent != true {
            // 没有存凭据时绝不弹提示，测试连接应当立即失败而不是挂住。
            arguments.append(contentsOf: ["-o", "BatchMode=yes", "-o", "NumberOfPasswordPrompts=0"])
        }
        arguments.append(contentsOf: destinationArguments(for: host))
        arguments.append("true")
        return try make(arguments: arguments, host: host, secrets: secrets, context: context)
    }

    private static func make(arguments: [String], host: HostProfile, secrets: TerminalSecrets?, context: Context) throws -> ProcessLaunch {
        var askpassFile: URL?
        if let secrets, secrets.hasContent {
            try validateIdentity(host: host)
            askpassFile = try AskpassMaterial(password: secrets.password, privateKeyPassphrase: secrets.passphrase).url
        }
        return ProcessLaunch(
            executable: sshPath,
            arguments: arguments,
            environment: environment(for: host, context: context, askpassFile: askpassFile),
            askpassFile: askpassFile
        )
    }

    static func commonOptions(for host: HostProfile, context: Context) -> [String] {
        var options: [String] = [
            "-o", "LogLevel=ERROR",
            // ~/.ssh/config 里的 EscapeChar 会截获 “~”，会话里输入波浪号时
            // 可能意外进入 ssh 的转义命令，这里统一关掉。
            "-o", "EscapeChar=none",
            "-o", "StrictHostKeyChecking=yes",
            // known_hosts 路径含空格（Application Support），必须用双引号包住，
            // 否则 OpenSSH 会按空白拆成多个文件名。
            "-o", "UserKnownHostsFile=\"\(context.knownHostsURL.path)\"",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=\(max(1, host.connectTimeout))",
            "-o", "TCPKeepAlive=yes",
            "-o", "BatchMode=no",
            "-o", "ClearAllForwardings=yes",
        ]
        if host.keepaliveInterval > 0 {
            options.append(contentsOf: ["-o", "ServerAliveInterval=\(host.keepaliveInterval)", "-o", "ServerAliveCountMax=3"])
        }
        options.append(contentsOf: authOptions(for: host))
        if host.port != 22 {
            options.append(contentsOf: ["-p", "\(host.port)"])
        }
        return options
    }

    static func authOptions(for host: HostProfile) -> [String] {
        var options: [String] = []
        let identity = (host.identityFile as NSString).expandingTildeInPath
        switch host.authMethod {
        case .automatic:
            if !identity.isEmpty { options.append(contentsOf: ["-i", identity]) }
        case .password:
            options.append(contentsOf: [
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "PubkeyAuthentication=no",
                "-o", "IdentitiesOnly=yes",
                "-o", "NumberOfPasswordPrompts=1",
            ])
        case .privateKey:
            options.append(contentsOf: ["-o", "PreferredAuthentications=publickey", "-o", "IdentitiesOnly=yes"])
            if !identity.isEmpty { options.append(contentsOf: ["-i", identity]) }
        }
        return options
    }

    static func destinationArguments(for host: HostProfile) -> [String] {
        if host.username.isEmpty { return [host.address] }
        return ["-l", host.username, host.address]
    }

    /// 远端命令由 sshd 交给登录 shell 解析，因此只按 POSIX 规则转义。
    static func startupCommand(directory: String) -> String {
        "cd \(posixQuote(directory)) && exec \"${SHELL:-/bin/sh}\" -l"
    }

    static func posixQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func environment(for host: HostProfile, context: Context, askpassFile: URL?) -> [String] {
        let inherited = context.inheritedEnvironment
        var entries: [String] = []
        // SSH_AUTH_SOCK 决定 agent 认证能否复用，HOME 决定 ssh_config 与
        // ~/.ssh 里的默认密钥能否读到，必须透传。
        for key in ["HOME", "USER", "LOGNAME", "LANG", "LC_CTYPE", "SSH_AUTH_SOCK"] {
            if let value = inherited[key], !value.isEmpty { entries.append("\(key)=\(value)") }
        }
        entries.append("PATH=\(inherited["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")")
        if inherited["LANG"] == nil { entries.append("LANG=en_US.UTF-8") }
        entries.append("TERM=\(host.terminalType.isEmpty ? "xterm-256color" : host.terminalType)")
        entries.append("COLORTERM=truecolor")
        if let askpassFile {
            entries.append("SSH_ASKPASS=\(context.askpassLauncherURL.path)")
            entries.append("SSH_ASKPASS_REQUIRE=force")
            entries.append("\(AskpassHelper.fileEnvironmentKey)=\(askpassFile.path)")
        }
        return entries
    }

    private static func validateIdentity(host: HostProfile) throws {
        guard host.authMethod == .privateKey else { return }
        let path = (host.identityFile as NSString).expandingTildeInPath
        if path.isEmpty || !FileManager.default.fileExists(atPath: path) {
            throw SSHLaunchError.identityFileMissing(path.isEmpty ? "（未填写）" : path)
        }
    }
}
