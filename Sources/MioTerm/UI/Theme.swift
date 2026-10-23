import AppKit
import MioTermCore
import SwiftTerm

/// 统一主题：颜色分成深浅两套，装进动态 NSColor，界面在切换外观时自动重绘。
/// 强调色只出现在选中态与图标上，避免整屏花哨。
enum Theme {
    static func rgba(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
    }

    /// 同一个颜色名给出深浅两份：AppKit 在绘制时按当前外观取用，
    /// 文本、图标、描边这类 NSColor 就不必在切换主题时逐个重设。
    private static func dynamic(_ name: String, dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: NSColor.Name("mio.theme.\(name)")) { appearance in
            isDark(appearance) ? dark : light
        }
    }

    static func isDark(_ appearance: NSAppearance? = nil) -> Bool {
        let resolved = appearance ?? NSApp?.effectiveAppearance
        return resolved?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// 图层只接受 CGColor；动态色必须在赋值前按视图当前外观解析，
    /// 否则会固化成赋值那一刻的深浅版本。
    static func layerColor(_ color: NSColor, for view: NSView) -> CGColor {
        var resolved = color.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved
    }

    static let background = dynamic("background", dark: rgba(13, 15, 19), light: rgba(244, 246, 250))
    static let sidebarTop = dynamic("sidebarTop", dark: rgba(23, 26, 32), light: rgba(255, 255, 255))
    static let sidebarBottom = dynamic("sidebarBottom", dark: rgba(18, 21, 26), light: rgba(240, 243, 248))
    static let tabBar = dynamic("tabBar", dark: rgba(17, 19, 24), light: rgba(233, 237, 245))
    static let surface = dynamic("surface", dark: rgba(23, 26, 32), light: rgba(255, 255, 255))
    static let surfaceRaised = dynamic("surfaceRaised", dark: rgba(32, 37, 46), light: rgba(238, 242, 248))
    static let selectedTab = dynamic("selectedTab", dark: rgba(38, 44, 55), light: rgba(220, 228, 242))
    static let hoverFill = dynamic("hoverFill", dark: NSColor(white: 1, alpha: 0.045), light: NSColor(white: 0, alpha: 0.05))
    static let terminalBackground = dynamic("terminalBackground", dark: rgba(11, 13, 17), light: rgba(250, 251, 252))
    static let terminalForeground = dynamic("terminalForeground", dark: rgba(201, 209, 217), light: rgba(36, 41, 47))

    static let border = dynamic("border", dark: NSColor(white: 1, alpha: 0.07), light: NSColor(white: 0, alpha: 0.10))
    static let borderStrong = dynamic("borderStrong", dark: NSColor(white: 1, alpha: 0.12), light: NSColor(white: 0, alpha: 0.16))

    static let textPrimary = dynamic("textPrimary", dark: rgba(230, 234, 240), light: rgba(28, 36, 48))
    static let textSecondary = dynamic("textSecondary", dark: rgba(148, 156, 170), light: rgba(90, 102, 117))
    static let textTertiary = dynamic("textTertiary", dark: rgba(104, 113, 128), light: rgba(138, 148, 163))

    static let accent = dynamic("accent", dark: rgba(106, 166, 255), light: rgba(46, 111, 224))
    static let accentDeep = dynamic("accentDeep", dark: rgba(59, 130, 246), light: rgba(31, 95, 209))
    static let accentSoft = dynamic("accentSoft", dark: rgba(106, 166, 255, 0.16), light: rgba(46, 111, 224, 0.12))
    static let success = dynamic("success", dark: rgba(74, 222, 128), light: rgba(31, 157, 85))
    static let warning = dynamic("warning", dark: rgba(251, 191, 36), light: rgba(183, 110, 0))
    static let danger = dynamic("danger", dark: rgba(248, 113, 113), light: rgba(211, 47, 47))
    static let purple = dynamic("purple", dark: rgba(192, 132, 252), light: rgba(124, 58, 237))
    static let orange = dynamic("orange", dark: rgba(251, 146, 60), light: rgba(194, 65, 12))
    /// 欢迎页左上角那团柔光：深色下偏蓝，浅色下只是一层淡雾。
    static let glow = dynamic("glow", dark: rgba(26, 34, 50), light: rgba(226, 235, 250))

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
        case .telnet: return purple
        case .serial: return orange
        }
    }

    // MARK: - 终端

    /// SwiftTerm 只接受具体色值，没法跟着动态颜色走，所以深浅各备一套，
    /// 由 TerminalController 在外观变化时重新安装。
    static func terminalBackground(dark: Bool) -> NSColor {
        dark ? rgba(11, 13, 17) : rgba(250, 251, 252)
    }

    static func terminalForeground(dark: Bool) -> NSColor {
        dark ? rgba(201, 209, 217) : rgba(36, 41, 47)
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
