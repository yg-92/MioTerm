import CFreeRDPShim
import Foundation
import IOSurface

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
    private let enableAudio: Bool

    public var onClipboardReady: (@Sendable () -> Void)?
    public var onRemoteClipboardChanged: (@Sendable (_ hasText: Bool, _ hasFiles: Bool) -> Void)?
    public var onClipboardDownloadProgress: (@Sendable (_ downloadedBytes: UInt64, _ totalBytes: UInt64) -> Void)?
    public var onFrameReady: (@Sendable () -> Void)?

    private let stateLock = NSLock()
    private let clipboardSendQueue = DispatchQueue(label: "com.mio.term.rdp.clipboard-send", qos: .userInitiated)
    private var session: OpaquePointer?
    private var stopped = false
    private var lastButtonMask: UInt8 = 0
    private var lastPointerMoveTime: TimeInterval = 0
    private var captureConnectError = false
    private var capturedConnectError: String?
    private var latestSurface: IOSurfaceRef?
    private var latestSurfaceSize: (width: Int, height: Int) = (0, 0)
    private var frameNotificationScheduled = false

    public init(
        host: String,
        port: Int = 3389,
        username: String = "",
        password: String = "",
        domain: String = "",
        sharedDirectory: String? = nil,
        width: Int = 1280,
        height: Int = 800,
        scalePercent: Int = 100,
        enableAudio: Bool = false
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
        self.enableAudio = enableAudio

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
        latestSurface = nil
        latestSurfaceSize = (0, 0)
        stateLock.unlock()

        if !alreadyStopped {
            continuation.finish()
        }
    }

    public func sendPointerEvent(x: Int, y: Int, buttonMask: UInt8) {
        stateLock.lock()
        let activeSession = session
        let previousMask = lastButtonMask
        let now = ProcessInfo.processInfo.systemUptime
        // 纯移动/拖动事件按 ~100Hz 节流，避免高刷鼠标/触控板向旧版 Windows 狂发坐标导致窗口重绘堆积；按键与滚轮不节流。
        let isPureMove = (buttonMask == previousMask) && ((buttonMask & 0x78) == 0)
        if isPureMove && (now - lastPointerMoveTime) < 0.010 {
            stateLock.unlock()
            return
        }
        lastPointerMoveTime = now
        lastButtonMask = buttonMask
        stateLock.unlock()
        guard let activeSession else { return }

        let clampedX = UInt16(clamping: max(0, x))
        let clampedY = UInt16(clamping: max(0, y))

        // 鼠标滚轮脉冲（VNC buttonMask bit 3=上, 4=下, 5=左, 6=右）
        // [MS-RDPBCGR] 2.2.8.1.1.3.1.1.3：WheelRotationMask(0x01FF) 为 9 位补码，+120 = 0x0078，-120 = 0x0188。
        if (buttonMask & (1 << 3)) != 0 && (previousMask & (1 << 3)) == 0 {
            mio_rdp_send_mouse(activeSession, 0x0200 | 0x0078, clampedX, clampedY) // PTR_FLAGS_WHEEL (+120)
            return
        }
        if (buttonMask & (1 << 4)) != 0 && (previousMask & (1 << 4)) == 0 {
            mio_rdp_send_mouse(activeSession, 0x0200 | 0x0188, clampedX, clampedY) // PTR_FLAGS_WHEEL (-120)
            return
        }
        if (buttonMask & (1 << 5)) != 0 && (previousMask & (1 << 5)) == 0 {
            mio_rdp_send_mouse(activeSession, 0x0400 | 0x0188, clampedX, clampedY) // PTR_FLAGS_HWHEEL (-120, 左滚)
            return
        }
        if (buttonMask & (1 << 6)) != 0 && (previousMask & (1 << 6)) == 0 {
            mio_rdp_send_mouse(activeSession, 0x0400 | 0x0078, clampedX, clampedY) // PTR_FLAGS_HWHEEL (+120, 右滚)
            return
        }
        // 滚轮脉冲的复位事件不需要再补发一次鼠标移动。
        if (previousMask & 0x78) != 0 && (buttonMask & 0x78) == 0 && (buttonMask & 0x07) == (previousMask & 0x07) {
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

    public var supportsDynamicResize: Bool {
        stateLock.lock()
        let activeSession = session
        stateLock.unlock()
        guard let activeSession else { return false }
        return mio_rdp_supports_dynamic_resize(activeSession)
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
        let resolvedURLs = urls
            .filter(\.isFileURL)
            .map { URL(fileURLWithPath: $0.standardizedFileURL.path, isDirectory: false) }
        guard !resolvedURLs.isEmpty else { return false }
        stateLock.lock()
        let activeSession = session
        stateLock.unlock()
        guard let activeSession else { return false }
        let uriList = resolvedURLs.map(\.absoluteString).joined(separator: "\r\n") + "\r\n"
        return uriList.withCString { ptr in
            mio_rdp_clipboard_send_files(activeSession, ptr)
        }
    }

    public func sendClipboardTextAsync(_ text: String) {
        clipboardSendQueue.async { [weak self] in
            _ = self?.sendClipboardText(text)
        }
    }

    public func sendClipboardFilesAsync(_ urls: [URL], completion: (@Sendable (Bool) -> Void)? = nil) {
        clipboardSendQueue.async { [weak self] in
            let ok = self?.sendClipboardFiles(urls) ?? false
            completion?(ok)
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

    public struct RemoteClipboardFileSummary: Sendable {
        public let names: [String]
        public let generation: UInt64
        public let totalBytes: UInt64
    }

    public func listRemoteClipboardFiles() -> RemoteClipboardFileSummary? {
        stateLock.lock()
        let activeSession = session
        stateLock.unlock()
        guard let activeSession else { return nil }
        var generation: UInt64 = 0
        var totalBytes: UInt64 = 0
        guard let ptr = mio_rdp_clipboard_list_remote_files(activeSession, &generation, &totalBytes) else {
            return nil
        }
        let raw = String(cString: ptr)
        mio_rdp_free_string(ptr)
        let names = raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard !names.isEmpty else { return nil }
        return RemoteClipboardFileSummary(names: names, generation: generation, totalBytes: totalBytes)
    }

    public func cancelRemoteClipboardDownload() {
        stateLock.lock()
        let activeSession = session
        stateLock.unlock()
        guard let activeSession else { return }
        mio_rdp_clipboard_cancel_download(activeSession)
    }

    public func downloadRemoteClipboardFiles(
        to directory: URL,
        maxTotalBytes: UInt64 = 0
    ) -> [URL] {
        stateLock.lock()
        let activeSession = session
        stateLock.unlock()
        guard let activeSession else { return [] }
        guard let ptr = directory.path.withCString({ dirC in
            mio_rdp_clipboard_download_remote_files(activeSession, dirC, maxTotalBytes)
        }) else {
            return []
        }
        let raw = String(cString: ptr)
        mio_rdp_free_string(ptr)
        return raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0), isDirectory: false) }
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
        callbacks.on_clipboard_download_progress = { userdata, downloadedBytes, totalBytes in
            guard let userdata else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(userdata).takeUnretainedValue()
            box.owner?.onClipboardDownloadProgress?(downloadedBytes, totalBytes)
        }

        func createSession(disableNLA: Bool) -> OpaquePointer? {
            host.withCString { hostC in
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
                                    scale_percent: UInt32(max(100, initialScalePercent)),
                                    disable_nla: disableNLA,
                                    enable_audio: enableAudio
                                )
                                return mio_rdp_create(&config, callbacks, box.toOpaque())
                            }
                        }
                    }
                }
            }
        }

        var activeSession: OpaquePointer?
        defer {
            stateLock.lock()
            let toDestroy = activeSession
            session = nil
            latestSurface = nil
            latestSurfaceSize = (0, 0)
            stateLock.unlock()
            if let toDestroy {
                mio_rdp_disconnect(toDestroy)
                mio_rdp_destroy(toDestroy)
            }
            box.release()
        }

        guard let first = createSession(disableNLA: false) else {
            yieldFailed(L10n.tr(.rdpConnectFailed))
            return
        }

        stateLock.lock()
        if stopped {
            stateLock.unlock()
            mio_rdp_destroy(first)
            return
        }
        activeSession = first
        session = first
        captureConnectError = true
        capturedConnectError = nil
        stateLock.unlock()

        if !mio_rdp_connect(first) {
            stateLock.lock()
            let firstError = capturedConnectError
            let wasStopped = stopped
            captureConnectError = false
            capturedConnectError = nil
            session = nil
            activeSession = nil
            stateLock.unlock()
            mio_rdp_destroy(first)

            guard !wasStopped else { return }

            // 部分旧版 Windows 或密码已过期主机在 NLA(CredSSP) 阶段会直接报错，
            // 自动关闭 NLA 回退至 TLS/RDP 协商重试一次（与 Windows App 行为一致）。
            let shouldFallbackNoNLA: Bool = {
                guard let err = firstError?.lowercased() else { return true }
                if err.contains("unable to connect") || err.contains("dns") || err.contains("refused") {
                    return false
                }
                return true
            }()

            guard shouldFallbackNoNLA, let fallback = createSession(disableNLA: true) else {
                yieldFailed(firstError ?? L10n.tr(.rdpConnectFailed))
                return
            }

            FileLogger.shared.info("RDP (\(host):\(port)): NLA 连接失败（\(firstError ?? "unknown")），自动回退 TLS/RDP 重试")

            stateLock.lock()
            if stopped {
                stateLock.unlock()
                mio_rdp_destroy(fallback)
                return
            }
            activeSession = fallback
            session = fallback
            stateLock.unlock()

            guard mio_rdp_connect(fallback) else {
                return
            }
        } else {
            stateLock.lock()
            captureConnectError = false
            capturedConnectError = nil
            stateLock.unlock()
        }

        guard let connectedSession = activeSession else { return }

        while !isStopped {
            let status = mio_rdp_poll(connectedSession, 16)
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
        FileLogger.shared.error("RDP (\(host):\(port)): \(message)")
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

    public func takeLatestSurface() -> (surface: IOSurfaceRef, width: Int, height: Int)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        frameNotificationScheduled = false
        guard let surface = latestSurface, latestSurfaceSize.width > 0, latestSurfaceSize.height > 0 else {
            return nil
        }
        return (surface, latestSurfaceSize.width, latestSurfaceSize.height)
    }

    private func handleFrame(ptr: UnsafePointer<UInt8>, width: Int, height: Int, stride: Int) {
        guard width > 0, height > 0, stride >= width * 4 else { return }
        let rowBytes = width * 4

        if let onFrameReady {
            stateLock.lock()
            guard !stopped else {
                stateLock.unlock()
                return
            }
            let surface: IOSurfaceRef
            if let existing = latestSurface, latestSurfaceSize.width == width, latestSurfaceSize.height == height {
                surface = existing
            } else {
                let bytesPerRow = (rowBytes + 15) & ~15
                let props: [CFString: Any] = [
                    kIOSurfaceWidth: width,
                    kIOSurfaceHeight: height,
                    kIOSurfaceBytesPerElement: 4,
                    kIOSurfaceBytesPerRow: bytesPerRow,
                    kIOSurfaceAllocSize: bytesPerRow * height,
                    kIOSurfacePixelFormat: UInt32(0x42475241), // 'BGRA'
                ]
                guard let created = IOSurfaceCreate(props as CFDictionary) else {
                    stateLock.unlock()
                    return
                }
                latestSurface = created
                latestSurfaceSize = (width, height)
                surface = created
            }

            IOSurfaceLock(surface, [], nil)
            let dstBase = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
            let dstStride = IOSurfaceGetBytesPerRow(surface)
            if stride == dstStride {
                memcpy(dstBase, ptr, dstStride * height)
            } else {
                for row in 0..<height {
                    memcpy(dstBase + row * dstStride, ptr + row * stride, rowBytes)
                }
            }
            IOSurfaceUnlock(surface, [], nil)

            let shouldNotify = !frameNotificationScheduled
            frameNotificationScheduled = true
            stateLock.unlock()
            if shouldNotify {
                onFrameReady()
            }
            return
        }

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
        stateLock.lock()
        if captureConnectError {
            capturedConnectError = message
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        yieldFailed(message)
    }

    private final class CallbackBox {
        weak var owner: RDPClient?
        init(owner: RDPClient) {
            self.owner = owner
        }
    }
}
