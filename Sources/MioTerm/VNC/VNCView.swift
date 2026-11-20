import AppKit
import Carbon.HIToolbox
import MioTermCore

/// VNC 远程桌面渲染与输入视图：
/// 维护本地 BGRA 像素缓冲，等比自适应窗口大小绘制，
/// 并将 macOS 鼠标坐标与键盘按键转换为 RFB 事件发往服务端。
@MainActor
final class VNCView: NSView {
    var onPointerEvent: ((Int, Int, UInt8) -> Void)?
    var onKeyEvent: ((UInt32, Bool) -> Void)?
    var onRawKeyDown: ((NSEvent) -> Bool)?
    var onRawKeyUp: ((NSEvent) -> Bool)?
    var onRawFlagsChanged: ((NSEvent) -> Bool)?
    var shouldInterceptCommandEquivalent: ((NSEvent) -> Bool)?
    var onFocus: (() -> Void)?
    var onSendCtrlAltDel: (() -> Void)?
    var onSyncClipboard: (() -> Void)?
    var onSendFiles: (([URL]) -> Void)? {
        didSet {
            menu = buildContextMenu()
            if onSendFiles != nil {
                registerForDraggedTypes([.fileURL])
            } else {
                unregisterDraggedTypes()
            }
        }
    }

    private var fbWidth = 0
    private var fbHeight = 0
    private var framebuffer = Data()
    private var buttonMask: UInt8 = 0
    private var trackingArea: NSTrackingArea?
    private var activeModifierFlags: NSEvent.ModifierFlags = []
    private var pointerInside = false
    private var lastRemotePoint: (Int, Int)?

    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        menu = buildContextMenu()
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    func configureFramebuffer(width: Int, height: Int) {
        let w = max(1, width)
        let h = max(1, height)
        guard w != fbWidth || h != fbHeight else { return }
        fbWidth = w
        fbHeight = h
        framebuffer = Data(count: w * h * 4)
        needsDisplay = true
    }

    func apply(_ updates: [VNCFrameUpdate]) {
        for update in updates {
            switch update {
            case .resize(let width, let height):
                configureFramebuffer(width: width, height: height)
            case .rawRect(let x, let y, let width, let height, let bgra):
                blitRawRect(x: x, y: y, width: width, height: height, bgra: bgra)
            case .copyRect(let x, let y, let width, let height, let srcX, let srcY):
                copyRect(x: x, y: y, width: width, height: height, srcX: srcX, srcY: srcY)
            }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cgContext = NSGraphicsContext.current?.cgContext else { return }
        cgContext.setFillColor(NSColor.black.cgColor)
        cgContext.fill(bounds)

        guard fbWidth > 0, fbHeight > 0,
              framebuffer.count == fbWidth * fbHeight * 4,
              let image = makeCGImage() else { return }

        let targetRect = contentRect()
        cgContext.saveGState()
        // VNC 视图本身 isFlipped = true，而 CGContext.draw(_:in:) 在 flipped 上下文中会倒置绘制，先翻正坐标系。
        cgContext.translateBy(x: 0, y: targetRect.minY + targetRect.maxY)
        cgContext.scaleBy(x: 1, y: -1)
        cgContext.interpolationQuality = .high
        cgContext.draw(image, in: targetRect)
        cgContext.restoreGState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
    }

    // MARK: - 鼠标输入

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onFocus?()
        buttonMask |= 1 << 0
        emitPointer(from: event)
    }

