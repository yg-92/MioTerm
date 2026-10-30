import Foundation

/// 终端里“这一条命令做了什么”的还原器。
///
/// App 看不到 shell 的 execve，只能看到用户按下的字节，所以命令意图必须从输入流复原；
/// 目录的最终事实以终端自己报出来的为准（OSC 7 或提示符），这里的 cd 预测只是第三顺位的兜底。
/// 一次回车。命令行未必还原得出来（Tab 补全会把文本换成 shell 写回的结果），
/// 但「执行了一条命令」这件事依然成立——目录跟随就挂在这一下上，不能因为文本丢了就整个不触发。
public struct ShellSubmission: Equatable {
    public var command: String?
    /// 命令行文本已不可信（Tab 补全、粘贴、输入法）：命令做了什么只能靠猜。
    public var isTextUnreliable = false
    /// 空行上的 Ctrl+D：当前这层 shell（可能正是容器里的那层）已结束。
    public var endedShell = false
    /// 文本不可信时仍然把用户按下的那一截留在手里：
    /// Tab 补全只是把后半个词交给 shell 写回屏幕，前缀还能用来从回显里认出整条命令。
    public var partialLine: String?

    public init(command: String? = nil, isTextUnreliable: Bool = false,
                endedShell: Bool = false, partialLine: String? = nil) {
        self.command = command
        self.isTextUnreliable = isTextUnreliable
        self.endedShell = endedShell
        self.partialLine = partialLine
    }
}

public struct ShellCommandTracker {
    public init() {}

    private var line: [UInt8] = []
    /// 转义序列不是命令文本，必须整段跳过。只按“ESC 后固定两个字节”吃是不够的：
    /// shell 开了 2004 括号粘贴时，SwiftTerm 会在粘贴内容两侧发 `ESC[200~` / `ESC[201~`，
    /// 少吃的结果是把 `00~`、`1~` 记进命令里。
    private enum State {
        case normal
        /// 刚收到 ESC，下一个字节决定序列类型。
        case afterEscape
        /// `ESC [` 之后，参数与中间字节一直吃到最终字节。
        case csi
        /// SS3 之类：`ESC O` 后面只跟一个字节。
        case skipOne
        /// `ESC ]` 之后，直到 BEL 或 `ESC \`。
        case osc
        /// OSC 里又见到 ESC，等 `\` 收尾。
        case oscEscape
    }
    private var state = State.normal
    /// 出现过 Tab 补全：补全后的文本由 shell 写回，本端记的行已经和真实命令行脱节。
    private var isUnreliable = false

    /// 喂入一段将要发给远端的按键，返回被回车提交的那条命令；没有回车时返回 nil，
    /// 有回车但文本还原不出来时 `command` 是 nil。
    public mutating func consume(_ bytes: ArraySlice<UInt8>) -> ShellSubmission? {
        var submitted: ShellSubmission?
        for byte in bytes {
            if let submission = step(byte) { submitted = submission }
        }
        return submitted
    }

    public mutating func consume(_ bytes: [UInt8]) -> ShellSubmission? {
        consume(bytes[...])
    }

    /// 宿主看到一个改写命令行却还原不出内容的动作（粘贴、历史、输入法）时调用：
    /// 下一次回车仍然算一次执行，只是命令文本不再采信，之前攒下的半截字节也一并作废。
    public mutating func markLineUnreliable() {
        isUnreliable = true
        line.removeAll(keepingCapacity: true)
    }

    @discardableResult
    private mutating func step(_ byte: UInt8) -> ShellSubmission? {
        switch state {
        case .afterEscape:
            switch byte {
            case 0x5B: state = .csi          // [
            case 0x5D: state = .osc          // ]
            default: state = .skipOne
            }
            return nil
        case .skipOne:
            state = .normal
            return nil
        case .csi:
            // 参数 0x30..0x3F、中间 0x20..0x2F 继续等，最终字节 0x40..0x7E 结束整段。
            if (0x40...0x7E).contains(byte) {
                state = .normal
                return nil
            }
            guard byte >= 0x20 else {
                // 控制字节混进序列里说明它已经断了，别把随后正常的键入也吃掉。
                state = .normal
                return step(byte)
            }
            return nil
        case .osc:
            if byte == 0x07 { state = .normal }
            else if byte == 0x1B { state = .oscEscape }
            return nil
        case .oscEscape:
            state = .normal
            return byte == 0x5C ? nil : step(byte)
        case .normal:
            return stepNormal(byte)
        }
    }

