import Foundation
import zlib

/// VNC 帧更新与会话事件，供图形桌面控制器订阅。
public enum VNCFrameUpdate: Equatable, Sendable {
    case resize(width: Int, height: Int)
    case rawRect(x: Int, y: Int, width: Int, height: Int, bgra: Data)
    case copyRect(x: Int, y: Int, width: Int, height: Int, srcX: Int, srcY: Int)
}

public enum VNCEvent: Sendable {
    case connected(desktopName: String, width: Int, height: Int)
    case frameUpdates([VNCFrameUpdate])
    case clipboard(String)
    case bell
    case closed(reason: String?)
    case failed(String)
}

public enum RFBError: LocalizedError, Equatable {
    case invalidHandshake
    case unsupportedSecurity(String)
    case passwordRequired
    case authenticationFailed(String)
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHandshake:
            return L10n.tr(.vncHandshakeFailed)
        case .unsupportedSecurity(let detail):
            return L10n.tr(.vncUnsupportedAuth, detail)
        case .passwordRequired:
            return L10n.tr(.vncPasswordRequired)
        case .authenticationFailed(let reason):
            return L10n.tr(.vncAuthFailed, reason)
        case .protocolError(let detail):
            return L10n.tr(.vncProtocolError, detail)
        }
    }
}

/// 纯 Swift 实现的 RFB（VNC）客户端：
/// 支持 RFB 3.3 / 3.7 / 3.8 握手、None 与 VNC DES 认证，
/// 以及 Raw(0)、CopyRect(1)、Zlib(6)、DesktopSize(-223) 编码。
public final class RFBClient: @unchecked Sendable {
    public let events: AsyncStream<VNCEvent>
    private let continuation: AsyncStream<VNCEvent>.Continuation

    private let host: String
    private let port: Int
    private let password: String?
    private let connectTimeout: TimeInterval

    private let writeLock = NSLock()
    private var socket: TCPSocket?
    private var receiveBuffer = Data()
    private var zlibStream = z_stream()
    private var zlibInitialized = false
    private var stopped = false

    private var framebufferWidth = 0
    private var framebufferHeight = 0

    public init(
        host: String,
        port: Int = 5900,
        password: String? = nil,
        connectTimeout: TimeInterval = 10
    ) {
        self.host = host
        self.port = port
        self.password = password
        self.connectTimeout = connectTimeout
        var cont: AsyncStream<VNCEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    deinit {
        if zlibInitialized {
            inflateEnd(&zlibStream)
        }
    }

    public func start() {
        let queue = DispatchQueue(label: "com.mio.term.rfb.\(host).\(port)", qos: .userInitiated)
        queue.async { [weak self] in
            self?.runSession()
        }
    }

    public func stop() {
        writeLock.lock()
        let alreadyStopped = stopped
        stopped = true
        let sock = socket
        socket = nil
        writeLock.unlock()

        if !alreadyStopped {
            sock?.close()
            continuation.finish()
        }
    }

    public func sendPointerEvent(x: Int, y: Int, buttonMask: UInt8) {
        let clampedX = UInt16(clamping: max(0, x))
        let clampedY = UInt16(clamping: max(0, y))
        var packet = Data(capacity: 6)
        packet.append(5) // PointerEvent
        packet.append(buttonMask)
        appendUInt16(&packet, clampedX)
        appendUInt16(&packet, clampedY)
        sendRaw(packet)
    }

    public func sendKeyEvent(keysym: UInt32, down: Bool) {
        var packet = Data(capacity: 8)
        packet.append(4) // KeyEvent
        packet.append(down ? 1 : 0)
        packet.append(contentsOf: [0, 0])
        appendUInt32(&packet, keysym)
        sendRaw(packet)
    }

    public func sendClientCutText(_ text: String) {
        let bytes = Data(text.utf8)
        var packet = Data(capacity: 8 + bytes.count)
        packet.append(6) // ClientCutText
        packet.append(contentsOf: [0, 0, 0])
        appendUInt32(&packet, UInt32(bytes.count))
        packet.append(bytes)
        sendRaw(packet)
    }

    public func requestFramebufferUpdate(incremental: Bool) {
        requestFramebufferUpdate(
            incremental: incremental,
            x: 0,
            y: 0,
            width: framebufferWidth,
            height: framebufferHeight
        )
    }

    private func requestFramebufferUpdate(incremental: Bool, x: Int, y: Int, width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        var packet = Data(capacity: 10)
        packet.append(3) // FramebufferUpdateRequest
        packet.append(incremental ? 1 : 0)
        appendUInt16(&packet, UInt16(clamping: x))
        appendUInt16(&packet, UInt16(clamping: y))
        appendUInt16(&packet, UInt16(clamping: width))
        appendUInt16(&packet, UInt16(clamping: height))
        sendRaw(packet)
    }

    // MARK: - 会话主循环

    private func runSession() {
        do {
            let conn = try TCPSocket.connect(host: host, port: port, timeout: connectTimeout)
            writeLock.lock()
            if stopped {
                writeLock.unlock()
                conn.close()
                return
            }
            socket = conn
            writeLock.unlock()

            let minorVersion = try negotiateVersion()
            try authenticate(minorVersion: minorVersion)

            // ClientInit: shared = 1，允许与其他客户端共存。
            try writeAll(Data([1]))

            let serverInit = try readServerInit()
            framebufferWidth = serverInit.width
            framebufferHeight = serverInit.height

            try sendPixelFormatBGRA32()
            try sendSupportedEncodings()
            initZlib()

            continuation.yield(.connected(
                desktopName: serverInit.name,
                width: serverInit.width,
                height: serverInit.height
            ))

            requestFramebufferUpdate(incremental: false)
            try readServerMessagesLoop()
            finishClosed(reason: nil)
        } catch is CancellationError {
            finishClosed(reason: nil)
        } catch {
            if !isStopped {
                continuation.yield(.failed(error.localizedDescription))
                stop()
            }
        }
    }

    private var isStopped: Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        return stopped
    }

