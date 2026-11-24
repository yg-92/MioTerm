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
    private var resolutionPopUp: NSPopUpButton?
    private var scalePopUp: NSPopUpButton?

    private static let resolutionPresets: [(title: String, mode: RDPResolutionMode)] = [
        ("自适应窗口", .fitWindow),
        ("适应屏幕", .matchScreen),
        ("1280×720", .fixed(width: 1280, height: 720)),
        ("1366×768", .fixed(width: 1366, height: 768)),
        ("1440×900", .fixed(width: 1440, height: 900)),
        ("1600×900", .fixed(width: 1600, height: 900)),
        ("1920×1080", .fixed(width: 1920, height: 1080)),
        ("2560×1440", .fixed(width: 2560, height: 1440)),
        ("3840×2160", .fixed(width: 3840, height: 2160)),
    ]
    private static let scalePresets: [Int] = [100, 125, 150, 175, 200]

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
        installTitlebarControls(in: window)

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

    private func installTitlebarControls(in window: NSWindow) {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let rdp = sessionController as? RDPController {
            let refreshButton = NSButton(
                image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "按当前分辨率刷新") ?? NSImage(),
                target: self,
                action: #selector(displayOptionChanged(_:))
            )
            refreshButton.bezelStyle = .accessoryBarAction
            refreshButton.controlSize = .small
            refreshButton.toolTip = "按右侧所选分辨率与缩放重新加载画面"
            refreshButton.sizeToFit()
            stack.addArrangedSubview(refreshButton)

            let resPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
            resPopUp.bezelStyle = .accessoryBarAction
            resPopUp.controlSize = .small
            resPopUp.font = .systemFont(ofSize: 11, weight: .medium)
            resPopUp.toolTip = "调整远程桌面分辨率"
            for (idx, preset) in Self.resolutionPresets.enumerated() {
                if idx == 2 {
                    resPopUp.menu?.addItem(.separator())
                }
                let item = NSMenuItem(title: preset.title, action: nil, keyEquivalent: "")
                item.tag = idx
                resPopUp.menu?.addItem(item)
            }
            if let currentIdx = Self.resolutionPresets.firstIndex(where: { $0.mode == rdp.resolutionMode }) {
                resPopUp.selectItem(withTag: currentIdx)
            } else {
                resPopUp.selectItem(withTag: 0)
            }
            resPopUp.target = self
            resPopUp.action = #selector(displayOptionChanged(_:))
            resPopUp.sizeToFit()
            self.resolutionPopUp = resPopUp
            stack.addArrangedSubview(resPopUp)

            let scalePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
            scalePopUp.bezelStyle = .accessoryBarAction
            scalePopUp.controlSize = .small
            scalePopUp.font = .systemFont(ofSize: 11, weight: .medium)
            scalePopUp.toolTip = "调整远程桌面缩放比例"
            for percent in Self.scalePresets {
                let item = NSMenuItem(title: "\(percent)%", action: nil, keyEquivalent: "")
                item.tag = percent
                scalePopUp.menu?.addItem(item)
            }
            scalePopUp.selectItem(withTag: rdp.scalePercent)
            if scalePopUp.selectedItem == nil {
                scalePopUp.selectItem(withTag: 100)
            }
            scalePopUp.target = self
            scalePopUp.action = #selector(displayOptionChanged(_:))
            scalePopUp.sizeToFit()
            self.scalePopUp = scalePopUp
            stack.addArrangedSubview(scalePopUp)
        }

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
        stack.addArrangedSubview(button)

        let fitting = stack.fittingSize
        let container = NSView(frame: NSRect(x: 0, y: 0, width: ceil(fitting.width) + 12, height: 28))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        accessory.view = container
        window.addTitlebarAccessoryViewController(accessory)
    }

    @objc private func displayOptionChanged(_ sender: Any?) {
        guard let rdp = sessionController as? RDPController else { return }
        let resTag = resolutionPopUp?.selectedTag() ?? 0
        let mode = Self.resolutionPresets.indices.contains(resTag)
            ? Self.resolutionPresets[resTag].mode
            : .fitWindow
        let scale = scalePopUp?.selectedTag() ?? 100
        rdp.applyDisplaySettings(resolution: mode, scalePercent: scale > 0 ? scale : 100)
        sessionController.focus()
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
