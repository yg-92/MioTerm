import Foundation

/// 一条命令在库里的档案。
///
/// 只记“跑过几次、最后一次什么时候、有没有收藏”：退出码和所在目录要靠 shell 侧钩子
/// 或服务端配合，纯输入流还原出来的命令行给不出这两项，与其猜不如不记。
public struct CommandRecord: Codable, Equatable, Identifiable, Sendable {
    public var command: String
    public var executionCount: Int
    public var lastExecutedAt: Date
    public var favorite: Bool
    public var favoritedAt: Date?

    /// 命令文本本身就是键：同一条命令在同一个作用域里只应有一条档案。
    public var id: String { command }

    public init(command: String, executionCount: Int = 0, lastExecutedAt: Date = Date(), favorite: Bool = false, favoritedAt: Date? = nil) {
        self.command = command
        self.executionCount = executionCount
        self.lastExecutedAt = lastExecutedAt
        self.favorite = favorite
        self.favoritedAt = favoritedAt
    }

    /// 逐字段容错解码：统计以后还要加键，旧文件不该因此被整份判废。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decode(String.self, forKey: .command)
        executionCount = try container.decodeIfPresent(Int.self, forKey: .executionCount) ?? 0
        lastExecutedAt = try container.decodeIfPresent(Date.self, forKey: .lastExecutedAt) ?? Date()
        favorite = try container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        favoritedAt = try container.decodeIfPresent(Date.self, forKey: .favoritedAt)
    }
}

public enum CommandScope {
    /// 本地终端标签没有主机 ID，单独占一个作用域，免得它的命令混进某台主机。
    public static let localShell = "local"

    public static func key(host: HostProfile?) -> String { host?.id ?? localShell }
}

/// 忽略清单里的一条规则。
public struct IgnoredCommand: Equatable, Sendable {
    public var command: String
    /// 全局规则对所有主机生效，本机规则只管它所属的那个作用域。
    public var global: Bool

    public init(command: String, global: Bool) {
        self.command = command
        self.global = global
    }
}

/// 命令库：终端里敲过的命令的统计、收藏与忽略清单。
///
/// 全部落在一份 JSON 里，读写都在主线程——量小、写频低，和主机配置同一套处理方式。
/// 忽略清单分本机与全局两层，命中即不记录，与 webterm 的三张表同构。
@MainActor
public final class CommandLibraryStore {
    /// 每个作用域最多留下的非收藏条数；收藏不参与淘汰。
    public static let maximumTrackedCommands = 50
    /// 超过这个长度多半是粘贴的脚本，不是能一键注入的命令。
    public static let maximumCommandLength = 512

    public var onChange: (() -> Void)?

    /// 作用域（主机 ID 或 local）→ 命令 → 档案。
    private var entries: [String: [String: CommandRecord]] = [:]
    private var hostIgnores: [String: [String]] = [:]
    private var globalIgnores: [String] = []

    private struct Payload: Codable {
        var version: Int = 1
        var records: [String: [String: CommandRecord]] = [:]
        var hostIgnores: [String: [String]] = [:]
        var globalIgnores: [String] = []

        init() {}

