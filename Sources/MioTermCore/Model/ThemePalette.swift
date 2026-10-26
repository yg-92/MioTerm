import Foundation

/// 一组界面颜色的原始 RGB。放在 Core 里而不是直接用 NSColor，
/// 这样“柔和档比标准档暗多少”能被测试钉住，界面层只负责换算成 NSColor。
public struct ThemeRGB: Equatable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// 相对亮度（0…1），用来比较两档配色的明暗差。
    public var luminance: Double {
        (0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)) / 255
    }
}

/// 一套完整的界面配色。深浅各一份，由对比度档位与强调色决定。
public struct ThemePalette: Equatable, Sendable {
    public var background: ThemeRGB
    public var sidebarTop: ThemeRGB
    public var sidebarBottom: ThemeRGB
    public var tabBar: ThemeRGB
    public var surface: ThemeRGB
    public var surfaceRaised: ThemeRGB
    public var selectedTab: ThemeRGB
    public var terminalBackground: ThemeRGB
    public var terminalForeground: ThemeRGB
    public var textPrimary: ThemeRGB
    public var textSecondary: ThemeRGB
    public var textTertiary: ThemeRGB
    public var accent: ThemeRGB
    public var accentDeep: ThemeRGB
    public var success: ThemeRGB
    public var warning: ThemeRGB
    public var danger: ThemeRGB
    /// 欢迎页渐变与装饰用色，不跟强调色走。
    public var purple: ThemeRGB
    /// Telnet 会话的固定色：强调色可以换成紫或绿，协议色必须始终能区分开。
    public var teal: ThemeRGB
    public var orange: ThemeRGB
    public var glow: ThemeRGB
    /// 半透明描边与悬停底色的叠色基：深色叠白，浅色叠黑。
    public var overlay: ThemeRGB

    public var borderAlpha: Double
    public var borderStrongAlpha: Double
    public var hoverAlpha: Double
    public var accentSoftAlpha: Double

    public static func palette(dark: Bool, contrast: UIContrast, accent: AccentColor) -> ThemePalette {
        dark
            ? darkPalette(contrast: contrast, accent: accent)
            : lightPalette(contrast: contrast, accent: accent)
    }

    private static func accentPair(_ accent: AccentColor, dark: Bool) -> (ThemeRGB, ThemeRGB) {
        switch accent {
        case .blue:
            return dark ? (ThemeRGB(106, 166, 255), ThemeRGB(59, 130, 246))
                        : (ThemeRGB(46, 111, 224), ThemeRGB(31, 95, 209))
        case .purple:
            return dark ? (ThemeRGB(178, 146, 255), ThemeRGB(139, 92, 246))
                        : (ThemeRGB(124, 58, 237), ThemeRGB(106, 44, 214))
        case .green:
            return dark ? (ThemeRGB(110, 231, 183), ThemeRGB(16, 185, 129))
                        : (ThemeRGB(5, 150, 105), ThemeRGB(4, 120, 87))
        case .rose:
            return dark ? (ThemeRGB(251, 113, 133), ThemeRGB(244, 63, 94))
                        : (ThemeRGB(225, 29, 72), ThemeRGB(190, 24, 60))
        case .graphite:
            return dark ? (ThemeRGB(203, 213, 225), ThemeRGB(148, 163, 184))
                        : (ThemeRGB(71, 85, 105), ThemeRGB(51, 65, 85))
        }
    }

