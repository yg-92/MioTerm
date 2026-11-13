import Foundation
import Testing
@testable import MioTermCore

@Suite("多语言与扩展语种包")
struct LocalizationTests {
    @Test("内置语种包完整覆盖所有文案键")
    func builtInPacksCoverAllKeys() {
        for pack in LocalizationPacks.builtIn {
            for key in L10nKey.allCases {
                let value = pack.strings[key]
                #expect(value != nil, "Pack '\(pack.code)' is missing key '\(key.rawValue)'")
                #expect(value?.isEmpty == false, "Pack '\(pack.code)' has empty value for '\(key.rawValue)'")
            }
        }
    }

    @Test("跟随系统语言正确解析为中英文")
    func systemLanguageResolution() {
        #expect(
            L10n.resolveLanguageCode(preference: .system, preferredLanguages: ["zh-Hans-CN", "en-US"]) == "zh-Hans"
        )
        #expect(
            L10n.resolveLanguageCode(preference: .system, preferredLanguages: ["zh-Hant-TW"]) == "zh-Hans"
        )
        #expect(
            L10n.resolveLanguageCode(preference: .system, preferredLanguages: ["en-US"]) == "en"
        )
        #expect(
            L10n.resolveLanguageCode(preference: .system, preferredLanguages: ["ja-JP"]) == "en"
        )
        #expect(L10n.resolveLanguageCode(preference: .zhHans) == "zh-Hans")
        #expect(L10n.resolveLanguageCode(preference: .en) == "en")
    }

    @Test("支持注册新语种包并在缺省键时回退到 fallbackCode")
    func customLanguagePackRegistrationAndFallback() {
        let previous = L10n.currentLanguageCode
        defer { L10n.setLanguageCode(previous) }

        let jaPack = LocalizationPack(
            code: "ja",
            nativeName: "日本語",
            fallbackCode: "en",
            strings: [
                .commonCancel: "キャンセル",
            ]
        )
        L10n.register(jaPack)
        L10n.setLanguageCode("ja")

        #expect(L10n.tr(.commonCancel) == "キャンセル")
        #expect(L10n.tr(.commonSave) == "Save")
        #expect(L10n.registeredPacks.contains { $0.code == "ja" })
    }

    @Test("旧版配置缺少 language 字段时默认跟随系统")
    func appSettingsToleratesMissingLanguageKey() throws {
        let legacyJSON = """
        {
            "terminalFontName": "Menlo-Regular",
            "terminalFontSize": 13,
            "appearance": "dark"
        }
        """
        let data = try #require(legacyJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.language == .system)
    }
}
