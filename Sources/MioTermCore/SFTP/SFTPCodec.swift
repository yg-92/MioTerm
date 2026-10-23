import Foundation

/// 一个已拆帧的 SFTP 报文。`payload` 不含长度前缀、类型字节与请求号。
public struct SFTPPacket: Sendable {
    public let type: SFTPPacketType
    public let id: UInt32
    public let payload: Data

    public init(type: SFTPPacketType, id: UInt32, payload: Data) {
        self.type = type
        self.id = id
        self.payload = payload
    }
}

public enum SFTPCodecError: LocalizedError, Equatable {
    case frameTooLarge(UInt32)
    case unknownPacketType(UInt8)
    case unexpectedReply(expected: SFTPPacketType, actual: SFTPPacketType)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .frameTooLarge(let size): return "SFTP 帧长度异常（\(size) 字节），连接可能已错位"
        case .unknownPacketType(let value): return "无法识别的 SFTP 报文类型 \(value)"
        case .unexpectedReply(let expected, let actual): return "SFTP 应答类型不符：期望 \(expected.rawValue)，实到 \(actual.rawValue)"
        case .malformed(let detail): return "SFTP 报文解析失败：\(detail)"
        }
    }
}

/// 长度前缀拆帧。管道一次读到的字节可能包含半截报文，也可能包含多截，
/// 所以必须按 uint32 长度切分并缓存残片。
public struct SFTPFrameAssembler {
    /// sftp-server 单帧上限远小于此；超过它说明流已经错位，继续读只会得到垃圾。
    public static let maximumFrameSize = 1_048_576

    private var buffer = Data()

    public init() {}

    public var bufferedBytes: Int { buffer.count }

    public mutating func feed(_ data: Data) throws -> [SFTPPacket] {
        buffer.append(data)
        var packets: [SFTPPacket] = []
        while buffer.count >= 4 {
            let size = buffer.withUnsafeBytes { Int(UInt32(bigEndian: $0.load(as: UInt32.self))) }
            if size > SFTPFrameAssembler.maximumFrameSize {
                buffer.removeAll(keepingCapacity: false)
                throw SFTPCodecError.frameTooLarge(UInt32(size))
            }
            guard buffer.count >= size + 4 else { break }
            let frame = buffer.subdata(in: 4..<(4 + size))
            buffer.removeSubrange(0..<(4 + size))
            guard let typeByte = frame.first, frame.count >= 5 else {
                throw SFTPCodecError.malformed("报文长度不足")
            }
            guard let type = SFTPPacketType(rawValue: typeByte) else {
                throw SFTPCodecError.unknownPacketType(typeByte)
            }
            let id = frame.subdata(in: 1..<5).withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) }
            packets.append(SFTPPacket(type: type, id: id, payload: frame.subdata(in: 5..<frame.count)))
        }
        return packets
    }
}

public enum SFTPCodec {
    /// 组装一个完整帧：uint32 长度（含自身之后的所有字节）+ 类型 + 请求号 + 体。
    public static func frame(type: SFTPPacketType, id: UInt32, body: Data) -> Data {
        var writer = SFTPWriter(capacity: body.count + 9)
        writer.uint32(UInt32(body.count + 5))
        writer.uint8(type.rawValue)
        writer.uint32(id)
        writer.append(body)
        return writer.data
    }

    public static func frame(type: SFTPPacketType, id: UInt32, body: (inout SFTPWriter) -> Void) -> Data {
        var writer = SFTPWriter()
        body(&writer)
        return frame(type: type, id: id, body: writer.data)
    }

    /// v3 握手包：长度 + 类型 1 + 版本 3，没有请求号字段。
    public static func initializePacket(version: UInt32 = 3) -> Data {
        var writer = SFTPWriter(capacity: 9)
        writer.uint32(5)
        writer.uint8(SFTPPacketType.initialize.rawValue)
        writer.uint32(version)
        return writer.data
    }
}

/// 服务端应答的语义化形式；状态码非 ok 时由调用方决定是抛错还是当正常分支。
public enum SFTPReply: Sendable {
    case status(code: SFTPStatusCode, message: String)
    case handle(Data)
    case data(Data)
    case name([SFTPDirectoryEntry])
    case attributes(SFTPFileAttributes)
}

extension SFTPReply {
    /// 把应答帧解析成语义结果。握手包不属于应答，由连接层单独处理。
    public init(packet: SFTPPacket) throws {
        var reader = SFTPReader(packet.payload)
        switch packet.type {
        case .status:
            let code = SFTPStatusCode(rawValue: (try? reader.uint32()) ?? SFTPStatusCode.failure.rawValue) ?? .failure
            let message = (try? reader.string()) ?? ""
            self = .status(code: code, message: message)
        case .handle:
            self = .handle(try reader.bytes())
        case .data:
            self = .data(try reader.bytes())
        case .name:
            let count = Int(try reader.uint32())
            var entries: [SFTPDirectoryEntry] = []
            entries.reserveCapacity(count)
            for _ in 0..<count {
                // 顺序是硬规定：先文件名，再 ls -l 风格的长名，最后属性。
                // 读反了会把整行属性串当文件名，拼出来的路径全都不存在。
                let fileName = try reader.stringLenient(field: "文件名")
                let longName = try reader.stringLenient(field: "长名")
                let attributes = try SFTPFileAttributes.decoding(&reader)
                entries.append(SFTPDirectoryEntry(longName: longName, shortName: fileName, attributes: attributes))
            }
            self = .name(entries)
        case .attrs:
            self = .attributes(try SFTPFileAttributes.decoding(&reader))
        case .badMessage:
            _ = try? reader.uint32()
            let detail = (try? reader.string()) ?? ""
            throw SFTPCodecError.malformed(detail.isEmpty ? "服务端报告报文错误" : detail)
        default:
            throw SFTPCodecError.malformed("报文类型 \(packet.type.rawValue) 不是应答")
        }
    }

    /// 期望 ok 状态（close/remove/rename/mkdir/setstat 这类只有状态返回的请求）。
    public func requireOK() throws {
        guard case .status(let code, let message) = self else {
            throw SFTPCodecError.malformed("期望 SSH_FXP_STATUS，实到其它类型")
        }
        guard code == .ok else { throw SFTPStatusError(code: code, message: message) }
    }

    public var statusCode: SFTPStatusCode? {
        if case .status(let code, _) = self { return code }
        return nil
    }
}

/// 带服务端文案的状态错误，UI 直接展示。
public struct SFTPStatusError: LocalizedError, Equatable, Sendable {
    public let code: SFTPStatusCode
    public let message: String

    public init(code: SFTPStatusCode, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? {
        message.isEmpty ? code.errorDescription : "\(code.errorDescription ?? "SFTP 错误")：\(message)"
    }
}

/// 扩展报文（正斜杠规范化、批量 stat 等）不在第一版范围内，
/// 但服务端把 `.` 与 `..` 混在 readdir 结果里是常态，需要在客户端过滤。
public enum SFTPDirectoryFilter {
    public static let hiddenNames: Set<String> = [".", ".."]

    /// `.` 与 `..` 是导航别名而不是真条目，任何时候都不能进列表：
    /// 留着它们，树里会多出一个指向父目录的假文件夹，路径拼接也会绕圈。
    public static func entries(_ entries: [SFTPDirectoryEntry], showHidden: Bool) -> [SFTPDirectoryEntry] {
        entries.filter { entry in
            guard !hiddenNames.contains(entry.shortName) else { return false }
            return showHidden || !entry.shortName.hasPrefix(".")
        }
    }
}
