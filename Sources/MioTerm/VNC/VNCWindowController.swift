import AppKit
import MioTermCore

/// 从标签栏拖出或右键移出的独立图形桌面窗口（支持 VNC 与 RDP）。
@MainActor
final class VNCWindowController: NSWindowController, NSWindowDelegate {
    let sessionController: any SessionControlling
    private let tabController: TerminalTabViewController
    var onReconnect: ((any SessionControlling) -> Void)?
    var onReattach: ((any SessionControlling) -> Void)?
    var onDidClose: ((UUID) -> Void)?
    private var stateToken: UUID?
    private var isReattaching = false

    init(controller: any SessionControlling, screenPoint: NSPoint?, anchorWindow: NSWindow?) {
        self.sessionController = controller
        self.tabController = TerminalTabViewController(controller: controller)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 480, height: 320)
        window.title = controller.title
        window.alphaValue = 1.0
        window.contentViewController = tabController
        super.init(window: window)
        window.delegate = self
        installReattachTitlebarButton(in: window)

        tabController.setPanePresentation(split: false, active: true)
        tabController.onReconnect = { [weak self] session in
            self?.onReconnect?(session)
        }
        controller.onTitleChange = { [weak self] newTitle in
            self?.window?.title = newTitle
        }
        stateToken = controller.addStateObserver { [weak self] _ in
            guard let self else { return }
            self.tabController.updateConnectionState()
        }

        if let screenPoint {
            let size = window.frame.size
            let visible = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) })?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let rawX = screenPoint.x - size.width / 2
            let rawY = screenPoint.y - size.height + 24
            let x = min(max(rawX, visible.minX), max(visible.minX, visible.maxX - size.width))
            let y = min(max(rawY, visible.minY), max(visible.minY, visible.maxY - size.height))
            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            window.positionCentered(relativeTo: anchorWindow, topOffset: 40)
        }
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        sessionController.focus()
    }

    func setReconnecting(_ busy: Bool) {
        tabController.setReconnecting(busy)
    }

    private func installReattachTitlebarButton(in window: NSWindow) {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right

        let button = NSButton(
            title: L10n.tr(.tabReattachToMainWindow),
            image: NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: L10n.tr(.tabReattachToMainWindow)) ?? NSImage(),
            target: self,
            action: #selector(reattachToMainWindow)
        )
        button.imagePosition = .imageLeading
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.toolTip = L10n.tr(.tabReattachToMainWindow)
        button.sizeToFit()

        let container = NSView(frame: NSRect(x: 0, y: 0, width: button.frame.width + 12, height: 28))
        button.frame.origin = NSPoint(x: 4, y: floor((container.bounds.height - button.frame.height) / 2))
        container.addSubview(button)
        accessory.view = container
        window.addTitlebarAccessoryViewController(accessory)
    }

    @objc func reattachToMainWindow() {
        guard !isReattaching else { return }
        isReattaching = true
        sessionController.sessionView.removeFromSuperview()
        let controller = sessionController
        let callback = onReattach
        close()
        callback?(controller)
    }

    func windowWillClose(_ notification: Notification) {
        sessionController.removeStateObserver(stateToken)
        stateToken = nil
        sessionController.onTitleChange = nil
        if !isReattaching {
            sessionController.stop()
            AppEnvironment.shared.unregister(sessionController)
        }
        onDidClose?(sessionController.sessionID)
    }
}
