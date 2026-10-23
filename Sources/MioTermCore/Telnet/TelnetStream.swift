import Foundation

/// Telnet 客户端：TCPSocket 负责收发，TelnetNegotiator 负责协商，两者都只活在
/// engine 这条串行队列上，因此状态机不需要加锁。
///
/// 连接放在并发队列执行：非阻塞 connect + poll 会等到超时为止，
/// 挤在 engine 上会把同一时刻的键入一起卡住。
public final class TelnetStream: TerminalStream, @unchecked Sendable {
    /// 单次 read 的上限，与 webterm 的 32KB 分片一致。
    private static let maximumReadLength = 32_768

    private let stream: AsyncStream<StreamEvent>
    private let continuation: AsyncStream<StreamEvent>.Continuation
    public var events: AsyncStream<StreamEvent> { stream }

    private let host: String
    private let port: Int
    private let connectTimeout: TimeInterval
    private let engine = DispatchQueue(label: "mioTerm.telnet.engine")
    private let connectQueue = DispatchQueue(label: "mioTerm.telnet.connect", attributes: .concurrent)

    private var socket: TCPSocket?
    private var readSource: DispatchSourceRead?
    private var negotiator: TelnetNegotiator
    private var columns: Int
    private var rows: Int
    private var isClosed = false

    public init(host: String, port: Int = 23, terminalType: String = "xterm-256color",
                columns: Int = 80, rows: Int = 24, connectTimeout: TimeInterval = 10) {
        self.host = host
        self.port = port
        self.connectTimeout = max(1, connectTimeout)
        self.columns = columns
        self.rows = rows
        self.negotiator = TelnetNegotiator(terminalType: terminalType, columns: columns, rows: rows)
        let (stream, continuation) = AsyncStream.makeStream(of: StreamEvent.self)
        self.stream = stream
        self.continuation = continuation
    }

    public func start() async {
        let endpoint = host
        let port = self.port
        let timeout = self.connectTimeout
        let connection: (socket: TCPSocket?, failure: String?) = await withCheckedContinuation { box in
            connectQueue.async {
                do {
                    box.resume(returning: (try TCPSocket.connect(host: endpoint, port: port, timeout: timeout), nil))
                } catch {
                    box.resume(returning: (nil, error.localizedDescription))
                }
            }
        }
        await onEngine {
            guard !self.isClosed else {
                connection.socket?.close()
                return
            }
            if let connected = connection.socket {
                self.adopt(connected)
            } else {
                self.finish(with: .failed(connection.failure ?? "连接失败"))
            }
        }
    }

    public func write(_ data: Data) async {
        await onEngine { self.send(data) }
    }

    public func resize(columns: Int, rows: Int) async {
        await onEngine {
            self.columns = columns
            self.rows = rows
            if let packet = self.negotiator.setWindowSize(columns: columns, rows: rows) {
                self.writeRaw(packet)
            }
        }
    }

    public func close() async {
        await onEngine { self.finish(with: nil) }
    }

    /// 把一段工作交给 engine 串行队列并等它跑完。用 withCheckedContinuation 而不是
    /// DispatchQueue 的 async 重载：后者在这个工具链上会退化成“投递即返回”，
    /// 调用方以为发完了，其实字节还排在队列里。
    private func onEngine(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (box: CheckedContinuation<Void, Never>) in
            engine.async {
                work()
                box.resume()
            }
        }
    }

    // MARK: - engine 队列内部

    private func adopt(_ connected: TCPSocket) {
        socket = connected
        continuation.yield(.connected)
        // 服务器一旦同意 NAWS，就要马上告知当前窗口，否则远端程序按 80 列排版。
        if let packet = negotiator.setWindowSize(columns: columns, rows: rows) { writeRaw(packet) }

        let source = DispatchSource.makeReadSource(fileDescriptor: connected.descriptor, queue: engine)
        source.setEventHandler { [weak self] in self?.drain() }
        // 描述符只在取消处理器里关一次：提前 close 会让内核复用同号描述符，
        // 后续处理器就会写到别人的 socket 上。
        source.setCancelHandler { connected.close() }
        readSource = source
        source.resume()
    }

    private func drain() {
        guard let connected = socket, !isClosed else { return }
        while true {
            let chunk: TCPSocket.ReadResult
            do {
                chunk = try connected.read(maximumCount: Self.maximumReadLength)
            } catch {
                finish(with: .failed(error.localizedDescription))
                return
            }
            switch chunk {
            case .bytes(let bytes):
                let echoBefore = negotiator.localEchoRequired
                let outcome = negotiator.feed(ArraySlice(bytes))
                if !outcome.data.isEmpty { continuation.yield(.data(outcome.data)) }
                if !outcome.replies.isEmpty { writeRaw(outcome.replies) }
                if echoBefore != negotiator.localEchoRequired {
                    continuation.yield(.notice(negotiator.localEchoRequired
                        ? "服务器不回显输入，已启用本地回显"
                        : "服务器已接管回显，关闭本地回显"))
                }
                if isClosed { return }
                if let failure = outcome.failure {
                    finish(with: .failed(failure))
                    return
                }
            case .wouldBlock:
                return
            case .ended:
                finish(with: .closed(reason: nil))
                return
            }
        }
    }

    private func send(_ data: Data) {
        guard socket != nil, !isClosed else { return }
        let encoded = negotiator.encodeOutput(data)
        guard !encoded.isEmpty else { return }
        writeRaw(encoded)
        // 服务器不接管回显时，键入得自己显示出来，否则用户看不到在敲什么。
        if negotiator.localEchoRequired, !isClosed { continuation.yield(.data(encoded)) }
    }

    private func writeRaw(_ data: Data) {
        guard let connected = socket, !isClosed else { return }
        do {
            try connected.write(data)
        } catch {
            finish(with: .failed(error.localizedDescription))
        }
    }

    /// 唯一的收尾路径：先投最后一枚事件，再关描述符并结束事件流。
    private func finish(with event: StreamEvent?) {
        guard !isClosed else { return }
        isClosed = true
        if let event { continuation.yield(event) }
        continuation.finish()
        readSource?.cancel()
        readSource = nil
        socket = nil
    }
}
