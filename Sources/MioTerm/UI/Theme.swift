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
        }
    }

    static func tint(for kind: ConnectionProtocol) -> NSColor {
        switch kind {
        case .ssh: return accent
        case .telnet: return teal
        case .serial: return orange
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
