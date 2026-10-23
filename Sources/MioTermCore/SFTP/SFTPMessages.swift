import Foundation

/// SSH File Transfer Protocol v3 的报文类型、状态码与属性标志。
/// 编号按 RFC draft-ietf-secsh-filexfer-02 固定，服务端与客户端都以此为准。
/// 这些数字是线上的唯一事实：写错一位，RENAME 就会被服务端当 MKDIR 执行。
public enum SFTPPacketType: UInt8, Sendable {
    case initialize = 1
    case version = 2
    case open = 3
    case close = 4
    case read = 5
    case write = 6
    case lstat = 7
    case fstat = 8
    case setstat = 9
    case fsetstat = 10
    case openDir = 11
    case readDir = 12
    case remove = 13
    case mkdir = 14
    case rmdir = 15
    case realpath = 16
    case stat = 17
    case rename = 18

    case badMessage = 100
    case status = 101
    case handle = 102
    case data = 103
    case name = 104
    /// SSH_FXP_STAT/LSTAT/FSTAT 成功时的应答（OpenSSH 只回这个，不回带属性的 STATUS）。
    case attrs = 105
    case extended = 200
    case extendedReply = 201
}

public enum SFTPStatusCode: UInt32, Sendable {
    case ok = 0
    case eof = 1
    case NoSuchFile = 2
    case permissionDenied = 3
    case failure = 4
    case badMessage = 5
    case noConnection = 6
    case connectionLost = 7
    case opUnsupported = 8
}

extension SFTPStatusCode: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .ok: return "操作成功"
        case .eof: return "已到达文件末尾"
        case .NoSuchFile: return "文件或目录不存在"
        case .permissionDenied: return "权限不足"
        case .failure: return "远端服务器操作失败"
        case .badMessage: return "报文格式错误"
        case .noConnection: return "与远端的连接已断开"
        case .connectionLost: return "与远端的连接丢失"
        case .opUnsupported: return "远端 sftp-server 不支持该操作"
        }
    }
}

/// 文件属性。sftp-server 用位标志决定哪些字段真的存在，所以 uid/gid 这类
/// 缺省值不能当 0 直接用，必须看 flags。
public struct SFTPFileAttributes: Equatable, Sendable {
    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let size = Flags(rawValue: 0x00000001)
        public static let uidGid = Flags(rawValue: 0x00000002)
        public static let permissions = Flags(rawValue: 0x00000004)
        public static let times = Flags(rawValue: 0x00000008)
        public static let extended = Flags(rawValue: 0x80000000)
    }

    public var flags: Flags = []
    public var size: UInt64 = 0
    public var uid: UInt32 = 0
    public var gid: UInt32 = 0
    public var permissions: UInt32 = 0
    public var modificationTime: UInt32 = 0
    public var accessTime: UInt32 = 0
    public var extended: [String: Data] = [:]

    public init() {}

    /// POSIX S_IFDIR 位：判断目录只看它，不信任服务端可能乱填的 dtype。
    public var isDirectory: Bool {
        flags.contains(.permissions) && (permissions & 0o170000) == 0o040000
    }

    public func encode(into writer: inout SFTPWriter) {
        writer.uint32(flags.rawValue)
        if flags.contains(.size) { writer.uint64(size) }
        if flags.contains(.uidGid) {
            writer.uint32(uid)
            writer.uint32(gid)
        }
        if flags.contains(.permissions) { writer.uint32(permissions) }
        if flags.contains(.times) {
            writer.uint32(accessTime)
            writer.uint32(modificationTime)
        }
        if flags.contains(.extended) {
            writer.uint32(UInt32(extended.count))
            for (name, value) in extended {
                writer.string(name)
                writer.bytes(value)
            }
        }
    }

    public static func decoding(_ reader: inout SFTPReader) throws -> SFTPFileAttributes {
        var attributes = SFTPFileAttributes()
        let raw = try reader.uint32()
        attributes.flags = Flags(rawValue: raw)
        if attributes.flags.contains(.size) { attributes.size = try reader.uint64() }
        if attributes.flags.contains(.uidGid) {
            attributes.uid = try reader.uint32()
            attributes.gid = try reader.uint32()
        }
        if attributes.flags.contains(.permissions) { attributes.permissions = try reader.uint32() }
        if attributes.flags.contains(.times) {
            attributes.accessTime = try reader.uint32()
            attributes.modificationTime = try reader.uint32()
        }
        if attributes.flags.contains(.extended) {
            let count = Int(try reader.uint32())
            for _ in 0..<count {
                let name = try reader.string()
                let value = try reader.bytes()
                attributes.extended[name] = value
            }
        }
        return attributes
    }

    /// 创建目录时只需要 mode 位，其它字段留空。
    public static func directoryMode(_ mode: UInt32 = 0o755) -> SFTPFileAttributes {
        var attributes = SFTPFileAttributes()
        attributes.flags = [.permissions]
        attributes.permissions = mode | 0o040000
        return attributes
    }

    public static func fileMode(_ mode: UInt32 = 0o644) -> SFTPFileAttributes {
        var attributes = SFTPFileAttributes()
        attributes.flags = [.permissions]
        attributes.permissions = mode
        return attributes
    }
}

/// 目录项。SSH_FXP_NAME 里文件名在前、ls -l 风格的长名在后；
/// 展示与拼路径都只用文件名，长名是服务端随手拼的显示串，不可靠也不该解析。
public struct SFTPDirectoryEntry: Equatable, Sendable {
    public var longName: String
    public var shortName: String
    public var attributes: SFTPFileAttributes

    public init(longName: String, shortName: String, attributes: SFTPFileAttributes) {
        self.longName = longName
        self.shortName = shortName
        self.attributes = attributes
    }

    public var isDirectory: Bool { attributes.isDirectory }
    public var size: UInt64 { attributes.size }
    public var modificationTime: Date? {
        guard attributes.flags.contains(.times), attributes.modificationTime > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(attributes.modificationTime))
    }
}

/// SSH_FXP_OPEN 的 pflags 位。读用 read，写用 write|creaT|trunc 覆盖式创建。
public struct SFTPOpenFlag: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let read = SFTPOpenFlag(rawValue: 0x00000001)
    public static let write = SFTPOpenFlag(rawValue: 0x00000002)
    public static let create = SFTPOpenFlag(rawValue: 0x00000008)
    public static let truncate = SFTPOpenFlag(rawValue: 0x00000010)
}
