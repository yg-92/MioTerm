import AppKit
import MioTermCore
import SwiftTerm

/// 统一主题：颜色按“深浅 × 对比度档位 × 强调色”从 `ThemePalette` 取，
/// 装进动态 NSColor，界面在切换外观或配色档位时自动重绘。
/// 强调色只出现在选中态与图标上，避免整屏花哨。
enum Theme {
    /// 当前档位对应的深浅两套调色板。动态色的提供器每次绘制都会来取，
    /// 所以换档位只需替换这份数据，再让视图重绘一次。
    private struct Scheme {
        var dark: ThemePalette
        var light: ThemePalette
        var customization = ThemeCustomization()
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scheme = Scheme(
        dark: ThemePalette.palette(dark: true, contrast: .soft, accent: .blue),
        light: ThemePalette.palette(dark: false, contrast: .soft, accent: .blue)
    )

    /// 由设置在启动与保存时调用；调用方随后要让已经画好的视图重绘一次。
    static func configure(contrast: UIContrast, accent: AccentColor, customization: ThemeCustomization = ThemeCustomization()) {
        lock.lock()
        scheme = Scheme(
            dark: customization.applying(to: ThemePalette.palette(dark: true, contrast: contrast, accent: accent), dark: true),
            light: customization.applying(to: ThemePalette.palette(dark: false, contrast: contrast, accent: accent), dark: false),
            customization: customization
        )
        lock.unlock()
    }

    static func palette(dark: Bool) -> ThemePalette {
        lock.lock()
        defer { lock.unlock() }
        return dark ? scheme.dark : scheme.light
    }

    static func rgba(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
    }

    private static func color(_ rgb: ThemeRGB, alpha: CGFloat = 1) -> NSColor {
        rgba(CGFloat(rgb.red), CGFloat(rgb.green), CGFloat(rgb.blue), alpha)
    }

    /// 同一个颜色名给出深浅两份：AppKit 在绘制时按当前外观取用，
    /// 文本、图标、描边这类 NSColor 就不必在切换主题时逐个重设。
    private static func dynamic(_ name: String, _ pick: @escaping (ThemePalette) -> NSColor) -> NSColor {
        NSColor(name: NSColor.Name("mio.theme.\(name)")) { appearance in
            pick(palette(dark: isDark(appearance)))
        }
    }

