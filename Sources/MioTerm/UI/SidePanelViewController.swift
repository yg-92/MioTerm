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
    private var filesAvailable = false
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
        controller?.host?.supportsSFTP == true
    }

    func bind(to controller: TerminalController?) {
        let canBrowse = Self.supportsFiles(controller)
        filesAvailable = canBrowse
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
        guard mode != .files || filesAvailable else { return }
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
/// 分段参照 Finder 标签页：等宽、边界细线，选中段是一块浮起的白色胶囊。
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
    /// 胶囊与分段边界之间留一点缝，选中块不糊在细线上。
    private let horizontalInset: CGFloat = 1.5
    private let verticalInset: CGFloat = 1

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
        // 跟踪区不能再要 .mouseMoved：见 moveMonitor 上的说明。进出仍由这片区域负责。
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    /// macOS 26 上，窗口里只要有一片跟踪区要 `.mouseMoved`，窗口服务器就会凭空造出
    /// `leftMouseDown`——用户没点，事件却来了（SwiftTerm 上游 issue #584 记的是同一件事，
    /// 它的处理就是摘掉 `.mouseMoved`，改用窗口级监听收移动）。
    /// 幻影单击落在指针当时所在的视图上，于是终端里刚框选的单词被当成“又单击了一下”清掉，
    /// 文件树上的双击也因为 clickCount 被搅乱而发不出 doubleAction。
    /// 所以悬停要的移动事件走这里：打开窗口的 `acceptsMouseMovedEvents`，用一个监听派发。
    /// 这个控件全应用只有一个实例，监听也就只留一份。
    private static weak var moveWindow: NSWindow?
    private static var moveMonitor: Any?
    private static var moveWindowOriginalSetting = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Self.stopReceivingMoves()
        guard let window else { return }
        Self.moveWindow = window
        Self.moveWindowOriginalSetting = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true
        Self.moveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved(within: event) }
            // 绝不吞掉：同窗口的终端视图和响应链还要看这些移动事件。
            return event
        }
    }

    private static func stopReceivingMoves() {
        if let monitor = moveMonitor { NSEvent.removeMonitor(monitor) }
        moveMonitor = nil
        // 只有还停在我们写上去的那个 true 上才还原，免得盖掉别人后来的设置。
        if let window = moveWindow, window.acceptsMouseMovedEvents {
            window.acceptsMouseMovedEvents = moveWindowOriginalSetting
        }
        moveWindow = nil
    }

    private func pointerMoved(within event: NSEvent) {
        guard let window, event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        let index = index(at: point)
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
        guard !titles.isEmpty, bounds.contains(point), bounds.width > 0 else { return nil }
        let segmentWidth = bounds.width / CGFloat(titles.count)
        return min(titles.count - 1, max(0, Int(point.x / segmentWidth)))
    }

    private func segmentRect(_ index: Int) -> NSRect {
        let segmentWidth = bounds.width / CGFloat(titles.count)
        return NSRect(
            x: CGFloat(index) * segmentWidth + horizontalInset,
            y: verticalInset,
            width: segmentWidth - horizontalInset * 2,
            height: bounds.height - verticalInset * 2
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
        let segmentWidth = bounds.width / CGFloat(titles.count)
        let dark = Theme.isDark(effectiveAppearance)

        // 选中段浮起一层白色胶囊：细描边 + 轻投影，和 Finder 的活动标签一致。
        if titles.indices.contains(selectedIndex) {
            let pillRect = segmentRect(selectedIndex)
            let pill = NSBezierPath(roundedRect: pillRect, xRadius: pillRect.height / 2, yRadius: pillRect.height / 2)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.30 : 0.10)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            (dark ? Theme.surfaceRaised : Theme.surface).setFill()
            pill.fill()
            NSGraphicsContext.restoreGraphicsState()
            Theme.border.setStroke()
            pill.lineWidth = 1
            pill.stroke()
        }

        // 分段细线；紧挨选中胶囊的那条让位，避免和描边叠在一起。
        Theme.border.setFill()
        for boundary in 1..<titles.count {
            guard selectedIndex != boundary, selectedIndex != boundary - 1 else { continue }
            let x = (CGFloat(boundary) * segmentWidth).rounded()
            NSRect(x: x, y: 6, width: 1, height: bounds.height - 12).fill()
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
                color = Theme.textPrimary
            } else {
                color = Theme.textSecondary
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
            let textRect = NSRect(
                x: CGFloat(index) * segmentWidth,
                y: (bounds.height - 15) / 2,
                width: segmentWidth,
                height: 15
            )
            (title as NSString).draw(in: textRect, withAttributes: attributes)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
