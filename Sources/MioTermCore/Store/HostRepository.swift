import Foundation

/// 主机配置仓库。配置是少量、低频写的 JSON，直接放主线程读写，
/// 口令字段单独走 KeychainVault，因此这个文件里不含任何机密。
@MainActor
public final class HostRepository {
    public enum StoreError: LocalizedError {
        case unreadable(String)
        case unwritable(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let reason): return L10n.tr(.hostRepoUnreadable, reason)
            case .unwritable(let reason): return L10n.tr(.hostRepoUnwritable, reason)
            }
        }
    }

    public private(set) var hosts: [HostProfile] = []
    public var onChange: (() -> Void)?

    private let url: URL
    private let backupURL: URL
    private let fileManager: FileManager
    private let logger: (String) -> Void

    public init(
        url: URL = AppPaths.hostsFile,
        fileManager: FileManager = .default,
        logger: @escaping (String) -> Void = { FileLogger.shared.info($0) }
    ) {
        self.url = url
        self.backupURL = URL(fileURLWithPath: url.path + ".bak")
        self.fileManager = fileManager
        self.logger = logger
    }

    @discardableResult
    public func load() -> [HostProfile] {
        hosts = Self.decode(from: url, backup: backupURL, fileManager: fileManager, logger: logger)
        return hosts
    }

    public func host(id: String) -> HostProfile? {
        hosts.first { $0.id == id }
    }

    public func groups(matching query: String = "") -> [(name: String, hosts: [HostProfile])] {
        let filtered = filter(query)
        return HostSorting.groups(filtered)
    }

    public func filter(_ query: String) -> [HostProfile] {
        let ordered = HostSorting.sidebarOrder(hosts)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return ordered }
        return ordered.filter { host in
            host.displayName.lowercased().contains(needle)
                || host.address.lowercased().contains(needle)
                || host.username.lowercased().contains(needle)
                || host.groupName.lowercased().contains(needle)
                || host.serial.device.lowercased().contains(needle)
                || host.tags.contains { $0.lowercased().contains(needle) }
        }
    }

    /// 新建与更新共用一条路径：ID 由调用方给定，这里只负责规范化与落盘。
    public func save(_ host: HostProfile) throws -> HostProfile {
        let normalized = host.normalized()
        try normalized.validate()
        if let index = hosts.firstIndex(where: { $0.id == normalized.id }) {
            hosts[index] = normalized
        } else {
            hosts.append(normalized)
        }
        try persist()
        onChange?()
        return normalized
    }

    @discardableResult
    public func delete(id: String) throws -> Bool {
        let before = hosts.count
        hosts.removeAll { $0.id == id }
        if hosts.count != before { try persist() }
        onChange?()
        return hosts.count != before
    }

    public func duplicate(id: String) throws -> HostProfile? {
        guard var copy = host(id: id) else { return nil }
        copy.id = UUID().uuidString
        copy.name = "\(copy.name) \(L10n.tr(.hostDuplicateSuffix))"
        copy.hostKeyAlgorithm = ""
        copy.hostKeyFingerprint = ""
        copy.createdAt = Date()
        return try save(copy)
    }

    public func setFavorite(id: String, _ favorite: Bool) throws {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        var host = hosts[index]
        host.favorite = favorite
        host.updatedAt = Date()
        hosts[index] = host
        try persist()
        onChange?()
    }

    /// 指纹确认结果单独落库，不经过表单，避免表单里的旧值把新指纹覆盖掉。
    public func recordHostKey(id: String, algorithm: String, fingerprint: String) throws {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        var host = hosts[index]
        host.hostKeyAlgorithm = algorithm
        host.hostKeyFingerprint = fingerprint
        host.updatedAt = Date()
        hosts[index] = host
        try persist()
        onChange?()
    }

    @discardableResult
    private func persist() throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(hosts)
        } catch {
            throw StoreError.unwritable(error.localizedDescription)
        }
        do {
            try AppPaths.ensureDirectories()
            if fileManager.fileExists(atPath: url.path) {
                // 先留一份上一版本，损坏时 load() 会退回它。
                try? fileManager.removeItem(at: backupURL)
                try fileManager.copyItem(at: url, to: backupURL)
            }
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            throw StoreError.unwritable(error.localizedDescription)
        }
    }

    nonisolated static func decode(
        from url: URL,
        backup: URL,
        fileManager: FileManager,
        logger: @escaping (String) -> Void
    ) -> [HostProfile] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for candidate in [url, backup] {
            guard let data = fileManager.contents(atPath: candidate.path) else { continue }
            do {
                return try decoder.decode([HostProfile].self, from: data)
            } catch {
                logger("主机配置损坏，改用备份：\(candidate.lastPathComponent) - \(error.localizedDescription)")
                if candidate == url, fileManager.fileExists(atPath: url.path) {
                    // 留下坏文件而不是覆盖它，便于事后人工比对。
                    let quarantined = URL(fileURLWithPath: url.path + ".corrupt-\(Int(Date().timeIntervalSince1970))")
                    try? fileManager.moveItem(at: url, to: quarantined)
                }
            }
        }
        return []
    }
}
