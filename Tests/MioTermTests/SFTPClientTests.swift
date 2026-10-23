import Foundation
import Testing
@testable import MioTermCore

/// 客户端与连接层的端到端行为，跑在内存服务端上：
/// 不依赖真实 SSH，也能验证握手、请求号配对、目录枚举与错误传播。
struct SFTPClientTests {
    @Test func handshakeReadsServerVersionAndExtensions() async throws {
        let server = FakeSFTPServer()
        let client = try await SFTPClient.connect(transport: server)
        #expect(await client.serverVersion == 3)
        let extensions = await client.connection.extensions
        #expect(extensions["posix-rename@openssh.com"] == "1")
        await client.close()
    }

    @Test func handshakeTimeoutClosesTransport() async throws {
        let server = FakeSFTPServer()
        server.ignoresInit = true
        let error = await #expect(throws: SFTPConnection.ConnectionError.self) {
            _ = try await SFTPClient.connect(transport: server, handshakeTimeout: 1)
        }
        #expect(error?.isHandshakeTimeout == true)
        // 超时后必须已经把通道关掉，否则 ssh 子进程会挂着不放。
        #expect(await server.didCloseTransport)
    }

    @Test func listsDirectoryAcrossBatchesAndClosesHandle() async throws {
        let server = FakeSFTPServer()
        let client = try await SFTPClient.connect(transport: server)
        // 补足条目，让单批 3 条的服务端需要多轮回包
        for name in ["b.txt", "c.txt", "d.txt", "e.txt"] {
            try await client.write(Data("x".utf8), to: "/home/user/\(name)")
        }
        let entries = try await client.list("/home/user")
        #expect(entries.count == 7)
        // 目录永远排在前面，其余按名字排序
        #expect(entries.first?.name == "sub")
        #expect(entries.map(\.name) == ["sub", "a.txt", "b.txt", "c.txt", "d.txt", "e.txt", "hello.txt"])
        #expect(entries.first(where: { $0.name == "hello.txt" })?.size == 5)
        #expect(server.leakedDirectoryHandles == 0)
        await client.close()
    }

    @Test func hiddenFilterAppliesToRemoteListing() async throws {
        let server = FakeSFTPServer()
        let client = try await SFTPClient.connect(transport: server)
        try await client.write(Data("x".utf8), to: "/home/user/.secret")
        let visible = try await client.list("/home/user")
        let all = try await client.list("/home/user", showHidden: true)
        #expect(!visible.contains { $0.name.hasPrefix(".") })
        #expect(all.contains { $0.name == ".secret" })
        #expect(all.count == visible.count + 1)
        await client.close()
    }

    @Test func readsWholeFileInChunks() async throws {
        let server = FakeSFTPServer()
        let client = try await SFTPClient.connect(transport: server)
        let data = try await client.readData(from: "/home/user/sub/nested.bin")
        #expect(data.count == 5_000)
        #expect(data.allSatisfy { $0 == 0xAB })
        await client.close()
    }

    @Test func writeTruncatesExistingFile() async throws {
        let server = FakeSFTPServer()
        let client = try await SFTPClient.connect(transport: server)
        let payload = Data((0..<40_000).map { UInt8($0 % 251) })
        try await client.write(payload, to: "/home/user/big.bin")
        #expect(server.contents(of: "/home/user/big.bin") == payload)

        // 覆盖式写入不留尾巴
        try await client.write(Data("hi".utf8), to: "/home/user/big.bin")
        #expect(server.contents(of: "/home/user/big.bin") == Data("hi".utf8))
        await client.close()
    }

    @Test func writeSlicesStayUnderTheFrameLimit() async throws {
        let server = FakeSFTPServer()
        let client = try await SFTPClient.connect(transport: server)
        let payload = Data(repeating: 7, count: SFTPClient.maximumChunkSize * 3 + 11)
        try await client.write(payload, to: "/tmp/slices.bin")
        let sizes = server.writeRequestSizes()
        #expect(sizes.allSatisfy { $0 <= SFTPClient.maximumChunkSize })
        #expect(sizes.count == 4)
        #expect(server.contents(of: "/tmp/slices.bin") == payload)
        await client.close()
    }

    @Test func appendKeepsExistingBytes() async throws {
        let server = FakeSFTPServer()
        let client = try await SFTPClient.connect(transport: server)
        let handle = try await client.openAppend("/home/user/part.txt")
        try await client.write(handle: handle, offset: 0, data: Data("abc".utf8))
        try await client.write(handle: handle, offset: 3, data: Data("def".utf8))
        try await client.close(handle)
        #expect(server.contents(of: "/home/user/part.txt") == Data("abcdef".utf8))
        await client.close()
    }

    @Test func mkdirRenameRemoveRoundTrip() async throws {
        let server = FakeSFTPServer()
        let client = try await SFTPClient.connect(transport: server)
        try await client.makeDirectory("/home/user/newdir")
        #expect(server.node(at: "/home/user/newdir")?.isDirectory == true)

        try await client.move(from: "/home/user/newdir", to: "/home/user/renamed")
        #expect(server.node(at: "/home/user/newdir") == nil)
        #expect(server.node(at: "/home/user/renamed")?.isDirectory == true)

        try await client.removeDirectory("/home/user/renamed")
        #expect(server.node(at: "/home/user/renamed") == nil)
        await client.close()
    }

    @Test func renameIntoExistingNameSurfacesServerMessage() async throws {
        let server = FakeSFTPServer()
        let client = try await SFTPClient.connect(transport: server)
        try await client.write(Data("1".utf8), to: "/tmp/occupied")
        try await client.write(Data("2".utf8), to: "/tmp/free")
        let error = await #expect(throws: SFTPStatusError.self) {
            try await client.move(from: "/tmp/free", to: "/tmp/occupied")
        }
        #expect(error?.message == "目标已存在")
        await client.close()
    }

    @Test func missingPathThrowsTypedStatusError() async throws {
        let server = FakeSFTPServer()
        let client = try await SFTPClient.connect(transport: server)
        let error = await #expect(throws: SFTPStatusError.self) {
            _ = try await client.attributes(of: "/home/user/nope.txt")
        }
        #expect(error?.code == .NoSuchFile)
        #expect(error?.message == "不存在：/home/user/nope.txt")

        let listing = await #expect(throws: SFTPStatusError.self) {
            _ = try await client.list("/home/user/nope")
        }
        #expect(listing?.code == .NoSuchFile)
        #expect(try await client.exists("/home/user/hello.txt") == true)
        #expect(try await client.exists("/home/user/ghost") == false)
        await client.close()
    }

    /// REALPATH 发的是 16 号报文，应答是 SSH_FXP_NAME，路径在第一个文件名字段里。
    @Test func realpathSendsTheRealpathOpcodeAndReadsTheNameField() async throws {
        let transport = ScriptedTransport()
        let connection = SFTPConnection(transport: transport)
        let connectTask = Task { try await connection.connect(timeout: 5) }
        transport.respond(Self.versionFrame(extensions: ["expand-path@openssh.com": "1"]))
        _ = try await connectTask.value
        let client = SFTPClient(connection: connection)

        let task = Task { try await client.realpath(".") }
        try await Task.sleep(nanoseconds: 20_000_000)
        // 最后一帧是 realpath 请求（第一帧是 INIT）；长度前缀之后第一个字节就是报文类型。
        #expect(transport.written.last.map { $0[$0.startIndex + 4] } == SFTPPacketType.realpath.rawValue)
        var body = SFTPWriter()
        body.uint32(1)
        body.string("/home/user")
        body.string("")
        body.uint32(0)
        transport.respond(SFTPCodec.frame(type: .name, id: 0, body: body.data))
        #expect(try await task.value == "/home/user")
        await client.close()
    }

    @Test func repliesArrivingOutOfOrderStillMatchTheirRequest() async throws {
        let transport = ScriptedTransport()
        let connection = SFTPConnection(transport: transport)
        let connectTask = Task { try await connection.connect() }

        // INIT 出去后手工回 VERSION，再乱序回两个请求，验证靠请求号而非到达顺序配对
        try await Task.sleep(nanoseconds: 50_000_000)
        transport.respond(Self.versionFrame(extensions: ["statvfs@openssh.com": "2"]))
        #expect(try await connectTask.value == 3)

        async let first = connection.status(.setstat) { $0.string("/a") }
        async let second = connection.status(.setstat) { $0.string("/b") }
        try await Task.sleep(nanoseconds: 50_000_000)
        let ids = transport.sentRequestIDs
        #expect(ids.count == 2)
        transport.respond(Self.statusFrame(id: ids[1]))
        transport.respond(Self.statusFrame(id: ids[0]))
        try await first
        try await second
        await connection.close()
    }

    @Test func pendingRequestsWakeUpWhenTheChannelDies() async throws {
        let transport = ScriptedTransport()
        let connection = SFTPConnection(transport: transport)
        let connectTask = Task { try await connection.connect(timeout: 1) }
        transport.respond(Self.versionFrame(extensions: [:]))
        _ = try await connectTask.value

        // 请求发出后服务端再也不回，读端突然 EOF：等待方必须被唤醒而不是挂死。
        let task = Task { try await connection.status(.lstat) { $0.string("/never-answered") } }
        try await Task.sleep(nanoseconds: 50_000_000)
        transport.endOutput()
        await #expect(throws: SFTPConnection.ConnectionError.self) {
            try await task.value
        }
    }

    @Test func transportWriteFailureClosesTheConnection() async throws {
        let transport = FailingTransport()
        let connection = SFTPConnection(transport: transport)
        await #expect(throws: SFTPConnection.ConnectionError.self) {
            try await connection.connect()
        }
        #expect(transport.closeCalled)
    }

    @Test func writeRejectsOversizedFrame() async throws {
        let server = FakeSFTPServer()
        let client = try await SFTPClient.connect(transport: server)
        let handle = try await client.openWrite("/tmp/oversize.bin")
        await #expect(throws: SFTPCodecError.self) {
            try await client.write(handle: handle, offset: 0, data: Data(repeating: 1, count: SFTPClient.maximumChunkSize + 1))
        }
        await client.close()
    }

    // MARK: - 帮助

    private static func versionFrame(extensions: [String: String]) -> Data {
        var body = SFTPWriter()
        for (name, value) in extensions {
            body.string(name)
            body.string(value)
        }
        return SFTPCodec.frame(type: .version, id: 3, body: body.data)
    }

    private static func statusFrame(id: UInt32, code: SFTPStatusCode = .ok) -> Data {
        var body = SFTPWriter()
        body.uint32(code.rawValue)
        body.string("")
        body.string("")
        return SFTPCodec.frame(type: .status, id: id, body: body.data)
    }
}

/// 写入即失败，模拟 ssh 进程已退出后的 Broken pipe。
private final class FailingTransport: SFTPTransport, @unchecked Sendable {
    var closeCalled = false

    func start() async throws {}
    func read() async throws -> Data? { nil }

    func write(_ data: Data) async throws {
        throw SFTPTransportError.closed
    }

    func close() async {
        closeCalled = true
    }
}
