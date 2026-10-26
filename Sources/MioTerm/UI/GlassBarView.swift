import AppKit

/// 面板底部的玻璃胶囊：纯色面板上没有东西可采样，光靠系统材质几乎看不出边界，
/// 所以底色、顶部高光和描边一律自己画；macOS 26 起底下再垫一层
/// NSGlassEffectView 取得系统材质，画出来的部分保证任何外观下都看得见。
@MainActor
final class GlassBarView: NSView {
    private let fill = GlassFillView()
    private let edge = GlassEdgeView()
    private let content: NSView
    private let padding: NSEdgeInsets
    private var glass: NSView?

    init(content: NSView, padding: NSEdgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)) {
        self.content = content
        self.padding = padding
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = false
        // 放进横向栈时保持药丸宽度，别被拉满整条面板。
        setContentHuggingPriority(.required, for: .horizontal)

        fill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fill)

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.tintColor = Theme.accentSoft
            glass.translatesAutoresizingMaskIntoConstraints = false
            addSubview(glass)
            self.glass = glass
        }

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        edge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(edge)

        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: trailingAnchor),
            fill.topAnchor.constraint(equalTo: topAnchor),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor),

            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding.left),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding.right),
            content.topAnchor.constraint(equalTo: topAnchor, constant: padding.top),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding.bottom),

            edge.leadingAnchor.constraint(equalTo: leadingAnchor),
            edge.trailingAnchor.constraint(equalTo: trailingAnchor),
            edge.topAnchor.constraint(equalTo: topAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if let glass {
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                glass.topAnchor.constraint(equalTo: topAnchor),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    override func layout() {
        super.layout()
        // 胶囊：圆角永远等于半高，窗口缩放时自己保持药丸形状。
        let radius = bounds.height / 2
        fill.cornerRadius = radius
        edge.cornerRadius = radius
        if #available(macOS 26.0, *), let glass = glass as? NSGlassEffectView {
            glass.cornerRadius = radius
        }

        layer?.shadowPath = CGPath(
            roundedRect: bounds,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        layer?.shadowColor = Theme.layerColor(.black, for: self)
        layer?.shadowOpacity = Theme.isDark(effectiveAppearance) ? 0.30 : 0.10
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }
}

/// 玻璃的底色与顶部反光。
private final class GlassFillView: NSView {
    var cornerRadius: CGFloat = 14 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        Theme.glassFill.setFill()
        path.fill()

        // 上沿一道柔光，模拟玻璃边缘把环境光聚起来的那层亮边。
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let highlightRect = NSRect(
            x: 0,
            y: bounds.maxY - bounds.height * 0.55,
            width: bounds.width,
            height: bounds.height * 0.55
        )
        let gradient = NSGradient(
            starting: Theme.glassHighlight,
            ending: Theme.glassHighlight.withAlphaComponent(0)
        )
        gradient?.draw(in: highlightRect, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// 描边单独盖在内容上方，避免被 NSGlassEffectView 的材质盖掉。
private final class GlassEdgeView: NSView {
    var cornerRadius: CGFloat = 14 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        Theme.glassBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
