import AppKit

/// 主页：没有选中会话时的落地页。左侧仍是主机列表，
/// 这里只放最常用的四个入口，视觉上让刚打开的窗口不至于空白。
@MainActor
final class WelcomeViewController: NSViewController {
    override func loadView() {
        let root = WelcomeBackgroundView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        view = root

        let mark = BrandMarkView(frame: NSRect(x: 0, y: 0, width: 68, height: 68))
        mark.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "MioTerm")
        title.font = .systemFont(ofSize: 34, weight: .bold)
        title.textColor = Theme.textPrimary
        title.alignment = .center

        let subtitle = NSTextField(labelWithString: "原生 macOS 终端工作台 · SSH / Telnet / 串口")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = Theme.textSecondary
        subtitle.alignment = .center

        let hint = NSTextField(labelWithString: "在左侧选择主机回车连接，或从下面开始")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = Theme.textTertiary
        hint.alignment = .center

        let cards = makeCards()
        let footer = NSTextField(labelWithString: "⌘T 新建终端   ·   ⌘N 新增主机   ·   ⌘, 设置")
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
    }

    private func makeCards() -> NSView {
        let left = NSStackView(views: [
            WelcomeActionCard(
                symbol: "terminal.fill",
                title: "新建本地终端",
                detail: "打开一个本机 shell",
                shortcut: "⌘T",
                action: #selector(WorkspaceViewController.newLocalTerminal(_:))
            ),
            WelcomeActionCard(
                symbol: "plus.circle.fill",
                title: "新增主机",
                detail: "SSH、Telnet 或串口",
                shortcut: "⌘N",
                action: #selector(WorkspaceViewController.newHost(_:))
            ),
        ])
        let right = NSStackView(views: [
            WelcomeActionCard(
                symbol: "bolt.fill",
                title: "连接所选主机",
                detail: "选中左侧主机后直接连接",
                shortcut: "↩",
                action: #selector(WorkspaceViewController.connectSelectedHost(_:))
            ),
            WelcomeActionCard(
                symbol: "gearshape.fill",
                title: "设置",
                detail: "字体、跟随与关闭确认",
                shortcut: "⌘,",
                action: #selector(WorkspaceViewController.showPreferences(_:))
            ),
        ])
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
        let glow = NSRect(
            x: bounds.midX - 300,
            y: bounds.midY - 220,
            width: 600,
            height: 440
        )
        let path = NSBezierPath(ovalIn: glow)
        NSGradient(
            colors: [Theme.accent.withAlphaComponent(0.13), Theme.accent.withAlphaComponent(0)]
        )?.draw(in: path, relativeCenterPosition: .zero)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// 程序化画的应用标记：渐变圆角方块，代替缺位的 bundle 图标。
@MainActor
private final class BrandMarkView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 17, yRadius: 17)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = Theme.accent.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 26
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.set()
        NSGradient(colors: [Theme.accentDeep, Theme.purple])?.draw(in: path, angle: -55)
        NSGraphicsContext.restoreGraphicsState()

        guard let glyph = NSImage(systemSymbolName: "terminal.fill", accessibilityDescription: nil) else { return }
        let tinted = glyph.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        ) ?? glyph
        let size = tinted.size
        tinted.draw(in: NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        ))
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
