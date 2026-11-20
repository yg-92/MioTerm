import Darwin
import Foundation
import Testing
@testable import MioTermCore

@Suite("VNC 协议与 RFB 客户端")
struct VNCTests {
    @Test("VNC DES 挑战响应加密符合标准 RFB 向量")
    func vncDesStandardVector() {
        // 标准已知向量：空密码（8 个 0x00），全 0 challenge -> DES-ECB(0x00, 0x00) = 8CA64DE9C1B123A7
        let challenge = Data(repeating: 0, count: 16)
        let response = VNCDes.encryptChallenge(challenge, password: "")
        let hex = response.map { String(format: "%02x", $0) }.joined()
        #expect(hex == "8ca64de9c1b123a78ca64de9c1b123a7")

        // 带口令且超过 8 字节时仅取前 8 字节并按位反转
        let r1 = VNCDes.encryptChallenge(challenge, password: "12345678")
        let r2 = VNCDes.encryptChallenge(challenge, password: "1234567890")
        #expect(r1 == r2)
        #expect(r1 != response)
    }

    @Test("VNC 主机配置默认端口与校验规则")
    func vncHostProfileDefaultsAndValidation() throws {
        #expect(ConnectionProtocol.vnc.defaultPort == 5900)
        #expect(!ConnectionProtocol.vnc.supportsSFTP)
        #expect(!ConnectionProtocol.vnc.usesHostKey)

        let raw = HostProfile(
            name: "Win Desktop",
            protocolKind: .vnc,
            address: "192.168.1.20",
            port: 22
        )
        let normalized = raw.normalized()
        #expect(normalized.port == 5900)
        #expect(normalized.subtitle == "192.168.1.20:5900")
        try normalized.validate()

        let missingAddress = HostProfile(name: "NoAddr", protocolKind: .vnc, address: "")
        #expect(throws: HostProfile.ValidationError.addressRequired) {
            try missingAddress.validate()
        }
    }

    @Test("RFBClient 完成 RFB 003.008 握手、认证与帧缓冲更新")
    func rfbClientHandshakeAndFrameUpdates() async throws {
        let server = try MockRFBServer(password: "secret")
        let port = server.port
        let client = RFBClient(host: "127.0.0.1", port: port, password: "secret", connectTimeout: 5)
        client.start()

        var connectedInfo: (String, Int, Int)?
        var receivedUpdates: [VNCFrameUpdate] = []

        for await event in client.events {
            switch event {
            case .connected(let name, let width, let height):
                connectedInfo = (name, width, height)
            case .frameUpdates(let updates):
                receivedUpdates.append(contentsOf: updates)
                if receivedUpdates.count >= 2 {
                    client.stop()
                }
            case .failed(let reason):
                Issue.record("RFBClient failed: \(reason)")
                client.stop()
            case .closed, .bell, .clipboard:
                break
            }
        }
        server.stop()

        #expect(connectedInfo?.0 == "MockDesktop")
        #expect(connectedInfo?.1 == 4)
        #expect(connectedInfo?.2 == 2)
        #expect(receivedUpdates.contains(.rawRect(x: 0, y: 0, width: 2, height: 1, bgra: Data([1, 2, 3, 255, 4, 5, 6, 255]))))
        #expect(receivedUpdates.contains(.resize(width: 8, height: 6)))
    }
}

/// 轻量级本机回环 RFB 003.008 服务端，用于测试握手、DES 认证和矩形解码。
private final class MockRFBServer: @unchecked Sendable {
    let port: Int
    private let listenFD: Int32
    private var acceptThread: Thread?
    private let password: String

    init(password: String) throws {
        self.password = password
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "MockRFB", code: 1) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "MockRFB", code: 2)
        }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &len)
            }
        }
        self.listenFD = fd
        self.port = Int(UInt16(bigEndian: bound.sin_port))

        let thread = Thread { [weak self] in
            self?.serve()
        }
        thread.start()
        self.acceptThread = thread
    }

    func stop() {
        Darwin.close(listenFD)
    }

    private func serve() {
        var clientAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(listenFD, $0, &len)
            }
        }
        guard clientFD >= 0 else { return }
        defer { Darwin.close(clientFD) }

        // 1. 版本握手
        sendAll(clientFD, Data("RFB 003.008\n".utf8))
        _ = readExact(clientFD, 12)

        // 2. 安全类型：仅提供 VNC Auth (2)
        sendAll(clientFD, Data([1, 2]))
        let chosen = readExact(clientFD, 1)
        guard chosen == Data([2]) else { return }

        let challenge = Data((0..<16).map { UInt8($0) })
        sendAll(clientFD, challenge)
        let response = readExact(clientFD, 16)
        let expected = VNCDes.encryptChallenge(challenge, password: password)
        sendAll(clientFD, response == expected ? Data([0, 0, 0, 0]) : Data([0, 0, 0, 1]))
        guard response == expected else { return }

        // 3. ClientInit & ServerInit
        _ = readExact(clientFD, 1)
        let nameBytes = Data("MockDesktop".utf8)
        var serverInit = Data()
        serverInit.append(contentsOf: [0, 4, 0, 2]) // 4x2
        serverInit.append(contentsOf: [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
        serverInit.append(contentsOf: [0, 0, 0, UInt8(nameBytes.count)])
        serverInit.append(nameBytes)
        sendAll(clientFD, serverInit)

        // 4. 读取 SetPixelFormat (20) + SetEncodings (4 + 4*4 = 20) + FramebufferUpdateRequest (10)
        _ = readExact(clientFD, 20)
        _ = readExact(clientFD, 20)
        _ = readExact(clientFD, 10)

        // 5. 发送 FramebufferUpdate：Raw(0) + DesktopSize(-223)
        var update = Data()
        update.append(contentsOf: [0, 0, 0, 2]) // type 0, pad, 2 rects
        // Rect 1: x=0, y=0, w=2, h=1, encoding=0 (Raw)
        update.append(contentsOf: [0, 0, 0, 0, 0, 2, 0, 1, 0, 0, 0, 0])
        update.append(contentsOf: [1, 2, 3, 255, 4, 5, 6, 255])
        // Rect 2: x=0, y=0, w=8, h=6, encoding=-223 (0xFFFFFF21)
        update.append(contentsOf: [0, 0, 0, 0, 0, 8, 0, 6, 0xFF, 0xFF, 0xFF, 0x21])
        sendAll(clientFD, update)
        Thread.sleep(forTimeInterval: 0.2)
    }

    private func sendAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = Darwin.send(fd, base + sent, data.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    private func readExact(_ fd: Int32, _ count: Int) -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { raw in
                Darwin.recv(fd, raw.baseAddress! + offset, count - offset, 0)
            }
            if n <= 0 { break }
            offset += n
        }
        return Data(buffer.prefix(offset))
    }
}
