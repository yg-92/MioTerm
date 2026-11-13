import AppKit
import MioTermCore

/// 分屏时才显示的会话标题；焦点只改变小圆点与文字权重，不描整圈边框。
@MainActor
final class TerminalPaneHeaderView: NSView {
    var onActivate: (() -> Void)?
    private let indicator = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let directoryLabel = NSTextField(labelWithString: "")
    private let separator = NSView()
    private var active = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 3
        separator.wantsLayer = true
        for child in [indicator, titleLabel, directoryLabel, separator] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        directoryLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        directoryLabel.lineBreakMode = .byTruncatingMiddle
        directoryLabel.maximumNumberOfLines = 1
        directoryLabel.alignment = .right
        directoryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            indicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            indicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 6),
            indicator.heightAnchor.constraint(equalToConstant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: indicator.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.55),
            directoryLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 16),
            directoryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            directoryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
        refreshAppearance()
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    func update(title: String, directory: String?, active: Bool) {
        self.active = active
        titleLabel.stringValue = title
        directoryLabel.stringValue = directory ?? ""
        toolTip = [title, directory].compactMap { $0 }.joined(separator: " · ")
        setAccessibilityLabel("\(title)\(active ? L10n.tr(.paneHeaderActiveSuffix) : L10n.tr(.paneHeaderInactiveSuffix))")
        refreshAppearance()
    }

    func refreshAppearance() {
        layer?.backgroundColor = Theme.layerColor(active ? Theme.surfaceRaised : Theme.surface, for: self)
        indicator.layer?.backgroundColor = Theme.layerColor(active ? Theme.accent : Theme.textTertiary, for: self)
        separator.layer?.backgroundColor = Theme.layerColor(Theme.border, for: self)
        titleLabel.font = .systemFont(ofSize: 11, weight: active ? .semibold : .medium)
        titleLabel.textColor = active ? Theme.textPrimary : Theme.textSecondary
        directoryLabel.textColor = Theme.textTertiary
    }

    override func mouseDown(with event: NSEvent) { onActivate?() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
}
