import Foundation

/// 凭据库条目：集中维护可复用的用户名与密码（密码正文存放在系统 Keychain 中，不落明文 JSON）。
/// 主机配置通过 `credentialID` 引用这里的条目，修改凭据后所有关联主机自动生效。
public struct CredentialProfile: Codable, Equatable, Identifiable, Sendable {
    public enum ValidationError: LocalizedError, Equatable {
        case emptyNameAndUsername

        public var errorDescription: String? {
            switch self {
            case .emptyNameAndUsername:
                return "凭据名称和用户名不能同时为空"
            }
        }
    }

    public var id: String
    public var name: String
    public var username: String
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String = "",
        username: String = "",
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.username = username
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 供 KeychainVault 使用的隔离键，避免与主机 ID 冲突。
    public var vaultKey: String {
        Self.vaultKey(for: id)
    }

    public static func vaultKey(for credentialID: String) -> String {
        "credential.\(credentialID)"
    }

    public var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { return trimmedName }
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedUser.isEmpty ? "未命名凭据" : trimmedUser
    }

    /// 下拉列表展示标题：例如「生产 root (root)」或「Administrator」。
    public var menuTitle: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty, !trimmedUser.isEmpty, trimmedName != trimmedUser {
            return "\(trimmedName) (\(trimmedUser))"
        }
        return displayName
    }

    public func normalized() -> CredentialProfile {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.updatedAt = Date()
        return copy
    }

    public func validate() throws {
        if name.isEmpty && username.isEmpty {
            throw ValidationError.emptyNameAndUsername
        }
    }
}
