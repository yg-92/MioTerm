import CFreeRDPShim
import Foundation

/// 基于动态加载的 FreeRDP 3.x 客户端，复用桌面帧缓冲与事件模型供图形视图渲染。
public final class RDPClient: @unchecked Sendable {
    public let events: AsyncStream<VNCEvent>
    private let continuation: AsyncStream<VNCEvent>.Continuation

    private let host: String
    private let port: Int
    private let username: String
    private let password: String
    private let domain: String
    public let sharedDirectory: String
    private let initialWidth: Int
    private let initialHeight: Int
    private let initialScalePercent: Int

    public var onClipboardReady: (@Sendable () -> Void)?
    public var onRemoteClipboardChanged: (@Sendable (_ hasText: Bool, _ hasFiles: Bool) -> Void)?

    private let stateLock = NSLock()
    private var session: OpaquePointer?
    private var stopped = false
    private var lastButtonMask: UInt8 = 0

    public init(
        host: String,
        port: Int = 3389,
        username: String = "",
        password: String = "",
        domain: String = "",
        sharedDirectory: String? = nil,
        width: Int = 1280,
        height: Int = 800,
        scalePercent: Int = 100
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.domain = domain
        let defaultDownloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory()
        self.sharedDirectory = sharedDirectory ?? defaultDownloads
        self.initialWidth = width
        self.initialHeight = height
        self.initialScalePercent = scalePercent

        var cont: AsyncStream<VNCEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public func start() {
        let queue = DispatchQueue(label: "com.mio.term.rdp.\(host).\(port)", qos: .userInitiated)
        queue.async { [weak self] in
            self?.runSession()
        }
    }

    public func stop() {
        stateLock.lock()
        let alreadyStopped = stopped
        stopped = true
        stateLock.unlock()

        if !alreadyStopped {
            continuation.finish()
        }
    }

    public func sendPointerEvent(x: Int, y: Int, buttonMask: UInt8) {
        stateLock.lock()
        let activeSession = session
        let previousMask = lastButtonMask
        lastButtonMask = buttonMask
        stateLock.unlock()
        guard let activeSession else { return }

        let clampedX = UInt16(clamping: max(0, x))
        let clampedY = UInt16(clamping: max(0, y))

        // 鼠标滚轮脉冲（VNC buttonMask bit 3=up, 4=down）
        if (buttonMask & (1 << 3)) != 0 && (previousMask & (1 << 3)) == 0 {
            mio_rdp_send_mouse(activeSession, 0x0200 | 0x0078, clampedX, clampedY) // PTR_FLAGS_WHEEL + 120
            return
        }
        if (buttonMask & (1 << 4)) != 0 && (previousMask & (1 << 4)) == 0 {
            mio_rdp_send_mouse(activeSession, 0x0200 | 0x0100 | 0x0078, clampedX, clampedY) // PTR_FLAGS_WHEEL | NEGATIVE
            return
        }

        let changed = buttonMask ^ previousMask
        let buttonMappings: [(UInt8, UInt16)] = [
            (1 << 0, 0x1000), // Left -> PTR_FLAGS_BUTTON1
            (1 << 2, 0x2000), // Right -> PTR_FLAGS_BUTTON2
            (1 << 1, 0x4000), // Middle -> PTR_FLAGS_BUTTON3
        ]

        var sentButton = false
        for (bit, rdpButton) in buttonMappings where (changed & bit) != 0 {
            let isDown = (buttonMask & bit) != 0
            let flags: UInt16 = rdpButton | (isDown ? 0x8000 : 0)
            mio_rdp_send_mouse(activeSession, flags, clampedX, clampedY)
            sentButton = true
        }
        if !sentButton {
            mio_rdp_send_mouse(activeSession, 0x0800, clampedX, clampedY) // PTR_FLAGS_MOVE
        }
    }

    public func sendScancode(_ scancode: UInt32, down: Bool) {
        stateLock.lock()
        let activeSession = session
        stateLock.unlock()
        guard let activeSession else { return }
        mio_rdp_send_key(activeSession, down, scancode)
    }

    public func sendUnicode(_ code: UInt16, down: Bool) {
        stateLock.lock()
        let activeSession = session
        stateLock.unlock()
        guard let activeSession else { return }
        mio_rdp_send_unicode(activeSession, down, code)
    }

    public func requestResize(width: Int, height: Int, scalePercent: Int = 100) {
        stateLock.lock()
        let activeSession = session
        stateLock.unlock()
        guard let activeSession, width >= 200, height >= 200 else { return }
        mio_rdp_resize(activeSession, UInt32(width), UInt32(height), UInt32(max(100, scalePercent)))
    }

    @discardableResult
    public func sendClipboardText(_ text: String) -> Bool {
        stateLock.lock()
        let activeSession = session
        stateLock.unlock()
        guard let activeSession else { return false }
        return text.withCString { ptr in
            mio_rdp_clipboard_send_text(activeSession, ptr)
        }
    }

    @discardableResult
    public func sendClipboardFiles(_ urls: [URL]) -> Bool {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return false }
        stateLock.lock()
        let activeSession = session
        stateLock.unlock()
        guard let activeSession else { return false }
        let uriList = fileURLs.map(\.absoluteString).joined(separator: "\r\n") + "\r\n"
        return uriList.withCString { ptr in
            mio_rdp_clipboard_send_files(activeSession, ptr)
        }
    }

