import Testing
import Foundation
@testable import MioTermCore

/// 子进程通道的读、写、stderr 各自都会长时间阻塞在管道上。
/// 早先把三件事排在同一条串行队列上，stderr 的抽取循环把队列永久占住，
/// 握手报文永远写不出去，真实 ssh 连上后面板只能一直停在“正在打开文件通道”。
struct SSHSubsystemTransportTests {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    @Test func writeCompletesWhileStderrDrainLoopIsBlocked() async throws {
        // cat 不写 stderr 也不退出，抽取循环会一直卡在读取上，正是当初堵死队列的场景。
        let launch = ProcessLaunch(executable: "/bin/cat", arguments: [], environment: ["LANG=en_US.UTF-8"])
        let transport = SSHSubsystemTransport(launch: launch)
        try await transport.start()
        defer { transport.terminateNow() }

        let written = Flag()
        let writeTask = Task {
            try? await transport.write(Data("mioterm".utf8))
            written.set()
        }
        for _ in 0..<50 where !written.isSet {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(written.isSet, "写操作被 stderr 抽取循环堵在队列里")
        writeTask.cancel()
    }

    @Test func readEchoesWhatWriteSent() async throws {
        let launch = ProcessLaunch(executable: "/bin/cat", arguments: [], environment: ["LANG=en_US.UTF-8"])
        let transport = SSHSubsystemTransport(launch: launch)
        try await transport.start()
        defer { transport.terminateNow() }

        let payload = Data("handshake".utf8)
        try await transport.write(payload)
        var received = Data()
        for _ in 0..<50 where received.count < payload.count {
            guard let chunk = try await transport.read() else { break }
            received.append(chunk)
        }
        #expect(received == payload)
    }
}
