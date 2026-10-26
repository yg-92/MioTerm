import Foundation

/// 服务端返回的不透明文件/目录句柄。
public struct SFTPHandle: Equatable, Sendable {
    public let bytes: Data

    public init(_ bytes: Data) { self.bytes = bytes }
}

/// 文件面板一行所需的信息，已从 SSH_FXP_NAME 里挑出可展示的部分。
public struct SFTPFileEntry: Equatable, Identifiable, Sendable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var size: UInt64
    public var modifiedAt: Date?
    public var permissions: UInt32
    public var owner: String
    public var group: String

    public var id: String { path }

    public init(path: String, name: String, isDirectory: Bool, size: UInt64, modifiedAt: Date?, permissions: UInt32 = 0, owner: String = "", group: String = "") {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
        self.permissions = permissions
        self.owner = owner
        self.group = group
    }

    /// 大小可能整个缺失（服务端没置 SIZE 位），此时显示为空而不是 0 字节。
    public var sizeText: String {
        isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    /// 点文件/点目录：只有打开“显示隐藏文件”时才会进列表，界面据此弱化图标。
    public var isHidden: Bool { name.hasPrefix(".") }

    public var modifiedText: String {
        guard let modifiedAt else { return "" }
        return Self.formatter.string(from: modifiedAt)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

/// 把 SFTP 报文翻译成“目录、读写、增删改”这些动作。
/// 传输层已经保证串行分发应答，所以这里的方法可以并发调用。
public actor SFTPClient {
    /// 单个 SSH_FXP_READ/WRITE 的字节上限。sftp-server 会拒绝超过 ~34000 的帧，
    /// 32 KiB 是所有实现都接受的值，也是 OpenSSH 自己用的值。
    public static let maximumChunkSize = 32_768

    /// 本地读写一次搬运的字节数；对协议来说仍是上限 32 KiB 的小帧。
    public static let readChunkSize = 65_536

    /// 会话层需要直接持有连接（例如按路径新建独立通道），因此不做私有封装。
    public let connection: SFTPConnection

    public init(connection: SFTPConnection) {
        self.connection = connection
    }

    /// 建立通道 + 握手，返回可直接使用的客户端。
    public static func connect(transport: any SFTPTransport, handshakeTimeout: TimeInterval = 20) async throws -> SFTPClient {
        let connection = SFTPConnection(transport: transport)
        try await connection.connect(timeout: handshakeTimeout)
        return SFTPClient(connection: connection)
    }

    public func close() async {
        await connection.close()
    }

    public var serverVersion: UInt32 {
        get async { await connection.serverVersion }
    }

    // MARK: - 路径与元数据

    /// `.` 即服务端登录 shell 的当前目录，用来作为文件面板初始位置。
    public func currentDirectory() async throws -> String {
        try await realpath(".")
    }

    /// 把 `~`、`./projects` 这类写法换成服务端认可的绝对路径。
    /// 应答是 SSH_FXP_NAME，第一个文件名字段就是规范化后的路径。
    public func realpath(_ path: String) async throws -> String {
        let reply = try await connection.request(.realpath) { writer in
            writer.string(path)
        }
        guard case .name(let entries) = reply, let first = entries.first else {
            throw SFTPCodecError.malformed("realpath 应答类型不符")
        }
        return first.shortName
    }

    /// 用 LSTAT 而不是 STAT：软链接要显示链接本身，
    /// 点开一个指向别处的链接不会把文件面板带到莫名其妙的目录。
    public func attributes(of path: String) async throws -> SFTPFileAttributes {
        let reply = try await connection.request(.lstat) { writer in
            writer.string(SFTPPath.normalize(path))
        }
        switch reply {
        case .attributes(let attributes): return attributes
        case .status(let code, let message): throw SFTPStatusError(code: code, message: message)
        default: throw SFTPCodecError.malformed("lstat 应答类型不符")
        }
    }

    /// 列目录。opens → 反复 readdir 到 EOF → 无论成败都 close，
    /// 否则服务端的句柄会一直占着。
    public func list(_ directory: String, showHidden: Bool = false) async throws -> [SFTPFileEntry] {
        let handle = try await openDirectory(directory)
        do {
            var collected: [SFTPDirectoryEntry] = []
            while true {
                let reply = try await connection.request(.readDir) { writer in
                    writer.bytes(handle.bytes)
                }
                switch reply {
                case .name(let batch):
                    collected.append(contentsOf: batch)
                case .status(let code, _) where code == .eof:
                    try await close(handle)
                    return organize(collected, directory: directory, showHidden: showHidden)
                case .status(let code, let message):
                    throw SFTPStatusError(code: code, message: message)
                default:
                    throw SFTPCodecError.malformed("readdir 应答类型不符")
                }
            }
        } catch {
            try? await close(handle)
            throw error
        }
    }

    private func organize(_ entries: [SFTPDirectoryEntry], directory: String, showHidden: Bool) -> [SFTPFileEntry] {
        SFTPDirectoryFilter.entries(entries, showHidden: showHidden)
            .map { entry in
                SFTPFileEntry(
                    path: SFTPPath.join(directory, entry.shortName),
                    name: entry.shortName,
                    isDirectory: entry.isDirectory,
                    size: entry.attributes.size,
                    modifiedAt: entry.modificationTime,
                    permissions: entry.attributes.permissions,
                    owner: entry.attributes.flags.contains(.uidGid) ? String(entry.attributes.uid) : "",
                    group: entry.attributes.flags.contains(.uidGid) ? String(entry.attributes.gid) : ""
                )
            }
            .sorted { left, right in
                if left.isDirectory != right.isDirectory { return left.isDirectory }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
    }

    // MARK: - 写操作

    public func makeDirectory(_ path: String) async throws {
        try await connection.status(.mkdir) { writer in
            writer.string(SFTPPath.normalize(path))
            SFTPFileAttributes.directoryMode().encode(into: &writer)
        }
    }

    public func removeFile(_ path: String) async throws {
        try await connection.status(.remove) { writer in
            writer.string(SFTPPath.normalize(path))
        }
    }

    public func removeDirectory(_ path: String) async throws {
        try await connection.status(.rmdir) { writer in
            writer.string(SFTPPath.normalize(path))
        }
    }

    /// 递归删除。SFTP v3 的 RMDIR 只接受空目录，非空目录只能由客户端先清空。
    /// 软链接按 LSTAT 判定，删的是链接本身，不会顺着链接删掉指向的远端内容。
    /// 路径已经不存在时视为成功：调用方要的结果就是“它不在了”。
    public func removeTree(_ path: String) async throws {
        let attributes: SFTPFileAttributes
        do {
            attributes = try await self.attributes(of: path)
        } catch let error as SFTPStatusError where error.code == .NoSuchFile {
            return
        }
        guard attributes.isDirectory else {
            try await removeFile(path)
            return
        }
        // 隐藏项也要一起清掉，否则目录看起来空了却仍然删不掉。
        for child in try await list(path, showHidden: true) {
            do {
                if try await isDirectoryEntry(child) {
                    try await removeTree(child.path)
                } else {
                    try await removeFile(child.path)
                }
            } catch let error as SFTPStatusError where error.code == .NoSuchFile {
                // 枚举到删除之间被别的进程清掉了，接着删剩下的。
            }
        }
        try await removeDirectory(path)
    }

    /// readdir 有时不带权限位，此时目录与文件只能靠一次 LSTAT 分开。
    private func isDirectoryEntry(_ entry: SFTPFileEntry) async throws -> Bool {
        guard entry.permissions == 0 else { return entry.isDirectory }
        return try await attributes(of: entry.path).isDirectory
    }

    /// sftp v3 只有 rename；同名目标会被服务端拒绝，UI 需要自己先删除再改名。
    public func move(from source: String, to destination: String) async throws {
        try await connection.status(.rename) { writer in
            writer.string(SFTPPath.normalize(source))
            writer.string(SFTPPath.normalize(destination))
        }
    }

    // MARK: - 句柄读写

    public func openRead(_ path: String) async throws -> SFTPHandle {
        try await open(path, flags: [.read])
    }

    /// 覆盖式写入：不存在则创建，存在则截断。续传走 append 形式。
    public func openWrite(_ path: String, mode: UInt32 = 0o644) async throws -> SFTPHandle {
        try await open(path, flags: [.write, .create, .truncate], mode: mode)
    }

    /// 不截断，供断点续传从既有长度接着写。
    public func openAppend(_ path: String, mode: UInt32 = 0o644) async throws -> SFTPHandle {
        try await open(path, flags: [.write, .create], mode: mode)
    }

    private func open(_ path: String, flags: SFTPOpenFlag, mode: UInt32 = 0o644) async throws -> SFTPHandle {
        let attributes = SFTPFileAttributes.fileMode(mode)
        let reply = try await connection.request(.open) { writer in
            writer.string(SFTPPath.normalize(path))
            writer.uint32(flags.rawValue)
            attributes.encode(into: &writer)
        }
        guard case .handle(let bytes) = reply else {
            if case .status(let code, let message) = reply { throw SFTPStatusError(code: code, message: message) }
            throw SFTPCodecError.malformed("open 应答类型不符")
        }
        return SFTPHandle(bytes)
    }

    public func openDirectory(_ path: String) async throws -> SFTPHandle {
        let reply = try await connection.request(.openDir) { writer in
            writer.string(SFTPPath.normalize(path))
        }
        guard case .handle(let bytes) = reply else {
            if case .status(let code, let message) = reply { throw SFTPStatusError(code: code, message: message) }
            throw SFTPCodecError.malformed("opendir 应答类型不符")
        }
        return SFTPHandle(bytes)
    }

    /// 返回 nil 表示已到文件末尾，调用方据此结束循环。
    /// 请求长度固定：sftp-server 不会主动少给，缩短它只会白白增加往返。
    public func read(handle: SFTPHandle, offset: UInt64) async throws -> Data? {
        let reply = try await connection.request(.read) { writer in
            writer.bytes(handle.bytes)
            writer.uint64(offset)
            writer.uint32(UInt32(Self.maximumChunkSize))
        }
        switch reply {
        case .data(let payload): return payload
        case .status(let code, _) where code == .eof: return nil
        case .status(let code, let message): throw SFTPStatusError(code: code, message: message)
        default: throw SFTPCodecError.malformed("read 应答类型不符")
        }
    }

    public func write(handle: SFTPHandle, offset: UInt64, data: Data) async throws {
        // 分片是传输层的职责；这里挡住越界帧，否则服务端会直接判定协议错误。
        guard data.count <= Self.maximumChunkSize else {
            throw SFTPCodecError.malformed("单帧写入 \(data.count) 字节，超过 \(Self.maximumChunkSize) 上限")
        }
        try await connection.status(.write) { writer in
            writer.bytes(handle.bytes)
            writer.uint64(offset)
            writer.bytes(data)
        }
    }

    public func close(_ handle: SFTPHandle) async throws {
        try await connection.status(.close) { writer in
            writer.bytes(handle.bytes)
        }
    }

    /// 一次读完远端小文件。大文件走传输队列，不把整份内容搬进内存。
    public func readData(from path: String) async throws -> Data {
        let handle = try await openRead(path)
        var collected = Data()
        do {
            while let chunk = try await read(handle: handle, offset: UInt64(collected.count)) {
                guard !chunk.isEmpty else { break }
                collected.append(chunk)
            }
            try await close(handle)
        } catch {
            try? await close(handle)
            throw error
        }
        return collected
    }

    /// 覆盖写入一份小文件，按协议上限自动切帧。
    public func write(_ data: Data, to path: String) async throws {
        let handle = try await openWrite(path)
        do {
            var offset = 0
            while offset < data.count {
                let end = min(offset + Self.maximumChunkSize, data.count)
                try await write(handle: handle, offset: UInt64(offset), data: data.subdata(in: offset..<end))
                offset = end
            }
            try await close(handle)
        } catch {
            try? await close(handle)
            throw error
        }
    }

    /// v3 没有专门的存在性查询，用一次 stat 换“在不在”；权限之类的其它错误
    /// 要原样抛出，让 UI 说明真实原因。
    public func exists(_ path: String) async throws -> Bool {
        do {
            _ = try await attributes(of: path)
            return true
        } catch let error as SFTPStatusError where error.code == .NoSuchFile {
            return false
        }
    }
}