    override func mouseUp(with event: NSEvent) {
        buttonMask &= ~(1 << 0)
        emitPointerRelease(from: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            super.rightMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        onFocus?()
        buttonMask |= 1 << 2
        emitPointer(from: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        buttonMask &= ~(1 << 2)
        emitPointerRelease(from: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onFocus?()
        buttonMask |= 1 << 1
        emitPointer(from: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        buttonMask &= ~(1 << 1)
        emitPointerRelease(from: event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard pointerInside else { return }
        emitPointer(from: event)
    }

    override func mouseDragged(with event: NSEvent) {
        emitPointer(from: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        emitPointer(from: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        emitPointer(from: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let point = remotePoint(from: event) else { return }
        if event.scrollingDeltaY > 0 {
            sendWheelPulse(bit: 3, at: point)
        } else if event.scrollingDeltaY < 0 {
            sendWheelPulse(bit: 4, at: point)
        }
        if event.scrollingDeltaX > 0 {
            sendWheelPulse(bit: 5, at: point)
        } else if event.scrollingDeltaX < 0 {
            sendWheelPulse(bit: 6, at: point)
        }
    }

    private func sendWheelPulse(bit: UInt8, at point: (Int, Int)) {
        let downMask = buttonMask | (1 << bit)
        onPointerEvent?(point.0, point.1, downMask)
        onPointerEvent?(point.0, point.1, buttonMask)
    }

    private func emitPointer(from event: NSEvent) {
        guard let (x, y) = remotePoint(from: event, allowOutside: false) else { return }
        lastRemotePoint = (x, y)
        onPointerEvent?(x, y, buttonMask)
    }

    private func emitPointerRelease(from event: NSEvent) {
        guard let (x, y) = remotePoint(from: event, allowOutside: true) ?? lastRemotePoint else { return }
        onPointerEvent?(x, y, buttonMask)
    }

    private func remotePoint(from event: NSEvent, allowOutside: Bool = false) -> (Int, Int)? {
        guard fbWidth > 0, fbHeight > 0 else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        let rect = contentRect()
        guard rect.width > 0, rect.height > 0 else { return nil }
        if !allowOutside {
            guard bounds.contains(local), rect.contains(local) else { return nil }
        }
        let rx = Int(((local.x - rect.minX) / rect.width) * CGFloat(fbWidth))
        let ry = Int(((local.y - rect.minY) / rect.height) * CGFloat(fbHeight))
        return (min(max(rx, 0), fbWidth - 1), min(max(ry, 0), fbHeight - 1))
    }

    private func contentRect() -> NSRect {
        guard fbWidth > 0, fbHeight > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let scale = min(bounds.width / CGFloat(fbWidth), bounds.height / CGFloat(fbHeight))
        let drawWidth = floor(CGFloat(fbWidth) * scale)
        let drawHeight = floor(CGFloat(fbHeight) * scale)
        let originX = floor((bounds.width - drawWidth) / 2)
        let originY = floor((bounds.height - drawHeight) / 2)
        return NSRect(x: originX, y: originY, width: drawWidth, height: drawHeight)
    }

    // MARK: - 键盘输入

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        // Esc（含 Ctrl+Shift+Esc）及 Ctrl / Option 组合键直接发给远端桌面，避免被 macOS 窗口/菜单拦截。
        if Int(event.keyCode) == kVK_Escape {
            keyDown(with: event)
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
            let keepLocalAppShortcuts: Set<String> = ["q", "w", "h", "m", ","]
            if !keepLocalAppShortcuts.contains(chars) && shouldInterceptCommandEquivalent?(event) == true {
                keyDown(with: event)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
        if flags.contains(.control) || flags.contains(.option) {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        // Esc 由 keyDown/performKeyEquivalent 转发到远端，不在此吞掉。
    }

    override func keyDown(with event: NSEvent) {
        if onRawKeyDown?(event) == true { return }
        for keysym in keysyms(for: event) {
            onKeyEvent?(keysym, true)
        }
    }

    override func keyUp(with event: NSEvent) {
        if onRawKeyUp?(event) == true { return }
        for keysym in keysyms(for: event) {
            onKeyEvent?(keysym, false)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        if onRawFlagsChanged?(event) == true {
            activeModifierFlags = event.modifierFlags
            return
        }
        let next = event.modifierFlags
        let mapping = AppEnvironment.shared.settings.settings.remoteKeyMapping
        let mappings: [(NSEvent.ModifierFlags, UInt32?)] = [
            (.shift, 0xFFE1),   // Shift_L
            (.control, mapping.controlKey.x11Keysym),
            (.option, mapping.optionKey.x11Keysym),
            (.command, mapping.commandKey.x11Keysym),
        ]
        for (flag, keysym) in mappings {
            guard let keysym else { continue }
            let wasDown = activeModifierFlags.contains(flag)
            let isDown = next.contains(flag)
            if wasDown != isDown {
                onKeyEvent?(keysym, isDown)
            }
        }
        activeModifierFlags = next
    }

    private func keysyms(for event: NSEvent) -> [UInt32] {
        switch Int(event.keyCode) {
        case kVK_Return, kVK_ANSI_KeypadEnter: return [0xFF0D]
        case kVK_Tab: return [0xFF09]
        case kVK_Delete: return [0xFF08]
        case kVK_ForwardDelete: return [0xFFFF]
        case kVK_Escape: return [0xFF1B]
        case kVK_LeftArrow: return [0xFF51]
        case kVK_UpArrow: return [0xFF52]
        case kVK_RightArrow: return [0xFF53]
        case kVK_DownArrow: return [0xFF54]
        case kVK_Home: return [0xFF50]
        case kVK_End: return [0xFF57]
        case kVK_PageUp: return [0xFF55]
        case kVK_PageDown: return [0xFF56]
        case kVK_F1: return [0xFFBE]
        case kVK_F2: return [0xFFBF]
        case kVK_F3: return [0xFFC0]
        case kVK_F4: return [0xFFC1]
        case kVK_F5: return [0xFFC2]
        case kVK_F6: return [0xFFC3]
        case kVK_F7: return [0xFFC4]
        case kVK_F8: return [0xFFC5]
        case kVK_F9: return [0xFFC6]
        case kVK_F10: return [0xFFC7]
        case kVK_F11: return [0xFFC8]
        case kVK_F12: return [0xFFC9]
        default:
            break
        }
        let chars = event.charactersIgnoringModifiers ?? event.characters ?? ""
        return chars.unicodeScalars.compactMap { scalar in
            let v = scalar.value
            if v >= 0x20 && v <= 0x7E { return v }
            if v >= 0xA0 && v <= 0xFF { return v }
            if v > 0xFF { return 0x0100_0000 | v }
            return nil
        }
    }

    // MARK: - 像素操作

    private func blitRawRect(x: Int, y: Int, width: Int, height: Int, bgra: Data) {
        guard fbWidth > 0, fbHeight > 0, width > 0, height > 0, x >= 0, y >= 0 else { return }
        let copyWidth = min(width, max(0, fbWidth - x))
        let copyHeight = min(height, max(0, fbHeight - y))
        guard copyWidth > 0, copyHeight > 0 else { return }

        let srcRowBytes = width * 4
        let dstRowBytes = fbWidth * 4
        let copyRowBytes = copyWidth * 4

        framebuffer.withUnsafeMutableBytes { dstRaw in
            let dstCount = dstRaw.count
            bgra.withUnsafeBytes { srcRaw in
                let srcCount = srcRaw.count
                guard let dstBase = dstRaw.baseAddress, let srcBase = srcRaw.baseAddress else { return }
                for row in 0..<copyHeight {
                    let srcOffset = row * srcRowBytes
                    let dstOffset = (y + row) * dstRowBytes + x * 4
                    guard srcOffset + copyRowBytes <= srcCount,
                          dstOffset + copyRowBytes <= dstCount else { break }
                    memcpy(dstBase + dstOffset, srcBase + srcOffset, copyRowBytes)
                }
            }
        }
    }

    private func copyRect(x: Int, y: Int, width: Int, height: Int, srcX: Int, srcY: Int) {
        guard fbWidth > 0, fbHeight > 0, width > 0, height > 0,
              x >= 0, y >= 0, srcX >= 0, srcY >= 0 else { return }
        let rowBytes = fbWidth * 4
        let copyRowBytes = min(width, min(fbWidth - x, fbWidth - srcX)) * 4
        let copyHeight = min(height, min(fbHeight - y, fbHeight - srcY))
        guard copyRowBytes > 0, copyHeight > 0 else { return }

        framebuffer.withUnsafeMutableBytes { raw in
            let count = raw.count
            guard let base = raw.baseAddress else { return }
            let rows = y > srcY ? Array((0..<copyHeight).reversed()) : Array(0..<copyHeight)
            for row in rows {
                let srcOffset = (srcY + row) * rowBytes + srcX * 4
                let dstOffset = (y + row) * rowBytes + x * 4
                guard srcOffset + copyRowBytes <= count,
                      dstOffset + copyRowBytes <= count else { continue }
                memmove(base + dstOffset, base + srcOffset, copyRowBytes)
            }
        }
    }

    private func makeCGImage() -> CGImage? {
        guard let provider = CGDataProvider(data: framebuffer as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
        )
        return CGImage(
            width: fbWidth,
            height: fbHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: fbWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    // MARK: - 右键快捷菜单

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        if onSendFiles != nil {
            menu.addItem(withTitle: L10n.tr(.rdpSendFiles), action: #selector(sendFilesMenu), keyEquivalent: "")
                .target = self
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: L10n.tr(.vncSendCtrlAltDel), action: #selector(sendCtrlAltDelMenu), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: L10n.tr(.vncSendClipboard), action: #selector(syncClipboardMenu), keyEquivalent: "")
            .target = self
        return menu
    }

    @objc private func sendFilesMenu() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        let handleSelection: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            self?.onSendFiles?(panel.urls)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handleSelection)
        } else {
            handleSelection(panel.runModal())
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onSendFiles != nil,
              sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let onSendFiles,
              let urls = sender.draggingPasteboard.readObjects(
                  forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]
              ) as? [URL],
              !urls.isEmpty else { return false }
        onSendFiles(urls)
        return true
    }

    @objc private func sendCtrlAltDelMenu() {
        onSendCtrlAltDel?()
    }

    @objc private func syncClipboardMenu() {
        onSyncClipboard?()
    }
}
