import AppKit

/// 面板上的玻璃胶囊，按 Apple 文档的用法实现：
/// 把内容装进 NSGlassEffectView.contentView，用 cornerRadius 控制圆角，
/// tintColor 给玻璃染上主题色。26 以前没有这个 API，退回 NSVisualEffectView。
@MainActor
final class GlassBarView: NSView {
    private let content: NSView
    private let padding: NSEdgeInsets
    private var glass: NSView?
    private var blur: NSVisualEffectView?

    init(content: NSView, padding: NSEdgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)) {
        self.content = content
        self.padding = padding
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // 放进横向栈时保持胶囊宽度，别被拉满整条面板。
        setContentHuggingPriority(.required, for: .horizontal)

        if #available(macOS 26.0, *) {
            let host = NSView()
            host.translatesAutoresizingMaskIntoConstraints = false
            embed(content, in: host)

            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 16
            // 纯色面板上没有背景可采样，染一点主题强调色让玻璃有明确的存在感。
            glass.tintColor = Theme.accentSoft
            glass.contentView = host
            glass.translatesAutoresizingMaskIntoConstraints = false
            addSubview(glass)
            self.glass = glass
            pin(glass)
        } else {
            let blur = NSVisualEffectView()
            blur.material = .popover
            blur.blendingMode = .withinWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.translatesAutoresizingMaskIntoConstraints = false
            addSubview(blur)
            self.blur = blur
            pin(blur)
            embed(content, in: self)
        }
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    override func layout() {
        super.layout()
        // 高度变了也保持药丸形状，交给系统玻璃自己重绘圆角。
        let radius = bounds.height / 2
        if #available(macOS 26.0, *), let glass = glass as? NSGlassEffectView {
            glass.cornerRadius = radius
        }
        blur?.layer?.cornerRadius = radius
    }

    private func embed(_ view: NSView, in host: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: padding.left),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -padding.right),
            view.topAnchor.constraint(equalTo: host.topAnchor, constant: padding.top),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -padding.bottom),
        ])
    }

    private func pin(_ view: NSView) {
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
