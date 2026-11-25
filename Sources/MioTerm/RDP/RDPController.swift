import AppKit
import Carbon.HIToolbox
import MioTermCore
import UniformTypeIdentifiers

enum RDPResolutionMode: Equatable {
    case fitWindow
    case matchScreen
    case fixed(width: Int, height: Int)

    var storageKey: String {
        switch self {
        case .fitWindow: return "fitWindow"
        case .matchScreen: return "matchScreen"
        case .fixed(let w, let h): return "\(w)x\(h)"
        }
    }

    init?(storageKey: String) {
        switch storageKey {
        case "fitWindow":
            self = .fitWindow
        case "matchScreen":
            self = .matchScreen
        default:
            let parts = storageKey.split(separator: "x")
            guard parts.count == 2,
                  let w = Int(parts[0]), let h = Int(parts[1]),
                  w >= 200, h >= 200 else { return nil }
            self = .fixed(width: w, height: h)
        }
    }
}

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
    private static let displayPreferencesKey = "MioTerm.rdpDisplayPreferences"
    /// 超过 50 MB 的文件不走访达同步剪贴板回调（避免阻塞访达转圈卡死与 60 秒 IPC 超时），
    /// 改在切出 MioTerm 时弹出右上角轻量浮窗，由用户一键流式保存到「下载」或任意自选目录。
    private static let largeFilePromptThresholdBytes: UInt64 = 50 * 1024 * 1024
    private static var recentClipboardStagingDirs: [URL] = []
    private static var lazyPasteboardChangeCount: Int = -1
    private static var latestRemoteClipboardSource: RemoteClipboardFileSource?

    private var stateObservers: [UUID: (TerminalController.State) -> Void] = [:]
    private var clipboardObserver: NSObjectProtocol?
    private var resignActiveObserver: NSObjectProtocol?
    private var becomeActiveObserver: NSObjectProtocol?
    private var globalPasteKeyMonitor: Any?
    private var pendingGlobalPasteLargeFile: RDPClient.RemoteClipboardFileSummary?
    private var client: RDPClient?
    private var eventTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var clipboardPollTask: Task<Void, Never>?
    private var clipboardFetchTask: Task<Void, Never>?
    private var pendingRemoteFileSummary: RDPClient.RemoteClipboardFileSummary?
    private var activeLazyPasteboardProvider: LazyRDPFilePasteboardProvider?
    private var isDownloadingClipboardFiles = false
    private var swallowingRelayPasteKeyUp = false
    private var lastSyncedPasteboardChangeCount: Int = -1
    private var clipboardReady = false
    private var currentRemoteSize: (width: Int, height: Int) = (0, 0)
    private var appliedRemoteScale: Int = 100
    private var didQueueInitialDisplaySync = false
    private var lastRequestedReconnectSize: (width: Int, height: Int)?
    private(set) var resolutionMode: RDPResolutionMode = .fitWindow
    private(set) var scalePercent: Int = 100
    private var lastPassword: String?
    private var activeModifierFlags: NSEvent.ModifierFlags = []
    private var keyMapping = AppEnvironment.shared.settings.settings.remoteKeyMapping

    init(host: HostProfile) {
        self.host = host
        self.title = host.displayName
        loadSavedDisplaySettings()
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
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.publishPendingRemoteFilesIfNeeded()
            }
        }
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.removeGlobalPasteKeyMonitor()
                guard !self.isDownloadingClipboardFiles else { return }
                // 切回 MioTerm 时自动收起尚未点击的大文件下载提示，不打扰在 Windows 内的继续操作。
                RDPClipboardTransferHUD.shared.dismiss()
            }
        }
    }

    deinit {
        if let clipboardObserver {
            NotificationCenter.default.removeObserver(clipboardObserver)
        }
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
        }
        if let becomeActiveObserver {
            NotificationCenter.default.removeObserver(becomeActiveObserver)
        }
        if let globalPasteKeyMonitor {
            NSEvent.removeMonitor(globalPasteKeyMonitor)
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
        desktopView.onResetModifiers = { [weak self] in
            self?.syncModifiers([])
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
        lastRequestedReconnectSize = nil
        start(password: password, explicitSize: nil, preserveFramebuffer: false)
    }

    private func start(password: String?, explicitSize: (width: Int, height: Int)?, preserveFramebuffer: Bool) {
        guard let host else { return }
        stop(clearFramebuffer: !preserveFramebuffer)

        guard FreeRDPAvailability.isInstalled else {
            state = .failed(L10n.tr(.rdpDependencyMissing, FreeRDPAvailability.installCommand))
            return
        }

        state = .starting
        lastPassword = password
        didQueueInitialDisplaySync = false
        appliedRemoteScale = 100
        let initial = explicitSize ?? resolvedTargetSize(forConnect: true)
        let rdpClient = RDPClient(
            host: host.address,
            port: host.port,
            username: host.username,
            password: password ?? "",
            domain: "",
            width: initial.width,
            height: initial.height,
            scalePercent: scalePercent,
            enableAudio: host.rdpAudioEnabled
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
        rdpClient.onClipboardDownloadProgress = { [weak self, weak rdpClient] downloadedBytes, totalBytes in
            Task { @MainActor [weak self, weak rdpClient] in
                guard let self, let rdpClient, self.client === rdpClient, self.isDownloadingClipboardFiles else { return }
                self.updateClipboardDownloadProgress(downloadedBytes: downloadedBytes, totalBytes: totalBytes)
            }
        }
        rdpClient.onFrameReady = { [weak self, weak rdpClient] in
            Task { @MainActor [weak self, weak rdpClient] in
                guard let self, let rdpClient, self.client === rdpClient else { return }
                guard let frame = rdpClient.takeLatestSurface() else { return }
                self.currentRemoteSize = (frame.width, frame.height)
                self.desktopView.presentSurface(frame.surface, width: frame.width, height: frame.height)
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
            if !didQueueInitialDisplaySync {
                didQueueInitialDisplaySync = true
                // Windows 重连到已有会话时往往会忽略建连握手里的 DesktopScaleFactor，
                // 这里直接通过 DisplayControl 排队发送一次目标分辨率与缩放（待 disp_ready 就绪后立即下发；
                // 不支持 DisplayControl 的 Win7 不会触发任何动作）。
                let target = resolvedTargetSize(forConnect: false)
                if scalePercent != 100 || resolutionMode != .fitWindow || abs(target.width - width) >= 4 || abs(target.height - height) >= 4 {
                    appliedRemoteScale = scalePercent
                    client?.requestResize(width: target.width, height: target.height, scalePercent: scalePercent)
                }
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
        stop(clearFramebuffer: true)
    }

    private func stop(clearFramebuffer: Bool) {
        resizeTask?.cancel()
        resizeTask = nil
        clipboardPollTask?.cancel()
        clipboardPollTask = nil
        clipboardFetchTask?.cancel()
        clipboardFetchTask = nil
        pendingRemoteFileSummary = nil
        removeGlobalPasteKeyMonitor()
        activeLazyPasteboardProvider = nil
        if Self.latestRemoteClipboardSource?.controller === self {
            Self.latestRemoteClipboardSource = nil
        }
        if isDownloadingClipboardFiles {
            isDownloadingClipboardFiles = false
            client?.cancelRemoteClipboardDownload()
            RDPClipboardTransferHUD.shared.dismiss()
        }
        clipboardReady = false
        lastSyncedPasteboardChangeCount = -1
        syncModifiers([])
        eventTask?.cancel()
        eventTask = nil
        client?.stop()
        client = nil
        if clearFramebuffer {
            desktopView.clearFramebuffer()
        }
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
        guard changeCount != lastSyncedPasteboardChangeCount,
              changeCount != Self.lazyPasteboardChangeCount else { return }
        lastSyncedPasteboardChangeCount = changeCount

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            Self.latestRemoteClipboardSource = nil
            client.sendClipboardFilesAsync(urls)
            return
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            Self.latestRemoteClipboardSource = nil
            client.sendClipboardTextAsync(text)
        }
    }

    private func handleRemoteClipboardChanged(hasText: Bool, hasFiles: Bool, client: RDPClient) {
        clipboardFetchTask?.cancel()
        clipboardFetchTask = nil
        if hasFiles {
            clipboardFetchTask = Task.detached(priority: .userInitiated) { [weak self, weak client] in
                // 合并 Windows Explorer 短时间内连发两次 ServerFormatList 的抖动。
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled, let client else { return }
                // 按需流式粘贴：复制时仅拉取极小的 FileGroupDescriptorW 文件列表（约几百字节，瞬间完成），
                // 不主动下载文件内容；只有真正在 Mac 访达按 ⌘V 时才开始流式拉取。
                guard let summary = client.listRemoteClipboardFiles() else { return }
                await MainActor.run { [weak self, weak client] in
                    guard let self, let client, self.client === client, !Task.isCancelled else { return }
                    self.clipboardFetchTask = nil
                    self.pendingRemoteFileSummary = summary
                    Self.latestRemoteClipboardSource = RemoteClipboardFileSource(
                        controller: self,
                        client: client,
                        hostName: self.title,
                        summary: summary
                    )
                    // 如果用户当前就在 MioTerm 窗口内操作（比如在 Windows 里复制/移动文件，或在两个 RDP 之间导文件），
                    // 绝不立刻写入 Mac 剪贴板，避免触发系统 Universal Clipboard 或剪贴板监听工具提前拉取；
                    // 仅当用户切到访达等其他 Mac 应用（didResignActive）时，才把延迟项挂到 Mac 剪贴板。
                    if !NSApp.isActive {
                        self.publishPendingRemoteFilesIfNeeded()
                    }
                }
            }
            return
        }
        pendingRemoteFileSummary = nil
        if Self.latestRemoteClipboardSource?.controller === self {
            Self.latestRemoteClipboardSource = nil
        }
        if !isDownloadingClipboardFiles {
            onTitleChange?(title)
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

    private func publishPendingRemoteFilesIfNeeded() {
        guard let summary = pendingRemoteFileSummary, let client else { return }
        pendingRemoteFileSummary = nil
        if let source = Self.latestRemoteClipboardSource,
           source.controller === self,
           let cached = source.cachedStagedURLs, !cached.isEmpty {
            let pasteboard = NSPasteboard.general
            pasteboard.prepareForNewContents(with: .currentHostOnly)
            pasteboard.writeObjects(cached as [NSURL])
            lastSyncedPasteboardChangeCount = pasteboard.changeCount
            return
        }
        // 无论文件大小，切出 MioTerm 时都不弹任何浮窗、不下载任何字节。
        // 对于 > 50 MB 的大文件：
        // - 若已授予辅助功能权限（AXIsProcessTrusted），不写 .fileURL 到访达剪贴板，
        //   仅挂一个临时全局 ⌘V 监听，按下 ⌘V 直接流式下载，彻底消除访达“不能粘贴”报错弹窗；
        // - 未授权时自动回退到 .fileURL 延迟项以保证按 ⌘V 依然可用。
        if Self.isLargeRemoteTransfer(summary) {
            let axTrusted = AXIsProcessTrusted()
            FileLogger.shared.info("RDP 大文件切出准备: bytes=\(summary.totalBytes) axTrusted=\(axTrusted)")
            if axTrusted {
                installGlobalPasteMonitorForLargeFile(summary: summary, client: client)
                return
            }
        }
        installLazyFilePasteboard(summary: summary, client: client)
    }

    private func installGlobalPasteMonitorForLargeFile(
        summary: RDPClient.RemoteClipboardFileSummary,
        client: RDPClient
    ) {
        removeGlobalPasteKeyMonitor()
        // 清空可能残留的旧 .fileURL，避免在访达按 ⌘V 时把上一次的文件误贴出来或弹报错框。
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        lastSyncedPasteboardChangeCount = pasteboard.changeCount
        Self.lazyPasteboardChangeCount = pasteboard.changeCount

        pendingGlobalPasteLargeFile = summary
        globalPasteKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self, weak client] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard Int(event.keyCode) == kVK_ANSI_V, flags == .command else { return }
            Task { @MainActor [weak self, weak client] in
                guard let self, let client, self.client === client,
                      !NSApp.isActive,
                      let pending = self.pendingGlobalPasteLargeFile else { return }
                let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
                guard frontBundle == "com.apple.finder" else { return }
                FileLogger.shared.info("RDP 全局 ⌘V 触发大文件流式下载: files=\(pending.names.count) bytes=\(pending.totalBytes)")
                self.removeGlobalPasteKeyMonitor()
                self.startDirectLargeFileDownload(client: client, summary: pending)
            }
        }
    }

    private func removeGlobalPasteKeyMonitor() {
        pendingGlobalPasteLargeFile = nil
        if let monitor = globalPasteKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalPasteKeyMonitor = nil
        }
    }

    private func chooseDirectoryAndDownloadLargeFiles(
        client: RDPClient,
        summary: RDPClient.RemoteClipboardFileSummary
    ) {
        NSApp.activate(ignoringOtherApps: true)
        let openPanel = NSOpenPanel()
        openPanel.title = "选择保存目录"
        openPanel.prompt = "保存到此目录"
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if openPanel.runModal() == .OK, let dir = openPanel.url {
            startDirectLargeFileDownload(client: client, summary: summary, customDirectory: dir)
        } else {
            RDPClipboardTransferHUD.shared.dismiss()
        }
    }

    fileprivate func startDirectLargeFileDownload(
        client: RDPClient,
        summary: RDPClient.RemoteClipboardFileSummary,
        customDirectory: URL? = nil
    ) {
        guard self.client === client else { return }
        let rootDir = customDirectory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let targetDir = Self.resolveNonCollidingDownloadDirectory(root: rootDir, topLevelNames: summary.names)
        let fileSummary = Self.formatFileSummary(summary.names)
        let destinationLabel = customDirectory?.lastPathComponent ?? "下载目录"

        isDownloadingClipboardFiles = true
        onTitleChange?("\(title) · 正在接收大文件…")
        RDPClipboardTransferHUD.shared.show(
            hostName: title,
            fileSummary: fileSummary,
            destinationText: destinationLabel,
            totalBytes: summary.totalBytes,
            onCancel: { client.cancelRemoteClipboardDownload() }
        )

        Task.detached(priority: .userInitiated) { [weak self, weak client] in
            guard let client else { return }
            let urls = client.downloadRemoteClipboardFiles(to: targetDir)
            await MainActor.run { [weak self, weak client] in
                guard let self else { return }
                self.isDownloadingClipboardFiles = false
                self.onTitleChange?(self.title)
                guard let client, self.client === client, !urls.isEmpty else {
                    RDPClipboardTransferHUD.shared.dismiss()
                    if targetDir != rootDir {
                        try? FileManager.default.removeItem(at: targetDir)
                    }
                    return
                }
                let pasteboard = NSPasteboard.general
                pasteboard.prepareForNewContents(with: .currentHostOnly)
                pasteboard.writeObjects(urls as [NSURL])
                self.lastSyncedPasteboardChangeCount = pasteboard.changeCount
                RDPClipboardTransferHUD.shared.markCompleted(
                    savedURLs: urls,
                    message: "已保存至「\(destinationLabel)」，可直接打开或再次 ⌘V 粘贴"
                )
            }
        }
    }

    private static func resolveNonCollidingDownloadDirectory(root: URL, topLevelNames: [String]) -> URL {
        let fm = FileManager.default
        let hasCollision = topLevelNames.contains { name in
            fm.fileExists(atPath: root.appendingPathComponent(name).path)
        }
        guard hasCollision else { return root }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return root.appendingPathComponent("MioTerm-\(formatter.string(from: Date()))", isDirectory: true)
    }

    private func installLazyFilePasteboard(summary: RDPClient.RemoteClipboardFileSummary, client: RDPClient) {
        let provider = LazyRDPFilePasteboardProvider(controller: self, client: client, summary: summary)
        let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

        // 访达的 ⌘V 粘贴仅识别 public.file-url (.fileURL)；配合 NSPasteboardItemDataProvider，
        // 在 Windows 按 Ctrl+C 时零下载，仅在用户切到访达并按下 ⌘V 时才按需流式拉取并返回真实本地文件 URL。
        let items: [NSPasteboardItem] = summary.names.map { _ in
            let item = NSPasteboardItem()
            item.setDataProvider(provider, forTypes: [.fileURL])
            item.setData(Data(), forType: transientType)
            return item
        }
        provider.items = items
        activeLazyPasteboardProvider = provider

        let pasteboard = NSPasteboard.general
        // 必须指定 .currentHostOnly，禁止 macOS 通用剪贴板（useractivityd / Handoff）在后台偷读触发下载。
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.writeObjects(items)
        lastSyncedPasteboardChangeCount = pasteboard.changeCount
        Self.lazyPasteboardChangeCount = pasteboard.changeCount
    }

    fileprivate func fulfillLazyFilePasteSynchronously(
        client: RDPClient,
        summary: RDPClient.RemoteClipboardFileSummary
    ) -> [URL] {
        guard self.client === client else { return [] }
        let targetDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MioTermRDPClipboard", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileSummary = Self.formatFileSummary(summary.names)

        isDownloadingClipboardFiles = true
        onTitleChange?("\(title) · 正在同步剪贴板文件…")

        let showHUDImmediately = summary.totalBytes >= 5 * 1024 * 1024
        var hudShown = false
        if showHUDImmediately {
            hudShown = true
            RDPClipboardTransferHUD.shared.show(
                hostName: title,
                fileSummary: fileSummary,
                destinationText: "访达粘贴",
                totalBytes: summary.totalBytes,
                onCancel: { client.cancelRemoteClipboardDownload() }
            )
        }

        let box = SyncDownloadResultBox()
        let startDate = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let urls = client.downloadRemoteClipboardFiles(to: targetDir)
            box.finish(urls: urls)
        }

        while !box.isDone {
            let elapsed = Date().timeIntervalSince(startDate)
            if elapsed >= 25.0 {
                // 防止同步剪贴板回调长时间阻塞导致访达或 MioTerm 卡死。
                client.cancelRemoteClipboardDownload()
                break
            }
            if !hudShown && elapsed >= 0.35 {
                hudShown = true
                RDPClipboardTransferHUD.shared.show(
                    hostName: title,
                    fileSummary: fileSummary,
                    destinationText: "访达粘贴",
                    totalBytes: summary.totalBytes,
                    onCancel: { client.cancelRemoteClipboardDownload() }
                )
            }
            if let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.03), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }

        isDownloadingClipboardFiles = false
        onTitleChange?(title)
        if hudShown {
            RDPClipboardTransferHUD.shared.dismiss()
        }

        let urls = box.urls
        if urls.isEmpty {
            try? FileManager.default.removeItem(at: targetDir)
            return []
        }
        Self.registerClipboardStagingDir(targetDir)
        return urls
    }

    fileprivate static func isLargeRemoteTransfer(_ summary: RDPClient.RemoteClipboardFileSummary) -> Bool {
        summary.totalBytes > largeFilePromptThresholdBytes
    }

    private static func formatFileSummary(_ names: [String]) -> String {
        guard let first = names.first else { return "远端文件" }
        return names.count == 1 ? first : "\(first) 等 \(names.count) 项"
    }

    private func updateClipboardDownloadProgress(downloadedBytes: UInt64, totalBytes: UInt64) {
        RDPClipboardTransferHUD.shared.update(downloadedBytes: downloadedBytes, totalBytes: totalBytes)
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        let doneStr = formatter.string(fromByteCount: Int64(min(downloadedBytes, UInt64(Int64.max))))
        if totalBytes > 0 {
            let pct = min(100, Int((Double(downloadedBytes) / Double(totalBytes)) * 100.0))
            let totalStr = formatter.string(fromByteCount: Int64(min(totalBytes, UInt64(Int64.max))))
            onTitleChange?("\(title) · 正在同步剪贴板文件 \(pct)% (\(doneStr) / \(totalStr))…")
        } else {
            onTitleChange?("\(title) · 正在同步剪贴板文件 (\(doneStr))…")
        }
    }

    private static func registerClipboardStagingDir(_ dir: URL) {
        recentClipboardStagingDirs.append(dir)
        // 保留最近 8 个中转目录，同时在超过 1 GB 时自动清理更早的中转目录（始终保留最新一次），
        // 避免连续复制数 GB 大文件占满临时磁盘空间。
        let maxTotalStagingBytes: UInt64 = 1024 * 1024 * 1024
        while recentClipboardStagingDirs.count > 8 {
            let obsolete = recentClipboardStagingDirs.removeFirst()
            try? FileManager.default.removeItem(at: obsolete)
        }
        while recentClipboardStagingDirs.count > 1 && totalStagingBytes() > maxTotalStagingBytes {
            let obsolete = recentClipboardStagingDirs.removeFirst()
            try? FileManager.default.removeItem(at: obsolete)
        }
    }

    private static func totalStagingBytes() -> UInt64 {
        let fm = FileManager.default
        var total: UInt64 = 0
        for dir in recentClipboardStagingDirs {
            guard let enumerator = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let fileURL as URL in enumerator {
                if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 {
                    total += UInt64(size)
                }
            }
        }
        return total
    }

    private func screenLogicalSize() -> CGSize {
        (desktopView.window?.screen ?? NSScreen.main)?.frame.size ?? desktopView.bounds.size
    }

    private func loadSavedDisplaySettings() {
        guard let hostID = host?.id,
              let all = UserDefaults.standard.dictionary(forKey: Self.displayPreferencesKey) as? [String: [String: Any]],
              let saved = all[hostID] else { return }
        if let rawRes = saved["resolution"] as? String,
           let mode = RDPResolutionMode(storageKey: rawRes) {
            self.resolutionMode = mode
        }
        if let savedScale = saved["scalePercent"] as? Int,
           savedScale >= 100 && savedScale <= 200 {
            self.scalePercent = savedScale
        }
    }

    private func saveDisplaySettings() {
        guard let hostID = host?.id else { return }
        var all = (UserDefaults.standard.dictionary(forKey: Self.displayPreferencesKey) as? [String: [String: Any]]) ?? [:]
        all[hostID] = [
            "resolution": resolutionMode.storageKey,
            "scalePercent": scalePercent,
        ]
        UserDefaults.standard.set(all, forKey: Self.displayPreferencesKey)
    }

    private func resolvedTargetSize(forConnect: Bool) -> (width: Int, height: Int) {
        let baseWidth: Int
        let baseHeight: Int
        switch resolutionMode {
        case .fixed(let w, let h):
            baseWidth = w
            baseHeight = h
        case .matchScreen:
            let screenSize = screenLogicalSize()
            baseWidth = max(800, Int(screenSize.width))
            baseHeight = max(600, Int(screenSize.height))
        case .fitWindow:
            let base = forConnect ? screenLogicalSize() : desktopView.bounds.size
            baseWidth = max(forConnect ? 800 : 200, Int(base.width))
            baseHeight = max(forConnect ? 600 : 200, Int(base.height))
        }
        return (
            max(200, min(8192, (baseWidth + 1) & ~1)),
            max(200, min(8192, (baseHeight + 1) & ~1))
        )
    }

    /// Win7 等不支持 DisplayControl 的主机通过“保留画面 + 先断连等 500ms 再重连”切换精确分辨率，
    /// 避免快速重连触发“远程桌面服务当前正忙”，也避免跨屏/换电脑时分辨率错位模糊。
    private func reconnectForResize(to target: (width: Int, height: Int)) {
        let password = lastPassword
        lastRequestedReconnectSize = target
        stop(clearFramebuffer: false)
        state = .starting
        resizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.start(password: password, explicitSize: target, preserveFramebuffer: true)
        }
    }

    func applyDisplaySettings(resolution: RDPResolutionMode, scalePercent: Int) {
        let clampedScale = max(100, min(200, scalePercent))
        self.resolutionMode = resolution
        self.scalePercent = clampedScale
        self.lastRequestedReconnectSize = nil
        saveDisplaySettings()
        resizeTask?.cancel()
        resizeTask = nil
        guard state == .running, let client else { return }
        let target = resolvedTargetSize(forConnect: false)
        if client.supportsDynamicResize {
            appliedRemoteScale = clampedScale
            client.requestResize(width: target.width, height: target.height, scalePercent: clampedScale)
        } else {
            reconnectForResize(to: target)
        }
    }

    private func scheduleResize(for size: CGSize) {
        guard resolutionMode == .fitWindow else { return }
        // 只有支持 DisplayControl 的主机（Win10/11 等）才在窗口大小变化时无感动态调整；
        // Win7 协议本身不支持动态改分辨率，绝不因拖动/最大化窗口自动重新登录。
        guard client?.supportsDynamicResize == true else { return }
        let targetWidth = max(200, min(8192, (Int(size.width) + 1) & ~1))
        let targetHeight = max(200, min(8192, (Int(size.height) + 1) & ~1))
        let sizeChanged = abs(targetWidth - currentRemoteSize.width) >= 4 || abs(targetHeight - currentRemoteSize.height) >= 4
        let scaleChanged = appliedRemoteScale != scalePercent
        guard sizeChanged || scaleChanged else {
            return
        }
        let scale = scalePercent
        resizeTask?.cancel()
        resizeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self,
                  !Task.isCancelled,
                  self.state == .running,
                  self.resolutionMode == .fitWindow,
                  let client = self.client,
                  client.supportsDynamicResize else { return }
            self.appliedRemoteScale = scale
            client.requestResize(width: targetWidth, height: targetHeight, scalePercent: scale)
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
        if !down && swallowingRelayPasteKeyUp && Int(event.keyCode) == kVK_ANSI_V {
            swallowingRelayPasteKeyUp = false
            return
        }
        if down {
            syncModifiers(event.modifierFlags)
            if Int(event.keyCode) == kVK_ANSI_V,
               event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                syncLocalPasteboardToRemote()
                if let source = Self.latestRemoteClipboardSource,
                   source.controller !== self,
                   let sourceController = source.controller,
                   let sourceClient = source.client {
                    swallowingRelayPasteKeyUp = true
                    relayRemoteFilesFromAnotherRDP(
                        source: source,
                        sourceController: sourceController,
                        sourceClient: sourceClient
                    )
                    return
                }
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

    /// 零落盘直通中间人模式：在 RDP A 复制文件后切到 RDP B 按 Ctrl+V / ⌘V 时，
    /// 立刻把 A 的文件列表通告给 B 并触发粘贴；B 的资源管理器随即一边向 MioTerm 拉片、
    /// MioTerm 一边从 A 拉片直接回传给 B，全程零落盘、零等待、B 端直接显示原生复制进度条。
    private func relayRemoteFilesFromAnotherRDP(
        source: RemoteClipboardFileSource,
        sourceController: RDPController,
        sourceClient: RDPClient
    ) {
        if let cached = source.cachedStagedURLs, !cached.isEmpty {
            sendFiles(cached)
            return
        }
        guard clipboardReady, let targetClient = client else { return }
        focus()
        syncModifiers([])
        targetClient.relayClipboardFilesAsync(from: sourceClient) { [weak self, weak targetClient] ok in
            guard ok else { return }
            Task { @MainActor [weak self, weak targetClient] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self, let targetClient, self.client === targetClient, self.state == .running else { return }
                targetClient.sendScancode(0x1D, down: true)
                targetClient.sendScancode(0x2F, down: true)
                targetClient.sendScancode(0x2F, down: false)
                targetClient.sendScancode(0x1D, down: false)
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

@MainActor
private final class RemoteClipboardFileSource {
    weak var controller: RDPController?
    weak var client: RDPClient?
    let hostName: String
    let summary: RDPClient.RemoteClipboardFileSummary
    var cachedStagedURLs: [URL]?

    init(
        controller: RDPController,
        client: RDPClient,
        hostName: String,
        summary: RDPClient.RemoteClipboardFileSummary
    ) {
        self.controller = controller
        self.client = client
        self.hostName = hostName
        self.summary = summary
    }
}

private final class SyncDownloadResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var result: [URL] = []

    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    func finish(urls: [URL]) {
        lock.lock()
        result = urls
        done = true
        lock.unlock()
    }
}

/// 延迟提供 RDP 剪贴板文件 URL：Windows 按 Ctrl+C 时不下载任何内容，
/// 直到 Mac 端真正执行 ⌘V 粘贴时才触发流式拉取。
@MainActor
private final class LazyRDPFilePasteboardProvider: NSObject, NSPasteboardItemDataProvider {
    private weak var controller: RDPController?
    private weak var client: RDPClient?
    private let summary: RDPClient.RemoteClipboardFileSummary
    var items: [NSPasteboardItem] = []

    private var cachedURLs: [URL]?
    private var didStartLargeDownload = false

    init(controller: RDPController, client: RDPClient, summary: RDPClient.RemoteClipboardFileSummary) {
        self.controller = controller
        self.client = client
        self.summary = summary
        super.init()
    }

    nonisolated func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard type == .fileURL else { return }
        MainActor.assumeIsolated {
            guard let controller, let client else { return }
            // 如果 MioTerm 仍是前台活跃应用，说明不是用户在访达等外部应用按 ⌘V 粘贴，直接忽略。
            guard !NSApp.isActive else { return }
            let frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
            FileLogger.shared.info("RDP 剪贴板按需触发粘贴: frontApp=\(frontApp) files=\(summary.names.count) bytes=\(summary.totalBytes)")
            let itemIndex = items.firstIndex(where: { $0 === item }) ?? 0

            if let cachedURLs {
                if itemIndex < cachedURLs.count {
                    item.setString(cachedURLs[itemIndex].absoluteString, forType: .fileURL)
                }
                return
            }

            if RDPController.isLargeRemoteTransfer(summary) {
                guard !didStartLargeDownload else { return }
                didStartLargeDownload = true
                // 超过 50 MB 的大文件在用户按下 ⌘V 后立刻弹出浮窗并在后台流式保存到「下载」目录，
                // 不阻塞访达同步剪贴板导致卡死转圈。
                controller.startDirectLargeFileDownload(client: client, summary: summary)
                return
            }

            let urls = controller.fulfillLazyFilePasteSynchronously(client: client, summary: summary)
            cachedURLs = urls
            if itemIndex < urls.count {
                item.setString(urls[itemIndex].absoluteString, forType: .fileURL)
            }
        }
    }

    nonisolated func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        MainActor.assumeIsolated {
            cachedURLs = nil
            items = []
        }
    }
}
