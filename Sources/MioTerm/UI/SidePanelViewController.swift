import AppKit

/// 左侧面板：主机列表与远端文件树共用一个槽位。
/// 没会话时看主机，进入 SSH 主机后看文件，切换由会话状态驱动，也允许手动切。
/// 命令库已经移到右上角按钮的弹出面板，不再占用左侧。
@MainActor
final class SidePanelViewController: NSViewController {
    enum Mode: Int {
        case hosts = 0
        case files = 1
    }

    let hosts = HostSidebarViewController(repository: AppEnvironment.shared.hosts)
    let files = SFTPBrowserViewController()

    private let modeSwitcher = CapsuleSegmentedView(titles: ["主机", "文件"])
    /// 切换器套进系统玻璃，胶囊轨道由 NSGlassEffectView 提供，控件自己只画选中块和文字。
    private lazy var switcher: GlassBarView = {
        modeSwitcher.drawsTrack = false
        return GlassBarView(
            content: modeSwitcher,
            padding: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        )
    }()
    private let content = ContainerViewController()
    private let divider = NSView()
    private var autoSwitchedFor: UUID?
    private(set) var mode: Mode = .hosts

    override func loadView() {
        let root = SidePanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 280, height: 620))
        root.onAppearanceChange = { [weak self] in self?.refreshAppearance() }

        modeSwitcher.onChange = { [weak self] index in
            self?.select(Mode(rawValue: index) ?? .hosts)
        }
        modeSwitcher.selectedIndex = mode.rawValue
        modeSwitcher.setEnabled(false, at: Mode.files.rawValue)
        switcher.translatesAutoresizingMaskIntoConstraints = false

        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.layerColor(Theme.border, for: divider)
        divider.translatesAutoresizingMaskIntoConstraints = false

        addChild(content)
        let contentRoot = content.view
        contentRoot.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(switcher)
        root.addSubview(contentRoot)
        root.addSubview(divider)
        NSLayoutConstraint.activate([
            switcher.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            switcher.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            // 自绘控件没有 intrinsicContentSize，必须把宽度钉死；
            // 只用 lessThanOrEqual 时宽度是二义的，布局偶尔会把整条切换器压成 0。
            switcher.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            switcher.heightAnchor.constraint(equalToConstant: 26),

            contentRoot.topAnchor.constraint(equalTo: switcher.bottomAnchor, constant: 8),
            contentRoot.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentRoot.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentRoot.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
        ])
        // 若 bind(to:) 先于视图加载跑过，这里要按当前 mode 复原，否则分段控件和内容会错位。
        content.show(viewController(for: mode))
        view = root
    }

    private func viewController(for mode: Mode) -> NSViewController {
        switch mode {
        case .hosts: return hosts
        case .files: return files
        }
    }

    /// 当前标签是否是能用文件面板的 SSH 会话。
    static func supportsFiles(_ controller: TerminalController?) -> Bool {
        controller?.host?.protocolKind.supportsSFTP == true
    }

    func bind(to controller: TerminalController?) {
        let canBrowse = Self.supportsFiles(controller)
        modeSwitcher.setEnabled(canBrowse, at: Mode.files.rawValue)
        if !canBrowse {
            autoSwitchedFor = nil
            files.bind(to: nil)
            // 只有正停在文件视图上才退回主机。
            if mode == .files { select(.hosts) }
            return
        }
        guard let controller else { return }
        files.bind(to: controller)
        // 只在换会话时自动跳到文件视图，手动点回主机不该被抢回去。
        if autoSwitchedFor != controller.sessionID {
            autoSwitchedFor = controller.sessionID
            select(.files)
        }
    }

    @objc private func switcherChanged(_ sender: NSSegmentedControl) {
        select(Mode(rawValue: sender.selectedSegment) ?? .hosts)
    }

    func select(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        modeSwitcher.selectedIndex = mode.rawValue
        content.show(viewController(for: mode))
    }

    func showHosts() {
        autoSwitchedFor = nil
        select(.hosts)
    }

    private func refreshAppearance() {
        divider.layer?.backgroundColor = Theme.layerColor(Theme.border, for: divider)
    }
}

/// 侧栏底色只比终端亮一点，靠一条发丝线和工作区隔开。
@MainActor
private final class SidePanelBackgroundView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [Theme.sidebarTop, Theme.sidebarBottom])?.draw(in: bounds, angle: -90)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        onAppearanceChange?()
    }
}