    /// 深色三档：柔和把底色抬亮、文字压暗，标准是原来的观感，高对比再拉开一档。
    private static func darkPalette(contrast: UIContrast, accent: AccentColor) -> ThemePalette {
        let (accentColor, accentDeepColor) = accentPair(accent, dark: true)
        switch contrast {
        case .soft:
            return ThemePalette(
                background: ThemeRGB(20, 22, 27),
                sidebarTop: ThemeRGB(28, 31, 38),
                sidebarBottom: ThemeRGB(23, 26, 31),
                tabBar: ThemeRGB(22, 24, 29),
                surface: ThemeRGB(28, 31, 38),
                surfaceRaised: ThemeRGB(37, 41, 50),
                selectedTab: ThemeRGB(44, 49, 60),
                terminalBackground: ThemeRGB(17, 19, 23),
                terminalForeground: ThemeRGB(190, 198, 208),
                textPrimary: ThemeRGB(214, 220, 229),
                textSecondary: ThemeRGB(150, 158, 171),
                textTertiary: ThemeRGB(112, 120, 134),
                accent: accentColor,
                accentDeep: accentDeepColor,
                success: ThemeRGB(96, 214, 147),
                warning: ThemeRGB(240, 194, 96),
                danger: ThemeRGB(236, 126, 126),
                purple: ThemeRGB(192, 132, 252),
                teal: ThemeRGB(94, 234, 212),
                orange: ThemeRGB(251, 146, 60),
                glow: ThemeRGB(30, 38, 54),
                overlay: ThemeRGB(255, 255, 255),
                borderAlpha: 0.06,
                borderStrongAlpha: 0.09,
                hoverAlpha: 0.035,
                accentSoftAlpha: 0.14
            )
        case .standard:
            return ThemePalette(
                background: ThemeRGB(13, 15, 19),
                sidebarTop: ThemeRGB(23, 26, 32),
                sidebarBottom: ThemeRGB(18, 21, 26),
                tabBar: ThemeRGB(17, 19, 24),
                surface: ThemeRGB(23, 26, 32),
                surfaceRaised: ThemeRGB(32, 37, 46),
                selectedTab: ThemeRGB(38, 44, 55),
                terminalBackground: ThemeRGB(11, 13, 17),
                terminalForeground: ThemeRGB(201, 209, 217),
                textPrimary: ThemeRGB(230, 234, 240),
                textSecondary: ThemeRGB(148, 156, 170),
                textTertiary: ThemeRGB(104, 113, 128),
                accent: accentColor,
                accentDeep: accentDeepColor,
                success: ThemeRGB(74, 222, 128),
                warning: ThemeRGB(251, 191, 36),
                danger: ThemeRGB(248, 113, 113),
                purple: ThemeRGB(192, 132, 252),
                teal: ThemeRGB(94, 234, 212),
                orange: ThemeRGB(251, 146, 60),
                glow: ThemeRGB(26, 34, 50),
                overlay: ThemeRGB(255, 255, 255),
                borderAlpha: 0.07,
                borderStrongAlpha: 0.12,
                hoverAlpha: 0.045,
                accentSoftAlpha: 0.16
            )
        case .high:
            return ThemePalette(
                background: ThemeRGB(8, 9, 12),
                sidebarTop: ThemeRGB(18, 20, 25),
                sidebarBottom: ThemeRGB(13, 15, 19),
                tabBar: ThemeRGB(12, 13, 17),
                surface: ThemeRGB(18, 20, 25),
                surfaceRaised: ThemeRGB(28, 32, 40),
                selectedTab: ThemeRGB(34, 39, 49),
                terminalBackground: ThemeRGB(6, 7, 9),
                terminalForeground: ThemeRGB(226, 232, 240),
                textPrimary: ThemeRGB(246, 248, 251),
                textSecondary: ThemeRGB(176, 184, 197),
                textTertiary: ThemeRGB(140, 149, 164),
                accent: accentColor,
                accentDeep: accentDeepColor,
                success: ThemeRGB(74, 222, 128),
                warning: ThemeRGB(253, 224, 71),
                danger: ThemeRGB(255, 138, 138),
                purple: ThemeRGB(216, 180, 254),
                teal: ThemeRGB(153, 246, 228),
                orange: ThemeRGB(254, 215, 170),
                glow: ThemeRGB(22, 30, 46),
                overlay: ThemeRGB(255, 255, 255),
                borderAlpha: 0.12,
                borderStrongAlpha: 0.18,
                hoverAlpha: 0.06,
                accentSoftAlpha: 0.20
            )
        }
    }

