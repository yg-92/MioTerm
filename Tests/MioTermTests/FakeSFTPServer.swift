import Foundation
@testable import MioTermCore

/// 内存 SFTP 服务端，用来在无网络环境下验证客户端的报文逻辑：
/// 握手、请求号配对、目录枚举、分片读写与错误传播。
/// 只实现 MioTerm 用到的那几类请求，不追求协议完整性。
final class FakeSFTPServer: SFTPTransport, @unchecked Sendable {
    struct Node: Equatable {
        var isDirectory: Bool
        var contents: [UInt8]
        var mode: UInt32
        var modified: UInt32
    }

    private let lock = NSLock()
    private var assembler = SFTPFrameAssembler()
    private var outbound: [Data] = []
    private var readers: [CheckedContinuation<Data?, Never>] = []
    private var openDirectoryHandles: [String: Int] = [:]
    private var writeSizes: [Int] = []
    private var nodes: [String: Node] = [:]
    private var closed = false
    /// 置位后不回握手包，用来验证连接超时会收尾。
    var ignoresInit = false
    /// 记录本端收到的每一帧，便于断言请求号与顺序。
    private(set) var receivedFrames: [SFTPPacket] = []

    init() {
        nodes["/"] = Node(isDirectory: true, contents: [], mode: 0o040755, modified: 1_700_000_000)
        nodes["/home"] = Node(isDirectory: true, contents: [], mode: 0o040755, modified: 1_700_000_000)
        nodes["/home/user"] = Node(isDirectory: true, contents: [], mode: 0o040755, modified: 1_700_000_000)
        nodes["/home/user/hello.txt"] = Node(isDirectory: false, contents: Array("hello".utf8), mode: 0o100644, modified: 1_700_000_100)
        nodes["/home/user/a.txt"] = Node(isDirectory: false, contents: Array("a".utf8), mode: 0o100644, modified: 1_700_000_110)
        nodes["/home/user/sub"] = Node(isDirectory: true, contents: [], mode: 0o040755, modified: 1_700_000_200)
        nodes["/home/user/sub/nested.bin"] = Node(isDirectory: false, contents: Array(repeating: 0xAB, count: 5_000), mode: 0o100600, modified: 1_700_000_300)
    }

    // MARK: - 传输协议

    func start() async throws {}

