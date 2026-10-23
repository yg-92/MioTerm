import Foundation
import Testing
@testable import MioTermCore

/// Telnet 客户端的端到端用例，对端是只在本测试进程里监听 127.0.0.1 随机端口的假服务器。
///
/// macOS 早就不带 telnetd，因此这一层能钉死的是“客户端发出的字节对不对、收到的
/// 字节处理对不对”。报文里的控制字节全部写成字面量：这些数字一旦记错，
/// SFTP 那边已经演示过会出现什么灾难（服务端把 RENAME 当 MKDIR）。
struct TelnetStreamTests {
    private let iac: UInt8 = 255
    private let dont: UInt8 = 254
    private let doOption: UInt8 = 253
    private let wont: UInt8 = 252
    private let will: UInt8 = 251
    private let sb: UInt8 = 250
    private let se: UInt8 = 240
    private let echo: UInt8 = 1
    private let naws: UInt8 = 31

    private func makeStream(port: Int, columns: Int = 80, rows: Int = 24) -> TelnetStream {
        TelnetStream(host: "127.0.0.1", port: port, terminalType: "xterm-256color",
                     columns: columns, rows: rows, connectTimeout: 3)
    }

    @Test func handshakesAndFeedsOnlyCleanData() async throws {
        let server = try FakeTelnetServer()
        defer { server.close() }
        server.startAccepting()
        let stream = makeStream(port: server.port)
        let recorder = StreamHarness.record(stream.events)
        await stream.start()
        #expect(await server.waitForClient())

        server.send([iac, will, echo])
        server.send([iac, doOption, naws])
        server.send(Array("Hello\r\n".utf8))

        #expect(await StreamHarness.waitUntil { recorder.received == Data("Hello\r\n".utf8) })
        #expect(recorder.contains(.connected))
        // 协商字节绝不能漏进终端，否则屏幕上会出现乱码方块。
        #expect(!recorder.received.contains(iac))

        #expect(await StreamHarness.waitUntil { server.receivedSnapshot.range(of: Data([iac, doOption, echo])) != nil })
        #expect(await StreamHarness.waitUntil { server.receivedSnapshot.range(of: Data([iac, will, naws])) != nil })
        // 同意 NAWS 的同一批应答里就要报出当前窗口。
        let sawNaws = await StreamHarness.waitUntil {
            server.receivedSnapshot.range(of: Data([iac, sb, naws, 0, 80, 0, 24, iac, se])) != nil
        }
        #expect(sawNaws)
        await stream.close()
    }

    @Test func serverThatRefusesEchoGetsLocalEchoAndAWarning() async throws {
        let server = try FakeTelnetServer()
        defer { server.close() }
        server.startAccepting()
        let stream = makeStream(port: server.port)
        let recorder = StreamHarness.record(stream.events)
        await stream.start()
        #expect(await server.waitForClient())

        server.send([iac, wont, echo])
        #expect(await StreamHarness.waitUntil { !recorder.notices.isEmpty })
        #expect(recorder.notices.first?.contains("本地回显") == true)

        await stream.write(Data("ls\n".utf8))
        // 线上按 NVT 补成 CRLF，屏上把同样的字节显示给用户。
        #expect(await StreamHarness.waitUntil { server.receivedSnapshot == Data("ls\r\n".utf8) })
        #expect(recorder.received == Data("ls\r\n".utf8))
        await stream.close()
    }

    @Test func escapedIACInPayloadReachesTerminalAsOneByte() async throws {
        let server = try FakeTelnetServer()
        defer { server.close() }
        server.startAccepting()
        let stream = makeStream(port: server.port)
        let recorder = StreamHarness.record(stream.events)
        await stream.start()
        #expect(await server.waitForClient())

        server.send([0x41, iac, iac, 0x42])
        #expect(await StreamHarness.waitUntil { recorder.received == Data([0x41, 0xFF, 0x42]) })
        await stream.close()
    }

