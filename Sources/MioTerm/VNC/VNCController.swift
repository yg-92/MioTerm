import AppKit
import MioTermCore

/// VNC 远程桌面会话控制器：驱动 `RFBClient` 与 `VNCView`，
/// 接入统一会话标签页、状态栏与断线重连提示条。
@MainActor
final class VNCController: SessionControlling {
    let sessionID = UUID()
    let host: HostProfile?
    let vncView = VNCView()
    var sessionView: NSView { vncView }

    private(set) var state: TerminalController.State = .idle {
        didSet { notifyStateChange() }
    }
    private(set) var workingDirectory: String? = nil
    var context: TerminalContext { TerminalContext() }

    private var stateObservers: [UUID: (TerminalController.State) -> Void] = [:]
    var onTitleChange: ((String) -> Void)?
    var onFocus: (() -> Void)?

    private var client: RFBClient?
    private var eventTask: Task<Void, Never>?
    private var desktopName: String?

    var title: String {
        if let host { return host.displayName }
        return desktopName ?? L10n.tr(.vncDesktopTitle)
    }

    var tooltip: String {
        let subject = host.map { "\($0.protocolKind.displayName) · \($0.subtitle)" } ?? L10n.tr(.vncDesktopTitle)
        return "\(subject) · \(state.label)"
    }

    init(host: HostProfile) {
        self.host = host
        vncView.onPointerEvent = { [weak self] x, y, mask in
            self?.client?.sendPointerEvent(x: x, y: y, buttonMask: mask)
        }
        vncView.onKeyEvent = { [weak self] keysym, down in
            self?.client?.sendKeyEvent(keysym: keysym, down: down)
        }
        vncView.onFocus = { [weak self] in
            self?.onFocus?()
        }
        vncView.onSendCtrlAltDel = { [weak self] in
            self?.sendCtrlAltDel()
        }
        vncView.onSyncClipboard = { [weak self] in
            self?.syncLocalClipboardToRemote()
        }
        vncView.shouldInterceptCommandEquivalent = { _ in
            AppEnvironment.shared.settings.settings.remoteKeyMapping.commandKey != .disabled
        }
    }

    func start(password: String?) {
        guard !state.isAlive, let host else { return }
        stopClientOnly()
        state = .starting

        let client = RFBClient(
            host: host.address,
            port: host.port,
            password: password,
            connectTimeout: TimeInterval(max(1, host.connectTimeout))
        )
        self.client = client
        eventTask = Task { [weak self] in
            for await event in client.events {
                guard let self, self.client === client else { break }
                self.handle(event)
            }
        }
        client.start()
    }

    func stop() {
        stopClientOnly()
        if state.isAlive {
            state = .exited(nil)
        }
    }

    func failStart(reason: String) {
        stopClientOnly()
        state = .failed(reason)
    }

    func applyTheme() {}
    func apply(_ settings: AppSettings) {}

    func focus() {
        vncView.window?.makeFirstResponder(vncView)
    }

    func addStateObserver(_ observer: @escaping (TerminalController.State) -> Void) -> UUID {
        let token = UUID()
        stateObservers[token] = observer
        return token
    }

    func removeStateObserver(_ token: UUID?) {
        guard let token else { return }
        stateObservers[token] = nil
    }

    func addContextObserver(_ observer: @escaping (TerminalContext) -> Void) -> UUID {
        UUID()
    }

    func removeContextObserver(_ token: UUID?) {}

    private func notifyStateChange() {
        for observer in Array(stateObservers.values) {
            observer(state)
        }
    }

    private func stopClientOnly() {
        eventTask?.cancel()
        eventTask = nil
        client?.stop()
        client = nil
    }

    private func handle(_ event: VNCEvent) {
        switch event {
        case .connected(let name, let width, let height):
            desktopName = name
            vncView.configureFramebuffer(width: width, height: height)
            state = .running
            onTitleChange?(title)
        case .frameUpdates(let updates):
            vncView.apply(updates)
        case .clipboard(let text):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        case .bell:
            NSSound.beep()
        case .closed:
            stopClientOnly()
            if state.isAlive {
                state = .exited(nil)
            }
        case .failed(let reason):
            stopClientOnly()
            state = .failed(reason)
        }
    }

    private func sendCtrlAltDel() {
        guard let client else { return }
        let ctrl: UInt32 = 0xFFE3
        let alt: UInt32 = 0xFFE9
        let del: UInt32 = 0xFFFF
        client.sendKeyEvent(keysym: ctrl, down: true)
        client.sendKeyEvent(keysym: alt, down: true)
        client.sendKeyEvent(keysym: del, down: true)
        client.sendKeyEvent(keysym: del, down: false)
        client.sendKeyEvent(keysym: alt, down: false)
        client.sendKeyEvent(keysym: ctrl, down: false)
    }

    private func syncLocalClipboardToRemote() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        client?.sendClientCutText(text)
    }
}