        /// 逐字段容错：以后再加键，旧文件不该被判成损坏而清空全部统计。
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            records = try container.decodeIfPresent([String: [String: CommandRecord]].self, forKey: .records) ?? [:]
            hostIgnores = try container.decodeIfPresent([String: [String]].self, forKey: .hostIgnores) ?? [:]
            globalIgnores = try container.decodeIfPresent([String].self, forKey: .globalIgnores) ?? []
        }
    }

    private let url: URL
    private let backupURL: URL
    private let fileManager: FileManager
    private let logger: (String) -> Void

    public init(
        url: URL = AppPaths.commandsFile,
        fileManager: FileManager = .default,
        logger: @escaping (String) -> Void = { FileLogger.shared.info($0) }
    ) {
        self.url = url
        self.backupURL = URL(fileURLWithPath: url.path + ".bak")
        self.fileManager = fileManager
        self.logger = logger
    }

    /// 读盘。返回 false 表示主文件与备份都读不出可用内容，库从空开始。
    @discardableResult
    public func load() -> Bool {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for candidate in [url, backupURL] {
            guard let data = fileManager.contents(atPath: candidate.path) else { continue }
            do {
                let payload = try decoder.decode(Payload.self, from: data)
                entries = payload.records
                hostIgnores = payload.hostIgnores
                globalIgnores = payload.globalIgnores
                return true
            } catch {
                logger("命令库损坏，改用备份：\(candidate.lastPathComponent) - \(error.localizedDescription)")
                if candidate == url, fileManager.fileExists(atPath: url.path) {
                    // 留下坏文件而不是覆盖它，便于事后人工比对。
                    let quarantined = URL(fileURLWithPath: url.path + ".corrupt-\(Int(Date().timeIntervalSince1970))")
                    try? fileManager.moveItem(at: url, to: quarantined)
                }
            }
        }
        entries = [:]
        hostIgnores = [:]
        globalIgnores = []
        return false
    }

    // MARK: - 记录

    /// 记下一条命令；返回 false 表示这条被忽略清单挡掉了（或本身不该入库）。
    @discardableResult
    public func record(scope: String, command raw: String, at date: Date = Date()) -> Bool {
        guard let command = Self.normalize(raw) else { return false }
        if isIgnored(command, scope: scope) {
            // 忽略命中是常态（例如反复敲 `ls`），没有历史可清时不要每次都重写文件、刷新面板。
            if dropHistory(for: command) {
                persist()
                onChange?()
            }
            return false
        }
        var byCommand = entries[scope] ?? [:]
        if var existing = byCommand[command] {
            existing.executionCount += 1
            existing.lastExecutedAt = date
            byCommand[command] = existing
        } else {
            byCommand[command] = CommandRecord(command: command, executionCount: 1, lastExecutedAt: date)
        }
        entries[scope] = byCommand
        trim(scope: scope)
        persist()
        onChange?()
        return true
    }

    /// 只留 maximumTrackedCommands 条非收藏记录，先淘汰用得最少的，同样少则淘汰最久没用的。
    private func trim(scope: String) {
        var byCommand = entries[scope] ?? [:]
        let tracked = byCommand.values.filter { !$0.favorite }
        guard tracked.count > Self.maximumTrackedCommands else { return }
        let weakest = tracked.sorted {
            if $0.executionCount != $1.executionCount { return $0.executionCount < $1.executionCount }
            return $0.lastExecutedAt < $1.lastExecutedAt
        }
        for victim in weakest.prefix(tracked.count - Self.maximumTrackedCommands) {
            byCommand.removeValue(forKey: victim.command)
        }
        entries[scope] = byCommand
    }

    // MARK: - 读取

    public func records(scope: String) -> [CommandRecord] {
        Array((entries[scope] ?? [:]).values)
    }

    public func entry(scope: String, command raw: String) -> CommandRecord? {
        guard let command = Self.normalize(raw) else { return nil }
        return entries[scope]?[command]
    }

    /// 收藏按收藏时间倒序：刚收藏的排最前，符合“挑最近想常用的”直觉。
    public func favorites(scope: String) -> [CommandRecord] {
        records(scope: scope).filter { $0.favorite }
            .sorted { ($0.favoritedAt ?? .distantPast) > ($1.favoritedAt ?? .distantPast) }
    }

    /// 按执行次数排序，次数相同按最近使用。收藏也会出现在这里，由面板决定是否去重。
    public func mostUsed(scope: String) -> [CommandRecord] {
        records(scope: scope).sorted {
            if $0.executionCount != $1.executionCount { return $0.executionCount > $1.executionCount }
            return $0.lastExecutedAt > $1.lastExecutedAt
        }
    }

    public func mostRecent(scope: String) -> [CommandRecord] {
        records(scope: scope).sorted { $0.lastExecutedAt > $1.lastExecutedAt }
    }

    // MARK: - 收藏与删除

    public func setFavorite(_ raw: String, scope: String, favorite: Bool) {
        guard let command = Self.normalize(raw) else { return }
        var byCommand = entries[scope] ?? [:]
        // 收藏一条还没跑过的命令也成立：先建一条 0 次的档案，跑过之后再按次数参与淘汰。
        var stored = byCommand[command] ?? CommandRecord(command: command, executionCount: 0, lastExecutedAt: Date())
        stored.favorite = favorite
        stored.favoritedAt = favorite ? Date() : nil
        byCommand[command] = stored
        entries[scope] = byCommand
        persist()
        onChange?()
    }

    public func remove(command: String, scope: String) {
        guard var byCommand = entries[scope], byCommand.removeValue(forKey: command) != nil else { return }
        entries[scope] = byCommand
        persist()
        onChange?()
    }

    /// 清空一个作用域的历史与本机忽略清单。
    public func clear(scope: String) {
        guard entries[scope] != nil || hostIgnores[scope] != nil else { return }
        entries.removeValue(forKey: scope)
        hostIgnores.removeValue(forKey: scope)
        persist()
        onChange?()
    }

    /// 主机被删掉后，它的统计与本机忽略清单就是孤儿数据。
    public func prune(validScopes: Set<String>) {
        let local = CommandScope.localShell
        var changed = false
        for scope in Array(entries.keys) where scope != local && !validScopes.contains(scope) {
            entries.removeValue(forKey: scope)
            changed = true
        }
        for scope in Array(hostIgnores.keys) where scope != local && !validScopes.contains(scope) {
            hostIgnores.removeValue(forKey: scope)
            changed = true
        }
        guard changed else { return }
        persist()
        onChange?()
    }

    // MARK: - 忽略清单

    public func isIgnored(_ command: String, scope: String) -> Bool {
        globalIgnores.contains(command) || (hostIgnores[scope] ?? []).contains(command)
    }

    /// 本机与全局两层合并后的忽略清单，面板按 global 标记分组显示。
    public func ignoredCommands(scope: String) -> [IgnoredCommand] {
        let local = (hostIgnores[scope] ?? []).map { IgnoredCommand(command: $0, global: false) }
        let shared = globalIgnores.map { IgnoredCommand(command: $0, global: true) }
        return (local + shared).sorted { $0.command.localizedStandardCompare($1.command) == .orderedAscending }
    }

    /// scope 为 nil 表示全局清单：所有主机都不记录这条命令。
    public func addIgnore(_ raw: String, scope: String?) {
        guard let command = Self.normalize(raw) else { return }
        if scope == nil {
            guard !globalIgnores.contains(command) else { return }
            globalIgnores.append(command)
        } else {
            var list = hostIgnores[scope!] ?? []
            guard !list.contains(command) else { return }
            list.append(command)
            hostIgnores[scope!] = list
        }
        dropHistory(for: command)
        persist()
        onChange?()
    }

    public func removeIgnore(_ command: String, scope: String?) {
        if scope == nil {
            globalIgnores.removeAll { $0 == command }
        } else if var list = hostIgnores[scope!] {
            list.removeAll { $0 == command }
            if list.isEmpty {
                hostIgnores.removeValue(forKey: scope!)
            } else {
                hostIgnores[scope!] = list
            }
        }
        persist()
        onChange?()
    }

    /// 把某台主机上的忽略规则升级为全局规则。
    public func promoteIgnoreToGlobal(_ command: String, scope: String) {
        removeIgnore(command, scope: scope)
        addIgnore(command, scope: nil)
    }

    /// 命中忽略就把它在所有作用域里的历史清掉：留着会变成一条再也更新不了的僵尸记录。
    /// 返回是否真的删掉了东西，调用方据此决定要不要落盘。
    @discardableResult
    private func dropHistory(for command: String) -> Bool {
        var changed = false
        for scope in Array(entries.keys) {
            if entries[scope]?.removeValue(forKey: command) != nil { changed = true }
            if entries[scope]?.isEmpty == true { entries.removeValue(forKey: scope) }
        }
        return changed
    }

    // MARK: - 规范化与落盘

    /// 首尾空白去掉后原样存：折叠内部空白会把 `grep "a  b"` 改成另一条命令。
    public static func normalize(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // 带换行或响铃说明是粘贴的脚本/控制串：注入回去会连着执行好几条，不是“一条命令”。
        guard !text.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\u{07}" }) else { return nil }
        guard text.count <= maximumCommandLength else { return nil }
        return text
    }

    @discardableResult
    private func persist() -> Bool {
        var payload = Payload()
        payload.records = entries
        payload.hostIgnores = hostIgnores
        payload.globalIgnores = globalIgnores
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(payload)
            // 只保证自己所在目录存在：注入自定义路径（测试用临时目录）时才不必碰真实数据目录。
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: backupURL)
                try fileManager.copyItem(at: url, to: backupURL)
            }
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            // 统计写不进去不该打断终端，日志里留一句就够了。
            logger("命令库写入失败：\(error.localizedDescription)")
            return false
        }
    }
}
