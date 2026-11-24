import Foundation

public extension Notification.Name {
    static let mioTermCredentialsDidChange = Notification.Name("MioTermCredentialsDidChange")
}

/// 凭据库仓库：将凭据元数据（名称、用户名、备注）原子写入 `credentials.json`，
/// 密码正文全部交由 `KeychainVault` 保管，JSON 中不落任何明文密码。
@MainActor
public final class CredentialRepository {
    public private(set) var credentials: [CredentialProfile] = []
    public var onChange: (() -> Void)?

    private let url: URL
    private let backupURL: URL
    private let fileManager: FileManager
    private let logger: (String) -> Void

    public init(
        url: URL = AppPaths.credentialsFile,
        fileManager: FileManager = .default,
        logger: @escaping (String) -> Void = { FileLogger.shared.info($0) }
    ) {
        self.url = url
        self.backupURL = URL(fileURLWithPath: url.path + ".bak")
        self.fileManager = fileManager
        self.logger = logger
    }

    @discardableResult
    public func load() -> [CredentialProfile] {
        credentials = Self.decode(from: url, backup: backupURL, fileManager: fileManager, logger: logger)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return credentials
    }

    public func credential(id: String) -> CredentialProfile? {
        credentials.first { $0.id == id }
    }

    public func filter(_ query: String) -> [CredentialProfile] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return credentials }
        return credentials.filter { item in
            item.name.lowercased().contains(needle)
                || item.username.lowercased().contains(needle)
                || item.notes.lowercased().contains(needle)
        }
    }

    @discardableResult
    public func save(_ credential: CredentialProfile) throws -> CredentialProfile {
        let normalized = credential.normalized()
        try normalized.validate()
        if let index = credentials.firstIndex(where: { $0.id == normalized.id }) {
            credentials[index] = normalized
        } else {
            credentials.append(normalized)
        }
        credentials.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        try persist()
        onChange?()
        NotificationCenter.default.post(name: .mioTermCredentialsDidChange, object: self)
        return normalized
    }

    @discardableResult
    public func delete(id: String) throws -> Bool {
        let before = credentials.count
        credentials.removeAll { $0.id == id }
        if credentials.count != before {
            try persist()
            onChange?()
            NotificationCenter.default.post(name: .mioTermCredentialsDidChange, object: self)
            return true
        }
        return false
    }

    private func persist() throws {
        let dir = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(credentials)
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: backupURL)
            try? fileManager.copyItem(at: url, to: backupURL)
        }
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func decode(
        from primary: URL,
        backup: URL,
        fileManager: FileManager,
        logger: (String) -> Void
    ) -> [CredentialProfile] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for candidate in [primary, backup] {
            guard fileManager.fileExists(atPath: candidate.path) else { continue }
            do {
                let data = try Data(contentsOf: candidate)
                return try decoder.decode([CredentialProfile].self, from: data)
            } catch {
                logger("凭据库读取失败（\(candidate.lastPathComponent)）：\(error.localizedDescription)")
            }
        }
        return []
    }
}
