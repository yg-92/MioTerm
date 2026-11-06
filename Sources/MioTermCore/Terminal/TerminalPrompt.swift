import Foundation

/// 一行 shell 提示符里能读到的事实。
public struct PromptFact: Equatable {
    /// `user@主机` 里的主机段，用不着时是 nil。
    public var host: String?
    /// 提示符显示的那段路径原文：`/var/log`、`~`、`~/logs`，
    /// 也可能是 PS1 里 `\W` 那种只剩末级名字的 `nginx`。
    public var hint: String?

    public init(host: String? = nil, hint: String? = nil) {
        self.host = host
        self.hint = hint
    }

    /// 绝对路径形态，能直接给 SFTP 用。
    public var absoluteDirectory: String? {
        guard let hint, hint.hasPrefix("/") else { return nil }
        return SFTPPath.normalize(hint)
    }

    /// `~` 或 `~/xxx` 相对主目录的那一段；`~` 本身是空串，不是这种形态时是 nil。
    public var homeRelativePath: String? {
        guard let hint else { return nil }
        if hint == "~" { return "" }
        guard hint.hasPrefix("~/") else { return nil }
        let tail = String(hint.dropFirst(2))
        return tail.isEmpty ? nil : tail
    }

    /// 只剩末级目录名：只能用来核对已经预测到的路径，不足以单独定位。
    public var baseName: String? {
        guard let hint, absoluteDirectory == nil, homeRelativePath == nil else { return nil }
        return hint
    }
}

/// 没配 OSC 7 钩子的机器是常态：那时候提示符里的 `[user@host /路径]#`、`user@host:/路径$`
/// 是唯一能说清“终端此刻在哪、还在不在本机”的来源，语义对齐 webterm 的 directoryHintFromPrompt。
public enum TerminalPrompt {
    /// `[root@134 /var/log]#`、`[user@host ~]$`、`[user@host log]#`
    private static let bracketed = try! NSRegularExpression(
        pattern: #"\[(?![^\s\]]*\])[^@\s\]]+@([^\s\]]+)\s+(~[/\w.\-]*|/[^\]]*|[^\]\s]+)\][#$%]\s*$"#
    )
    /// `root@134:/var/log #`、`user@mac:~$`
    private static let colon = try! NSRegularExpression(
        pattern: #"(?:^|\s)([^@\s\]]+)@([^:\s]+):(~/[^\s]*|/[^\s]*|~)\s?[#$%]\s*$"#
    )
    /// 不带方括号也不带冒号的 PS1：`root@134 /var/log#`、`user@mac ~/code $`
    private static let spaced = try! NSRegularExpression(
        pattern: #"(?:^|\s)([^@\s\]]+)@([^\s:]+)\s(~/[^\s$#%]*|/[^\s$#%]*|~)\s?[#$%]\s*$"#
    )

    /// 认不出的行返回 nil，调用方据此保持“不知道”，不要拿半截字符串当目录。
    public static func parse(_ line: String) -> PromptFact? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let patterns = [(bracketed, 1, 2), (colon, 2, 3), (spaced, 2, 3)]
        for (pattern, hostGroup, hintGroup) in patterns {
            guard let match = pattern.firstMatch(in: text, range: range) else { continue }
            return PromptFact(
                host: capture(match, at: hostGroup, in: text),
                hint: capture(match, at: hintGroup, in: text)?.trimmingCharacters(in: .whitespaces)
            )
        }
        return nil
    }

    /// 命令回显和删除确认不是完成提示符。无路径的常见 PS1（如 bash-5.2#）
    /// 只能判断命令已结束，不能用它推断当前目录。
    public static func isReadyForCommand(_ line: String?) -> Bool {
        guard let line else { return false }
        if parse(line) != nil { return true }
        guard commandAfterPrompt(in: line) == nil,
              let last = line.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return "#$%❯➜".contains(last)
    }

    private static func capture(_ match: NSTextCheckingResult, at index: Int, in text: String) -> String? {
        guard index < match.numberOfRanges else { return nil }
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    /// 回显行是「提示符 + 已经敲进去的命令」，比如 `[root@134 ~]# cd /home/jenkins_home/`。
    ///
    /// 粘贴、历史回溯、输入法都会让本端攒的行和真实命令行脱节，按键也未必听得全；
    /// 但 shell 的回显是它自己写的，最可信。这里沿着一行从左往右找第一个能
    /// 按提示符语法解析出来的前缀，它后面那截就是命令。
    public static func commandAfterPrompt(in line: String?) -> String? {
        guard let line, !line.isEmpty else { return nil }
        var index = line.startIndex
        var matchedEnd: String.Index?
        while index < line.endIndex {
            let character = line[index]
            if character == "#" || character == "$" || character == "%" {
                if parse(String(line[line.startIndex...index])) != nil {
                    matchedEnd = index
                    let next = line.index(after: index)
                    // 提示符的结尾符后面通常紧跟空格；若后面还连着非空白字符（例如目录名本身含 `#`：`root@134:/a#1# cmd`），
                    // 继续往同一词的末尾找，避免把路径后半截当成命令。
                    if next == line.endIndex || line[next].isWhitespace {
                        break
                    }
                }
            }
            index = line.index(after: index)
        }
        guard let end = matchedEnd else { return nil }
        let command = String(line[line.index(after: end)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }
}
