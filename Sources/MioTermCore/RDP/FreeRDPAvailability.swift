import CFreeRDPShim
import Foundation

/// 运行时检测本机是否安装了 FreeRDP（`libwinpr3` + `libfreerdp3`）。
/// 支持通过开关覆盖以便在单元测试中验证无依赖时的拦截逻辑。
public enum FreeRDPAvailability {
    public static let installCommand = "brew install freerdp"

    private static let lock = NSLock()
    private static var overrideInstalled: Bool?

    public static var isInstalled: Bool {
        lock.lock()
        let overridden = overrideInstalled
        lock.unlock()
        if let overridden { return overridden }
        return mio_freerdp_is_available()
    }

    public static var libraryPath: String? {
        guard isInstalled, let cString = mio_freerdp_library_path() else { return nil }
        return String(cString: cString)
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
