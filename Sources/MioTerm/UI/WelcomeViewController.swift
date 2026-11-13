import AppKit
import MioTermCore

/// 主页：没有选中会话时的落地页。左侧仍是主机列表，
/// 这里只放最常用的四个入口，视觉上让刚打开的窗口不至于空白。
@MainActor
final class WelcomeViewController: NSViewController {
    private let subtitle = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private let localCard = WelcomeActionCard(
        symbol: "terminal.fill",
        title: "",
        detail: "",
        shortcut: "⌘T",
        action: #selector(WorkspaceViewController.newLocalTerminal(_:))
    )
    private let newHostCard = WelcomeActionCard(
        symbol: "plus.circle.fill",
        title: "",
        detail: "",
        shortcut: "⌘N",
        action: #selector(WorkspaceViewController.newHost(_:))
    )
    private let connectCard = WelcomeActionCard(
        symbol: "bolt.fill",
        title: "",
        detail: "",
        shortcut: "↩",
        action: #selector(WorkspaceViewController.connectSelectedHost(_:))
    )
    private let settingsCard = WelcomeActionCard(
        symbol: "gearshape.fill",
        title: "",
        detail: "",
        shortcut: "⌘,",
        action: #selector(WorkspaceViewController.showPreferences(_:))
    )
    private var settingsObserver: NSObjectProtocol?

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    override func loadView() {
        let root = WelcomeBackgroundView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        view = root

        let mark = NSImageView()
        mark.image = NSApp.applicationIconImage
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "MioTerm")
        title.font = .systemFont(ofSize: 34, weight: .bold)
        title.textColor = Theme.textPrimary
        title.alignment = .center

        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = Theme.textSecondary
        subtitle.alignment = .center

        hint.font = .systemFont(ofSize: 12)
        hint.textColor = Theme.textTertiary
        hint.alignment = .center

        let cards = makeCards()
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = Theme.textTertiary
        footer.alignment = .center

        let stack = NSStackView(views: [mark, title, subtitle, hint, cards, footer])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(18, after: mark)
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(22, after: hint)
        stack.setCustomSpacing(22, after: cards)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            mark.widthAnchor.constraint(equalToConstant: 68),
            mark.heightAnchor.constraint(equalToConstant: 68),
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -14),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            cards.widthAnchor.constraint(equalToConstant: 464),
        ])

        applyLocalization()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .mioTermSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyLocalization()
            }
        }
    }

    private func applyLocalization() {
        subtitle.stringValue = L10n.tr(.welcomeSubtitle)
        hint.stringValue = L10n.tr(.welcomeHint)
        footer.stringValue = L10n.tr(.welcomeFooter)
        localCard.updateContent(
            title: L10n.tr(.welcomeLocalTerminal),
            detail: L10n.tr(.welcomeLocalTerminalDetail)
        )
        newHostCard.updateContent(
            title: L10n.tr(.welcomeNewHost),
            detail: L10n.tr(.welcomeNewHostDetail)
        )
        connectCard.updateContent(
            title: L10n.tr(.welcomeConnectTitle),
            detail: L10n.tr(.welcomeConnectDetail)
        )
        settingsCard.updateContent(
            title: L10n.tr(.welcomeSettingsTitle),
            detail: L10n.tr(.welcomeSettingsDetail)
        )
    }

    private func makeCards() -> NSView {
        let left = NSStackView(views: [localCard, newHostCard])
        let right = NSStackView(views: [connectCard, settingsCard])
        for column in [left, right] {
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 12
        }
        let grid = NSStackView(views: [left, right])
        grid.orientation = .horizontal
        grid.alignment = .top
        grid.spacing = 12
        return grid
    }
}

// MARK: - 背景

@MainActor
private final class WelcomeBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill()
        bounds.fill()

        if let gradient = NSGradient(colors: [Theme.glow, Theme.background]) {
            gradient.draw(in: bounds, angle: -90)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - 入口卡片

@MainActor
private final class WelcomeActionCard: NSView {
    private let action: Selector
    private let iconView = NSImageView()
    private let iconBadge = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var hovering = false

    init(symbol: String, title: String, detail: String, shortcut: String, action: Selector) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        iconBadge.wantsLayer = true
        iconBadge.layer?.cornerRadius = 8
        iconBadge.layer?.cornerCurve = .continuous
        iconBadge.layer?.backgroundColor = Theme.layerColor(Theme.accentSoft, for: iconBadge)
        iconBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconBadge)

        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iconView.contentTintColor = Theme.accent
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconBadge.addSubview(iconView)

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        detailLabel.stringValue = detail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = Theme.textSecondary
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailLabel)

        shortcutLabel.stringValue = shortcut
        shortcutLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        shortcutLabel.textColor = Theme.textTertiary
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shortcutLabel)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 226),
            heightAnchor.constraint(equalToConstant: 78),
            iconBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconBadge.widthAnchor.constraint(equalToConstant: 34),
            iconBadge.heightAnchor.constraint(equalToConstant: 34),
            iconView.centerXAnchor.constraint(equalTo: iconBadge.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBadge.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 17),
            iconView.heightAnchor.constraint(equalToConstant: 17),
            titleLabel.leadingAnchor.constraint(equalTo: iconBadge.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -6),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            shortcutLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    func updateContent(title: String, detail: String) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        NSApp.sendAction(action, to: nil, from: self)
    }

    private func updateAppearance() {
        iconBadge.layer?.backgroundColor = Theme.layerColor(Theme.accentSoft, for: iconBadge)
        layer?.backgroundColor = Theme.layerColor(hovering ? Theme.surfaceRaised : Theme.surface, for: self)
        layer?.borderColor = Theme.layerColor(
            hovering ? Theme.accent.withAlphaComponent(0.55) : Theme.border,
            for: self
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }
}
