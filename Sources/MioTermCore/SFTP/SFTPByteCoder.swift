import Foundation

/// SSH_FXP 报文里的基础类型编解码。协议全部是大端网络字节序，
/// 字符串统一为 uint32 长度 + UTF-8，因此这里集中做一遍，避免各处手写偏移。
public struct SFTPReader {
    public enum DecodeError: LocalizedError, Equatable {
        case truncated(need: Int, available: Int)
        case invalidUTF8

        public var errorDescription: String? {
            switch self {
            case .truncated(let need, let available):
                return "SFTP 报文被截断：需要 \(need) 字节，只剩 \(available) 字节"
            case .invalidUTF8:
                return "SFTP 报文字段不是合法 UTF-8"
            }
        }
    }

    private let data: Data
    public private(set) var offset: Int = 0

    public init(_ data: Data) {
        self.data = data
    }

    public var isAtEnd: Bool { offset >= data.count }
    public var remaining: Int { max(0, data.count - offset) }

    private mutating func take(_ count: Int) throws -> Data {
        guard remaining >= count else { throw DecodeError.truncated(need: count, available: remaining) }
        let slice = data.subdata(in: offset..<(offset + count))
        offset += count
        return slice
    }

    public mutating func uint8() throws -> UInt8 {
        let slice = try take(1)
        return slice[slice.startIndex]
    }

    public mutating func uint32() throws -> UInt32 {
        let slice = try take(4)
        return slice.withUnsafeBytes { raw in UInt32(bigEndian: raw.load(as: UInt32.self)) }
    }

    public mutating func uint64() throws -> UInt64 {
        let slice = try take(8)
        return slice.withUnsafeBytes { raw in UInt64(bigEndian: raw.load(as: UInt64.self)) }
    }

    public mutating func bytes() throws -> Data {
        let length = Int(try uint32())
        return try take(length)
    }

    public mutating func string() throws -> String {
        let payload = try bytes()
        guard let text = String(data: payload, encoding: .utf8) else { throw DecodeError.invalidUTF8 }
        return text
    }

    /// 文件名按“尽力而为”解码。历史文件、备份或非 UTF-8 locale 下创建的条目
    /// 可能带着原始字节；不能为了一个名字让整层目录都读不出来。
    public mutating func stringLenient(field: String) throws -> String {
        let payload = try bytes()
        if let text = String(data: payload, encoding: .utf8) { return text }
        let hex = payload.map { String(format: "%02x", $0) }.joined(separator: " ")
        FileLogger.shared.warning("SFTP：\(field)不是合法 UTF-8（\(payload.count) 字节）：\(hex)")
        return String(decoding: payload, as: UTF8.self)
    }
}

public struct SFTPWriter {
    public private(set) var data = Data()

    public init() {}
    public init(capacity: Int) { data.reserveCapacity(capacity) }

    public mutating func uint8(_ value: UInt8) { data.append(value) }

    public mutating func uint32(_ value: UInt32) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    public mutating func uint64(_ value: UInt64) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    public mutating func bytes(_ payload: Data) {
        uint32(UInt32(payload.count))
        data.append(payload)
    }

    /// 原样追加，不带长度前缀；用于拼接已经编码好的报文体。
    public mutating func append(_ payload: Data) {
        data.append(payload)
    }

    public mutating func string(_ value: String) {
        bytes(Data(value.utf8))
    }
}
