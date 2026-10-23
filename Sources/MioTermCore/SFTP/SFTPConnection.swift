import Foundation

/// 一次性唤醒。请求登记与应答到达的先后顺序不确定，两边都能先落地，
/// 因此不会出现“应答比等待先到”而永久挂起的竞态。
final class OneShot<Success: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Success, Error>?
    private var settledResult: Result<Success, Error>?

    /// 结果先到也可以：value() 取走后直接返回，不会永久挂起。
    func value() async throws -> Success {
        var captured: Result<Success, Error>?
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if let result = settledResult {
                    settledResult = nil
                    captured = result
                } else {
                    self.continuation = continuation
                }
            }
            if let captured { continuation.resume(with: captured) }
        }
    }

    func complete(with result: Result<Success, Error>) {
        var waiting: CheckedContinuation<Success, Error>?
        lock.withLock {
            if let continuation {
                self.continuation = nil
                waiting = continuation
            } else if settledResult == nil {
                settledResult = result
            }
        }
        if let waiting { waiting.resume(with: result) }
    }

    /// 等待方被取消时调用：唤醒可能已经在路上的应答，让请求号可以被回收。
    func abandon() {
        var waiting: CheckedContinuation<Success, Error>?
        lock.withLock {
            waiting = continuation
            continuation = nil
            if waiting == nil { settledResult = .failure(CancellationError()) }
        }
        waiting?.resume(throwing: CancellationError())
    }
}

