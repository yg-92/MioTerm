import Foundation

/// 应用自有的 known_hosts。把它与 `~/.ssh/known_hosts` 分开，
/// 是为了让 “用户确认过什么” 由 MioTerm 自己说清楚，也便于整体撤销。
public struct KnownHostsStore {
    public enum StoreError: LocalizedError {
        case unwritable(String)

        public var errorDescription: String? {
            switch self {
            case .unwritable(let reason): return "写入 known_hosts 失败：\(reason)"
            }
        }
    }

    public let url: URL

    public init(url: URL = AppPaths.knownHostsFile) {
        self.url = url
    }

    public func lines() -> [String] {
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// 只按字面名字匹配，不做别名归并：ssh 校验的正是这个字段，
    /// 把 1.2.3.4 与 host.example.com 混为一谈反而会掩盖密钥变更。
    public func rawLines(matching token: String) -> [String] {
        lines().filter { line in
            guard let entry = Self.parse(line) else { return false }
            return entry.names.contains(token)
        }
    }

    public func hasEntry(for token: String) -> Bool {
        !rawLines(matching: token).isEmpty
    }

    /// 信任一组公钥：先清掉旧条目，再整体写入，避免出现同一主机多套密钥并存。
    public func trust(_ keys: [ScannedHostKey]) throws {
        try write(replacing: keys.map(\.hostToken), with: keys.map(\.keyLine))
    }

    public func revoke(token: String) throws {
        try write(replacing: [token], with: [])
    }

    private func write(replacing tokens: [String], with additions: [String]) throws {
        let kept = lines().filter { line in
            guard let entry = Self.parse(line) else { return true }
            return !entry.names.contains(where: { tokens.contains($0) })
        }
        var out = kept
        out.append(contentsOf: additions)
        let text = out.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n") + "\n"
        do {
            try AppPaths.ensureDirectories()
            try text.data(using: .utf8)!.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw StoreError.unwritable(error.localizedDescription)
        }
    }

    struct Entry {
        let names: [String]
        let algorithm: String
        let publicKey: String
    }

    static func parse(_ line: String) -> Entry? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 3 else { return nil }
        let names = fields[0].split(separator: ",").map(String.init)
        return Entry(names: names, algorithm: String(fields[1]), publicKey: String(fields[2]))
    }
}