/// 系统 `NSSegmentedControl` 的胶囊样式在深色底上几乎看不出分段和选中态，
/// 这里自绘容器、选中胶囊和悬停反馈，保证任何背景色下层级都清楚。
@MainActor
final class CapsuleSegmentedView: NSView {
    var onChange: ((Int) -> Void)?
    var selectedIndex = 0 {
        didSet {
            guard selectedIndex != oldValue else { return }
            needsDisplay = true
        }
    }

    /// 外层轨道交给玻璃时不再自绘底色和描边，只保留选中块、悬停与文字。
    var drawsTrack = true {
        didSet { needsDisplay = true }
    }

    private let titles: [String]
    private var enabledFlags: [Bool]
    private var hovered: Int?
    private var trackingAreaRef: NSTrackingArea?
    private let inset: CGFloat = 3

    init(titles: [String]) {
        self.titles = titles
        enabledFlags = Array(repeating: true, count: titles.count)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("侧栏视图")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    func setEnabled(_ enabled: Bool, at index: Int) {
        guard enabledFlags.indices.contains(index), enabledFlags[index] != enabled else { return }
        enabledFlags[index] = enabled
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseMoved(with event: NSEvent) {
        let index = index(at: convert(event.locationInWindow, from: nil))
        updateHover(index.flatMap { enabledFlags[$0] ? $0 : nil })
    }

    override func mouseExited(with event: NSEvent) {
        updateHover(nil)
    }

    private func updateHover(_ index: Int?) {
        guard hovered != index else { return }
        hovered = index
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = index(at: convert(event.locationInWindow, from: nil)),
              enabledFlags[index], index != selectedIndex else { return }
        selectedIndex = index
        onChange?(index)
    }

    private func index(at point: NSPoint) -> Int? {
        guard !titles.isEmpty, bounds.contains(point), bounds.width > inset * 2 else { return nil }
        let segmentWidth = (bounds.width - inset * 2) / CGFloat(titles.count)
        let relative = point.x - inset
        guard relative >= 0, relative < segmentWidth * CGFloat(titles.count) else { return nil }
        return min(titles.count - 1, Int(relative / segmentWidth))
    }

    private func segmentRect(_ index: Int) -> NSRect {
        let segmentWidth = (bounds.width - inset * 2) / CGFloat(titles.count)
        return NSRect(
            x: inset + CGFloat(index) * segmentWidth + 1,
            y: inset,
            width: segmentWidth - 2,
            height: bounds.height - inset * 2
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        if drawsTrack {
            let outer = bounds.insetBy(dx: 0.5, dy: 0.5)
            let outerPath = NSBezierPath(roundedRect: outer, xRadius: outer.height / 2, yRadius: outer.height / 2)
            Theme.surface.withAlphaComponent(0.9).setFill()
            outerPath.fill()
            Theme.border.setStroke()
            outerPath.lineWidth = 1
            outerPath.stroke()
        }

        guard !titles.isEmpty else { return }

        if titles.indices.contains(selectedIndex) {
            let pillRect = segmentRect(selectedIndex)
            let pill = NSBezierPath(roundedRect: pillRect, xRadius: pillRect.height / 2, yRadius: pillRect.height / 2)
            Theme.accent.withAlphaComponent(0.16).setFill()
            pill.fill()
            Theme.accent.withAlphaComponent(0.38).setStroke()
            pill.lineWidth = 1
            pill.stroke()
        }

        for index in titles.indices where index != selectedIndex {
            if hovered == index, enabledFlags[index] {
                let hoverRect = segmentRect(index)
                Theme.hoverFill.setFill()
                NSBezierPath(roundedRect: hoverRect, xRadius: hoverRect.height / 2, yRadius: hoverRect.height / 2).fill()
            }
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        for (index, title) in titles.enumerated() {
            let isSelected = index == selectedIndex
            let color: NSColor
            if !enabledFlags[index] {
                color = Theme.textTertiary.withAlphaComponent(0.45)
            } else if isSelected {
                color = Theme.accent
            } else {
                color = Theme.textSecondary
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: isSelected ? .semibold : .medium),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
            let segmentWidth = (bounds.width - inset * 2) / CGFloat(titles.count)
            let textRect = NSRect(
                x: inset + CGFloat(index) * segmentWidth,
                y: (bounds.height - 14) / 2,
                width: segmentWidth,
                height: 14
            )
            (title as NSString).draw(in: textRect, withAttributes: attributes)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