/// SFTP 请求/应答配对。请求号自增，应答由唯一的读循环分发，
/// 因此允许多个请求并发在飞（上传下载的分片并发依赖这一点）。
public actor SFTPConnection {
    public enum ConnectionError: LocalizedError, Equatable {
        case closed(String)
        case handshakeTimeout
        case alreadyConnected

        /// 握手超时要和“连不上”区别对待：前者多半是远端没起 sftp-server。
        public var isHandshakeTimeout: Bool { self == .handshakeTimeout }

        /// 远端明确拒绝子系统时，面板应该提示“未启用 SFTP”，
        /// 而不是把 ssh 的原始 stderr 当异常弹出来。
        public var indicatesMissingSubsystem: Bool {
            guard case .closed(let reason) = self else { return false }
            return Self.looksLikeMissingSubsystem(reason)
        }

        /// ssh 拒绝 `-s sftp` 的几种说法：服务器没配 Subsystem，或 sftp-server 不存在。
        public static func looksLikeMissingSubsystem(_ reason: String) -> Bool {
            let text = reason.lowercased()
            let direct = [
                "subsystem request failed",
                "administratively prohibited",
                "exec request failed",
                "unknown subsystem",
                "subsystem not found",
                "subsystem 'sftp' not found",
                "sftp-server: not found",
                "sftp-server: no such file",
            ]
            if direct.contains(where: { text.contains($0) }) { return true }
            return text.contains("sftp-server")
                && (text.contains("not found") || text.contains("no such file"))
        }

        public var errorDescription: String? {
            switch self {
            case .closed(let reason): return reason.isEmpty ? "SFTP 连接已关闭" : "SFTP 连接已关闭：\(reason)"
            case .handshakeTimeout: return "等待远端 sftp-server 握手超时"
            case .alreadyConnected: return "该连接已经建立"
            }
        }
    }

    private let transport: any SFTPTransport
    private var nextRequestID: UInt32 = 0
    private var pending: [UInt32: OneShot<SFTPPacket>] = [:]
    private var handshake: OneShot<UInt32>?
    private var readLoop: Task<Void, Never>?
    private var closedReason: String?
    private var didCloseTransport = false

    public private(set) var serverVersion: UInt32 = 0
    public private(set) var extensions: [String: String] = [:]

    public var isConnected: Bool { closedReason == nil }

    public init(transport: any SFTPTransport) {
        self.transport = transport
    }

    /// 建立通道并完成 v3 握手；`timeout` 兜住对端不回的挂死场景。
    @discardableResult
    public func connect(timeout: TimeInterval = 20) async throws -> UInt32 {
        guard readLoop == nil else { throw ConnectionError.alreadyConnected }
        let waiter = OneShot<UInt32>()
        do {
            try await transport.start()
            handshake = waiter
            readLoop = Task { await self.runReadLoop() }
            try await transport.write(SFTPCodec.initializePacket())
            let version = try await awaitHandshake(waiter, timeout: timeout)
            handshake = nil
            serverVersion = version
            return version
        } catch {
            // 握手失败不留半开通道：子进程、askpass 与挂起的请求都要收尾。
            await close(reason: error.localizedDescription)
            if let error = error as? ConnectionError { throw error }
            throw ConnectionError.closed(error.localizedDescription)
        }
    }

    /// 握手等待与超时竞速。
    /// `withThrowingTaskGroup` 在返回前会收尾全部子任务，而超时先触发时等握手的那个子任务
    /// 还挂着，因此必须先把结果落到 waiter 上，否则这里出不去、连接永久卡死。
    private func awaitHandshake(_ waiter: OneShot<UInt32>, timeout: TimeInterval) async throws -> UInt32 {
        try await withThrowingTaskGroup(of: UInt32.self) { group in
            group.addTask { try await waiter.value() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                throw ConnectionError.handshakeTimeout
            }
            do {
                guard let version = try await group.next() else { throw ConnectionError.handshakeTimeout }
                group.cancelAll()
                return version
            } catch {
                waiter.complete(with: .failure(error))
                group.cancelAll()
                throw error
            }
        }
    }

    /// 发送一个请求并等待对应应答。
    public func request(_ type: SFTPPacketType, body: (inout SFTPWriter) -> Void) async throws -> SFTPReply {
        let packet = try await perform(type, body: body)
        return try SFTPReply(packet: packet)
    }

    public func status(_ type: SFTPPacketType, body: (inout SFTPWriter) -> Void) async throws {
        try await request(type, body: body).requireOK()
    }

    private func perform(_ type: SFTPPacketType, body: (inout SFTPWriter) -> Void) async throws -> SFTPPacket {
        if let reason = closedReason { throw ConnectionError.closed(reason) }
        let id = nextRequestID
        nextRequestID = nextRequestID &+ 1

        var writer = SFTPWriter()
        body(&writer)
        let frame = SFTPCodec.frame(type: type, id: id, body: writer.data)

        let waiter = OneShot<SFTPPacket>()
        pending[id] = waiter
        do {
            try await transport.write(frame)
        } catch {
            // 写管道失败等于通道已断，服务端不会再回任何东西。
            await close(reason: error.localizedDescription)
            throw ConnectionError.closed(error.localizedDescription)
        }

        // 闭包内不碰 actor 存储，取消路径交给 abandon，避免隔离标注随 SDK 版本变化。
        let packet: SFTPPacket
        do {
            packet = try await withTaskCancellationHandler(operation: {
                try await waiter.value()
            }, onCancel: {
                Task { await self.abandon(id) }
            })
            try Task.checkCancellation()
        } catch {
            pending[id] = nil
            throw error
        }
        pending[id] = nil
        return packet
    }

    private func abandon(_ id: UInt32) {
        pending.removeValue(forKey: id)?.abandon()
    }

    private func runReadLoop() async {
        var assembler = SFTPFrameAssembler()
        do {
            while true {
                guard let chunk = try await transport.read() else { break }
                let packets = try assembler.feed(chunk)
                ingest(packets)
            }
            await close(reason: "远端通道已结束")
        } catch {
            await close(reason: error.localizedDescription)
        }
    }

    private func ingest(_ packets: [SFTPPacket]) {
        for packet in packets {
            switch packet.type {
            case .initialize, .version:
                serverVersion = packet.id
                extensions = Self.parseExtensions(packet.payload)
                handshake?.complete(with: .success(packet.id))
                handshake = nil
            case .badMessage:
                var reader = SFTPReader(packet.payload)
                let offendingID = (try? reader.uint32()) ?? packet.id
                let detail = (try? reader.string()) ?? ""
                let waiter = pending.removeValue(forKey: offendingID) ?? pending.removeValue(forKey: packet.id)
                waiter?.complete(with: .failure(SFTPCodecError.malformed(detail.isEmpty ? "服务端拒绝了报文" : detail)))
            default:
                pending.removeValue(forKey: packet.id)?.complete(with: .success(packet))
            }
        }
    }

    /// SSH_FXP_VERSION 之后是若干 (名称, 取值) 扩展字符串对。
    private static func parseExtensions(_ payload: Data) -> [String: String] {
        var reader = SFTPReader(payload)
        var result: [String: String] = [:]
        while !reader.isAtEnd {
            do {
                let name = try reader.string()
                let value = try reader.string()
                result[name] = value
            } catch {
                break
            }
        }
        return result
    }

    /// 连接结束：把所有还在等待的请求以错误唤醒，避免调用方永久挂起。
    private func fail(reason: String) {
        if closedReason == nil { closedReason = reason }
        handshake?.complete(with: .failure(ConnectionError.closed(reason)))
        handshake = nil
        let waiting = pending
        pending.removeAll()
        for (_, waiter) in waiting {
            waiter.complete(with: .failure(ConnectionError.closed(reason)))
        }
    }

    /// 只负责收尾，不取消读循环任务：`transport.close()` 会让阻塞的读返回 EOF，
    /// 循环自然退出，强行 cancel 反而可能把收尾的 await 打断。
    /// 收尾只看“子进程管道是否关过”，不能用 isConnected 当门槛：
    /// 读循环自己发现断开时已经写入了 closedReason，那时仍需把通道真正关掉。
    public func close(reason: String = "本地关闭") async {
        guard !didCloseTransport else { return }
        didCloseTransport = true
        fail(reason: reason)
        readLoop = nil
        await transport.close()
    }
}
