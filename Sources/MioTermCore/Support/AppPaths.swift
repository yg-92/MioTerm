import Foundation

/// 应用数据目录与派生路径。所有可写状态都放在 Application Support 下，
/// 保证 `swift run` 与打包后的 .app 使用同一份数据。
public enum AppPaths {
    public static let bundleIdentifier = "com.mio.term"

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MioTerm", isDirectory: true)
    }

    public static var knownHostsFile: URL { supportDirectory.appendingPathComponent("known_hosts") }
    public static var hostsFile: URL { supportDirectory.appendingPathComponent("hosts.json") }
    public static var commandsFile: URL { supportDirectory.appendingPathComponent("commands.json") }
    public static var settingsFile: URL { supportDirectory.appendingPathComponent("settings.json") }
    public static var logDirectory: URL { supportDirectory.appendingPathComponent("logs", isDirectory: true) }
    public static var askpassDirectory: URL { supportDirectory.appendingPathComponent("askpass", isDirectory: true) }

    /// 建目录并把权限收紧到 0700；失败直接抛出，由调用方决定是否降级。
    public static func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [supportDirectory, logDirectory, askpassDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }
}