    private func finishClosed(reason: String?) {
        if !isStopped {
            continuation.yield(.closed(reason: reason))
            stop()
        }
    }

    // MARK: - 握手与认证

    private func negotiateVersion() throws -> Int {
        let banner = try readExact(12)
        guard let text = String(data: banner, encoding: .ascii),
              text.hasPrefix("RFB "), text.count == 12 else {
            throw RFBError.invalidHandshake
        }
        let minor = Int(text.dropFirst(8).prefix(3)) ?? 8
        let negotiatedMinor = min(max(minor, 3), 8)
        let reply = String(format: "RFB 003.%03d\n", negotiatedMinor)
        try writeAll(Data(reply.utf8))
        return negotiatedMinor
    }

    private func authenticate(minorVersion: Int) throws {
        let chosenType: UInt8
        if minorVersion >= 7 {
            let count = Int(try readUInt8())
            if count == 0 {
                let reason = try readReasonString()
                throw RFBError.authenticationFailed(reason)
            }
            let types = try readExact(count)
            if types.contains(2) && !(password ?? "").isEmpty {
                chosenType = 2
            } else if types.contains(1) {
                chosenType = 1
            } else if types.contains(2) {
                throw RFBError.passwordRequired
            } else {
                let names = types.map { String($0) }.joined(separator: ", ")
                throw RFBError.unsupportedSecurity(names)
            }
            try writeAll(Data([chosenType]))
        } else {
            let rawType = try readUInt32()
            if rawType == 0 {
                let reason = try readReasonString()
                throw RFBError.authenticationFailed(reason)
            }
            if rawType == 1 {
                chosenType = 1
            } else if rawType == 2 {
                guard !(password ?? "").isEmpty else { throw RFBError.passwordRequired }
                chosenType = 2
            } else {
                throw RFBError.unsupportedSecurity("\(rawType)")
            }
        }

        if chosenType == 2 {
            let challenge = try readExact(16)
            let response = VNCDes.encryptChallenge(challenge, password: password ?? "")
            try writeAll(response)
        }

        if chosenType != 1 || minorVersion >= 8 {
            let result = try readUInt32()
            if result != 0 {
                let reason = minorVersion >= 8 ? try readReasonString() : L10n.tr(.vncAuthInvalid)
                throw RFBError.authenticationFailed(reason)
            }
        }
    }

