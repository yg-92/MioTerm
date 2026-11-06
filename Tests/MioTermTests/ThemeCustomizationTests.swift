import Foundation
import Testing
@testable import MioTermCore

@Suite("页面样式配色")
struct ThemeCustomizationTests {
    @Test func hexColorsAreStrictAndCanonical() {
        #expect(ThemeRGB(hex: " #a1b2c3 ")?.hexString == "#A1B2C3")
        for invalid in ["##123456", "#abc", "#12345678", "#GG0000", "１２３４５６", "12#3456"] {
            #expect(ThemeRGB(hex: invalid) == nil)
        }
    }

    @Test func lightAndDarkOverridesAreIndependentAndResettable() {
        var style = ThemeCustomization()
        style.set(ThemeRGB(1, 2, 3), for: .terminalBackground, dark: true)
        style.set(ThemeRGB(240, 241, 242), for: .terminalBackground, dark: false)
        #expect(style.color(.terminalBackground, dark: true) == ThemeRGB(1, 2, 3))
        #expect(style.color(.terminalBackground, dark: false) == ThemeRGB(240, 241, 242))
        style.set(nil, for: .terminalBackground, dark: true)
        #expect(style.color(.terminalBackground, dark: true) == nil)
        #expect(style.color(.terminalBackground, dark: false) != nil)
    }

    @Test func overridesReachThePaletteAndSelectionFallback() {
        let base = ThemePalette.palette(dark: true, contrast: .soft, accent: .blue)
        var style = ThemeCustomization()
        style.set(ThemeRGB(1, 2, 3), for: .terminalForeground, dark: true)
        style.set(ThemeRGB(4, 5, 6), for: .selectedTab, dark: true)
        #expect(style.applying(to: base, dark: true).selectedTab == ThemeRGB(4, 5, 6))
        #expect(style.resolved(.selectionForeground, palette: base, dark: true) == ThemeRGB(1, 2, 3))
        #expect(style.applying(to: base, dark: false) == base)
    }

    @Test func allPresetsRoundTripBothModes() throws {
        for preset in ThemePreset.allCases {
            let style = preset.customization
            #expect(try ThemeCustomization.imported(from: style.exportedData()) == style.normalized())
            if preset != .standard {
                for role in ThemeColorRole.allCases {
                    #expect(style.color(role, dark: true) != nil)
                    #expect(style.color(role, dark: false) != nil)
                }
            }
        }
    }

    @Test func invalidImportsCannotSilentlyResetTheTheme() {
        for json in ["{}", "[]", "{\"dark\":[]}", "{\"light\":{\"text\":\"oops\"}}", "{\"dark\":{\"unknown\":\"#123456\"}}"] {
            #expect(throws: (any Error).self) { try ThemeCustomization.imported(from: Data(json.utf8)) }
        }
        #expect(throws: (any Error).self) { try ThemeCustomization.imported(from: Data(repeating: 32, count: 129 * 1024)) }
    }

    @Test func themeSettingsPersistWithoutAffectingConnectionSettings() throws {
        var settings = AppSettings(terminalFontSize: 17, scrollbackLines: 10000, defaultConnectTimeout: 25)
        settings.themeCustomization = ThemePreset.forest.customization
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored == settings)
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{\"scrollbackLines\":10000}".utf8))
        #expect(legacy.themeCustomization == ThemeCustomization())
        #expect(legacy.scrollbackLines == 10000)
    }

    @Test func normalizationDropsOnlyMalformedOverrides() {
        let style = ThemeCustomization(dark: ["text":"#aaBBcc", "cursor":"bad", "unknown":"#123456"])
        #expect(style.normalized().dark == ["text":"#AABBCC"])
    }
}
