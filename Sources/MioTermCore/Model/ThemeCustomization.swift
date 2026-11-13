import Foundation

public enum ThemeColorRole: String, CaseIterable, Sendable {
    case background, sidebar, tabBar, surface, text, secondaryText, accent, selectedTab
    case terminalBackground, terminalForeground, selectionBackground, selectionForeground, cursor

    public var displayName: String {
        switch self {
        case .background: return L10n.tr(.themeRoleBackground)
        case .sidebar: return L10n.tr(.themeRoleSidebar)
        case .tabBar: return L10n.tr(.themeRoleTabBar)
        case .surface: return L10n.tr(.themeRoleSurface)
        case .text: return L10n.tr(.themeRoleText)
        case .secondaryText: return L10n.tr(.themeRoleSecondaryText)
        case .accent: return L10n.tr(.themeRoleAccent)
        case .selectedTab: return L10n.tr(.themeRoleSelectedTab)
        case .terminalBackground: return L10n.tr(.themeRoleTerminalBackground)
        case .terminalForeground: return L10n.tr(.themeRoleTerminalForeground)
        case .selectionBackground: return L10n.tr(.themeRoleSelectionBackground)
        case .selectionForeground: return L10n.tr(.themeRoleSelectionForeground)
        case .cursor: return L10n.tr(.themeRoleCursor)
        }
    }
}

extension ThemeRGB {
    public init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, value.allSatisfy({ $0.isASCII && $0.isHexDigit }), let number = UInt32(value, radix: 16) else { return nil }
        self.init(UInt8((number >> 16) & 255), UInt8((number >> 8) & 255), UInt8(number & 255))
    }

    public var hexString: String { String(format: "#%02X%02X%02X", red, green, blue) }
}

/// 深浅独立的颜色覆盖；只保存 RGB，不依赖 AppKit，可移植为主题文件。
public struct ThemeCustomization: Codable, Equatable, Sendable {
    public var dark: [String: String]
    public var light: [String: String]

    public init(dark: [String: String] = [:], light: [String: String] = [:]) {
        self.dark = dark
        self.light = light
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dark = (try? container.decode([String: String].self, forKey: .dark)) ?? [:]
        light = (try? container.decode([String: String].self, forKey: .light)) ?? [:]
    }

    public func color(_ role: ThemeColorRole, dark isDark: Bool) -> ThemeRGB? {
        (isDark ? dark : light)[role.rawValue].flatMap { ThemeRGB(hex: $0) }
    }

    public mutating func set(_ color: ThemeRGB?, for role: ThemeColorRole, dark isDark: Bool) {
        if isDark { dark[role.rawValue] = color?.hexString } else { light[role.rawValue] = color?.hexString }
    }

    public func normalized() -> Self {
        func clean(_ source: [String: String]) -> [String: String] {
            source.reduce(into: [:]) { result, item in
                if ThemeColorRole(rawValue: item.key) != nil, let color = ThemeRGB(hex: item.value) {
                    result[item.key] = color.hexString
                }
            }
        }
        return Self(dark: clean(dark), light: clean(light))
    }

    public func applying(to base: ThemePalette, dark: Bool) -> ThemePalette {
        var result = base
        for role in ThemeColorRole.allCases {
            guard let rgb = color(role, dark: dark) else { continue }
            switch role {
            case .background: result.background = rgb
            case .sidebar: result.sidebarTop = rgb; result.sidebarBottom = rgb
            case .tabBar: result.tabBar = rgb
            case .surface: result.surface = rgb; result.surfaceRaised = rgb
            case .text: result.textPrimary = rgb
            case .secondaryText: result.textSecondary = rgb; result.textTertiary = rgb
            case .accent: result.accent = rgb; result.accentDeep = rgb
            case .selectedTab: result.selectedTab = rgb
            case .terminalBackground: result.terminalBackground = rgb
            case .terminalForeground: result.terminalForeground = rgb
            case .selectionBackground, .selectionForeground, .cursor: break
            }
        }
        return result
    }