    @Test func typedTerminalSizeIsReportedOnceNawsIsNegotiated() async throws {
        let server = try FakeTelnetServer()
        defer { server.close() }
        server.startAccepting()
        let stream = makeStream(port: server.port, columns: 80, rows: 24)
        await stream.start()
        #expect(await server.waitForClient())

        server.send([iac, doOption, naws])
        #expect(await StreamHarness.waitUntil { server.receivedSnapshot.contains(Data([iac, sb, naws, 0, 80, 0, 24, iac, se])) })

        await stream.resize(columns: 120, rows: 50)
        #expect(await StreamHarness.waitUntil {
            server.receivedSnapshot.contains(Data([iac, sb, naws, 0, 120, 0, 50, iac, se]))
        })
        await stream.close()
    }

    @Test func peerCloseRaisesClosedAndStopsTheStream() async throws {
        let server = try FakeTelnetServer()
        defer { server.close() }
        server.startAccepting()
        let stream = makeStream(port: server.port)
        let recorder = StreamHarness.record(stream.events)
        await stream.start()
        #expect(await server.waitForClient())

        server.send(Array("bye\r\n".utf8))
        #expect(await StreamHarness.waitUntil { recorder.received == Data("bye\r\n".utf8) })
        server.closeClient()
        #expect(await StreamHarness.waitUntil { recorder.terminalEvent == .closed(reason: nil) })
        await stream.close()
    }

    /// 协商报文畸形不能默默吞掉：设备发错一次就永远等不到应答，界面表现为“卡住”。
    @Test func malformedSubnegotiationFailsTheSessionWithReason() async throws {
        let server = try FakeTelnetServer()
        defer { server.close() }
        server.startAccepting()
        let stream = makeStream(port: server.port)
        let recorder = StreamHarness.record(stream.events)
        await stream.start()
        #expect(await server.waitForClient())

        server.send([iac, sb, naws, 0, 80, 0, 24, iac, 0x41])
        #expect(await StreamHarness.waitUntil {
            if case .failed(let reason) = recorder.terminalEvent { return reason.contains("子协商") }
            return false
        })
        await stream.close()
    }

    @Test func refusedConnectionReportsReadableReason() async throws {
        let port = try StreamHarness.closedLocalPort()
        let stream = makeStream(port: port)
        let recorder = StreamHarness.record(stream.events)
        await stream.start()
        #expect(await StreamHarness.waitUntil {
            if case .failed(let reason) = recorder.terminalEvent { return !reason.isEmpty }
            return false
        })
        if case .failed(let reason) = recorder.terminalEvent {
            #expect(reason.contains("连接") || reason.contains("127.0.0.1"), "错误文案要能定位问题：\(reason)")
        }
        await stream.close()
    }
}

/// 假 Telnet 服务器：一次 accept，之后把客户端字节攒起来供断言。
/// 读循环跑在独立队列上，用阻塞读，因为测试里只需要“有数据就收下”。
final class FakeTelnetServer: @unchecked Sendable {
    let port: Int
    private let listener: Int32
    private let queue = DispatchQueue(label: "mioTermTests.fakeTelnetServer")
    private let lock = NSLock()
    private var client: Int32 = -1
    private var inbox = Data()

    init() throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw StreamHarness.HarnessError(message: "无法创建测试监听套接字") }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
                                  sin_family: UInt8(AF_INET),
                                  sin_port: 0,
                                  sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
                                  sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(descriptor)
            throw StreamHarness.HarnessError(message: "测试监听套接字绑定失败：\(String(cString: strerror(errno)))")
        }
        guard listen(descriptor, 4) == 0 else {
            Darwin.close(descriptor)
            throw StreamHarness.HarnessError(message: "测试监听套接字 listen 失败")
        }
        var name = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &name) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard read == 0 else {
            Darwin.close(descriptor)
            throw StreamHarness.HarnessError(message: "读取测试端口失败")
        }
        listener = descriptor
        port = Int(UInt16(bigEndian: name.sin_port))
    }

    func startAccepting() {
        queue.async {
            let accepted = Darwin.accept(self.listener, nil, nil)
            guard accepted >= 0 else { return }
            self.lock.withLock { self.client = accepted }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(accepted, &buffer, buffer.count)
                if count <= 0 { break }
                let chunk = Data(buffer[0..<count])
                self.lock.withLock { self.inbox.append(chunk) }
            }
            Darwin.close(accepted)
            self.lock.withLock { self.client = -1 }
        }
    }

    var hasClient: Bool { lock.withLock { client >= 0 } }

    var receivedSnapshot: Data { lock.withLock { inbox } }

    func waitForClient(timeout: TimeInterval = 3) async -> Bool {
        await StreamHarness.waitUntil(timeout: timeout) { self.hasClient }
    }

    func send(_ bytes: [UInt8]) {
        let descriptor = lock.withLock { client }
        guard descriptor >= 0 else { return }
        _ = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    }

    /// 模拟对端断开：只关连接，监听套接字留给 close() 统一收拾。
    func closeClient() {
        let descriptor = lock.withLock { client }
        guard descriptor >= 0 else { return }
        shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    func close() {
        closeClient()
        Darwin.close(listener)
    }
}
