import Foundation

/// SFTP 报文的双向字节通道。生产实现是 `ssh -T -s host sftp` 的子进程管道，
/// 测试用内存实现，这样协议逻辑不依赖真实服务器也能跑。
public protocol SFTPTransport: Sendable {
    func start() async throws
    /// 返回 nil 表示对端关闭（EOF），连接层据此判定会话结束。
    func read() async throws -> Data?
    func write(_ data: Data) async throws
    func close() async
}

public enum SFTPTransportError: LocalizedError, Equatable {
    case launchFailed(String)
    case closed

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let detail): return "无法启动 SFTP 通道：\(detail)"
        case .closed: return "SFTP 通道已关闭"
        }
    }
}

/// 走系统 OpenSSH 的 sftp 子系统。加密、认证、主机密钥校验全部复用
/// `SSHLaunchPlanner.sftpLaunch` 的结果，本类只搬运字节。
/// 可变状态都由 `stateLock` 保护，因此 unchecked Sendable 是安全的。
public final class SSHSubsystemTransport: SFTPTransport {
    private let launch: ProcessLaunch
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    /// 读、写、stderr 三条独立队列：每个都可能长时间阻塞在管道读上，
    /// 共用一条串行队列时 stderr 的抽取循环会把读写全部堵死，握手永远等不到。
    /// 写单独一条串行队列，保证 SFTP 报文按提交顺序落进管道。
    private let readQueue = DispatchQueue(label: "com.mio.term.sftp.read", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "com.mio.term.sftp.write", qos: .userInitiated)
    private let errorQueue = DispatchQueue(label: "com.mio.term.sftp.stderr", qos: .utility)
    private let stateLock = NSLock()
    private var stderr = Data()
    private var started = false
    private var finished = false

    public init(launch: ProcessLaunch) {
        self.launch = launch
    }

    /// ssh 退出前的 stderr 文本，用来把 “Connection refused” 这类原因带回 UI。
    public var errorText: String {
        stateLock.withLock { String(decoding: stderr, as: UTF8.self) }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func start() async throws {
        if started { return }
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in launch.environmentDictionary { environment[key] = value }
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] _ in self?.markFinished() }

        // 持续抽干 stderr，否则管道写满会把 ssh 卡住。
        errorQueue.async { [weak self] in
            guard let self else { return }
            let handle = self.errorPipe.fileHandleForReading
            while true {
                guard let chunk = Self.readSome(from: handle, capacity: 4096) else { break }
                self.stateLock.withLock { self.stderr.append(chunk) }
            }
        }

        do {
            try process.run()
            started = true
        } catch {
            throw SFTPTransportError.launchFailed(launch.executable)
        }
    }

    public func read() async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            readQueue.async {
                continuation.resume(returning: Self.readSome(from: self.outputPipe.fileHandleForReading, capacity: 65_536))
            }
        }
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                if self.finished {
                    continuation.resume(throwing: SFTPTransportError.closed)
                    return
                }
                do {
                    try self.inputPipe.fileHandleForWriting.write(contentsOf: data)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: SFTPTransportError.closed)
                }
            }
        }
    }

    public func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // 排在写队列尾部：等在途报文落进管道再收尾。
            writeQueue.async {
                self.finish()
                continuation.resume()
            }
        }
    }

    /// 不等队列、立即执行：应用退出时已经没有机会再 await，
    /// 但 ssh 子进程与 askpass 临时文件必须当场收掉。
    public func terminateNow() {
        finish()
    }

    private func markFinished() {
        stateLock.withLock { finished = true }
    }

    /// FileHandle 的 readData/read(upToCount:) 都要凑满请求长度或遇到 EOF 才返回，
    /// 报文流里零散的回包永远凑不满，只能自己对 fd 调一次 read(2)：有多少拿多少。
    /// 返回 nil 表示 EOF 或句柄已失效。
    private static func readSome(from handle: FileHandle, capacity: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: capacity)
        let descriptor = handle.fileDescriptor
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 { return Data(bytes: buffer, count: count) }
            if count == 0 { return nil }
            if errno == EINTR { continue }
            return nil
        }
    }

    private func finish() {
        stateLock.withLock { finished = true }
        try? inputPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        // 读线程阻塞在 read(2) 上，进程退出后管道给 EOF 就能自己收摊；
        // 在这里关掉正被别的线程读的 fd，句柄号会被复用，之后读到的就是别人的数据。
        AskpassHelper.destroy(fileAt: launch.askpassFile)
    }
}

extension SSHSubsystemTransport: @unchecked Sendable {}