    private mutating func stepNormal(_ byte: UInt8) -> ShellSubmission? {
        switch byte {
        case 0x0D, 0x0A:
            defer { line.removeAll(keepingCapacity: true); isUnreliable = false }
            let typed = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !isUnreliable else {
                return ShellSubmission(isTextUnreliable: true,
                                       partialLine: typed.isEmpty ? nil : typed)
            }
            return ShellSubmission(command: typed.isEmpty ? nil : typed)
        case 0x7F, 0x08:
            if isUnreliable {
                // Tab 补全之后再退格，可能已经删进了补全前的前缀，这段前缀不再可信。
                line.removeAll(keepingCapacity: true)
            } else if !line.isEmpty {
                line.removeLast()
            }
            return nil
        case 0x04:
            // Ctrl+D：空行上是 EOF，当前这层 shell 结束；行内有内容时是删字符，还原不出来。
            guard line.isEmpty, !isUnreliable else {
                isUnreliable = true
                line.removeAll(keepingCapacity: true)
                return nil
            }
            return ShellSubmission(endedShell: true)
        case 0x03, 0x15:
            // Ctrl+C 打断、Ctrl+U 清行：整行作废，"文本不可信"的标记也跟着失效。
            line.removeAll(keepingCapacity: true)
            isUnreliable = false
            return nil
        case 0x0C:
            // Ctrl+L 只是重绘，屏幕上的行没变；别把它当成新的一行。
            line.removeAll(keepingCapacity: true)
            return nil
        case 0x1B:
            state = .afterEscape
            return nil
        case 0x09:
            isUnreliable = true
            return nil
        case let value where value < 0x20:
            return nil
        default:
            // 一旦出现过 Tab 补全，后续敲入的字符隔着一段未知的补全结果，
            // 不能再拼到前缀后面，否则 `cd /var/lo<Tab>ng<Tab>` 会拼成不存在的 `cd /var/long`。
            if !isUnreliable {
                line.append(byte)
            }
            return nil
        }
    }
}

/// 一条命令对文件面板意味着什么。
public struct ShellCommandEffect: Equatable {
    /// `cd` 的目标目录；算不准就是 nil（裸 `cd`、`cd -`、`~`、带变量或通配符的写法）。
    public var predictedDirectory: String?
    /// 这条命令动没动文件系统；动了就该重读当前目录。
    public var mayChangeFiles: Bool

    public init(predictedDirectory: String? = nil, mayChangeFiles: Bool = false) {
        self.predictedDirectory = predictedDirectory
        self.mayChangeFiles = mayChangeFiles
    }
}

public enum ShellCommandClassifier {
    /// 会改动目录内容的命令。编辑器也算：`vim new.txt` 会在退出时留下新文件。
    /// 重读发生在编辑器退出、屏幕安静之后，不会打断正在编辑的画面。
    private static let fileMutating: Set<String> = [
        "rm", "mv", "cp", "rsync", "scp", "mkdir", "rmdir", "touch", "ln", "install",
        "chmod", "chown", "chgrp", "dd", "truncate", "tar", "zip", "unzip", "gzip",
        "gunzip", "bzip2", "xz", "git", "svn", "hg", "make", "cmake", "docker", "podman",
        "apt", "apt-get", "yum", "dnf", "apk", "brew", "pip", "pip3", "npm", "pnpm",
        "yarn", "cargo", "gem", "tee", "ssh-keygen", "sed",
        "vim", "vi", "nvim", "nano", "pico", "emacs", "micro", "code"
    ]

    /// 出现这些字符，命令行就不再是一条能静态推断的简单命令。
    private static let unpredictableMarkers = ["$", "`", "|", "&", ";", "<", "*", "?"]

    public static func classify(_ line: String, currentDirectory: String?) -> ShellCommandEffect {
        let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // 重定向与追加一定落了盘，即使命令本身不在白名单里。
        var effect = ShellCommandEffect(mayChangeFiles: line.contains(">") || isMutating(words))
        guard !containsUnpredictable(line), let target = extractCDArgument(from: line) else { return effect }
        // `cd` 是唯一能从输入预测目录的命令；`sudo cd` 之类不成立，其余场景等 OSC 7 报真实目录。
        effect.predictedDirectory = resolveCD(target, from: currentDirectory)
        return effect
    }

    private static func isMutating(_ words: [String]) -> Bool {
        guard let first = words.first else { return false }
        if first == "sudo", words.count > 1 { return fileMutating.contains(words[1]) }
        return fileMutating.contains(first) || fileMutating.contains((first as NSString).lastPathComponent)
    }

    private static func containsUnpredictable(_ line: String) -> Bool {
        unpredictableMarkers.contains { line.contains($0) }
    }

    /// 提取 `cd` 的单一路径参数，支持引号包裹与反斜杠转义空格，以及 `cd -- /path`。
    private static func extractCDArgument(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("cd") else { return nil }
        let afterCD = trimmed.dropFirst(2)
        guard let firstChar = afterCD.first, firstChar.isWhitespace else { return nil }
        var rest = afterCD.drop(while: \.isWhitespace)
        if rest.hasPrefix("--") {
            let afterDash = rest.dropFirst(2)
            if afterDash.isEmpty { return nil }
            if let next = afterDash.first, next.isWhitespace {
                rest = afterDash.drop(while: \.isWhitespace)
            }
        }
        guard !rest.isEmpty else { return nil }
        var result = ""
        var activeQuote: Character?
        var escaped = false
        var index = rest.startIndex
        while index < rest.endIndex {
            let ch = rest[index]
            if escaped {
                result.append(ch)
                escaped = false
            } else if ch == "\\" && activeQuote != "'" {
                escaped = true
            } else if let quote = activeQuote {
                if ch == quote {
                    activeQuote = nil
                } else {
                    result.append(ch)
                }
            } else if ch == "'" || ch == "\"" {
                activeQuote = ch
            } else if ch.isWhitespace {
                // 第一个参数结束后还有别的非空内容（比如 `cd a b`），不作静态预测。
                let trailing = rest[index...].drop(while: \.isWhitespace)
                return trailing.isEmpty && !result.isEmpty ? result : nil
            } else {
                result.append(ch)
            }
            index = rest.index(after: index)
        }
        guard activeQuote == nil, !escaped, !result.isEmpty else { return nil }
        return result
    }

