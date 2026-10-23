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
    public var scrollbackLines: Int
    public var playBellSound: Bool
    public var confirmBeforeClose: Bool
    public var followTerminalDirectory: Bool
    public var uploadChunkBytes: Int
    public var maxConcurrentTransfers: Int
    public var defaultConnectTimeout: Int
    public var defaultKeepaliveInterval: Int

    public init(
        appearance: AppearanceMode = .system,
        terminalFontName: String = "Menlo Regular",
        terminalFontSize: Double = 13,
        scrollbackLines: Int = 10_000,
        playBellSound: Bool = false,
        confirmBeforeClose: Bool = true,
        followTerminalDirectory: Bool = true,
        uploadChunkBytes: Int = 8 * 1024 * 1024,
        maxConcurrentTransfers: Int = 3,
        defaultConnectTimeout: Int = 10,
        defaultKeepaliveInterval: Int = 30
    ) {
        self.appearance = appearance
        self.terminalFontName = terminalFontName
        self.terminalFontSize = terminalFontSize
        self.scrollbackLines = scrollbackLines
        self.playBellSound = playBellSound
        self.confirmBeforeClose = confirmBeforeClose
        self.followTerminalDirectory = followTerminalDirectory
        self.uploadChunkBytes = uploadChunkBytes
        self.maxConcurrentTransfers = maxConcurrentTransfers
        self.defaultConnectTimeout = defaultConnectTimeout
        self.defaultKeepaliveInterval = defaultKeepaliveInterval
    }

    public static let `default` = AppSettings()

    public func normalized() -> AppSettings {
        var copy = self
        copy.terminalFontSize = min(32, max(9, terminalFontSize))
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