    public func resolved(_ role: ThemeColorRole, palette: ThemePalette, dark: Bool) -> ThemeRGB {
        if let color = color(role, dark: dark) { return color }
        let palette = applying(to: palette, dark: dark)
        switch role {
        case .background: return palette.background
        case .sidebar: return palette.sidebarTop
        case .tabBar: return palette.tabBar
        case .surface: return palette.surface
        case .text: return palette.textPrimary
        case .secondaryText: return palette.textSecondary
        case .accent: return palette.accent
        case .selectedTab: return palette.selectedTab
        case .terminalBackground: return palette.terminalBackground
        case .terminalForeground, .selectionForeground, .cursor: return palette.terminalForeground
        case .selectionBackground: return palette.selectedTab
        }
    }
}

public enum ThemePreset: String, CaseIterable {
    case standard, midnight, forest, paper
    public var displayName: String {
        switch self {
        case .standard: return L10n.tr(.themePresetStandard)
        case .midnight: return L10n.tr(.themePresetMidnight)
        case .forest: return L10n.tr(.themePresetForest)
        case .paper: return L10n.tr(.themePresetPaper)
        }
    }
    public var customization: ThemeCustomization {
        guard self != .standard else { return ThemeCustomization() }
        let dark: [String]
        let light: [String]
        switch self {
        case .midnight:
            dark = ["101827", "162033", "131D2E", "1B2940", "DAE5F5", "8FA4BF", "7DB7FF", "2A4365", "101827", "DAE5F5", "315579", "FFFFFF", "A8D1FF"]
            light = ["F3F7FD", "EAF0FA", "E6EDF8", "FFFFFF", "25354B", "60738B", "2563C4", "D6E4F8", "F8FAFE", "25354B", "C9DDF7", "15314F", "2563C4"]
        case .forest:
            dark = ["14201C", "192A23", "17261F", "20352B", "DFEAE2", "9CAE9F", "8FD3A6", "2C4938", "14201C", "DFEAE2", "386047", "FFFFFF", "A1DFB4"]
            light = ["F3F7F2", "E8F0E6", "E3EDDF", "FFFFFF", "283D2E", "627866", "287647", "D8E9D3", "F9FCF7", "283D2E", "C9E2BE", "203A24", "287647"]
        case .paper:
            dark = ["24211D", "2D2822", "29241F", "363027", "E6DDCD", "B0A48E", "D3AE78", "4C4031", "24211D", "E6DDCD", "675239", "FFFFFF", "E8C898"]
            light = ["F5F0E5", "ECE5D6", "E8E0CE", "FCF8EF", "443C30", "80735E", "936932", "E5D5B6", "FCF8EF", "443C30", "DDC59B", "382A17", "936932"]
        case .standard: return ThemeCustomization()
        }
        return ThemeCustomization(dark: Dictionary(uniqueKeysWithValues: zip(ThemeColorRole.allCases.map(\.rawValue), dark)),
                                  light: Dictionary(uniqueKeysWithValues: zip(ThemeColorRole.allCases.map(\.rawValue), light))).normalized()
    }
}

extension ThemeCustomization {
    public static let maximumFileBytes = 128 * 1024
    public enum ImportError: LocalizedError {
        case invalidTheme
        public var errorDescription: String? { L10n.tr(.themeImportInvalid) }
    }

    public static func imported(from data: Data) throws -> ThemeCustomization {
        guard data.count <= maximumFileBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["dark"] != nil || object["light"] != nil else { throw ImportError.invalidTheme }
        for key in ["dark", "light"] where object[key] != nil {
            guard let entries = object[key] as? [String: String],
                  entries.allSatisfy({ ThemeColorRole(rawValue: $0.key) != nil && ThemeRGB(hex: $0.value) != nil })
            else { throw ImportError.invalidTheme }
        }
        return try JSONDecoder().decode(Self.self, from: data).normalized()
    }

    public func exportedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(normalized())
    }
}