    /// 浅色三档：柔和把正文从近黑抬成深灰，高对比反过来压到近黑并加重描边。
    private static func lightPalette(contrast: UIContrast, accent: AccentColor) -> ThemePalette {
        let (accentColor, accentDeepColor) = accentPair(accent, dark: false)
        switch contrast {
        case .soft:
            return ThemePalette(
                background: ThemeRGB(246, 247, 250),
                sidebarTop: ThemeRGB(255, 255, 255),
                sidebarBottom: ThemeRGB(242, 244, 248),
                tabBar: ThemeRGB(236, 239, 246),
                surface: ThemeRGB(255, 255, 255),
                surfaceRaised: ThemeRGB(240, 243, 248),
                selectedTab: ThemeRGB(226, 232, 243),
                terminalBackground: ThemeRGB(251, 252, 253),
                terminalForeground: ThemeRGB(52, 60, 72),
                textPrimary: ThemeRGB(48, 56, 68),
                textSecondary: ThemeRGB(98, 108, 122),
                textTertiary: ThemeRGB(146, 155, 168),
                accent: accentColor,
                accentDeep: accentDeepColor,
                success: ThemeRGB(31, 157, 85),
                warning: ThemeRGB(183, 110, 0),
                danger: ThemeRGB(211, 47, 47),
                purple: ThemeRGB(124, 58, 237),
                teal: ThemeRGB(13, 148, 136),
                orange: ThemeRGB(194, 65, 12),
                glow: ThemeRGB(230, 237, 249),
                overlay: ThemeRGB(0, 0, 0),
                borderAlpha: 0.08,
                borderStrongAlpha: 0.12,
                hoverAlpha: 0.04,
                accentSoftAlpha: 0.10
            )
        case .standard:
            return ThemePalette(
                background: ThemeRGB(244, 246, 250),
                sidebarTop: ThemeRGB(255, 255, 255),
                sidebarBottom: ThemeRGB(240, 243, 248),
                tabBar: ThemeRGB(233, 237, 245),
                surface: ThemeRGB(255, 255, 255),
                surfaceRaised: ThemeRGB(238, 242, 248),
                selectedTab: ThemeRGB(220, 228, 242),
                terminalBackground: ThemeRGB(250, 251, 252),
                terminalForeground: ThemeRGB(36, 41, 47),
                textPrimary: ThemeRGB(28, 36, 48),
                textSecondary: ThemeRGB(90, 102, 117),
                textTertiary: ThemeRGB(138, 148, 163),
                accent: accentColor,
                accentDeep: accentDeepColor,
                success: ThemeRGB(31, 157, 85),
                warning: ThemeRGB(183, 110, 0),
                danger: ThemeRGB(211, 47, 47),
                purple: ThemeRGB(124, 58, 237),
                teal: ThemeRGB(13, 148, 136),
                orange: ThemeRGB(194, 65, 12),
                glow: ThemeRGB(226, 235, 250),
                overlay: ThemeRGB(0, 0, 0),
                borderAlpha: 0.10,
                borderStrongAlpha: 0.16,
                hoverAlpha: 0.05,
                accentSoftAlpha: 0.12
            )
        case .high:
            return ThemePalette(
                background: ThemeRGB(255, 255, 255),
                sidebarTop: ThemeRGB(255, 255, 255),
                sidebarBottom: ThemeRGB(244, 246, 249),
                tabBar: ThemeRGB(236, 239, 244),
                surface: ThemeRGB(255, 255, 255),
                surfaceRaised: ThemeRGB(242, 244, 248),
                selectedTab: ThemeRGB(224, 230, 240),
                terminalBackground: ThemeRGB(255, 255, 255),
                terminalForeground: ThemeRGB(18, 22, 28),
                textPrimary: ThemeRGB(12, 16, 22),
                textSecondary: ThemeRGB(62, 70, 82),
                textTertiary: ThemeRGB(104, 113, 127),
                accent: accentColor,
                accentDeep: accentDeepColor,
                success: ThemeRGB(20, 130, 66),
                warning: ThemeRGB(150, 82, 0),
                danger: ThemeRGB(185, 28, 28),
                purple: ThemeRGB(107, 33, 168),
                teal: ThemeRGB(15, 118, 110),
                orange: ThemeRGB(154, 52, 18),
                glow: ThemeRGB(232, 239, 251),
                overlay: ThemeRGB(0, 0, 0),
                borderAlpha: 0.16,
                borderStrongAlpha: 0.24,
                hoverAlpha: 0.06,
                accentSoftAlpha: 0.16
            )
        }
    }
}
