import Foundation
@testable import MioTermCore

/// 字节流会话（Telnet、串口）测试共用的脚手架。
///
/// 这两类连接都是“后台队列 + 事件流”的形态，测试没法直接 await 出结果，
/// 只能收集事件再轮询快照，所以收集器与轮询只留一份。
enum StreamHarness {
    struct HarnessError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 轮询到条件成立为止；超时不抛错，把最后的快照交给调用方断言，
    /// 失败信息里能看到实际收到了什么。
    static func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    /// 起一个任务把事件流收干净，测试结束时由调用方 cancel。
    static func record(_ stream: AsyncStream<StreamEvent>) -> Recorder {
        let recorder = Recorder()
        Task {
            for await event in stream {
                recorder.append(event)
            }
        }
        return recorder
    }

    /// 找一个刚释放的本地端口：连接它一定拿到 ECONNREFUSED，
    /// 比依赖外网或固定端口稳。
    static func closedLocalPort() throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw HarnessError(message: "无法创建测试套接字") }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
                                  sin_family: UInt8(AF_INET),
                                  sin_port: in_port_t(0).bigEndian,
                                  sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
                                  sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw HarnessError(message: "测试套接字绑定失败：\(String(cString: strerror(errno)))") }
        var name = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &name) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard read == 0 else { throw HarnessError(message: "读取测试端口失败") }
        return Int(UInt16(bigEndian: name.sin_port))
    }

    /// 事件流快照收集器。
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [StreamEvent] = []

        func append(_ event: StreamEvent) {
            lock.withLock { storage.append(event) }
        }

        var all: [StreamEvent] { lock.withLock { storage } }

        /// 所有净负载按到达顺序拼起来，就是终端应当看到的内容。
        var received: Data {
            var bytes = Data()
            for event in all {
                if case .data(let chunk) = event { bytes.append(chunk) }
            }
            return bytes
        }

        var notices: [String] {
            all.compactMap { event in
                guard case .notice(let text) = event else { return nil }
                return text
            }
        }

        var terminalEvent: StreamEvent? {
            all.first { event in
                switch event {
                case .closed, .failed: return true
                default: return false
                }
            }
        }

        func contains(_ event: StreamEvent) -> Bool { all.contains { $0 == event } }
    }
}