    func read() async throws -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            lock.withLock {
                if !outbound.isEmpty {
                    continuation.resume(returning: outbound.removeFirst())
                } else if closed {
                    continuation.resume(returning: nil)
                } else {
                    readers.append(continuation)
                }
            }
        }
    }

    func write(_ data: Data) async throws {
        var frames: [SFTPPacket] = []
        var parseFailed = false
        lock.withLock {
            do {
                frames = try assembler.feed(data)
                receivedFrames.append(contentsOf: frames)
            } catch {
                parseFailed = true
                frames = []
            }
        }
        guard !parseFailed else { return }
        for frame in frames { handle(frame) }
    }

    func close() async {
        lock.withLock {
            closed = true
            let waiting = readers
            readers = []
            for continuation in waiting { continuation.resume(returning: nil) }
        }
    }

    // MARK: - 测试可见状态

    func node(at path: String) -> Node? {
        lock.withLock { nodes[SFTPPath.normalize(path)] }
    }

    func contents(of path: String) -> Data? {
        node(at: path).map { Data($0.contents) }
    }

    /// 未被 close 的目录句柄数；列表遍历结束后应当归零。
    var leakedDirectoryHandles: Int {
        lock.withLock { openDirectoryHandles.count }
    }

    /// 每次 SSH_FXP_WRITE 携带的字节数，用来验证本端确实按上限切帧。
    func writeRequestSizes() -> [Int] {
        lock.withLock { writeSizes }
    }

    /// 本端是否已被连接层关闭；握手超时若没关，ssh 子进程就会挂着。
    var didCloseTransport: Bool {
        get async { lock.withLock { closed } }
    }


    // MARK: - 报文处理

    private func enqueue(_ frame: Data) {
        lock.withLock {
            if closed { return }
            outbound.append(frame)
            while !outbound.isEmpty, !readers.isEmpty {
                readers.removeFirst().resume(returning: outbound.removeFirst())
            }
        }
    }

    private func handle(_ packet: SFTPPacket) {
        switch packet.type {
        case .initialize:
            if !ignoresInit { enqueue(versionPacket()) }
        case .realpath:
            // SSH_FXP_REALPATH 回 SSH_FXP_NAME，第一个文件名字段是规范化后的绝对路径。
            let path = SFTPPath.normalize(firstString(in: packet))
            guard node(at: path) != nil else {
                enqueue(statusFrame(id: packet.id, code: .NoSuchFile, message: "不存在：\(path)"))
                return
            }
            replyName(id: packet.id, entries: [entry(at: path)])
        case .lstat, .stat:
            replyAttrib(id: packet.id, path: SFTPPath.normalize(firstString(in: packet)))
        case .openDir:
            openDirectory(packet)
        case .readDir:
            replyReadDir(id: packet.id, handle: handleName(packet))
        case .open:
            replyOpen(packet)
        case .read:
            replyRead(packet)
        case .write:
            replyWrite(packet)
        case .close:
            let name = handleName(packet)
            lock.withLock { _ = openDirectoryHandles.removeValue(forKey: name) }
            enqueue(statusFrame(id: packet.id, code: .ok, message: ""))
        case .mkdir:
            makeDirectory(packet)
        case .rmdir:
            removeDirectory(packet)
        case .remove:
            removeFile(packet)
        case .rename:
            rename(packet)
        default:
            enqueue(statusFrame(id: packet.id, code: .opUnsupported, message: "未实现"))
        }
    }

    private func versionPacket() -> Data {
        var body = SFTPWriter()
        body.string("posix-rename@openssh.com")
        body.string("1")
        body.string("expand-path@openssh.com")
        body.string("1")
        return SFTPCodec.frame(type: .version, id: 3, body: body.data)
    }

    /// 载荷里的第一个字符串字段。
    private func firstString(in packet: SFTPPacket) -> String {
        var reader = SFTPReader(packet.payload)
        return (try? reader.string()) ?? ""
    }

    /// 载荷里的第一个长度前缀字节串，解成 UTF-8 句柄名。
    private func handleName(_ packet: SFTPPacket) -> String {
        var reader = SFTPReader(packet.payload)
        guard let bytes = try? reader.bytes() else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func entry(at path: String) -> SFTPDirectoryEntry {
        let node = self.node(at: path)
        var attributes = SFTPFileAttributes()
        attributes.flags = [.size, .permissions, .times]
        attributes.size = UInt64(node?.contents.count ?? 0)
        attributes.permissions = node?.mode ?? (path.hasSuffix("/") ? 0o040755 : 0o100644)
        attributes.modificationTime = node?.modified ?? 1_700_000_000
        attributes.accessTime = attributes.modificationTime
        return SFTPDirectoryEntry(longName: path, shortName: path, attributes: attributes)
    }

    private func replyName(id: UInt32, entries: [SFTPDirectoryEntry]) {
        var body = SFTPWriter()
        body.uint32(UInt32(entries.count))
        for entry in entries {
            // 与真实服务端一致：文件名字段在前，ls -l 长名在后。
            body.string(entry.shortName)
            body.string(entry.longName)
            entry.attributes.encode(into: &body)
        }
        enqueue(SFTPCodec.frame(type: .name, id: id, body: body.data))
    }

    /// SSH_FXP_ATTRS：SSH_FXP_LSTAT/STAT 成功时的应答形态。
    private func replyAttrib(id: UInt32, path: String) {
        guard let node = node(at: path) else {
            enqueue(statusFrame(id: id, code: .NoSuchFile, message: "不存在：\(path)"))
            return
        }
        var body = SFTPWriter()
        writeAttributes(of: node, into: &body)
        enqueue(SFTPCodec.frame(type: .attrs, id: id, body: body.data))
    }

    private func writeAttributes(of node: Node, into body: inout SFTPWriter) {
        var attributes = SFTPFileAttributes()
        attributes.flags = [.size, .permissions, .times, .uidGid]
        attributes.size = UInt64(node.contents.count)
        attributes.permissions = node.mode
        attributes.modificationTime = node.modified
        attributes.accessTime = node.modified
        attributes.uid = 501
        attributes.gid = 20
        attributes.encode(into: &body)
    }

    private func openDirectory(_ packet: SFTPPacket) {
        let path = SFTPPath.normalize(firstString(in: packet))
        guard let node = node(at: path), node.isDirectory else {
            enqueue(statusFrame(id: packet.id, code: .NoSuchFile, message: "没有这个目录"))
            return
        }
        let name = "dir:\(path)"
        lock.withLock { openDirectoryHandles[name] = 0 }
        enqueue(handleFrame(id: packet.id, handle: name))
    }

    private func replyReadDir(id: UInt32, handle: String) {
        guard openDirectoryHandles[handle] != nil else {
            enqueue(statusFrame(id: id, code: .badMessage, message: "句柄不是目录"))
            return
        }
        let path = String(handle.dropFirst(4))
        let children = childEntries(of: path)
        let cursor = lock.withLock { openDirectoryHandles[handle] ?? 0 }
        guard cursor < children.count else {
            enqueue(statusFrame(id: id, code: .eof, message: ""))
            return
        }
        // 一次最多回三条，逼出客户端的多批聚合逻辑
        let batch = Array(children[cursor..<min(cursor + 3, children.count)])
        lock.withLock { openDirectoryHandles[handle] = cursor + batch.count }
        replyName(id: id, entries: batch)
    }

    private func childEntries(of directory: String) -> [SFTPDirectoryEntry] {
        let base = SFTPPath.normalize(directory)
        let keys = nodes.keys.filter { path in
            path != base && SFTPPath.parent(path) == base
        }.sorted()
        return keys.map { path in
            let node = nodes[path]!
            var attributes = SFTPFileAttributes()
            attributes.flags = [.size, .permissions, .times]
            attributes.size = UInt64(node.contents.count)
            attributes.permissions = node.mode
            attributes.modificationTime = node.modified
            attributes.accessTime = node.modified
            return SFTPDirectoryEntry(longName: path, shortName: SFTPPath.lastComponent(path), attributes: attributes)
        }
    }

    private func replyOpen(_ packet: SFTPPacket) {
        var reader = SFTPReader(packet.payload)
        guard let rawPath = try? reader.string(), let flags = try? reader.uint32() else { return }
        let path = SFTPPath.normalize(rawPath)
        let create = (flags & 0x08) != 0
        let truncate = (flags & 0x10) != 0
        if node(at: path) == nil {
            guard create else {
                enqueue(statusFrame(id: packet.id, code: .NoSuchFile, message: "不存在：\(path)"))
                return
            }
            lock.withLock { nodes[path] = Node(isDirectory: false, contents: [], mode: 0o100644, modified: UInt32(Date().timeIntervalSince1970)) }
        } else if truncate {
            lock.withLock { nodes[path]?.contents = [] }
        }
        enqueue(handleFrame(id: packet.id, handle: "file:\(path)"))
    }

    private func replyRead(_ packet: SFTPPacket) {
        var reader = SFTPReader(packet.payload)
        guard let handle = try? reader.bytes(), let offset = try? reader.uint64(), let length = try? reader.uint32() else { return }
        let path = path(of: handle)
        guard let node = node(at: path) else {
            enqueue(statusFrame(id: packet.id, code: .NoSuchFile, message: "句柄失效"))
            return
        }
        let start = Int(offset)
        guard start < node.contents.count else {
            enqueue(statusFrame(id: packet.id, code: .eof, message: ""))
            return
        }
        let end = min(start + Int(length), node.contents.count)
        var body = SFTPWriter()
        body.bytes(Data(node.contents[start..<end]))
        enqueue(SFTPCodec.frame(type: .data, id: packet.id, body: body.data))
    }

    private func replyWrite(_ packet: SFTPPacket) {
        var reader = SFTPReader(packet.payload)
        guard let handle = try? reader.bytes(), let offset = try? reader.uint64(), let payload = try? reader.bytes() else { return }
        let path = path(of: handle)
        guard lock.withLock({ nodes[path] }) != nil else {
            enqueue(statusFrame(id: packet.id, code: .NoSuchFile, message: "句柄失效"))
            return
        }
        let start = Int(offset)
        lock.withLock {
            writeSizes.append(payload.count)
            var node = nodes[path]!
            if node.contents.count < start { node.contents.append(contentsOf: Array(repeating: 0, count: start - node.contents.count)) }
            let end = start + payload.count
            if node.contents.count < end { node.contents.append(contentsOf: Array(repeating: 0, count: end - node.contents.count)) }
            for (index, byte) in payload.enumerated() { node.contents[start + index] = byte }
            node.modified = UInt32(Date().timeIntervalSince1970)
            nodes[path] = node
        }
        enqueue(statusFrame(id: packet.id, code: .ok, message: ""))
    }

    private func makeDirectory(_ packet: SFTPPacket) {
        let path = SFTPPath.normalize(firstString(in: packet))
        lock.withLock {
            nodes[path] = Node(isDirectory: true, contents: [], mode: 0o040755, modified: UInt32(Date().timeIntervalSince1970))
        }
        enqueue(statusFrame(id: packet.id, code: .ok, message: ""))
    }

    private func removeDirectory(_ packet: SFTPPacket) {
        let path = SFTPPath.normalize(firstString(in: packet))
        guard let node = node(at: path), node.isDirectory else {
            enqueue(statusFrame(id: packet.id, code: .NoSuchFile, message: "目录不存在"))
            return
        }
        if !childEntries(of: path).isEmpty {
            enqueue(statusFrame(id: packet.id, code: .failure, message: "目录非空"))
            return
        }
        _ = lock.withLock { nodes.removeValue(forKey: path) }
        enqueue(statusFrame(id: packet.id, code: .ok, message: ""))
    }

    private func removeFile(_ packet: SFTPPacket) {
        let path = SFTPPath.normalize(firstString(in: packet))
        guard lock.withLock({ nodes.removeValue(forKey: path) }) != nil else {
            enqueue(statusFrame(id: packet.id, code: .NoSuchFile, message: "文件不存在"))
            return
        }
        enqueue(statusFrame(id: packet.id, code: .ok, message: ""))
    }

    private func rename(_ packet: SFTPPacket) {
        var reader = SFTPReader(packet.payload)
        guard let source = try? reader.string(), let destination = try? reader.string() else { return }
        let from = SFTPPath.normalize(source)
        let to = SFTPPath.normalize(destination)
        guard let moved = node(at: from) else {
            enqueue(statusFrame(id: packet.id, code: .NoSuchFile, message: "源不存在"))
            return
        }
        if node(at: to) != nil {
            enqueue(statusFrame(id: packet.id, code: .failure, message: "目标已存在"))
            return
        }
        lock.withLock {
            _ = nodes.removeValue(forKey: from)
            nodes[to] = moved
        }
        enqueue(statusFrame(id: packet.id, code: .ok, message: ""))
    }

    private func path(of handle: Data) -> String {
        let text = String(decoding: handle, as: UTF8.self)
        guard text.hasPrefix("file:") else { return text }
        return SFTPPath.normalize(String(text.dropFirst(5)))
    }

    private func handleFrame(id: UInt32, handle: String) -> Data {
        var body = SFTPWriter()
        body.bytes(Data(handle.utf8))
        return SFTPCodec.frame(type: .handle, id: id, body: body.data)
    }

    private func statusFrame(id: UInt32, code: SFTPStatusCode, message: String) -> Data {
        var body = SFTPWriter()
        body.uint32(code.rawValue)
        body.string(message)
        body.string("zh-CN")
        return SFTPCodec.frame(type: .status, id: id, body: body.data)
    }
}

