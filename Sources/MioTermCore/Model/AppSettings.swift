import Foundation

public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system
    case dark
    case light

    public var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .dark: return "深色"
        case .light: return "浅色"
        }
    }
}

/// 配色档位。深色下最刺眼的是近黑底配近白字，柔和档把底色抬亮、文字压暗，
/// 长时间盯着终端不那么累；标准档是原来的观感，高对比留给强光环境。
public enum UIContrast: String, Codable, CaseIterable, Sendable {
    case soft
    case standard
    case high

    public var displayName: String {
        switch self {
        case .soft: return "柔和"
        case .standard: return "标准"
        case .high: return "高对比"
        }
    }
}

/// 强调色只作用于选中态、图标与链接，不换协议标识色。
public enum AccentColor: String, Codable, CaseIterable, Sendable {
    case blue
    case purple
    case green
    case rose
    case graphite

    public var displayName: String {
        switch self {
        case .blue: return "蓝"
        case .purple: return "紫"
        case .green: return "绿"
        case .rose: return "玫瑰"
        case .graphite: return "石墨"
        }
    }
}

/// 界面与连接的可调项。除监听/路径类配置外，这里的改动即时生效，
/// 对齐 webterm “页面配置热更新” 的行为。
public struct AppSettings: Codable, Equatable, Sendable {
    public static let defaultScrollbackLines = 2_000
    public var themeCustomization: ThemeCustomization
    public var appearance: AppearanceMode
    public var contrast: UIContrast
    public var accent: AccentColor
    public var terminalFontName: String
    public var terminalFontSize: Double
    /// 新建主机时预填的 TERM，也是主机留空时的兜底；本地终端不吃这一项，
    /// 因为内置模拟器就是 xterm，给它换 TERM 只会让本地程序按错的能力表输出。
    public var terminalType: String
    /// 左侧目录树的文字与图标尺寸；树比终端窄得多，两者分开调。
    public var fileTreeFontSize: Double
    public var fileTreeIconSize: Double
    public var scrollbackLines: Int
    public var playBellSound: Bool
    public var followTerminalDirectory: Bool
    public var uploadChunkBytes: Int
    public var maxConcurrentTransfers: Int
    public var defaultConnectTimeout: Int
    public var defaultKeepaliveInterval: Int

    public init(
        themeCustomization: ThemeCustomization = ThemeCustomization(),
        appearance: AppearanceMode = .system,
        contrast: UIContrast = .soft,
        accent: AccentColor = .blue,
        terminalFontName: String = "Menlo Regular",
        terminalFontSize: Double = 13,
        terminalType: String = TerminalTypes.fallback,
        fileTreeFontSize: Double = 12,
        fileTreeIconSize: Double = 13,
        scrollbackLines: Int = AppSettings.defaultScrollbackLines,
        playBellSound: Bool = false,
        followTerminalDirectory: Bool = true,
        uploadChunkBytes: Int = 8 * 1024 * 1024,
        maxConcurrentTransfers: Int = 3,
        defaultConnectTimeout: Int = 10,
        defaultKeepaliveInterval: Int = 30
    ) {
        self.themeCustomization = themeCustomization.normalized()
        self.appearance = appearance
        self.contrast = contrast
        self.accent = accent
        self.terminalFontName = terminalFontName
        self.terminalFontSize = terminalFontSize
        self.terminalType = terminalType
        self.fileTreeFontSize = fileTreeFontSize
        self.fileTreeIconSize = fileTreeIconSize
        self.scrollbackLines = scrollbackLines
        self.playBellSound = playBellSound
        self.followTerminalDirectory = followTerminalDirectory
        self.uploadChunkBytes = uploadChunkBytes
        self.maxConcurrentTransfers = maxConcurrentTransfers
        self.defaultConnectTimeout = defaultConnectTimeout
        self.defaultKeepaliveInterval = defaultKeepaliveInterval
    }

    public static let `default` = AppSettings()