    static func isDark(_ appearance: NSAppearance? = nil) -> Bool {
        let resolved = appearance ?? NSApp?.effectiveAppearance
        return resolved?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// 图层只接受 CGColor；动态色必须在赋值前按当前外观解析，
    /// 否则会固化成赋值那一刻的深浅版本。
    /// 外观取窗口的而不是这个视图自己的：外观变化自上而下派发，
    /// 父视图收到回调时子视图的 effectiveAppearance 还是旧值，按它解析会把旧配色固化进图层。
    static func layerColor(_ color: NSColor, for view: NSView) -> CGColor {
        let appearance = view.window?.effectiveAppearance ?? view.effectiveAppearance
        var resolved = color.cgColor
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved
    }

    static let background = dynamic("background") { color($0.background) }
    static let sidebarTop = dynamic("sidebarTop") { color($0.sidebarTop) }
    static let sidebarBottom = dynamic("sidebarBottom") { color($0.sidebarBottom) }
    static let tabBar = dynamic("tabBar") { color($0.tabBar) }
    static let surface = dynamic("surface") { color($0.surface) }
    static let surfaceRaised = dynamic("surfaceRaised") { color($0.surfaceRaised) }
    static let selectedTab = dynamic("selectedTab") { color($0.selectedTab) }
    static let hoverFill = dynamic("hoverFill") { color($0.overlay, alpha: $0.hoverAlpha) }
    static let terminalBackground = dynamic("terminalBackground") { color($0.terminalBackground) }
    static let terminalForeground = dynamic("terminalForeground") { color($0.terminalForeground) }

    static func terminalColor(_ role: ThemeColorRole, dark: Bool) -> NSColor {
        lock.lock()
        let current = scheme
        lock.unlock()
        return color(current.customization.resolved(role, palette: dark ? current.dark : current.light, dark: dark))
    }

    static let border = dynamic("border") { color($0.overlay, alpha: $0.borderAlpha) }
    static let borderStrong = dynamic("borderStrong") { color($0.overlay, alpha: $0.borderStrongAlpha) }

    static let textPrimary = dynamic("textPrimary") { color($0.textPrimary) }
    static let textSecondary = dynamic("textSecondary") { color($0.textSecondary) }
    static let textTertiary = dynamic("textTertiary") { color($0.textTertiary) }

    static let accent = dynamic("accent") { color($0.accent) }
    static let accentDeep = dynamic("accentDeep") { color($0.accentDeep) }
    static let accentSoft = dynamic("accentSoft") { color($0.accent, alpha: $0.accentSoftAlpha) }
    static let success = dynamic("success") { color($0.success) }
    static let warning = dynamic("warning") { color($0.warning) }
    static let danger = dynamic("danger") { color($0.danger) }
    static let purple = dynamic("purple") { color($0.purple) }
    static let teal = dynamic("teal") { color($0.teal) }
    static let orange = dynamic("orange") { color($0.orange) }
    /// 欢迎页左上角那团柔光：深色下偏蓝，浅色下只是一层淡雾。
    static let glow = dynamic("glow") { color($0.glow) }

    static func color(for state: TerminalController.State) -> NSColor {
        switch state {
        case .starting: return warning
        case .running: return success
        case .failed: return danger
        case .exited(let code?) where code != 0: return warning
        case .exited: return textTertiary
        case .idle: return textTertiary
        }
    }

    static func symbol(for kind: ConnectionProtocol) -> String {
        switch kind {
        case .ssh: return "terminal"
        case .telnet: return "network"
        case .serial: return "cable.connector"
        case .vnc: return "display"
        case .rdp: return "desktopcomputer"
        }
    }

    static func tint(for kind: ConnectionProtocol) -> NSColor {
        switch kind {
        case .ssh: return accent
        case .telnet: return teal
        case .serial: return orange
        case .vnc: return .systemIndigo
        case .rdp: return .systemCyan
        }
    }

    // MARK: - 终端

    /// SwiftTerm 只接受具体色值，没法跟着动态颜色走，所以按深浅各取一份，
    /// 由 TerminalController 在外观或配色档位变化时重新安装。
    static func terminalBackground(dark: Bool) -> NSColor {
        color(palette(dark: dark).terminalBackground)
    }

    static func terminalForeground(dark: Bool) -> NSColor {
        color(palette(dark: dark).terminalForeground)
    }

    static func terminalPalette(dark: Bool) -> [SwiftTerm.Color] {
        dark ? terminalPaletteDark : terminalPaletteLight
    }

    /// One Dark 风格的 16 色 ANSI 调色板，和深色界面是同一位作者的感觉。
    private static let terminalPaletteDark: [SwiftTerm.Color] = [
        SwiftTerm.Color(red8: 0x1B, green8: 0x1E, blue8: 0x27),
        SwiftTerm.Color(red8: 0xF7, green8: 0x76, blue8: 0x8E),
        SwiftTerm.Color(red8: 0x9E, green8: 0xCE, blue8: 0x6A),
        SwiftTerm.Color(red8: 0xE0, green8: 0xAF, blue8: 0x68),
        SwiftTerm.Color(red8: 0x7A, green8: 0xA2, blue8: 0xF7),
        SwiftTerm.Color(red8: 0xBB, green8: 0x9A, blue8: 0xF7),
        SwiftTerm.Color(red8: 0x7D, green8: 0xCF, blue8: 0xFF),
        SwiftTerm.Color(red8: 0xA9, green8: 0xB1, blue8: 0xD6),
        SwiftTerm.Color(red8: 0x41, green8: 0x48, blue8: 0x68),
        SwiftTerm.Color(red8: 0xF7, green8: 0x76, blue8: 0x8E),
        SwiftTerm.Color(red8: 0x9E, green8: 0xCE, blue8: 0x6A),
        SwiftTerm.Color(red8: 0xE0, green8: 0xAF, blue8: 0x68),
        SwiftTerm.Color(red8: 0x7A, green8: 0xA2, blue8: 0xF7),
        SwiftTerm.Color(red8: 0xBB, green8: 0x9A, blue8: 0xF7),
        SwiftTerm.Color(red8: 0x7D, green8: 0xCF, blue8: 0xFF),
        SwiftTerm.Color(red8: 0xC0, green8: 0xCA, blue8: 0xF5),
    ]

    /// 浅色底上的 ANSI 颜色要压暗，否则黄、青在近白背景上几乎看不清。
    private static let terminalPaletteLight: [SwiftTerm.Color] = [
        SwiftTerm.Color(red8: 0x24, green8: 0x29, blue8: 0x2F),
        SwiftTerm.Color(red8: 0xCF, green8: 0x22, blue8: 0x2E),
        SwiftTerm.Color(red8: 0x11, green8: 0x63, blue8: 0x29),
        SwiftTerm.Color(red8: 0x9A, green8: 0x67, blue8: 0x00),
        SwiftTerm.Color(red8: 0x09, green8: 0x69, blue8: 0xDA),
        SwiftTerm.Color(red8: 0x82, green8: 0x50, blue8: 0xDF),
        SwiftTerm.Color(red8: 0x1B, green8: 0x7C, blue8: 0x83),
        SwiftTerm.Color(red8: 0x6E, green8: 0x77, blue8: 0x81),
        SwiftTerm.Color(red8: 0x57, green8: 0x60, blue8: 0x6A),
        SwiftTerm.Color(red8: 0xA4, green8: 0x0E, blue8: 0x26),
        SwiftTerm.Color(red8: 0x1A, green8: 0x7F, blue8: 0x37),
        SwiftTerm.Color(red8: 0x63, green8: 0x3C, blue8: 0x01),
        SwiftTerm.Color(red8: 0x21, green8: 0x8B, blue8: 0xFF),
        SwiftTerm.Color(red8: 0xA4, green8: 0x75, blue8: 0xF9),
        SwiftTerm.Color(red8: 0x31, green8: 0x92, blue8: 0xAA),
        SwiftTerm.Color(red8: 0x8C, green8: 0x95, blue8: 0x9F),
    ]

    static func tint(for host: HostProfile) -> NSColor {
        guard host.protocolKind == .ssh, host.systemIcon != .default else {
            return tint(for: host.protocolKind)
        }
        return tint(for: host.systemIcon)
    }

    static func tint(for systemIcon: SSHSystemIcon) -> NSColor {
        switch systemIcon {
        case .default: return tint(for: .ssh)
        case .ubuntu: return rgba(0xE9, 0x54, 0x20)
        case .debian: return rgba(0xD7, 0x0A, 0x53)
        case .centos: return rgba(0x93, 0x22, 0x79)
        case .rhel: return rgba(0xEE, 0x00, 0x00)
        case .fedora: return rgba(0x51, 0xA2, 0xDA)
        case .arch: return rgba(0x17, 0x93, 0xD1)
        case .alpine: return rgba(0x0D, 0x59, 0x7F)
        case .kylin: return rgba(0x1A, 0x73, 0xE8)
        case .macos: return textPrimary
        case .windows: return rgba(0x00, 0x78, 0xD4)
        case .linux: return rgba(0xE0, 0x9F, 0x1F)
        }
    }

    static func iconImage(for host: HostProfile) -> NSImage? {
        guard host.protocolKind == .ssh, host.systemIcon != .default else {
            return NSImage(systemSymbolName: symbol(for: host.protocolKind), accessibilityDescription: host.protocolKind.displayName)
        }
        return iconImage(for: host.systemIcon)
    }

    static func iconImage(for systemIcon: SSHSystemIcon) -> NSImage? {
        if systemIcon == .default {
            return NSImage(systemSymbolName: symbol(for: .ssh), accessibilityDescription: systemIcon.displayName)
        }
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            switch systemIcon {
            case .ubuntu:
                let ring = NSBezierPath(ovalIn: NSRect(x: 2.5, y: 2.5, width: 9, height: 9))
                ring.lineWidth = 1.6
                ring.stroke()
                for angle in [0.0, 120.0, 240.0] {
                    let rad = angle * .pi / 180.0
                    let cx = 7.0 + cos(rad) * 4.5
                    let cy = 7.0 + sin(rad) * 4.5
                    NSBezierPath(ovalIn: NSRect(x: cx - 1.5, y: cy - 1.5, width: 3, height: 3)).fill()
                }
            case .centos:
                // 经典 CentOS 四向箭头 + 中心菱形核
                let arrows = NSBezierPath()
                arrows.lineWidth = 1.4
                arrows.lineCapStyle = .round
                arrows.lineJoinStyle = .round
                // 上箭头
                arrows.move(to: NSPoint(x: 5.0, y: 10.3))
                arrows.line(to: NSPoint(x: 7.0, y: 12.6))
                arrows.line(to: NSPoint(x: 9.0, y: 10.3))
                // 下箭头
                arrows.move(to: NSPoint(x: 5.0, y: 3.7))
                arrows.line(to: NSPoint(x: 7.0, y: 1.4))
                arrows.line(to: NSPoint(x: 9.0, y: 3.7))
                // 左箭头
                arrows.move(to: NSPoint(x: 3.7, y: 5.0))
                arrows.line(to: NSPoint(x: 1.4, y: 7.0))
                arrows.line(to: NSPoint(x: 3.7, y: 9.0))
                // 右箭头
                arrows.move(to: NSPoint(x: 10.3, y: 5.0))
                arrows.line(to: NSPoint(x: 12.6, y: 7.0))
                arrows.line(to: NSPoint(x: 10.3, y: 9.0))
                arrows.stroke()
                let diamond = NSBezierPath()
                diamond.move(to: NSPoint(x: 7.0, y: 9.6))
                diamond.line(to: NSPoint(x: 9.6, y: 7.0))
                diamond.line(to: NSPoint(x: 7.0, y: 4.4))
                diamond.line(to: NSPoint(x: 4.4, y: 7.0))
                diamond.close()
                diamond.lineWidth = 1.4
                diamond.stroke()
            case .debian:
                let spiral = NSBezierPath()
                spiral.lineWidth = 1.6
                spiral.lineCapStyle = .round
                spiral.appendArc(withCenter: NSPoint(x: 7, y: 7), radius: 5, startAngle: 20, endAngle: 300)
                spiral.appendArc(withCenter: NSPoint(x: 7.4, y: 7.2), radius: 2.3, startAngle: 300, endAngle: 120, clockwise: true)
                spiral.stroke()
            case .rhel:
                let crown = NSBezierPath()
                crown.lineWidth = 1.5
                crown.lineJoinStyle = .round
                crown.move(to: NSPoint(x: 2, y: 4.5))
                crown.curve(to: NSPoint(x: 12, y: 4.5), controlPoint1: NSPoint(x: 5, y: 3), controlPoint2: NSPoint(x: 9, y: 3))
                crown.move(to: NSPoint(x: 4, y: 5))
                crown.line(to: NSPoint(x: 5.5, y: 10.5))
                crown.line(to: NSPoint(x: 8.5, y: 10.5))
                crown.line(to: NSPoint(x: 10, y: 5))
                crown.stroke()
            case .fedora:
                let badge = NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 10, height: 10), xRadius: 4.5, yRadius: 4.5)
                badge.lineWidth = 1.5
                badge.stroke()
                let f = NSBezierPath()
                f.lineWidth = 1.5
                f.lineCapStyle = .round
                f.move(to: NSPoint(x: 6.5, y: 4))
                f.line(to: NSPoint(x: 6.5, y: 9.2))
                f.curve(to: NSPoint(x: 9.2, y: 9.5), controlPoint1: NSPoint(x: 6.5, y: 10.6), controlPoint2: NSPoint(x: 9.2, y: 10.6))
                f.move(to: NSPoint(x: 4.8, y: 7))
                f.line(to: NSPoint(x: 8.5, y: 7))
                f.stroke()
            case .arch:
                let tri = NSBezierPath()
                tri.lineWidth = 1.6
                tri.lineJoinStyle = .round
                tri.lineCapStyle = .round
                tri.move(to: NSPoint(x: 2.5, y: 2.5))
                tri.line(to: NSPoint(x: 7, y: 12))
                tri.line(to: NSPoint(x: 11.5, y: 2.5))
                tri.move(to: NSPoint(x: 4.8, y: 5.2))
                tri.line(to: NSPoint(x: 9.2, y: 5.2))
                tri.stroke()
            case .alpine:
                let peak = NSBezierPath()
                peak.lineWidth = 1.5
                peak.lineJoinStyle = .round
                peak.lineCapStyle = .round
                peak.move(to: NSPoint(x: 1.5, y: 3))
                peak.line(to: NSPoint(x: 5.5, y: 10.5))
                peak.line(to: NSPoint(x: 8.5, y: 5.5))
                peak.line(to: NSPoint(x: 10.2, y: 8.5))
                peak.line(to: NSPoint(x: 12.5, y: 3))
                peak.stroke()
            case .kylin:
                // 六边形盾牌 + 麒麟 K 翼
                let hex = NSBezierPath()
                hex.lineWidth = 1.4
                hex.lineJoinStyle = .round
                hex.move(to: NSPoint(x: 7.0, y: 12.6))
                hex.line(to: NSPoint(x: 11.8, y: 9.8))
                hex.line(to: NSPoint(x: 11.8, y: 4.2))
                hex.line(to: NSPoint(x: 7.0, y: 1.4))
                hex.line(to: NSPoint(x: 2.2, y: 4.2))
                hex.line(to: NSPoint(x: 2.2, y: 9.8))
                hex.close()
                hex.stroke()
                let k = NSBezierPath()
                k.lineWidth = 1.5
                k.lineCapStyle = .round
                k.lineJoinStyle = .round
                k.move(to: NSPoint(x: 5.2, y: 4.2))
                k.line(to: NSPoint(x: 5.2, y: 9.8))
                k.move(to: NSPoint(x: 9.2, y: 9.5))
                k.line(to: NSPoint(x: 5.4, y: 7.0))
                k.line(to: NSPoint(x: 9.4, y: 4.3))
                k.stroke()
            case .macos:
                let screen = NSBezierPath(roundedRect: NSRect(x: 2, y: 4, width: 10, height: 7.5), xRadius: 1.5, yRadius: 1.5)
                screen.lineWidth = 1.5
                screen.stroke()
                let base = NSBezierPath()
                base.lineWidth = 1.5
                base.lineCapStyle = .round
                base.move(to: NSPoint(x: 4.5, y: 2.2))
                base.line(to: NSPoint(x: 9.5, y: 2.2))
                base.stroke()
            case .windows:
                for rect in [
                    NSRect(x: 2, y: 7.6, width: 4.4, height: 4.4),
                    NSRect(x: 7.6, y: 7.6, width: 4.4, height: 4.4),
                    NSRect(x: 2, y: 2, width: 4.4, height: 4.4),
                    NSRect(x: 7.6, y: 2, width: 4.4, height: 4.4),
                ] {
                    NSBezierPath(roundedRect: rect, xRadius: 0.7, yRadius: 0.7).fill()
                }
            case .linux:
                let box = NSBezierPath(roundedRect: NSRect(x: 1.8, y: 2.5, width: 10.4, height: 9), xRadius: 2, yRadius: 2)
                box.lineWidth = 1.5
                box.stroke()
                let prompt = NSBezierPath()
                prompt.lineWidth = 1.4
                prompt.lineCapStyle = .round
                prompt.lineJoinStyle = .round
                prompt.move(to: NSPoint(x: 4.2, y: 8.5))
                prompt.line(to: NSPoint(x: 6.2, y: 7))
                prompt.line(to: NSPoint(x: 4.2, y: 5.5))
                prompt.move(to: NSPoint(x: 7.4, y: 5.5))
                prompt.line(to: NSPoint(x: 9.8, y: 5.5))
                prompt.stroke()
            case .default:
                break
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// 只有 NSView 暴露外观变化回调，NSViewController 没有；
/// 需要刷新图层色的控制器把根视图换成它，再挂一个回调即可。
@MainActor
final class AppearanceAwareView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

extension NSView {
    /// 配色档位或强调色变了，但系统外观没变，AppKit 不会自己回调外观变化。
    /// 沿视图树把 `viewDidChangeEffectiveAppearance` 走一遍，各视图既有的刷新逻辑
    /// 就会重新解析图层色，draw 型视图也会跟着重绘。
    @MainActor
    func applyThemeChangeRecursively() {
        viewDidChangeEffectiveAppearance()
        needsDisplay = true
        for subview in subviews { subview.applyThemeChangeRecursively() }
    }
}
