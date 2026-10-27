import Foundation

/// TERM 的候选与解析。列表里的每一项都在 macOS 自带的 terminfo 数据库里存在，
/// 但远端不一定有——挑到远端没有的类型，ssh 会报 “missing or unsuitable terminal”，
/// 这是配置问题不是连接故障，所以界面把选择权留给用户，代码只保证值本身合法。
public enum TerminalTypes {
    /// 内置模拟器就是 xterm，任何解析不出值的地方都退回它。
    public static let fallback = "xterm-256color"

    /// 候选按“越靠前越通用”排列：前三个几乎所有 Unix 都认，后面几类要求对端装了对应 terminfo。
    public static let options: [String] = [
        "xterm-256color",
        "xterm-color",
        "xterm",
        "screen-256color",
        "screen",
        "tmux-256color",
        "vt220",
        "vt100",
        "linux",
        "ansi",
    ]

    /// Telnet 的 TERMTYPE 子协商只带 64 字节，超长的值发不出去，不如当没填。
    public static let maximumLength = 64

    /// 清洗用户输入：去首尾空白，空值与超长值一律归零成空串。
    /// 空串是“跟随设置里的默认”，不是错误，主机配置和设置项都靠它区分“没指定”。
    public static func sanitized(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.count > maximumLength ? "" : trimmed
    }

    /// 解析成实际生效的 TERM。主机没指定时用设置里的默认值，默认值也不可用就用兜底。
    public static func resolved(_ value: String, default defaultValue: String) -> String {
        let candidate = sanitized(value)
        if !candidate.isEmpty { return candidate }
        let fallback = sanitized(defaultValue)
        return fallback.isEmpty ? TerminalTypes.fallback : fallback
    }
}
