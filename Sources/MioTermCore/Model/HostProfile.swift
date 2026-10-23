import Foundation

public enum ConnectionProtocol: String, Codable, CaseIterable, Sendable {
    case ssh
    case telnet
    case serial

    public var displayName: String {
        switch self {
        case .ssh: return "SSH"
        case .telnet: return "Telnet"
        case .serial: return "串口"
        }
    }

    /// 只有 SSH 走 SFTP 文件面板与指纹确认。
    public var supportsSFTP: Bool { self == .ssh }
    public var usesHostKey: Bool { self == .ssh }
}

public enum AuthMethod: String, Codable, CaseIterable, Sendable {
    /// 交给系统 OpenSSH：沿用 ~/.ssh/config、agent 与默认密钥。
    case automatic
    /// 只用口令认证，口令由应用通过 askpass 注入。
    case password
    /// 只用指定私钥，私钥口令由应用通过 askpass 注入。
    case privateKey

    public var displayName: String {
        switch self {
        case .automatic: return "自动（密钥 / agent / ssh_config）"
        case .password: return "密码"
        case .privateKey: return "私钥"
        }
    }
}

public enum LineEnding: String, Codable, CaseIterable, Sendable {
    case cr = "CR"
    case lf = "LF"
    case crlf = "CR LF"

    public var data: Data {
        switch self {
        case .cr: return Data([0x0D])
        case .lf: return Data([0x0A])
        case .crlf: return Data([0x0D, 0x0A])
        }
    }
}

public enum Parity: String, Codable, CaseIterable, Sendable {
    case none = "None"
    case even = "Even"
    case odd = "Odd"
}

public struct SerialConfig: Codable, Equatable, Sendable {
    public var device: String
    public var baudRate: Int
    public var dataBits: Int
    public var stopBits: String
    public var parity: Parity
    public var lineEnding: LineEnding
    public var localEcho: Bool

    public init(
        device: String = "",
        baudRate: Int = 115200,
        dataBits: Int = 8,
        stopBits: String = "1",
        parity: Parity = .none,
        lineEnding: LineEnding = .cr,
        localEcho: Bool = false
    ) {
        self.device = device
        self.baudRate = baudRate
        self.dataBits = dataBits
        self.stopBits = stopBits
        self.parity = parity
        self.lineEnding = lineEnding
        self.localEcho = localEcho
    }

    public static let `default` = SerialConfig()
}

public struct HostProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var group: String
    public var tags: [String]
    public var protocolKind: ConnectionProtocol
    public var address: String
    public var port: Int
    public var username: String
    public var authMethod: AuthMethod
    /// 私钥文件路径，保存原文内容会绕开 ssh-agent 与 Keychain，也与 OpenSSH 权限模型不符。
    public var identityFile: String
    public var connectTimeout: Int
    public var keepaliveInterval: Int
    public var startupDirectory: String
    public var terminalType: String
    public var favorite: Bool
    public var notes: String
    public var hostKeyAlgorithm: String
    public var hostKeyFingerprint: String
    public var serial: SerialConfig
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String = "",
        group: String = "",
        tags: [String] = [],
        protocolKind: ConnectionProtocol = .ssh,
        address: String = "",
        port: Int = 22,
        username: String = "",
        authMethod: AuthMethod = .automatic,
        identityFile: String = "",
        connectTimeout: Int = 10,
        keepaliveInterval: Int = 30,
        startupDirectory: String = "",
        terminalType: String = "xterm-256color",
        favorite: Bool = false,
        notes: String = "",
        hostKeyAlgorithm: String = "",
        hostKeyFingerprint: String = "",
        serial: SerialConfig = .default,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.tags = tags
        self.protocolKind = protocolKind
        self.address = address
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.identityFile = identityFile
        self.connectTimeout = connectTimeout
        self.keepaliveInterval = keepaliveInterval
        self.startupDirectory = startupDirectory
        self.terminalType = terminalType
        self.favorite = favorite
        self.notes = notes
        self.hostKeyAlgorithm = hostKeyAlgorithm
        self.hostKeyFingerprint = hostKeyFingerprint
        self.serial = serial
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func newSSH(name: String, address: String, username: String) -> HostProfile {
        var host = HostProfile(name: name, address: address, username: username)
        host.port = 22
        return host
    }

    /// 侧栏展示用的 “地址:端口” 或串口号。
    public var subtitle: String {
        switch protocolKind {
        case .ssh: return "\(address):\(port)"
        case .telnet: return "\(address):\(port)"
        case .serial: return serial.device
        }
    }

    public var displayName: String {
        name.isEmpty ? subtitle : name
    }

    /// 组名留空时归入 “未分组”，与 webterm 的分组行为一致。
    public var groupName: String {
        group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未分组" : group.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func normalized() -> HostProfile {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.identityFile = (identityFile as NSString).expandingTildeInPath
        copy.startupDirectory = (startupDirectory as NSString).expandingTildeInPath
        copy.tags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if copy.port == 22, copy.protocolKind == .telnet { copy.port = 23 }
        if copy.port <= 0 || copy.port > 65535 { copy.port = copy.protocolKind == .telnet ? 23 : 22 }
        copy.connectTimeout = max(1, min(300, copy.connectTimeout))
        copy.keepaliveInterval = max(0, min(600, copy.keepaliveInterval))
        copy.updatedAt = Date()
        return copy
    }

    public enum ValidationError: LocalizedError, Equatable {
        case nameRequired
        case addressRequired
        case serialDeviceRequired

        public var errorDescription: String? {
            switch self {
            case .nameRequired: return "请填写显示名称"
            case .addressRequired: return "请填写主机地址"
            case .serialDeviceRequired: return "请选择串口设备"
            }
        }
    }

    public func validate() throws {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ValidationError.nameRequired }
        switch protocolKind {
        case .ssh, .telnet:
            if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ValidationError.addressRequired }
        case .serial:
            if serial.device.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ValidationError.serialDeviceRequired }
        }
    }
}

public enum HostSorting {
    /// 侧栏顺序：收藏优先，其次按组名与显示名（中文按拼音局部排序）。
    public static func sidebarOrder(_ hosts: [HostProfile]) -> [HostProfile] {
        hosts.sorted { left, right in
            if left.favorite != right.favorite { return left.favorite }
            if left.groupName != right.groupName { return left.groupName.localizedStandardCompare(right.groupName) == .orderedAscending }
            return left.displayName.localizedStandardCompare(right.displayName) == .orderedAscending
        }
    }

    public static func groups(_ hosts: [HostProfile]) -> [(name: String, hosts: [HostProfile])] {
        Dictionary(grouping: hosts, by: { $0.groupName })
            .map { (name: $0.key, hosts: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
