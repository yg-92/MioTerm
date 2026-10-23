import Foundation

/// 最小可用的 TCP 客户端套接字。macOS 不带 telnet 命令，也没有可依赖的系统级
/// 明文端口探测工具，所以 Telnet 与“测试连接”只能自己碰 POSIX socket。
///
/// 连接后的描述符是非阻塞的：读由 DispatchSourceRead 驱动，写遇到 EAGAIN 时
/// 用 poll 等待可写并带超时，避免对端不收数据时把会话线程钉死。
public struct TCPSocket: Sendable {
    public enum ReadResult: Equatable {
        case bytes(Data)
        /// 暂时没数据，等下一次可读通知。
        case wouldBlock
        /// read 返回 0：对端已经关闭。
        case ended
    }

    public enum SocketError: LocalizedError, Equatable {
        case nameNotFound(String, Int32)
        case noAddress(String)
        case connectFailed(String, String)
        case timeout(String, TimeInterval)
        case writeFailed(String)
        case readFailed(String)

        public var errorDescription: String? {
            switch self {
            case .nameNotFound(let host, let code):
                return "无法解析 \(host)（getaddrinfo \(code)）"
            case .noAddress(let host):
                return "\(host) 没有可用的地址记录"
            case .connectFailed(let endpoint, let reason):
                return "连接 \(endpoint) 失败：\(reason)"
            case .timeout(let endpoint, let seconds):
                return "连接 \(endpoint) 超时（\(Int(seconds)) 秒）"
            case .writeFailed(let reason):
                return "发送失败：\(reason)"
            case .readFailed(let reason):
                return "读取失败：\(reason)"
            }
        }
    }

    public let descriptor: Int32
    /// 用于错误文案的 “地址:端口”，不带任何凭据。
    public let endpoint: String
    /// 写等待可写的上限，与 webterm 的 10 秒写超时一致。
    public var writeTimeout: TimeInterval = 10

    public init(descriptor: Int32, endpoint: String) {
        self.descriptor = descriptor
        self.endpoint = endpoint
    }

    public static func connect(host: String, port: Int, timeout: TimeInterval) throws -> TCPSocket {
        let endpoint = "\(host):\(port)"
        let addresses = try lookup(host: host, port: port)
        guard !addresses.isEmpty else { throw SocketError.noAddress(host) }

        var lastError: String?
        for address in addresses {
            do {
                return try openConnection(to: address, endpoint: endpoint, timeout: timeout)
            } catch {
                // 地址族回退：IPv6 失败后继续试 IPv4，只把最后一条原因报给用户。
                if case SocketError.timeout = error { throw error }
                lastError = error.localizedDescription
            }
        }
        throw SocketError.connectFailed(endpoint, lastError ?? "未知原因")
    }

    /// 只探测端口能否连通，不开会话。测试连接走这条路。
    public static func probe(host: String, port: Int, timeout: TimeInterval) throws {
        let socket = try connect(host: host, port: port, timeout: timeout)
        socket.close()
    }

