import Foundation

/// 远端路径只做词法处理，绝不碰本地文件系统规则：SFTP 服务端永远是 POSIX 语义，
/// 而 Swift 的 URL 会把 `\`、百分号转义等本地约定掺进来，用它拼远端路径迟早出错。
public enum SFTPPath {
    public static let root = "/"

    /// 等价于 Go `path.Clean`：折叠 `.`、`..`、重复斜杠，去掉结尾斜杠。
    public static func normalize(_ path: String) -> String {
        let absolute = path.hasPrefix(root)
        var components: [String] = []
        for piece in path.split(separator: "/", omittingEmptySubsequences: true) {
            let part = String(piece)
            switch part {
            case ".":
                continue
            case "..":
                if let last = components.last, last != ".." {
                    components.removeLast()
                } else if !absolute {
                    components.append("..")
                }
            default:
                components.append(part)
            }
        }
        let joined = components.joined(separator: root)
        if absolute { return root + joined }
        return joined.isEmpty ? "." : joined
    }

    public static func join(_ directory: String, _ name: String) -> String {
        if name.hasPrefix(root) { return normalize(name) }
        let base = normalize(directory)
        // 结尾斜杠也要收拾干净：`cd ../` 从 `/home` 算出来的 `/` 再拼 `x/`
        // 会得到 `/x/`，日志和比较里多一个斜杠只是噪音。
        if base == root { return normalize(root + name) }
        return normalize(base + root + name)
    }

    /// 上级目录；根目录的上级仍是根目录，UI 据此禁用“返回上级”。
    public static func parent(_ path: String) -> String {
        let cleaned = normalize(path)
        if cleaned == root { return root }
        guard let lastSlash = cleaned.lastIndex(of: "/") else { return "." }
        let candidate = String(cleaned[..<lastSlash])
        return candidate.isEmpty ? root : candidate
    }

    public static func lastComponent(_ path: String) -> String {
        let cleaned = normalize(path)
        if cleaned == root { return root }
        return String(cleaned.split(separator: "/").last ?? "")
    }

    public static func isRoot(_ path: String) -> Bool {
        normalize(path) == root
    }

    /// 面包屑：/usr/local/bin → ["/", "/usr", "/usr/local", "/usr/local/bin"]
    public static func ancestors(_ path: String) -> [String] {
        let cleaned = normalize(path)
        guard cleaned.hasPrefix(root) else { return [cleaned] }
        var result: [String] = [root]
        var current = ""
        for part in cleaned.split(separator: "/", omittingEmptySubsequences: true) {
            current += root + part
            result.append(current)
        }
        return result
    }

    /// 相对路径在服务端按登录目录解析；UI 需要展示时补一个可读前缀。
    public static func display(_ path: String) -> String {
        path.isEmpty ? root : normalize(path)
    }
}
