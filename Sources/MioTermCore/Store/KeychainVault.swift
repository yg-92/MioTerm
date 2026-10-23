import Foundation
import Security

/// 钥匙串读写的最小接口。真实实现走 Security，测试里换成内存实现，
/// 这样迁移与缓存逻辑不必真的去碰登录钥匙串。
protocol KeychainBackend {
    func read(service: String, account: String) throws -> String?
    func exists(service: String, account: String) -> Bool
    func write(service: String, account: String, value: String) throws
    func delete(service: String, account: String) throws
}

/// 每条凭据一个通用密码条目。创建者（当前签名身份）默认被信任，
/// 所以签名稳定时读取不会再弹授权框。
struct SystemKeychainBackend: KeychainBackend {
    func read(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
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
            throw KeychainVault.VaultError.failure(status)
        }
    }

    /// 只问“有没有保存过”，不取内容。查属性不会触发钥匙串授权弹窗。
    func exists(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    func write(service: String, account: String, value: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "MioTerm \(account)"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess { throw KeychainVault.VaultError.failure(status) }
    }

    func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            throw KeychainVault.VaultError.failure(status)
        }
    }
}

/// 凭据落盘位置：主机配置里只留字段是否存在，真正的口令交给系统 Keychain。
///
/// 早期版本每个主机每个字段各存一条，条目 ACL 绑定当时那次 ad-hoc 签名的 cdhash，
/// 一旦重新打包，每次读取都会要求输入登录钥匙串密码。现在所有凭据收进一条
/// “保险库”条目：签名稳定后由本应用创建，之后读写都不再弹框；首次遇到旧条目时
/// 读一次就迁进保险库，此后不再触碰旧条目。进程内再缓存一份，终端与文件面板
/// 同时取凭据也只读一次钥匙串。
public final class KeychainVault {
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
    /// 保险库条目自己的账号名；旧版条目是 `password:<主机 ID>` 这类形式，不会撞上。
    static let vaultAccount = "vault"

    /// 一条条目容纳全部凭据。旧版条目迁进来之后只写这一条，ACL 也只有这一份。
    struct Payload: Codable {
        var values: [String: String] = [:]
        /// 已经问过旧条目的账号。清空凭据也留在这里，避免下次又从旧条目把口令读回来。
        var legacyChecked: Set<String> = []

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            values = try container.decodeIfPresent([String: String].self, forKey: .values) ?? [:]
            legacyChecked = try container.decodeIfPresent(Set<String>.self, forKey: .legacyChecked) ?? []
        }
    }

    private let backend: any KeychainBackend
    private let logger: (String) -> Void
    private let lock = NSLock()
    private var payload: Payload?

    public convenience init() {
        self.init(backend: SystemKeychainBackend(), logger: { FileLogger.shared.info($0) })
    }

    init(backend: any KeychainBackend, logger: @escaping (String) -> Void = { _ in }) {
        self.backend = backend
        self.logger = logger
    }

    private func account(hostID: String, kind: CredentialKind) -> String { "\(kind.rawValue):\(hostID)" }

    public func secret(hostID: String, kind: CredentialKind) throws -> String? {
        let key = account(hostID: hostID, kind: kind)
        lock.lock()
        defer { lock.unlock() }
        var current = loadPayload()
        guard !current.legacyChecked.contains(key) else { return current.values[key] }

        // 旧条目可能弹一次授权框；只在真的存在时迁移，之后一直走保险库。
        let legacy = try backend.read(service: Self.service, account: key)
        current.legacyChecked.insert(key)
        guard let legacy, !legacy.isEmpty else {
            self.payload = current
            return nil
        }
        current.values[key] = legacy
        do {
            try persist(current)
        } catch {
            // 迁移写失败不该挡住这次连接：值已经拿到，旧条目也还在。
            self.payload = current
            logger("凭据迁移失败：\(error.localizedDescription)")
        }
        return legacy
    }

    public func hasSecret(hostID: String, kind: CredentialKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = account(hostID: hostID, kind: kind)
        let current = loadPayload()
        if current.values[key]?.isEmpty == false { return true }
        if current.legacyChecked.contains(key) { return false }
        // 只查属性，不读内容，因此不会弹授权框。
        return backend.exists(service: Self.service, account: key)
    }

    /// 传 nil 或空串表示清除；避免 “保存空密码” 与 “不保存密码” 混在一起。
    public func setSecret(_ value: String?, hostID: String, kind: CredentialKind) throws {
        let key = account(hostID: hostID, kind: kind)
        lock.lock()
        defer { lock.unlock() }
        var current = loadPayload()
        // 写过的账号不再回退旧条目：否则清空密码后又会被旧口令复活。
        current.legacyChecked.insert(key)
        if let value, !value.isEmpty {
            current.values[key] = value
        } else {
            current.values.removeValue(forKey: key)
        }
        try persist(current)
    }

    public func removeSecrets(hostID: String) {
        lock.lock()
        defer { lock.unlock() }
        var current = loadPayload()
        for kind in CredentialKind.allCases {
            let key = account(hostID: hostID, kind: kind)
            current.values.removeValue(forKey: key)
            current.legacyChecked.insert(key)
            // 旧条目属于已经废弃的存储方式，删掉才算真正清除；删不动就留给系统。
            try? backend.delete(service: Self.service, account: key)
        }
        try? persist(current)
    }

    // MARK: - 保险库读写

    /// 读一次保险库后一直用内存副本：同一次启动里终端与文件面板各取一次，
    /// 也只会有一次钥匙串访问。
    private func loadPayload() -> Payload {
        if let payload { return payload }
        let text: String?
        do {
            text = try backend.read(service: Self.service, account: Self.vaultAccount)
        } catch {
            logger("读取凭据保险库失败：\(error.localizedDescription)")
            text = nil
        }
        guard let text, let decoded = try? JSONDecoder().decode(Payload.self, from: Data(text.utf8)) else {
            if text != nil { logger("凭据保险库内容无法解析，按空库处理") }
            let empty = Payload()
            payload = empty
            return empty
        }
        payload = decoded
        return decoded
    }

    private func persist(_ next: Payload) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(next)
        guard let text = String(data: data, encoding: .utf8) else { throw VaultError.failure(errSecParam) }
        try backend.write(service: Self.service, account: Self.vaultAccount, value: text)
        payload = next
    }
}

extension KeychainVault.CredentialKind: CaseIterable {}
