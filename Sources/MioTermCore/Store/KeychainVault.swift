import Foundation
import Security

/// 凭据落盘位置：主机配置里只留字段是否存在，真正的口令交给系统 Keychain。
/// 相比自带主密钥文件的方案，这里不需要用户再备份一个 key 文件。
public struct KeychainVault {
    public enum CredentialKind: String, Sendable {
        case password
        case passphrase
    }

    public enum VaultError: LocalizedError, Equatable {
        case failure(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .failure(let status):
                return "Keychain 操作失败（\(SecCopyErrorMessageString(status, nil) as String? ?? "状态码 \(status)")）"
            }
        }
    }

    public static let service = "com.mio.term.credential"

    public init() {}

    private func account(hostID: String, kind: CredentialKind) -> String { "\(kind.rawValue):\(hostID)" }

    public func secret(hostID: String, kind: CredentialKind) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account(hostID: hostID, kind: kind),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        case errSecItemNotFound:
            return nil
        default:
            throw VaultError.failure(status)
        }
    }

    /// 传 nil 或空串表示清除；避免 “保存空密码” 与 “不保存密码” 混在一起。
    public func setSecret(_ value: String?, hostID: String, kind: CredentialKind) throws {
        let account = account(hostID: hostID, kind: kind)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            if status != errSecSuccess, status != errSecItemNotFound { throw VaultError.failure(status) }
            return
        }
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "MioTerm \(kind.rawValue) \(account)"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess { throw VaultError.failure(status) }
    }

    public func removeSecrets(hostID: String) {
        for kind in CredentialKind.allCases {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: account(hostID: hostID, kind: kind),
            ]
            _ = SecItemDelete(query as CFDictionary)
        }
    }
}

extension KeychainVault.CredentialKind: CaseIterable {}
