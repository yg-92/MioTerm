import Foundation

public enum ConnectionProtocol: String, Codable, CaseIterable, Sendable {
    case ssh
    case telnet
    case serial

    public var displayName: String {
        switch self {
        case .ssh: return L10n.tr(.protocolSSH)
        case .telnet: return L10n.tr(.protocolTelnet)
        case .serial: return L10n.tr(.protocolSerial)
        }
    }

    /// 只有 SSH 走 SFTP 文件面板与指纹确认。
    public var supportsSFTP: Bool { self == .ssh }
    public var usesHostKey: Bool { self == .ssh }

    /// 公认端口，用于表单默认值；串口没有端口概念。
    public var defaultPort: Int? {
        switch self {
        case .ssh: return 22
        case .telnet: return 23
        case .serial: return nil
        }
    }
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
        case .automatic: return L10n.tr(.authAutomatic)
        case .password: return L10n.tr(.authPassword)
        case .privateKey: return L10n.tr(.authPrivateKey)
        }
    }
}

/// 远端跑 X11 程序、窗口显示在本机。转发由系统 ssh 完成，窗口归 XQuartz 管，
/// 本端不解析 X 协议，所以这里只决定 ssh 的命令行参数。
public enum X11Forwarding: String, Codable, CaseIterable, Sendable {
    /// 不转发。SFTP 通道永远走这一档，否则每次开文件面板都会在远端
    /// `~/.Xauthority` 里多塞一枚没人用的 cookie。
    case off
    /// `ssh -X`：非可信转发。cookie 20 分钟过期，且远端拿不到本机剪贴板、
    /// 截不了别的窗口 —— 日常首选。
    case restricted
    /// `ssh -Y`：可信转发。Java/AWT 与老 Motif 程序只认这一档，
    /// 代价是远端那个用户对本机 X 服务有完整权限（能截屏、能注入按键）。
    case trusted

    public var displayName: String {
        switch self {
        case .off: return L10n.tr(.hostFormX11Off)
        case .restricted: return L10n.tr(.hostFormX11Restricted)
        case .trusted: return L10n.tr(.hostFormX11Trusted)
        }
    }

    public var isEnabled: Bool { self != .off }
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
    case mark = "Mark"
    case space = "Space"

    public var displayName: String {
        switch self {
        case .none: return "无"
        case .even: return "偶校验"
        case .odd: return "奇校验"
        case .mark: return "Mark（校验位恒 1）"
        case .space: return "Space（校验位恒 0）"
        }
    }
}

public struct SerialConfig: Codable, Equatable, Sendable {
    public var device: String
    public var baudRate: Int
    public var dataBits: Int
    public var stopBits: String
    public var parity: Parity
    public var lineEnding: LineEnding
    public var localEcho: Bool
    /// 打开设备时是否拉高 DTR/RTS。部分开发板在这两条线跳变时复位，
    /// 所以默认不动它们，由用户按板子手册显式勾选。
    public var dtr: Bool
    public var rts: Bool

    public init(
        device: String = "",
        baudRate: Int = 115200,
        dataBits: Int = 8,
        stopBits: String = "1",
        parity: Parity = .none,
        lineEnding: LineEnding = .cr,
        localEcho: Bool = false,
        dtr: Bool = false,
        rts: Bool = false
    ) {
        self.device = device
        self.baudRate = baudRate
        self.dataBits = dataBits
        self.stopBits = stopBits
        self.parity = parity
        self.lineEnding = lineEnding
        self.localEcho = localEcho
        self.dtr = dtr
        self.rts = rts
    }

    public static let `default` = SerialConfig()

    public static let supportedStopBits = ["1", "1.5", "2"]
    public static let supportedDataBits = [5, 6, 7, 8]
    public static let minimumBaudRate = 50
    public static let maximumBaudRate = 4_000_000