    public func fetchRemoteClipboardText() -> String? {
        stateLock.lock()
        let activeSession = session
        stateLock.unlock()
        guard let activeSession else { return nil }
        guard let ptr = mio_rdp_clipboard_fetch_remote_text(activeSession) else { return nil }
        let text = String(cString: ptr)
        mio_rdp_free_string(ptr)
        return text
    }

    @discardableResult
    public func publishRemoteClipboardFiles() -> Bool {
        stateLock.lock()
        let activeSession = session
        stateLock.unlock()
        guard let activeSession else { return false }
        return mio_rdp_clipboard_publish_remote_files(activeSession)
    }

    // MARK: - 会话循环

    private func runSession() {
        guard FreeRDPAvailability.isInstalled else {
            yieldFailed(L10n.tr(.rdpDependencyMissing, FreeRDPAvailability.installCommand))
            return
        }

        let box = Unmanaged.passRetained(CallbackBox(owner: self))
        var callbacks = MioRdpCallbacks()
        callbacks.on_connected = { userdata, width, height in
            guard let userdata else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(userdata).takeUnretainedValue()
            box.owner?.handleConnected(width: Int(width), height: Int(height))
        }
        callbacks.on_frame = { userdata, ptr, width, height, stride in
            guard let userdata, let ptr else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(userdata).takeUnretainedValue()
            box.owner?.handleFrame(ptr: ptr, width: Int(width), height: Int(height), stride: Int(stride))
        }
        callbacks.on_error = { userdata, msg in
            guard let userdata else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(userdata).takeUnretainedValue()
            let text = msg.map { String(cString: $0) } ?? L10n.tr(.rdpConnectFailed)
            box.owner?.handleError(text)
        }
        callbacks.on_log = { _, msg in
            guard let msg else { return }
            FileLogger.shared.info("RDP: \(String(cString: msg))")
        }
        callbacks.on_clipboard_ready = { userdata in
            guard let userdata else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(userdata).takeUnretainedValue()
            box.owner?.onClipboardReady?()
        }
        callbacks.on_clipboard_formats = { userdata, hasText, hasFiles in
            guard let userdata else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(userdata).takeUnretainedValue()
            box.owner?.onRemoteClipboardChanged?(hasText, hasFiles)
        }

        let created: OpaquePointer? = host.withCString { hostC in
            username.withCString { userC in
                password.withCString { passC in
                    domain.withCString { domainC in
                        sharedDirectory.withCString { sharedC in
                            var config = MioRdpConfig(
                                host: hostC,
                                port: UInt16(clamping: port),
                                username: userC,
                                password: passC,
                                domain: domainC,
                                shared_dir: sharedC,
                                width: UInt32(max(640, initialWidth)),
                                height: UInt32(max(480, initialHeight)),
                                scale_percent: UInt32(max(100, initialScalePercent))
                            )
                            return mio_rdp_create(&config, callbacks, box.toOpaque())
                        }
                    }
                }
            }
        }

        guard let created else {
            box.release()
            yieldFailed(L10n.tr(.rdpConnectFailed))
            return
        }

        stateLock.lock()
        if stopped {
            stateLock.unlock()
            mio_rdp_destroy(created)
            box.release()
            return
        }
        session = created
        stateLock.unlock()

        defer {
            stateLock.lock()
            session = nil
            stateLock.unlock()
            mio_rdp_destroy(created)
            box.release()
        }

        guard mio_rdp_connect(created) else {
            return
        }

        while !isStopped {
            let status = mio_rdp_poll(created, 50)
            if status == 0 {
                if !isStopped {
                    continuation.yield(.closed(reason: nil))
                    stop()
                }
                break
            } else if status < 0 {
                if !isStopped {
                    continuation.yield(.closed(reason: L10n.tr(.rdpConnectFailed)))
                    stop()
                }
                break
            }
        }
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    private func yieldFailed(_ message: String) {
        if !isStopped {
            continuation.yield(.failed(message))
            stop()
        }
    }

    private func handleConnected(width: Int, height: Int) {
        let title = L10n.tr(.rdpDesktopTitle, host)
        continuation.yield(.connected(desktopName: title, width: width, height: height))
        continuation.yield(.frameUpdates([.resize(width: width, height: height)]))
    }

    private func handleFrame(ptr: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int) {
        guard width > 0, height > 0, stride >= width * 4 else { return }
        let rowBytes = width * 4
        var bgra = Data(count: rowBytes * height)
        bgra.withUnsafeMutableBytes { dstRaw in
            guard let dstBase = dstRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            if stride == rowBytes {
                memcpy(dstBase, ptr, rowBytes * height)
            } else {
                for row in 0..<height {
                    memcpy(dstBase + row * rowBytes, ptr + row * stride, rowBytes)
                }
            }
        }
        continuation.yield(.frameUpdates([.rawRect(x: 0, y: 0, width: width, height: height, bgra: bgra)]))
    }

    private func handleError(_ message: String) {
        yieldFailed(message)
    }

    private final class CallbackBox {
        weak var owner: RDPClient?
        init(owner: RDPClient) {
            self.owner = owner
        }
    }
}
