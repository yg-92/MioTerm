import AppKit
import MioTermCore

/// 分屏时才显示的会话标题；焦点只改变小圆点与文字权重，不描整圈边框。
@MainActor
final class TerminalPaneHeaderView: NSView {
    var onActivate: (() -> Void)?
    var onClose: (() -> Void)?
    private let indicator = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let directoryLabel = NSTextField(labelWithString: "")
    private let closeButton = PaneHeaderCloseButton()
    private let separator = NSView()
    private var active = false
    var translucentBackdrop = false {
        didSet {
            guard translucentBackdrop != oldValue else { return }
            refreshAppearance()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 3
        separator.wantsLayer = true
        for child in [indicator, titleLabel, directoryLabel, closeButton, separator] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        closeButton.onTap = { [weak self] in self?.onClose?() }
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
            directoryLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            directoryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
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
        let baseSurface = active ? Theme.surfaceRaised : Theme.surface
        let background = translucentBackdrop
            ? baseSurface.withAlphaComponent(active ? 0.36 : 0.18)
            : baseSurface
        layer?.backgroundColor = Theme.layerColor(background, for: self)
        indicator.layer?.backgroundColor = Theme.layerColor(active ? Theme.accent : Theme.textTertiary, for: self)
        separator.layer?.backgroundColor = Theme.layerColor(Theme.border, for: self)
        titleLabel.font = .systemFont(ofSize: 11, weight: active ? .semibold : .medium)
        titleLabel.textColor = active ? Theme.textPrimary : Theme.textSecondary
        directoryLabel.textColor = Theme.textTertiary
        closeButton.refreshAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    override func mouseDown(with event: NSEvent) { onActivate?() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit.isDescendant(of: closeButton) ? hit : self
    }
}

@MainActor
private final class PaneHeaderCloseButton: NSButton {
    var onTap: (() -> Void)?
    private var hoverArea: NSTrackingArea?
    private var hovering = false {
        didSet { refreshAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        isBordered = false
        setButtonType(.momentaryChange)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.tr(.menuCloseTab))?
            .withSymbolConfiguration(config)
        toolTip = L10n.tr(.menuCloseTab)
        target = self
        action = #selector(tapped)
        refreshAppearance()
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    @objc private func tapped() { onTap?() }

    func refreshAppearance() {
        contentTintColor = hovering ? Theme.textPrimary : Theme.textTertiary
        layer?.backgroundColor = hovering
            ? Theme.layerColor(Theme.hoverFill, for: self)
            : NSColor.clear.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }
}
