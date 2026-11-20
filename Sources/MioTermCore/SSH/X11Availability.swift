import Foundation

/// 运行时检测本机是否安装了 X11 转发依赖（XQuartz 提供的 `/opt/X11/bin/xauth`）。
/// 支持通过开关覆盖以便在单元测试中验证无依赖时的拦截逻辑。
public enum X11Availability {
    public static let installCommand = "brew install --cask xquartz"

    private static let lock = NSLock()
    private static var overrideInstalled: Bool?

    public static var isInstalled: Bool {
        lock.lock()
        let overridden = overrideInstalled
        lock.unlock()
        if let overridden { return overridden }
        return FileManager.default.isExecutableFile(atPath: SSHLaunchPlanner.xauthPath)
    }

    static func withOverride<T>(_ installed: Bool?, body: () throws -> T) rethrows -> T {
        lock.lock()
        let previous = overrideInstalled
        overrideInstalled = installed
        lock.unlock()
        defer {
            lock.lock()
            overrideInstalled = previous
            lock.unlock()
        }
        return try body()
    }
}
