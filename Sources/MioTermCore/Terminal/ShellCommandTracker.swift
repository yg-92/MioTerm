import Foundation

/// 终端里“这一条命令做了什么”的还原器。
///
/// App 看不到 shell 的 execve，只能看到用户按下的字节，所以命令意图必须从输入流复原；
/// 目录的最终事实仍以 OSC 7 报上来的为准，这里的 cd 预测只在没配 OSC 7 钩子的 shell 里兜底。
public struct ShellCommandTracker {
    private var line: [UInt8] = []
    /// 转义序列的剩余字节数：ESC 之后还要吃掉 `[` 与最终字节。
    private var pendingEscape = 0
    /// 出现过 Tab 补全：补全后的文本由 shell 写回，本端记的行已经和真实命令行脱节。
    private var isUnreliable = false

    /// 喂入一段将要发给远端的按键，返回被回车提交的整行命令；无法还原时返回 nil。
    public mutating func consume(_ bytes: ArraySlice<UInt8>) -> String? {
        var submitted: String?
        for byte in bytes {
            if let text = step(byte) { submitted = text }
        }
        return submitted
    }

    public mutating func consume(_ bytes: [UInt8]) -> String? {
        consume(bytes[...])
    }

    @discardableResult
    private mutating func step(_ byte: UInt8) -> String? {
        if pendingEscape > 0 {
            pendingEscape -= 1
            return nil
        }
        switch byte {
        case 0x0D, 0x0A:
            defer { line.removeAll(keepingCapacity: true); isUnreliable = false }
            guard !isUnreliable else { return nil }
            let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        case 0x7F, 0x08:
            if !line.isEmpty { line.removeLast() }
            return nil
        case 0x03, 0x0C, 0x15:
            // Ctrl+C 打断、Ctrl+L 重绘、Ctrl+U 清行：都别留下半条命令。
            line.removeAll(keepingCapacity: true)
            return nil
        case 0x1B:
            pendingEscape = 2
            return nil
        case 0x09:
            isUnreliable = true
            return nil
        case let value where value < 0x20:
            return nil
        default:
            line.append(byte)
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
    /// 会改动目录内容的命令。编辑器不算：面板要的是增删改名，不是 mtime 变了。
    private static let fileMutating: Set<String> = [
        "rm", "mv", "cp", "rsync", "scp", "mkdir", "rmdir", "touch", "ln", "install",
        "chmod", "chown", "chgrp", "dd", "truncate", "tar", "zip", "unzip", "gzip",
        "gunzip", "bzip2", "xz", "git", "svn", "hg", "make", "cmake", "docker", "podman",
        "apt", "apt-get", "yum", "dnf", "apk", "brew", "pip", "pip3", "npm", "pnpm",
        "yarn", "cargo", "gem", "tee", "ssh-keygen"
    ]

    /// 出现这些字符，命令行就不再是一条能静态推断的简单命令。
    private static let unpredictableMarkers = ["$", "`", "|", "&", ";", "<", "*", "?"]

    public static func classify(_ line: String, currentDirectory: String?) -> ShellCommandEffect {
        let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // 重定向与追加一定落了盘，即使命令本身不在白名单里。
        var effect = ShellCommandEffect(mayChangeFiles: line.contains(">") || isMutating(words))
        guard let command = words.first, command == "cd", words.count == 2, !containsUnpredictable(line) else { return effect }
        // `cd` 是唯一能从输入预测目录的命令；`sudo cd` 之类不成立，其余场景等 OSC 7 报真实目录。
        effect.predictedDirectory = resolveCD(words[1], from: currentDirectory)
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

    /// `cd` 的目标只有这几种写法能本地算准：绝对路径、相对当前目录、`..`、`.`。
    private static func resolveCD(_ argument: String, from currentDirectory: String?) -> String? {
        var target = argument
        if let quote = target.first, quote == "'" || quote == "\"", target.hasSuffix(String(quote)), target.count > 1 {
            target = String(target.dropFirst().dropLast())
        }
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
    /// OSC 7 报上来的当前目录（没配钩子的 shell 用 cd 预测兜底）。
    public var directory: String?
    /// 每次“改动文件系统的命令执行完”加一；面板据此重读，而不必比较内容。
    public var filesystemRevision: Int

    public init(directory: String? = nil, filesystemRevision: Int = 0) {
        self.directory = directory
        self.filesystemRevision = filesystemRevision
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
}