    /// 逐字段容错解码。串口参数是后加的，旧配置里没有 dtr/rts 这些键，
    /// 而合成的解码器把缺失键当成损坏——那会让整份主机列表被判废。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        device = try container.decodeIfPresent(String.self, forKey: .device) ?? ""
        baudRate = try container.decodeIfPresent(Int.self, forKey: .baudRate) ?? 115_200
        dataBits = try container.decodeIfPresent(Int.self, forKey: .dataBits) ?? 8
        stopBits = try container.decodeIfPresent(String.self, forKey: .stopBits) ?? "1"
        parity = try container.decodeIfPresent(Parity.self, forKey: .parity) ?? .none
        lineEnding = try container.decodeIfPresent(LineEnding.self, forKey: .lineEnding) ?? .cr
        localEcho = try container.decodeIfPresent(Bool.self, forKey: .localEcho) ?? false
        dtr = try container.decodeIfPresent(Bool.self, forKey: .dtr) ?? false
        rts = try container.decodeIfPresent(Bool.self, forKey: .rts) ?? false
    }

    /// 键入的换行按设备要求改写：先把三种换行统一成 LF，再展开成配置里的那一种。
    /// 这样粘贴进来的 CRLF 不会变成两个 CR。
    public func encodeInput(_ data: Data) -> Data {
        data.normalizingLineEndingsToLF().expandingLineFeeds(to: lineEnding.data)
    }
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
    /// 空串表示“跟随设置里的默认终端类型”，连接前由 TerminalTypes.resolved 补上。
    public var terminalType: String
    /// X11 转发档位；非 SSH 协议没有 X11 概念，规范化时一律回到 off。
    public var x11Forwarding: X11Forwarding
    /// 是否为此主机启用 SFTP 文件通道；旧配置默认保持启用。
    public var sftpEnabled: Bool
    public var supportsSFTP: Bool { protocolKind.supportsSFTP && sftpEnabled }
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
        terminalType: String = "",
        x11Forwarding: X11Forwarding = .off,
        sftpEnabled: Bool = true,
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
        self.x11Forwarding = x11Forwarding
        self.sftpEnabled = sftpEnabled
        self.favorite = favorite
        self.notes = notes
        self.hostKeyAlgorithm = hostKeyAlgorithm
        self.hostKeyFingerprint = hostKeyFingerprint
        self.serial = serial
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 逐字段解码，为新增的可选功能保留旧配置兼容。
    ///
    /// 合成的解码器把缺键当成整条记录损坏，而整份 hosts.json 是一起判废的：
    /// 老文件里没有这一键，用合成解码就等于升级一次、主机列表清零一次。
    /// 其余字段的严格程度和合成解码器保持一致，不放宽。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        group = try container.decode(String.self, forKey: .group)
        tags = try container.decode([String].self, forKey: .tags)
        protocolKind = try container.decode(ConnectionProtocol.self, forKey: .protocolKind)
        address = try container.decode(String.self, forKey: .address)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        authMethod = try container.decode(AuthMethod.self, forKey: .authMethod)
        identityFile = try container.decode(String.self, forKey: .identityFile)
        connectTimeout = try container.decode(Int.self, forKey: .connectTimeout)
        keepaliveInterval = try container.decode(Int.self, forKey: .keepaliveInterval)
        startupDirectory = try container.decode(String.self, forKey: .startupDirectory)
        terminalType = try container.decode(String.self, forKey: .terminalType)
        x11Forwarding = try container.decodeIfPresent(X11Forwarding.self, forKey: .x11Forwarding) ?? .off
        sftpEnabled = try container.decodeIfPresent(Bool.self, forKey: .sftpEnabled) ?? true
        favorite = try container.decode(Bool.self, forKey: .favorite)
        notes = try container.decode(String.self, forKey: .notes)
        hostKeyAlgorithm = try container.decode(String.self, forKey: .hostKeyAlgorithm)
        hostKeyFingerprint = try container.decode(String.self, forKey: .hostKeyFingerprint)
        serial = try container.decode(SerialConfig.self, forKey: .serial)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public static func newSSH(name: String, address: String, username: String) -> HostProfile {
        var host = HostProfile(name: name, address: address, username: username)
        host.port = 22
        return host
    }

    /// 侧栏展示用的 “地址:端口”、串口设备与速率。
    public var subtitle: String {
        switch protocolKind {
        case .ssh: return "\(address):\(port)"
        case .telnet: return "\(address):\(port)"
        case .serial: return serial.device.isEmpty ? "未选串口" : "\(serial.device) · \(serial.baudRate) baud"
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
        copy.serial.device = serial.device.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.terminalType = TerminalTypes.sanitized(terminalType)
        // Telnet/串口没有 ssh 可以转发，档位留着只会让人以为窗口会出来。
        if copy.protocolKind != .ssh { copy.x11Forwarding = .off }
        if copy.port == 22, copy.protocolKind == .telnet { copy.port = 23 }
        if copy.port <= 0 || copy.port > 65535 { copy.port = copy.protocolKind.defaultPort ?? 22 }
        copy.connectTimeout = max(1, min(300, copy.connectTimeout))
        copy.keepaliveInterval = max(0, min(600, copy.keepaliveInterval))
        copy.updatedAt = Date()
        return copy
    }

    public enum ValidationError: LocalizedError, Equatable {
        case nameRequired
        case addressRequired
        case serialDeviceRequired
        case serialDevicePathInvalid
        case serialBaudOutOfRange
        case serialDataBitsOutOfRange
        case serialStopBitsInvalid

        public var errorDescription: String? {
            switch self {
            case .nameRequired: return "请填写显示名称"
            case .addressRequired: return "请填写主机地址"
            case .serialDeviceRequired: return "请选择串口设备"
            case .serialDevicePathInvalid: return "串口必须是 /dev/ 下的设备路径"
            case .serialBaudOutOfRange: return "波特率范围为 \(SerialConfig.minimumBaudRate)–\(SerialConfig.maximumBaudRate)"
            case .serialDataBitsOutOfRange: return "数据位范围为 5–8"
            case .serialStopBitsInvalid: return "停止位只能是 1、1.5 或 2"
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
            // 形状先于范围：配置里的字符串最终会进 open()，放过穿越路径就等于
            // 把普通文件当终端读写。
            if !SerialDevices.isAcceptablePath(serial.device) { throw ValidationError.serialDevicePathInvalid }
            if !(SerialConfig.minimumBaudRate...SerialConfig.maximumBaudRate).contains(serial.baudRate) { throw ValidationError.serialBaudOutOfRange }
            if !SerialConfig.supportedDataBits.contains(serial.dataBits) { throw ValidationError.serialDataBitsOutOfRange }
            if !SerialConfig.supportedStopBits.contains(serial.stopBits) { throw ValidationError.serialStopBitsInvalid }
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

    /// 主机表单的分组下拉：列出已有分组名，去重后按中文顺序排列。
    /// 空串代表“未分组”，不作为可选项。
    public static func groupNames(_ hosts: [HostProfile]) -> [String] {
        var seen = Set<String>()
        return hosts
            .map { $0.group.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
