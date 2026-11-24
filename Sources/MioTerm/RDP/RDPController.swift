import AppKit
import Carbon.HIToolbox
import MioTermCore

/// RDP 远程桌面会话控制器：通过动态加载的 FreeRDP 3.x 连接，
/// 复用 `VNCView` 渲染 BGRA 帧缓冲并转发鼠标与键盘事件，实现 `SessionControlling`。
@MainActor
final class RDPController: SessionControlling {
    let sessionID = UUID()
    let host: HostProfile?
    let desktopView = VNCView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))

    var sessionView: NSView { desktopView }

    var onTitleChange: ((String) -> Void)?
    var onFocus: (() -> Void)?

    private(set) var title: String
    private(set) var state: TerminalController.State = .idle {
        didSet {
            guard state != oldValue else { return }
            let current = state
            for observer in stateObservers.values {
                observer(current)
            }
        }
    }

    var context: TerminalContext { TerminalContext() }
    var workingDirectory: String? { nil }

    var tooltip: String {
        let subject = host?.subtitle ?? title
        return "\(subject) · \(state.label)"
    }

    private static let rdpClipboardDidUpdateNotification = Notification.Name("MioTermRDPClipboardDidUpdate")
    private static var recentClipboardStagingDirs: [URL] = []

    private var stateObservers: [UUID: (TerminalController.State) -> Void] = [:]
    private var clipboardObserver: NSObjectProtocol?
    private var client: RDPClient?
    private var eventTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var clipboardPollTask: Task<Void, Never>?
    private var clipboardFetchTask: Task<Void, Never>?
    private var lastSyncedPasteboardChangeCount: Int = -1
    private var clipboardReady = false
    private var currentRemoteSize: (width: Int, height: Int) = (0, 0)
    private var activeModifierFlags: NSEvent.ModifierFlags = []
    private var keyMapping = AppEnvironment.shared.settings.settings.remoteKeyMapping

    init(host: HostProfile) {
        self.host = host
        self.title = host.displayName
        wireView()
        clipboardObserver = NotificationCenter.default.addObserver(
            forName: Self.rdpClipboardDidUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self, (note.object as AnyObject?) !== self else { return }
                self.syncLocalPasteboardToRemote()
            }
        }
    }

    deinit {
        if let clipboardObserver {
            NotificationCenter.default.removeObserver(clipboardObserver)
        }
    }

    private func wireView() {
        desktopView.onPointerEvent = { [weak self] x, y, mask in
            self?.client?.sendPointerEvent(x: x, y: y, buttonMask: mask)
        }
        desktopView.onRawKeyDown = { [weak self] event in
            self?.handleKeyEvent(event, down: true)
            return true
        }
        desktopView.onRawKeyUp = { [weak self] event in
            self?.handleKeyEvent(event, down: false)
            return true
        }
        desktopView.onRawFlagsChanged = { [weak self] event in
            self?.syncModifiers(event.modifierFlags)
            return true
        }
        desktopView.shouldInterceptCommandEquivalent = { [weak self] _ in
            self?.keyMapping.commandKey != .disabled
        }
        desktopView.onFocus = { [weak self] in
            self?.syncLocalPasteboardToRemote()
            self?.onFocus?()
        }
        desktopView.onResize = { [weak self] size in
            self?.scheduleResize(for: size)
        }
        desktopView.onSendCtrlAltDel = { [weak self] in
            self?.sendCtrlAltDel()
        }
        desktopView.onSendFiles = { [weak self] urls in
            self?.sendFiles(urls)
        }
    }

    private func sendFiles(_ urls: [URL]) {
        guard clipboardReady, let client, !urls.isEmpty else { return }
        focus()
        syncModifiers([])
        client.sendClipboardFilesAsync(urls) { [weak self, weak client] ok in
            guard ok else { return }
            Task { @MainActor [weak self, weak client] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self, let client, self.client === client, self.state == .running else { return }
                // 在 Windows 端模拟 Ctrl+V，使拖入/选择的文件像复制粘贴一样直接落到当前窗口或桌面。
                client.sendScancode(0x1D, down: true)
                client.sendScancode(0x2F, down: true)
                client.sendScancode(0x2F, down: false)
                client.sendScancode(0x1D, down: false)
            }
        }
    }

    func start(password: String?) {
        guard let host else { return }
        stop()

        guard FreeRDPAvailability.isInstalled else {
            state = .failed(L10n.tr(.rdpDependencyMissing, FreeRDPAvailability.installCommand))
            return
        }

        state = .starting
        let scale = displayScaleFactor()
        let width = max(800, min(8192, (Int(desktopView.bounds.width * CGFloat(scale)) + 1) & ~1))
        let height = max(600, min(8192, (Int(desktopView.bounds.height * CGFloat(scale)) + 1) & ~1))
        let rdpClient = RDPClient(
            host: host.address,
            port: host.port,
            username: host.username,
            password: password ?? "",
            domain: "",
            width: width,
            height: height,
            scalePercent: scale * 100
        )
        self.client = rdpClient
        rdpClient.onClipboardReady = { [weak self, weak rdpClient] in
            Task { @MainActor [weak self, weak rdpClient] in
                guard let self, let rdpClient, self.client === rdpClient else { return }
                self.clipboardReady = true
                self.lastSyncedPasteboardChangeCount = -1
                self.syncLocalPasteboardToRemote()
                self.startClipboardPolling()
            }
        }
        rdpClient.onRemoteClipboardChanged = { [weak self, weak rdpClient] hasText, hasFiles in
            Task { @MainActor [weak self, weak rdpClient] in
                guard let self, let rdpClient, self.client === rdpClient else { return }
                self.handleRemoteClipboardChanged(hasText: hasText, hasFiles: hasFiles, client: rdpClient)
            }
        }

        eventTask = Task { @MainActor [weak self, weak rdpClient] in
            guard let self, let rdpClient else { return }
            for await event in rdpClient.events {
                guard self.client === rdpClient else { break }
                self.handle(event)
            }
        }
        rdpClient.start()
    }

    private func handle(_ event: VNCEvent) {
        switch event {
        case .connected(let desktopName, let width, let height):
            state = .running
            currentRemoteSize = (width, height)
            desktopView.configureFramebuffer(width: width, height: height)
            if !desktopName.isEmpty && (host?.name.isEmpty ?? true) {
                title = desktopName
                onTitleChange?(desktopName)
            }
            let viewSize = desktopView.bounds.size
            if viewSize.width >= 200, viewSize.height >= 200 {
                scheduleResize(for: viewSize)
            }
        case .frameUpdates(let updates):
            for update in updates {
                if case .resize(let width, let height) = update {
                    currentRemoteSize = (width, height)
                }
            }
            desktopView.apply(updates)
        case .clipboard, .bell:
            break
        case .closed(let reason):
            if let reason, !reason.isEmpty {
                state = .failed(reason)
            } else {
                state = .exited(0)
            }
        case .failed(let message):
            state = .failed(message)
        }
    }

    func stop() {
        resizeTask?.cancel()
        resizeTask = nil
        clipboardPollTask?.cancel()
        clipboardPollTask = nil
        clipboardFetchTask?.cancel()
        clipboardFetchTask = nil
        clipboardReady = false
        lastSyncedPasteboardChangeCount = -1
        syncModifiers([])
        eventTask?.cancel()
        eventTask = nil
        client?.stop()
        client = nil
        desktopView.clearFramebuffer()
    }

    private func startClipboardPolling() {
        clipboardPollTask?.cancel()
        clipboardPollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.clipboardReady {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled, self.clipboardReady else { break }
                self.syncLocalPasteboardToRemote()
            }
        }
    }

    private func syncLocalPasteboardToRemote() {
        guard clipboardReady, let client else { return }
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastSyncedPasteboardChangeCount else { return }
        lastSyncedPasteboardChangeCount = changeCount

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            client.sendClipboardFilesAsync(urls)
            return
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            client.sendClipboardTextAsync(text)
        }
    }

    private func handleRemoteClipboardChanged(hasText: Bool, hasFiles: Bool, client: RDPClient) {
        clipboardFetchTask?.cancel()
        if hasFiles {
            clipboardFetchTask = Task.detached(priority: .userInitiated) { [weak self, weak client] in
                guard let client else { return }
                let stagingDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("MioTermRDPClipboard", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                let urls = client.downloadRemoteClipboardFiles(to: stagingDir)
                guard !urls.isEmpty else {
                    try? FileManager.default.removeItem(at: stagingDir)
                    return
                }
                await MainActor.run { [weak self, weak client] in
                    guard let self, let client, self.client === client, !Task.isCancelled else {
                        try? FileManager.default.removeItem(at: stagingDir)
                        return
                    }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects(urls as [NSURL])
                    self.lastSyncedPasteboardChangeCount = pasteboard.changeCount
                    Self.registerClipboardStagingDir(stagingDir)
                    NotificationCenter.default.post(name: Self.rdpClipboardDidUpdateNotification, object: self)
                }
            }
            return
        }
        guard hasText else { return }
        clipboardFetchTask = Task.detached(priority: .userInitiated) { [weak self, weak client] in
            guard let client, let text = client.fetchRemoteClipboardText(), !text.isEmpty else { return }
            await MainActor.run { [weak self, weak client] in
                guard let self, let client, self.client === client, !Task.isCancelled else { return }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                self.lastSyncedPasteboardChangeCount = pasteboard.changeCount
                NotificationCenter.default.post(name: Self.rdpClipboardDidUpdateNotification, object: self)
            }
        }
    }

    private static func registerClipboardStagingDir(_ dir: URL) {
        recentClipboardStagingDirs.append(dir)
        // 保留最近 8 个中转目录，避免并发传输或连续复制多次时正在读取的文件被提前清理。
        while recentClipboardStagingDirs.count > 8 {
            let obsolete = recentClipboardStagingDirs.removeFirst()
            try? FileManager.default.removeItem(at: obsolete)
        }
    }

    private func displayScaleFactor() -> Int {
        // 按 100%（1× 逻辑分辨率）请求远程桌面，避免部分 Windows 会话忽略 200% DPI 导致图标字体偏小。
        1
    }

    private func scheduleResize(for size: CGSize) {
        let scale = displayScaleFactor()
        let targetWidth = max(200, min(8192, (Int(size.width * CGFloat(scale)) + 1) & ~1))
        let targetHeight = max(200, min(8192, (Int(size.height * CGFloat(scale)) + 1) & ~1))
        guard abs(targetWidth - currentRemoteSize.width) >= 4 || abs(targetHeight - currentRemoteSize.height) >= 4 else {
            return
        }
        resizeTask?.cancel()
        resizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled, self.state == .running else { return }
            self.client?.requestResize(width: targetWidth, height: targetHeight, scalePercent: scale * 100)
        }
    }

    func focus() {
        desktopView.window?.makeFirstResponder(desktopView)
    }

    func sendCtrlAltDel() {
        guard let client else { return }
        // Ctrl_L (0x1D), Alt_L (0x38), Delete (extended 0x153)
        client.sendScancode(0x1D, down: true)
        client.sendScancode(0x38, down: true)
        client.sendScancode(0x153, down: true)
        client.sendScancode(0x153, down: false)
        client.sendScancode(0x38, down: false)
        client.sendScancode(0x1D, down: false)
    }

    private func handleKeyEvent(_ event: NSEvent, down: Bool) {
        guard let client else { return }
        if down {
            syncModifiers(event.modifierFlags)
            if Int(event.keyCode) == kVK_ANSI_V,
               event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                syncLocalPasteboardToRemote()
            }
        }
        if let scancode = Self.rdpScancode(for: Int(event.keyCode)) {
            client.sendScancode(scancode, down: down)
            return
        }
        let chars = event.characters ?? ""
        for scalar in chars.unicodeScalars {
            if scalar.value <= 0xFFFF {
                client.sendUnicode(UInt16(scalar.value), down: down)
            }
        }
    }

    private func syncModifiers(_ flags: NSEvent.ModifierFlags) {
        guard let client else { return }
        let mappings: [(NSEvent.ModifierFlags, UInt32?)] = [
            (.shift, 0x2A),
            (.control, keyMapping.controlKey.rdpScancode),
            (.option, keyMapping.optionKey.rdpScancode),
            (.command, keyMapping.commandKey.rdpScancode),
        ]
        for (flag, scancode) in mappings {
            guard let scancode else { continue }
            let wasDown = activeModifierFlags.contains(flag)
            let isDown = flags.contains(flag)
            if wasDown != isDown {
                client.sendScancode(scancode, down: isDown)
            }
        }
        if activeModifierFlags.contains(.capsLock) != flags.contains(.capsLock) {
            // Caps Lock (0x3A) 在 Windows 端按按下+抬起触发一次大小写锁定切换。
            client.sendScancode(0x3A, down: true)
            client.sendScancode(0x3A, down: false)
        }
        activeModifierFlags = flags
    }

    private static func rdpScancode(for macKeyCode: Int) -> UInt32? {
        switch macKeyCode {
        case kVK_Escape: return 0x01
        case kVK_ANSI_1: return 0x02
        case kVK_ANSI_2: return 0x03
        case kVK_ANSI_3: return 0x04
        case kVK_ANSI_4: return 0x05
        case kVK_ANSI_5: return 0x06
        case kVK_ANSI_6: return 0x07
        case kVK_ANSI_7: return 0x08
        case kVK_ANSI_8: return 0x09
        case kVK_ANSI_9: return 0x0A
        case kVK_ANSI_0: return 0x0B
        case kVK_ANSI_Minus: return 0x0C
        case kVK_ANSI_Equal: return 0x0D
        case kVK_Delete: return 0x0E
        case kVK_Tab: return 0x0F
        case kVK_ANSI_Q: return 0x10
        case kVK_ANSI_W: return 0x11
        case kVK_ANSI_E: return 0x12
        case kVK_ANSI_R: return 0x13
        case kVK_ANSI_T: return 0x14
        case kVK_ANSI_Y: return 0x15
        case kVK_ANSI_U: return 0x16
        case kVK_ANSI_I: return 0x17
        case kVK_ANSI_O: return 0x18
        case kVK_ANSI_P: return 0x19
        case kVK_ANSI_LeftBracket: return 0x1A
        case kVK_ANSI_RightBracket: return 0x1B
        case kVK_Return: return 0x1C
        case kVK_Control: return 0x1D
        case kVK_ANSI_A: return 0x1E
        case kVK_ANSI_S: return 0x1F
        case kVK_ANSI_D: return 0x20
        case kVK_ANSI_F: return 0x21
        case kVK_ANSI_G: return 0x22
        case kVK_ANSI_H: return 0x23
        case kVK_ANSI_J: return 0x24
        case kVK_ANSI_K: return 0x25
        case kVK_ANSI_L: return 0x26
        case kVK_ANSI_Semicolon: return 0x27
        case kVK_ANSI_Quote: return 0x28
        case kVK_ANSI_Grave: return 0x29
        case kVK_Shift: return 0x2A
        case kVK_ANSI_Backslash: return 0x2B
        case kVK_ANSI_Z: return 0x2C
        case kVK_ANSI_X: return 0x2D
        case kVK_ANSI_C: return 0x2E
        case kVK_ANSI_V: return 0x2F
        case kVK_ANSI_B: return 0x30
        case kVK_ANSI_N: return 0x31
        case kVK_ANSI_M: return 0x32
        case kVK_ANSI_Comma: return 0x33
        case kVK_ANSI_Period: return 0x34
        case kVK_ANSI_Slash: return 0x35
        case kVK_RightShift: return 0x36
        case kVK_Option: return 0x38
        case kVK_Space: return 0x39
        case kVK_CapsLock: return 0x3A
        case kVK_F1: return 0x3B
        case kVK_F2: return 0x3C
        case kVK_F3: return 0x3D
        case kVK_F4: return 0x3E
        case kVK_F5: return 0x3F
        case kVK_F6: return 0x40
        case kVK_F7: return 0x41
        case kVK_F8: return 0x42
        case kVK_F9: return 0x43
        case kVK_F10: return 0x44
        case kVK_F11: return 0x57
        case kVK_F12: return 0x58
        case kVK_Home: return 0x147
        case kVK_UpArrow: return 0x148
        case kVK_PageUp: return 0x149
        case kVK_LeftArrow: return 0x14B
        case kVK_RightArrow: return 0x14D
        case kVK_End: return 0x14F
        case kVK_DownArrow: return 0x150
        case kVK_PageDown: return 0x151
        case kVK_ForwardDelete: return 0x153
        case kVK_Command: return 0x15B
        // 小数字键盘（Numpad）
        case kVK_ANSI_Keypad0: return 0x52
        case kVK_ANSI_Keypad1: return 0x4F
        case kVK_ANSI_Keypad2: return 0x50
        case kVK_ANSI_Keypad3: return 0x51
        case kVK_ANSI_Keypad4: return 0x4B
        case kVK_ANSI_Keypad5: return 0x4C
        case kVK_ANSI_Keypad6: return 0x4D
        case kVK_ANSI_Keypad7: return 0x47
        case kVK_ANSI_Keypad8: return 0x48
        case kVK_ANSI_Keypad9: return 0x49
        case kVK_ANSI_KeypadDecimal: return 0x53
        case kVK_ANSI_KeypadPlus: return 0x4E
        case kVK_ANSI_KeypadMinus: return 0x4A
        case kVK_ANSI_KeypadMultiply: return 0x37
        case kVK_ANSI_KeypadDivide: return 0x135
        case kVK_ANSI_KeypadEnter: return 0x11C
        case kVK_ANSI_KeypadClear: return 0x45
        case kVK_ANSI_KeypadEquals: return 0x0D
        default: return nil
        }
    }

    func applyTheme() {}
    func apply(_ settings: AppSettings) {
        if keyMapping != settings.remoteKeyMapping {
            syncModifiers([])
            keyMapping = settings.remoteKeyMapping
        }
    }

    func failStart(reason: String) {
        stop()
        state = .failed(reason)
    }

    @discardableResult
    func addStateObserver(_ observer: @escaping (TerminalController.State) -> Void) -> UUID {
        let token = UUID()
        stateObservers[token] = observer
        observer(state)
        return token
    }

    func removeStateObserver(_ token: UUID?) {
        guard let token else { return }
        stateObservers.removeValue(forKey: token)
    }

    @discardableResult
    func addContextObserver(_ observer: @escaping (TerminalContext) -> Void) -> UUID {
        let token = UUID()
        observer(context)
        return token
    }

    func removeContextObserver(_ token: UUID?) {}
}