    /// 逐字段容错：老文件缺字段时只回退那一项的默认值。
    /// 合成解码器会把缺键当成整份失败，等于用户改过的字体、主题一起清零。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        themeCustomization = ((try? c.decodeIfPresent(ThemeCustomization.self, forKey: .themeCustomization)) ?? ThemeCustomization()).normalized()
        appearance = (try? c.decodeIfPresent(AppearanceMode.self, forKey: .appearance)) ?? .system
        contrast = (try? c.decodeIfPresent(UIContrast.self, forKey: .contrast)) ?? .soft
        accent = (try? c.decodeIfPresent(AccentColor.self, forKey: .accent)) ?? .blue
        terminalFontName = (try? c.decodeIfPresent(String.self, forKey: .terminalFontName)) ?? "Menlo Regular"
        terminalFontSize = (try? c.decodeIfPresent(Double.self, forKey: .terminalFontSize)) ?? 13
        // 老文件没有这一项；解析不出来时也退回兜底值，绝不能留空串当 TERM 传给子进程。
        terminalType = TerminalTypes.resolved(
            (try? c.decodeIfPresent(String.self, forKey: .terminalType)) ?? "",
            default: TerminalTypes.fallback
        )
        fileTreeFontSize = (try? c.decodeIfPresent(Double.self, forKey: .fileTreeFontSize)) ?? 12
        fileTreeIconSize = (try? c.decodeIfPresent(Double.self, forKey: .fileTreeIconSize)) ?? 13
        scrollbackLines = (try? c.decodeIfPresent(Int.self, forKey: .scrollbackLines)) ?? Self.defaultScrollbackLines
        playBellSound = (try? c.decodeIfPresent(Bool.self, forKey: .playBellSound)) ?? false
        followTerminalDirectory = (try? c.decodeIfPresent(Bool.self, forKey: .followTerminalDirectory)) ?? true
        uploadChunkBytes = (try? c.decodeIfPresent(Int.self, forKey: .uploadChunkBytes)) ?? 8 * 1024 * 1024
        maxConcurrentTransfers = (try? c.decodeIfPresent(Int.self, forKey: .maxConcurrentTransfers)) ?? 3
        defaultConnectTimeout = (try? c.decodeIfPresent(Int.self, forKey: .defaultConnectTimeout)) ?? 10
        defaultKeepaliveInterval = (try? c.decodeIfPresent(Int.self, forKey: .defaultKeepaliveInterval)) ?? 30
    }

    public func normalized() -> AppSettings {
        var copy = self
        copy.themeCustomization = themeCustomization.normalized()
        copy.terminalFontSize = min(32, max(9, terminalFontSize))
        copy.terminalType = TerminalTypes.resolved(terminalType, default: TerminalTypes.fallback)
        copy.fileTreeFontSize = min(20, max(10, fileTreeFontSize))
        copy.fileTreeIconSize = min(24, max(10, fileTreeIconSize))
        copy.scrollbackLines = min(200_000, max(200, scrollbackLines))
        copy.uploadChunkBytes = min(64 * 1024 * 1024, max(64 * 1024, uploadChunkBytes))
        copy.maxConcurrentTransfers = min(8, max(1, maxConcurrentTransfers))
        copy.defaultConnectTimeout = min(300, max(1, defaultConnectTimeout))
        copy.defaultKeepaliveInterval = min(600, max(0, defaultKeepaliveInterval))
        return copy
    }
}

/// 设置读写：损坏或版本升级导致的字段缺失都退回默认值，不阻塞启动。
@MainActor
public final class SettingsStore {
    public private(set) var settings: AppSettings = .default
    public var onChange: ((AppSettings) -> Void)?

    private let url: URL

    public init(url: URL = AppPaths.settingsFile) {
        self.url = url
        load()
    }

    public func load() {
        guard let data = FileManager.default.contents(atPath: url.path) else { return }
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode(AppSettings.self, from: data) {
            settings = decoded.normalized()
        } else {
            FileLogger.shared.warning("设置文件无法解析，使用默认设置")
        }
    }

    public func update(_ transform: (inout AppSettings) -> Void) throws {
        var next = settings
        transform(&next)
        settings = next.normalized()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AppPaths.ensureDirectories()
        try encoder.encode(settings).write(to: url, options: .atomic)
        onChange?(settings)
    }
}
