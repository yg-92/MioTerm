import Foundation
import MioTermCore
import Testing

/// 配色档位是“看得舒不舒服”的核心，这里用 WCAG 对比度把它钉住：
/// 柔和档必须比标准档低、标准档必须比高对比档低，但每一档都还得够读。
@Suite("配色档位")
struct ThemePaletteTests {
    /// WCAG 2.1 相对亮度与对比度公式。
    private func contrast(_ a: ThemeRGB, _ b: ThemeRGB) -> Double {
        func luminance(_ rgb: ThemeRGB) -> Double {
            func channel(_ value: UInt8) -> Double {
                let v = Double(value) / 255
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(rgb.red) + 0.7152 * channel(rgb.green) + 0.0722 * channel(rgb.blue)
        }
        let la = luminance(a)
        let lb = luminance(b)
        let (high, low) = la > lb ? (la, lb) : (lb, la)
        return (high + 0.05) / (low + 0.05)
    }

    private func palette(dark: Bool, _ contrast: UIContrast) -> ThemePalette {
        ThemePalette.palette(dark: dark, contrast: contrast, accent: .blue)
    }

    @Test("深色柔和档确实比标准档低，标准档比高对比档低")
    func darkContrastIsOrdered() {
        let soft = palette(dark: true, .soft)
        let standard = palette(dark: true, .standard)
        let high = palette(dark: true, .high)
        let softRatio = contrast(soft.terminalForeground, soft.terminalBackground)
        let standardRatio = contrast(standard.terminalForeground, standard.terminalBackground)
        let highRatio = contrast(high.terminalForeground, high.terminalBackground)
        #expect(softRatio < standardRatio)
        #expect(standardRatio < highRatio)
        // 柔和档不只是“低一点”，要明显落到标准档之下。
        #expect(standardRatio - softRatio > 0.8)
    }

    @Test("柔和档抬亮深色底、压暗文字，而不是单纯变灰")
    func softLiftsDarkSurfacesAndDimsText() {
        let soft = palette(dark: true, .soft)
        let standard = palette(dark: true, .standard)
        #expect(soft.background.luminance > standard.background.luminance)
        #expect(soft.terminalBackground.luminance > standard.terminalBackground.luminance)
        #expect(soft.textPrimary.luminance < standard.textPrimary.luminance)
        #expect(soft.terminalForeground.luminance < standard.terminalForeground.luminance)
        // 分隔线也跟着收敛，界面里最扎眼的其实是这些细白线。
        #expect(soft.borderAlpha < standard.borderAlpha)
        #expect(soft.borderStrongAlpha < standard.borderStrongAlpha)
    }

    @Test("三档深浅都还够读")
    func everyLevelStaysReadable() {
        for dark in [true, false] {
            for level in UIContrast.allCases {
                let palette = palette(dark: dark, level)
                // 正文与终端文字至少要过 WCAG AA（4.5:1）。
                #expect(contrast(palette.textPrimary, palette.background) >= 4.5, "\(dark)/\(level) 正文对比度不足")
                #expect(contrast(palette.terminalForeground, palette.terminalBackground) >= 4.5, "\(dark)/\(level) 终端对比度不足")
                // 次要文字允许低一些，但不能低于 3:1。
                #expect(contrast(palette.textSecondary, palette.background) >= 3.0, "\(dark)/\(level) 次要文字对比度不足")
            }
        }
    }

    @Test("标准档保留原来的观感")
    func standardKeepsThePreviousColors() {
        let dark = palette(dark: true, .standard)
        #expect(dark.background == ThemeRGB(13, 15, 19))
        #expect(dark.textPrimary == ThemeRGB(230, 234, 240))
        #expect(dark.terminalBackground == ThemeRGB(11, 13, 17))
        #expect(dark.accent == ThemeRGB(106, 166, 255))
        #expect(dark.borderAlpha == 0.07)
    }

    @Test("强调色互不相同，且都比选中底色深")
    func accentsAreDistinct() {
        var seen: Set<String> = []
        for accent in AccentColor.allCases {
            let dark = ThemePalette.palette(dark: true, contrast: .soft, accent: accent)
            let light = ThemePalette.palette(dark: false, contrast: .soft, accent: accent)
            #expect(dark.accent != dark.accentDeep)
            #expect(seen.insert("\(dark.accent.red)-\(dark.accent.green)-\(dark.accent.blue)").inserted,
                    "\(accent) 的深色强调色与别的档位重复")
            // 深色模式强调色要亮于底色，浅色模式要暗于底色，否则选中态看不出来。
            #expect(dark.accent.luminance > dark.background.luminance)
            #expect(light.accent.luminance < light.background.luminance)
        }
    }

    @Test("协议标识色不跟强调色撞车")
    func protocolTintsStayIndependentOfAccent() {
        for accent in AccentColor.allCases {
            let dark = ThemePalette.palette(dark: true, contrast: .soft, accent: accent)
            // Telnet 用青、串口用橙：强调色换成紫或绿时三种协议仍能分辨。
            #expect(dark.teal != dark.accent)
            #expect(dark.orange != dark.accent)
        }
    }

    @Test("半透明描边在深色叠白、浅色叠黑")
    func overlayFollowsTheMode() {
        #expect(palette(dark: true, .soft).overlay == ThemeRGB(255, 255, 255))
        #expect(palette(dark: false, .soft).overlay == ThemeRGB(0, 0, 0))
    }
}
