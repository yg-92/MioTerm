import Foundation

/// 一次性外部命令执行（ssh-keyscan、ssh-keygen 这类）。终端会话走
/// SwiftTerm 的 PTY，不用这里的通道。
public struct ProcessRunner {
    public struct Executed: Sendable {
        public let exitStatus: Int32
        public let standardOutput: Data
        public let standardError: Data

        public init(exitStatus: Int32, standardOutput: Data, standardError: Data) {
            self.exitStatus = exitStatus
            self.standardOutput = standardOutput
            self.standardError = standardError
        }

        public var succeeded: Bool { exitStatus == 0 }
        public var outputText: String { String(decoding: standardOutput, as: UTF8.self) }
        public var errorText: String { String(decoding: standardError, as: UTF8.self) }
    }

    public enum RunnerError: LocalizedError, Equatable {
        case launchFailed(String)
        case timedOut(String)

        public var errorDescription: String? {
            switch self {
            case .launchFailed(let name): return "无法启动 \(name)"
            case .timedOut(let name): return "\(name) 执行超时"
            }
        }
    }

    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        standardInput: Data? = nil,
        timeout: TimeInterval = 15
    ) async throws -> Executed {
        let name = (executable as NSString).lastPathComponent
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Executed, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let environment {
                var base = ProcessInfo.processInfo.environment
                for (key, value) in environment { base[key] = value }
                process.environment = base
            }

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            let state = CollectorState()
            let resumed = OnceFlag()

            // 读端到 EOF：进程退出时写入端关闭，这两个调用自然返回，
            // 不会像 readabilityHandler 那样在收尾窗口丢数据。
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                state.setOutput((try? outputPipe.fileHandleForReading.readToEnd()) ?? Data())
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                state.setError((try? errorPipe.fileHandleForReading.readToEnd()) ?? Data())
                group.leave()
            }

            let settle: @Sendable (Result<Executed, Error>) -> Void = { outcome in
                guard resumed.set() else { return }
                group.notify(queue: .global()) {
                    switch outcome {
                    case .success(let value): continuation.resume(returning: value)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }

            let timeoutWork = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                    settle(.failure(RunnerError.timedOut(name)))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)

            process.terminationHandler = { finished in
                timeoutWork.cancel()
                settle(.success(Executed(
                    exitStatus: finished.terminationStatus,
                    standardOutput: state.takeOutput(),
                    standardError: state.takeError()
                )))
            }

            if let standardInput {
                let inputPipe = Pipe()
                process.standardInput = inputPipe
                DispatchQueue.global().async {
                    inputPipe.fileHandleForWriting.write(standardInput)
                    try? inputPipe.fileHandleForWriting.close()
                }
            }

            do {
                try process.run()
            } catch {
                timeoutWork.cancel()
                settle(.failure(RunnerError.launchFailed(name)))
            }
        }
    }
}

/// 线程安全的输出累积；take 之后仍可重复读取，由 OnceFlag 保证只恢复一次续体。
private final class CollectorState: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var error = Data()

    func setOutput(_ data: Data) { lock.withLock { output = data } }
    func setError(_ data: Data) { lock.withLock { error = data } }
    func takeOutput() -> Data { lock.withLock { output } }
    func takeError() -> Data { lock.withLock { error } }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func set() -> Bool {
        lock.withLock {
            if used { return false }
            used = true
            return true
        }
    }
}