    private func readReasonString() throws -> String {
        let length = Int(try readUInt32())
        guard length > 0, length <= 4096 else { return L10n.tr(.vncAuthInvalid) }
        let bytes = try readExact(length)
        return String(data: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
    }

    private func readServerInit() throws -> (width: Int, height: Int, name: String) {
        let header = try readExact(24)
        let width = Int(readUInt16(from: header, offset: 0))
        let height = Int(readUInt16(from: header, offset: 2))
        let nameLength = Int(readUInt32(from: header, offset: 20))
        let safeLength = min(max(nameLength, 0), 4096)
        let nameData = safeLength > 0 ? try readExact(safeLength) : Data()
        let name = String(data: nameData, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) ?? host
        return (max(1, width), max(1, height), name.isEmpty ? host : name)
    }

    private func sendPixelFormatBGRA32() throws {
        // 统一让服务端发小端 32-bit BGRA，直接匹配 macOS CGImage (byteOrder32Little + premultipliedFirst)。
        var packet = Data(capacity: 20)
        packet.append(0) // SetPixelFormat
        packet.append(contentsOf: [0, 0, 0])
        packet.append(32) // bits-per-pixel
        packet.append(24) // depth
        packet.append(0)  // big-endian-flag = 0 (little endian)
        packet.append(1)  // true-colour-flag = 1
        appendUInt16(&packet, 255) // red-max
        appendUInt16(&packet, 255) // green-max
        appendUInt16(&packet, 255) // blue-max
        packet.append(16) // red-shift
        packet.append(8)  // green-shift
        packet.append(0)  // blue-shift
        packet.append(contentsOf: [0, 0, 0])
        try writeAll(packet)
    }

    private func sendSupportedEncodings() throws {
        // 优先 Zlib(6) -> CopyRect(1) -> Raw(0) -> DesktopSize(-223)
        let encodings: [Int32] = [6, 1, 0, -223]
        var packet = Data(capacity: 4 + encodings.count * 4)
        packet.append(2) // SetEncodings
        packet.append(0)
        appendUInt16(&packet, UInt16(encodings.count))
        for enc in encodings {
            appendUInt32(&packet, UInt32(bitPattern: enc))
        }
        try writeAll(packet)
    }

    // MARK: - 服务端消息循环

    private func readServerMessagesLoop() throws {
        while !isStopped {
            let msgType = try readUInt8()
            switch msgType {
            case 0: // FramebufferUpdate
                _ = try readUInt8() // padding
                let rectCount = Int(try readUInt16())
                var updates: [VNCFrameUpdate] = []
                updates.reserveCapacity(rectCount)
                for _ in 0..<rectCount {
                    if let update = try readFramebufferRectangle() {
                        updates.append(update)
                    }
                }
                if !updates.isEmpty {
                    continuation.yield(.frameUpdates(updates))
                }
                requestFramebufferUpdate(incremental: true)

            case 1: // SetColourMapEntries
                _ = try readUInt8()
                _ = try readUInt16()
                let count = Int(try readUInt16())
                _ = try readExact(count * 6)

            case 2: // Bell
                continuation.yield(.bell)

            case 3: // ServerCutText
                _ = try readExact(3)
                let length = Int(try readUInt32())
                let capped = min(max(length, 0), 1024 * 1024)
                let data = capped > 0 ? try readExact(capped) : Data()
                if length > capped {
                    _ = try readExact(length - capped)
                }
                if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                    continuation.yield(.clipboard(text))
                }

            default:
                throw RFBError.protocolError("Unknown message type \(msgType)")
            }
        }
    }