    public func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
    }

    public func read(maximumCount: Int) throws -> ReadResult {
        var buffer = [UInt8](repeating: 0, count: maximumCount)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        if count > 0 { return .bytes(Data(buffer[0..<count])) }
        if count == 0 { return .ended }
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return .wouldBlock }
        throw SocketError.readFailed(String(cString: strerror(errno)))
    }

    public func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        let deadline = Date().addingTimeInterval(writeTimeout)
        var sent = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while sent < data.count {
                let count = Darwin.write(descriptor, base.advanced(by: sent), data.count - sent)
                if count > 0 { sent += count; continue }
                if errno == EINTR { continue }
                guard errno == EAGAIN || errno == EWOULDBLOCK else {
                    throw SocketError.writeFailed(String(cString: strerror(errno)))
                }
                try waitUntilWritable(deadline: deadline)
            }
        }
    }

    // MARK: - 内部实现

    private static func lookup(host: String, port: Int) throws -> [(family: Int32, address: Data)] {
        var hints = addrinfo(ai_flags: 0,
                             ai_family: AF_UNSPEC,
                             ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0,
                             ai_canonname: nil,
                             ai_addr: nil,
                             ai_next: nil)
        var results: UnsafeMutablePointer<addrinfo>?
        let code = getaddrinfo(host, String(port), &hints, &results)
        guard code == 0, let first = results else {
            throw SocketError.nameNotFound(host, code)
        }
        defer { freeaddrinfo(first) }
        var addresses: [(family: Int32, address: Data)] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let node = cursor?.pointee {
            if let raw = node.ai_addr, node.ai_family == AF_INET || node.ai_family == AF_INET6 {
                addresses.append((node.ai_family, Data(bytes: raw, count: Int(node.ai_addrlen))))
            }
            cursor = node.ai_next
        }
        return addresses
    }

    private static func openConnection(to address: (family: Int32, address: Data), endpoint: String, timeout: TimeInterval) throws -> TCPSocket {
        let descriptor = Darwin.socket(address.family, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw SocketError.connectFailed(endpoint, String(cString: strerror(errno)))
        }
        do {
            try configure(descriptor, endpoint: endpoint)
            try waitingConnect(descriptor, address: address, endpoint: endpoint, timeout: timeout)
            try setNonBlocking(descriptor, endpoint: endpoint)
            return TCPSocket(descriptor: descriptor, endpoint: endpoint)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func configure(_ descriptor: Int32, endpoint: String) throws {
        // 写向已关闭的连接要拿到 EPIPE，而不是让 SIGPIPE 终止整个应用。
        var enable: Int32 = 1
        if setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enable, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            throw SocketError.connectFailed(endpoint, String(cString: strerror(errno)))
        }
    }

    private static func setNonBlocking(_ descriptor: Int32, endpoint: String) throws {
        let current = fcntl(descriptor, F_GETFL, 0)
        guard current >= 0, fcntl(descriptor, F_SETFL, current | O_NONBLOCK) == 0 else {
            throw SocketError.connectFailed(endpoint, String(cString: strerror(errno)))
        }
    }

    private static func waitingConnect(_ descriptor: Int32, address: (family: Int32, address: Data), endpoint: String, timeout: TimeInterval) throws {
        let code = address.address.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.connect(descriptor, base.assumingMemoryBound(to: sockaddr.self), socklen_t(address.address.count))
        }
        if code == 0 { return }
        guard errno == EINPROGRESS || errno == EINTR else {
            throw SocketError.connectFailed(endpoint, String(cString: strerror(errno)))
        }
        var events = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let milliseconds = Int32(max(1, timeout * 1000))
        let ready = withUnsafeMutablePointer(to: &events) { poll($0, 1, milliseconds) }
        if ready == 0 { throw SocketError.timeout(endpoint, timeout) }
        guard ready > 0 else {
            if errno == EINTR { throw SocketError.connectFailed(endpoint, "连接被中断，请重试") }
            throw SocketError.connectFailed(endpoint, String(cString: strerror(errno)))
        }
        var pendingError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        if getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &pendingError, &length) != 0 || pendingError != 0 {
            throw SocketError.connectFailed(endpoint, String(cString: strerror(pendingError > 0 ? pendingError : errno)))
        }
    }

    private func waitUntilWritable(deadline: Date) throws {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            throw SocketError.writeFailed("对端长时间未接收数据")
        }
        var events = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let ready = withUnsafeMutablePointer(to: &events) { poll($0, 1, Int32(max(1, remaining * 1000))) }
        if ready == 0 { throw SocketError.writeFailed("对端长时间未接收数据") }
        guard ready > 0 else {
            if errno == EAGAIN || errno == EINTR { return }
            throw SocketError.writeFailed(String(cString: strerror(errno)))
        }
    }
}