/// 完全由测试脚本控制应答的通道，用来构造乱序、迟到与断流。
final class ScriptedTransport: SFTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [Data] = []
    private var readers: [CheckedContinuation<Data?, Never>] = []
    private(set) var written: [Data] = []
    private var closed = false

    func respond(_ frame: Data) {
        lock.withLock {
            queued.append(frame)
            while !queued.isEmpty, !readers.isEmpty {
                readers.removeFirst().resume(returning: queued.removeFirst())
            }
        }
    }

    func endOutput() {
        lock.withLock {
            closed = true
            let waiting = readers
            readers = []
            for continuation in waiting { continuation.resume(returning: nil) }
        }
    }

    func start() async throws {}

    func read() async throws -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            lock.withLock {
                if !queued.isEmpty {
                    continuation.resume(returning: queued.removeFirst())
                } else if closed {
                    continuation.resume(returning: nil)
                } else {
                    readers.append(continuation)
                }
            }
        }
    }

    func write(_ data: Data) async throws {
        lock.withLock { written.append(data) }
    }

    func close() async {
        endOutput()
    }

    /// 本端发出的请求号序列；握手帧没有请求号，跳过。
    var sentRequestIDs: [UInt32] {
        lock.withLock {
            written.compactMap { frame in
                guard frame.count > 8, frame[4] != SFTPPacketType.initialize.rawValue else { return nil }
                return frame.subdata(in: 5..<9).withUnsafeBytes { UInt32(bigEndian: $0.load(as: UInt32.self)) }
            }
        }
    }
}
