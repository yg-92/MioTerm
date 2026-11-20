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

    private var stateObservers: [UUID: (TerminalController.State) -> Void] = [:]
    private var client: RDPClient?
    private var eventTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var currentRemoteSize: (width: Int, height: Int) = (0, 0)
    private var activeModifierFlags: NSEvent.ModifierFlags = []
    private var keyMapping = AppEnvironment.shared.settings.settings.remoteKeyMapping

    init(host: HostProfile) {
        self.host = host
        self.title = host.displayName
        wireView()
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
        guard let sharedDir = client?.sharedDirectory else { return }
        let targetDir = URL(fileURLWithPath: sharedDir, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            var copiedCount = 0
            for url in urls {
                let destination = targetDir.appendingPathComponent(url.lastPathComponent)
                if url.standardizedFileURL == destination.standardizedFileURL {
                    copiedCount += 1
                    continue
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
                copiedCount += 1
            }
            AlertPresenter.notify(
                title: L10n.tr(.rdpFileCopiedTitle),
                message: L10n.tr(.rdpFileCopiedMsg, copiedCount, sharedDir),
                in: desktopView.window
            )
        } catch {
            AlertPresenter.fail(
                title: L10n.tr(.rdpFileCopyFailedTitle),
                message: error.localizedDescription,
                in: desktopView.window
            )
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
        let width = max(800, Int(desktopView.bounds.width))
        let height = max(600, Int(desktopView.bounds.height))
        let rdpClient = RDPClient(
            host: host.address,
            port: host.port,
            username: host.username,
            password: password ?? "",
            domain: "",
            width: width,
            height: height
        )
        self.client = rdpClient

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
        syncModifiers([])
        eventTask?.cancel()
        eventTask = nil
        client?.stop()
        client = nil
    }

    private func scheduleResize(for size: CGSize) {
        let targetWidth = max(200, min(8192, (Int(size.width) + 1) & ~1))
        let targetHeight = max(200, min(8192, (Int(size.height) + 1) & ~1))
        guard abs(targetWidth - currentRemoteSize.width) >= 4 || abs(targetHeight - currentRemoteSize.height) >= 4 else {
            return
        }
        resizeTask?.cancel()
        resizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled, self.state == .running else { return }
            self.client?.requestResize(width: targetWidth, height: targetHeight)
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
