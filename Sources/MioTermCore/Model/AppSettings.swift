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

/// 界面与连接的可调项。除监听/路径类配置外，这里的改动即时生效，
/// 对齐 webterm “页面配置热更新” 的行为。
public struct AppSettings: Codable, Equatable, Sendable {
    public var appearance: AppearanceMode
    public var terminalFontName: String
    public var terminalFontSize: Double
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
        appearance: AppearanceMode = .system,
        terminalFontName: String = "Menlo Regular",
        terminalFontSize: Double = 13,
        fileTreeFontSize: Double = 12,
        fileTreeIconSize: Double = 13,
        scrollbackLines: Int = 10_000,
        playBellSound: Bool = false,
        followTerminalDirectory: Bool = true,
        uploadChunkBytes: Int = 8 * 1024 * 1024,
        maxConcurrentTransfers: Int = 3,
        defaultConnectTimeout: Int = 10,
        defaultKeepaliveInterval: Int = 30
    ) {
        self.appearance = appearance
        self.terminalFontName = terminalFontName
        self.terminalFontSize = terminalFontSize
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
        appearance = (try? c.decodeIfPresent(AppearanceMode.self, forKey: .appearance)) ?? .system
        terminalFontName = (try? c.decodeIfPresent(String.self, forKey: .terminalFontName)) ?? "Menlo Regular"
        terminalFontSize = (try? c.decodeIfPresent(Double.self, forKey: .terminalFontSize)) ?? 13
        fileTreeFontSize = (try? c.decodeIfPresent(Double.self, forKey: .fileTreeFontSize)) ?? 12
        fileTreeIconSize = (try? c.decodeIfPresent(Double.self, forKey: .fileTreeIconSize)) ?? 13
        scrollbackLines = (try? c.decodeIfPresent(Int.self, forKey: .scrollbackLines)) ?? 10_000
        playBellSound = (try? c.decodeIfPresent(Bool.self, forKey: .playBellSound)) ?? false
        followTerminalDirectory = (try? c.decodeIfPresent(Bool.self, forKey: .followTerminalDirectory)) ?? true
        uploadChunkBytes = (try? c.decodeIfPresent(Int.self, forKey: .uploadChunkBytes)) ?? 8 * 1024 * 1024
        maxConcurrentTransfers = (try? c.decodeIfPresent(Int.self, forKey: .maxConcurrentTransfers)) ?? 3
        defaultConnectTimeout = (try? c.decodeIfPresent(Int.self, forKey: .defaultConnectTimeout)) ?? 10
        defaultKeepaliveInterval = (try? c.decodeIfPresent(Int.self, forKey: .defaultKeepaliveInterval)) ?? 30
    }

    public func normalized() -> AppSettings {
        var copy = self
        copy.terminalFontSize = min(32, max(9, terminalFontSize))
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