    private func readFramebufferRectangle() throws -> VNCFrameUpdate? {
        let header = try readExact(12)
        let x = Int(readUInt16(from: header, offset: 0))
        let y = Int(readUInt16(from: header, offset: 2))
        let width = Int(readUInt16(from: header, offset: 4))
        let height = Int(readUInt16(from: header, offset: 6))
        let encoding = Int32(bitPattern: readUInt32(from: header, offset: 8))

        switch encoding {
        case 0: // Raw
            let byteCount = width * height * 4
            let data = byteCount > 0 ? try readExact(byteCount) : Data()
            return .rawRect(x: x, y: y, width: width, height: height, bgra: data)

        case 1: // CopyRect
            let src = try readExact(4)
            let srcX = Int(readUInt16(from: src, offset: 0))
            let srcY = Int(readUInt16(from: src, offset: 2))
            return .copyRect(x: x, y: y, width: width, height: height, srcX: srcX, srcY: srcY)

        case 6: // Zlib
            let compressedLength = Int(try readUInt32())
            let compressed = compressedLength > 0 ? try readExact(compressedLength) : Data()
            let expectedBytes = width * height * 4
            let decompressed = try inflateZlib(compressed, expectedSize: expectedBytes)
            return .rawRect(x: x, y: y, width: width, height: height, bgra: decompressed)

        case -223: // DesktopSize pseudo-encoding
            framebufferWidth = max(1, width)
            framebufferHeight = max(1, height)
            return .resize(width: framebufferWidth, height: framebufferHeight)

        default:
            throw RFBError.protocolError("Unsupported encoding \(encoding)")
        }
    }

    // MARK: - Zlib 流解压

    private func initZlib() {
        zlibStream = z_stream()
        let status = inflateInit_(&zlibStream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        zlibInitialized = (status == Z_OK)
    }

    private func inflateZlib(_ compressed: Data, expectedSize: Int) throws -> Data {
        guard zlibInitialized, expectedSize > 0 else { return Data(count: expectedSize) }
        var output = [UInt8](repeating: 0, count: expectedSize)
        var outProduced = 0
        try compressed.withUnsafeBytes { inRaw in
            guard let inBase = inRaw.bindMemory(to: Bytef.self).baseAddress else { return }
            zlibStream.next_in = UnsafeMutablePointer(mutating: inBase)
            zlibStream.avail_in = uInt(compressed.count)

            try output.withUnsafeMutableBytes { outRaw in
                guard let outBase = outRaw.bindMemory(to: Bytef.self).baseAddress else { return }
                zlibStream.next_out = outBase
                zlibStream.avail_out = uInt(expectedSize)
                let rc = inflate(&zlibStream, Z_SYNC_FLUSH)
                if rc != Z_OK && rc != Z_STREAM_END {
                    throw RFBError.protocolError("zlib inflate failed (\(rc))")
                }
                outProduced = expectedSize - Int(zlibStream.avail_out)
            }
        }
        return Data(output.prefix(outProduced))
    }

    // MARK: - 底层 Socket 读写

    private func sendRaw(_ data: Data) {
        try? writeAll(data)
    }

    private func writeAll(_ data: Data) throws {
        writeLock.lock()
        let sock = socket
        writeLock.unlock()
        guard let sock else { throw RFBError.protocolError("Socket closed") }
        try sock.write(data)
    }

    private func readExact(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        while receiveBuffer.count < count {
            if isStopped { throw CancellationError() }
            writeLock.lock()
            let sock = socket
            writeLock.unlock()
            guard let sock else { throw RFBError.protocolError("Connection closed") }
            switch try sock.read(maximumCount: max(65_536, count - receiveBuffer.count)) {
            case .bytes(let chunk):
                receiveBuffer.append(chunk)
            case .wouldBlock:
                Thread.sleep(forTimeInterval: 0.005)
            case .ended:
                throw RFBError.protocolError("EOF")
            }
        }
        let result = receiveBuffer.prefix(count)
        receiveBuffer.removeFirst(count)
        return Data(result)
    }

    private func readUInt8() throws -> UInt8 {
        try readExact(1)[0]
    }

    private func readUInt16() throws -> UInt16 {
        let data = try readExact(2)
        return readUInt16(from: data, offset: 0)
    }

    private func readUInt32() throws -> UInt32 {
        let data = try readExact(4)
        return readUInt32(from: data, offset: 0)
    }

    private func readUInt16(from data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private func readUInt32(from data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }

    private func appendUInt16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}
