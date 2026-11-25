import AppKit
import Foundation

/// 跨应用可见的 RDP 文件流式接收进度浮窗（在访达粘贴或接收大文件时显示实时进度、速率与取消按钮）。
@MainActor
final class RDPClipboardTransferHUD {
    static let shared = RDPClipboardTransferHUD()

    private var panel: NSPanel?
    private let titleLabel = NSTextField(labelWithString: "")
    private let fileLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let detailLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "取消", target: nil, action: nil)
    private let revealButton = NSButton(title: "在访达中显示", target: nil, action: nil)

    private var onCancel: (() -> Void)?
    private var completedURLs: [URL] = []
    private var startTime: Date = Date()
    private var autoDismissTask: Task<Void, Never>?

    private init() {}

    func show(
        hostName: String,
        fileSummary: String,
        destinationText: String,
        totalBytes: UInt64,
        onCancel: @escaping () -> Void
    ) {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        self.onCancel = onCancel
        self.completedURLs = []
        self.startTime = Date()

        let panel = ensurePanel()
        titleLabel.stringValue = "正在从 \(hostName) 接收文件"
        fileLabel.stringValue = destinationText.isEmpty ? fileSummary : "\(fileSummary)  →  \(destinationText)"

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

        actionButton.title = "取消"
        actionButton.isHidden = false
        revealButton.isHidden = true

        positionPanel(panel)
        panel.orderFrontRegardless()
    }

    func update(downloadedBytes: UInt64, totalBytes: UInt64) {
        guard panel?.isVisible == true else { return }
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
        completedURLs = savedURLs
        guard let panel else { return }
        titleLabel.stringValue = "文件接收完成"
        progressBar.isIndeterminate = false
        progressBar.stopAnimation(nil)
        progressBar.doubleValue = 100
        detailLabel.stringValue = message
        actionButton.title = "关闭"
        actionButton.isHidden = false
        revealButton.isHidden = savedURLs.isEmpty
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
        onCancel = nil
        completedURLs = []
        panel?.orderOut(nil)
    }

    @objc private func handleAction() {
        if let onCancel {
            self.onCancel = nil
            detailLabel.stringValue = "正在取消…"
            onCancel()
            dismiss()
        } else {
            dismiss()
        }
    }

    @objc private func handleRevealInFinder() {
        guard !completedURLs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(completedURLs)
        dismiss()
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 410, height: 126),
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

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 410, height: 126))
        content.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        fileLabel.font = .systemFont(ofSize: 11.5)
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.lineBreakMode = .byTruncatingMiddle

        progressBar.style = .bar
        progressBar.controlSize = .small

        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.target = self
        actionButton.action = #selector(handleAction)

        revealButton.bezelStyle = .rounded
        revealButton.controlSize = .small
        revealButton.target = self
        revealButton.action = #selector(handleRevealInFinder)
        revealButton.isHidden = true

        let buttonRow = NSStackView(views: [NSView(), revealButton, actionButton])
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
            progressBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fileLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
