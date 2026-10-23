import Foundation

/// 把路径之类的值安全地塞进一行 shell 命令。
///
/// 单引号里除了单引号本身全是字面量，所以空格、`$`、反引号都不用逐个转义；
/// 遇到单引号只能先关引号、塞一个转义过的引号、再开引号。
public enum ShellQuoting {
    public static func singleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// 干净的路径保持原样（`cd /var/log` 比 `cd '/var/log'` 好读），
    /// 只有出现 shell 元字符或为空时才加引号。
    public static func quoteIfNeeded(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let isPlain = value.allSatisfy { char in
            char.isLetter || char.isNumber || "._-/@:+".contains(char)
        }
        return isPlain ? value : singleQuoted(value)
    }
}
