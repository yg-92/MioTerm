import Foundation

/// 串口设备发现与路径校验。macOS 没有可依赖的第三方枚举库，直接看 /dev。
public enum SerialDevices {
    /// macOS 的串口设备有两组名字：`/dev/cu.*`（call-up）打开即占用，
    /// `/dev/tty.*`（call-out）会等到对端拉起载波才返回——做终端必须用 cu，
    /// 否则插上一根没有流控线的设备就会把会话卡在连接那一步。
    public static func discover(fileManager: FileManager = .default) -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: "/dev") else { return [] }
        return entries
            .filter { $0.hasPrefix("cu.") && !$0.hasPrefix("cu.Bluetooth") }
            .map { "/dev/\($0)" }
            .sorted()
    }

    /// 同一个物理设备在 /dev 下常有多个名字（cu./tty.，以及驱动留下的软链接）。
    /// 比对配置与枚举结果时先归一化，否则“设备明明在列表里”也会被判定为不存在。
    public static func canonicalPath(_ device: String) -> String {
        let trimmed = device.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/dev/") else { return trimmed }
        var path = trimmed
        var resolutionCount = 0
        while resolutionCount < 8 {
            let resolved = (path as NSString).resolvingSymlinksInPath
            if resolved == path { break }
            path = resolved
            resolutionCount += 1
        }
        // 驱动偶尔只登记 tty. 那一个名字，两者指同一块芯片。
        return path.replacingOccurrences(of: "/dev/tty.", with: "/dev/cu.")
    }

    /// 路径形状检查：只接受 /dev/ 下的规范路径。这一步是安全边界——
    /// 配置里的字符串直接进 open()，若放过 `/dev/../etc/passwd` 就会把普通文件当终端读写。
    public static func isAcceptablePath(_ device: String) -> Bool {
        // 控制字符要先查、不能先 trim：`/dev/cu.ok\r` 去掉空白后看着完全合法，
        // 但那个换行会一路带进设备名。
        guard device.rangeOfCharacter(from: CharacterSet(charactersIn: "\u{00}\u{0D}\u{0A}")) == nil else { return false }
        let trimmed = device.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 256 else { return false }
        guard trimmed.hasPrefix("/dev/") else { return false }
        return (trimmed as NSString).standardizingPath == trimmed
    }

    /// 设备是否在系统枚举结果里。宁可报“不存在”，也不能打开一个没被识别的路径。
    public static func isAvailable(_ device: String, among candidates: [String]) -> Bool {
        let wanted = canonicalPath(device)
        return candidates.contains { canonicalPath($0) == wanted }
    }

    public static func isAvailable(_ device: String) -> Bool {
        isAvailable(device, among: discover())
    }
}