    /// `cd` 的目标只有这几种写法能本地算准：绝对路径、相对当前目录、`..`、`.`。
    private static func resolveCD(_ target: String, from currentDirectory: String?) -> String? {
        guard !target.isEmpty, target != "-", target != "--" else { return nil }
        // `~` 与 `$HOME` 要服务端解析，本地算不出来，交给 OSC 7 或“打开目录”。
        guard !target.hasPrefix("~") else { return nil }
        if target.hasPrefix("/") { return SFTPPath.normalize(target) }
        guard let currentDirectory else { return nil }
        return SFTPPath.join(currentDirectory, target)
    }
}

/// 终端当前对文件面板有意义的一组事实。
public struct TerminalContext: Equatable {
    /// OSC 7 报上来的当前目录（没配钩子的 shell 用 cd 预测或提示符兜底）。
    public var directory: String?
    /// 提示符只显示主目录（`~`、`~/logs`）时的相对段：`""` 就是家目录本身。
    /// 本端不知道远端家目录在哪，所以这截要交给文件通道去解析。
    public var promptHomeHint: String?
    /// 提示符只报了末级目录名（PS1 的 `\W`），而且定位不到绝对路径时记下这个名字。
    /// 只为把话说清楚：面板据此说明“不是没读到，而是读到了也拼不出全路径”。
    public var promptBasename: String?
    /// 每次“改动文件系统的命令执行完”加一；面板据此重读，而不必比较内容。
    public var filesystemRevision: Int
    /// 终端是否还停在本机 shell 里。会话里再 ssh 到别处、或进入 Docker 等容器后，
    /// 内层 shell 报的目录属于另一套文件系统，跟着走只会把树指向当前主机上不存在的路径。
    public var followAllowed: Bool
    /// 当前所处环境：普通 shell、Docker、其他容器或远程 shell。界面顶部据此显示模式。
    public var mode: TerminalMode

    public init(directory: String? = nil, promptHomeHint: String? = nil,
                promptBasename: String? = nil,
                filesystemRevision: Int = 0, followAllowed: Bool = true,
                mode: TerminalMode = .shell) {
        self.directory = directory
        self.promptHomeHint = promptHomeHint
        self.promptBasename = promptBasename
        self.filesystemRevision = filesystemRevision
        self.followAllowed = followAllowed
        self.mode = mode
    }

    /// 界面上展示“此刻在哪”。绝对路径最准；只有提示符写了 `~` / `~/子目录` 时，
    /// 远端家目录的位置本端还不知道，但至少要把提示符原文还原出来，不能显示成未知。
    public var displayDirectory: String? {
        if let directory { return directory }
        guard let promptHomeHint else { return nil }
        return promptHomeHint.isEmpty ? "~" : "~/\(promptHomeHint)"
    }
}

/// OSC 7 的载荷形如 `file://主机/路径`，SFTP 服务端只认路径部分。
public enum OSC7 {
    public static func path(from payload: String?) -> String? {
        guard let payload, !payload.isEmpty else { return nil }
        guard payload.hasPrefix("file:") else { return payload.hasPrefix("/") ? payload : nil }
        // 跳过 `file://` 与主机名，取第一个斜杠之后的内容；主机名为空时即 `file:///路径`。
        guard let slashes = payload.range(of: "//") else { return nil }
        guard let pathStart = payload.range(of: "/", range: slashes.upperBound..<payload.endIndex) else { return nil }
        let raw = String(payload[pathStart.lowerBound...])
        guard !raw.isEmpty else { return nil }
        // 带空格的路径常被编码成 %20，服务端要的是解码后的字面路径。
        return raw.removingPercentEncoding ?? raw
    }

    /// 载荷里的主机段，用来分辨这条 OSC 7 是本机 shell 报的还是嵌套 ssh 里另一台机器报的。
    /// `file:///路径`（主机段为空）与裸路径都返回 nil，等于“没报主机”，不做区分。
    public static func host(from payload: String?) -> String? {
        guard let payload, payload.hasPrefix("file:") else { return nil }
        guard let slashes = payload.range(of: "//") else { return nil }
        guard let pathStart = payload.range(of: "/", range: slashes.upperBound..<payload.endIndex) else { return nil }
        let raw = String(payload[slashes.upperBound..<pathStart.lowerBound])
        guard let decoded = raw.removingPercentEncoding else { return raw.isEmpty ? nil : raw }
        return decoded.isEmpty ? nil : decoded
    }
}
