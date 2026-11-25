import AppKit
import Foundation

/// 跨应用可见的 RDP 文件流式接收进度与大文件确认浮窗。
@MainActor
final class RDPClipboardTransferHUD {
    static let shared = RDPClipboardTransferHUD()

    private var panel: NSPanel?
    private let titleLabel = NSTextField(labelWithString: "")
    private let fileLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let detailLabel = NSTextField(labelWithString: "")
    private let primaryButton = NSButton(title: "下载到「下载」", target: nil, action: nil)
    private let secondaryButton = NSButton(title: "另存为…", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)

    private var onPrimaryAction: (() -> Void)?
    private var onSecondaryAction: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var startTime: Date = Date()
    private var autoDismissTask: Task<Void, Never>?

    private init() {}

    /// 检测到远端复制超大文件（> 200 MB）且用户切出 MioTerm 时，提示用户选择直接流式下载，
    /// 避免访达 ⌘V 同步剪贴板超时或弹出错误提示框。
    func showLargeFilePrompt(
        hostName: String,
        fileSummary: String,
        totalBytes: UInt64,
        onDownloadToDownloads: @escaping () -> Void,
        onChooseDirectory: @escaping () -> Void
    ) {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        onPrimaryAction = onDownloadToDownloads
        onSecondaryAction = onChooseDirectory
        onCancel = nil

        let panel = ensurePanel()
        titleLabel.stringValue = "\(hostName) 已复制大文件（\(Self.formatBytes(totalBytes))）"
        fileLabel.stringValue = fileSummary
        progressBar.isHidden = true
        detailLabel.stringValue = "大文件请直接流式保存，避免访达粘贴超时"

        primaryButton.title = "下载到「下载」"
        primaryButton.keyEquivalent = "\r"
        primaryButton.isHidden = false

        secondaryButton.title = "另存为…"
        secondaryButton.isHidden = false

        cancelButton.title = "忽略"
        cancelButton.isHidden = false

        positionPanel(panel)
        panel.orderFrontRegardless()
    }

    func show(
        hostName: String,
        fileSummary: String,
        destinationText: String,
        totalBytes: UInt64,
        onCancel: @escaping () -> Void
    ) {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        self.onPrimaryAction = nil
        self.onSecondaryAction = nil
        self.onCancel = onCancel
        self.startTime = Date()

        let panel = ensurePanel()
        titleLabel.stringValue = "正在从 \(hostName) 接收文件"
        fileLabel.stringValue = destinationText.isEmpty ? fileSummary : "\(fileSummary)  →  \(destinationText)"

        progressBar.isHidden = false
        progressBar.isIndeterminate = totalBytes == 0
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.doubleValue = 0
        if totalBytes == 0 {
            progressBar.startAnimation(nil)
        } else {
            progressBar.stopAnimation(nil)
        }

        if totalBytes > 0 {
            detailLabel.stringValue = "0% · 0 KB / \(Self.formatBytes(totalBytes))"
        } else {
            detailLabel.stringValue = "准备接收…"
        }

        primaryButton.isHidden = true
        secondaryButton.isHidden = true
        cancelButton.title = "取消"
        cancelButton.isHidden = false

        positionPanel(panel)
        panel.orderFrontRegardless()
    }

    func update(downloadedBytes: UInt64, totalBytes: UInt64) {
        guard panel?.isVisible == true, !progressBar.isHidden else { return }
        let elapsed = max(0.2, Date().timeIntervalSince(startTime))
        let bytesPerSec = Double(downloadedBytes) / elapsed
        let speedText = "\(Self.formatBytes(UInt64(max(0, bytesPerSec))))/s"
        let doneText = Self.formatBytes(downloadedBytes)

        if totalBytes > 0 {
            progressBar.isIndeterminate = false
            let fraction = min(1.0, Double(downloadedBytes) / Double(totalBytes))
            progressBar.doubleValue = fraction * 100.0
            let pct = Int(fraction * 100.0)
            let totalText = Self.formatBytes(totalBytes)
            var etaText = ""
            if bytesPerSec > 1024, downloadedBytes < totalBytes {
                let remainingSec = Int(Double(totalBytes - downloadedBytes) / bytesPerSec)
                etaText = " · 剩余约 \(Self.formatDuration(remainingSec))"
            }
            detailLabel.stringValue = "\(pct)% · \(doneText) / \(totalText) · \(speedText)\(etaText)"
        } else {
            detailLabel.stringValue = "已接收 \(doneText) · \(speedText)"
        }
    }

    func markCompleted(savedURLs: [URL], message: String) {
        autoDismissTask?.cancel()
        onCancel = nil
        onSecondaryAction = nil
        onPrimaryAction = savedURLs.isEmpty ? nil : { [weak self] in
            NSWorkspace.shared.activateFileViewerSelecting(savedURLs)
            self?.dismiss()
        }
        guard let panel else { return }
        titleLabel.stringValue = "文件接收完成"
        progressBar.isHidden = false
        progressBar.isIndeterminate = false
        progressBar.stopAnimation(nil)
        progressBar.doubleValue = 100
        detailLabel.stringValue = message

        primaryButton.title = "在访达中显示"
        primaryButton.keyEquivalent = ""
        primaryButton.isHidden = savedURLs.isEmpty
        secondaryButton.isHidden = true
        cancelButton.title = "关闭"
        cancelButton.isHidden = false
        panel.orderFrontRegardless()

        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.dismiss()
        }
    }

    func dismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        onPrimaryAction = nil
        onSecondaryAction = nil
        onCancel = nil
        panel?.orderOut(nil)
    }

    @objc private func handlePrimary() {
        let action = onPrimaryAction
        onPrimaryAction = nil
        action?()
    }

    @objc private func handleSecondary() {
        let action = onSecondaryAction
        onSecondaryAction = nil
        action?()
    }

    @objc private func handleCancel() {
        if let onCancel {
            self.onCancel = nil
            detailLabel.stringValue = "正在取消…"
            onCancel()
            dismiss()
        } else {
            dismiss()
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 132),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "MioTerm 文件传输"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 132))
        content.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        fileLabel.font = .systemFont(ofSize: 11.5)
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progressBar.style = .bar
        progressBar.controlSize = .small

        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        primaryButton.bezelStyle = .rounded
        primaryButton.controlSize = .small
        primaryButton.target = self
        primaryButton.action = #selector(handlePrimary)

        secondaryButton.bezelStyle = .rounded
        secondaryButton.controlSize = .small
        secondaryButton.target = self
        secondaryButton.action = #selector(handleSecondary)

        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.target = self
        cancelButton.action = #selector(handleCancel)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [spacer, secondaryButton, primaryButton, cancelButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let stack = NSStackView(views: [titleLabel, fileLabel, progressBar, detailLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fileLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progressBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        panel.contentView = content
        self.panel = panel
        return panel
    }

    private func positionPanel(_ panel: NSPanel) {
        guard !panel.isVisible else { return }
        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screenFrame.maxX - panel.frame.width - 24,
            y: screenFrame.maxY - panel.frame.height - 24
        )
        panel.setFrameOrigin(origin)
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    private static func formatDuration(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds) 秒"
        }
        let mins = seconds / 60
        let secs = seconds % 60
        return secs > 0 ? "\(mins) 分 \(secs) 秒" : "\(mins) 分钟"
    }
}
