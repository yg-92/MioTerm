import Foundation
import Testing

@testable import MioTermCore

/// 内存版钥匙串：记录每个条目的读取次数，用来证明旧条目只会被读一次。
private final class FakeKeychain: KeychainBackend {
    var storage: [String: String] = [:]
    var reads: [String: Int] = [:]

    private func key(_ service: String, _ account: String) -> String { "\(service)|\(account)" }

    func read(service: String, account: String) throws -> String? {
        reads[key(service, account), default: 0] += 1
        return storage[key(service, account)]
    }

    func exists(service: String, account: String) -> Bool {
        storage[key(service, account)] != nil
    }

    func write(service: String, account: String, value: String) throws {
        storage[key(service, account)] = value
    }

    func delete(service: String, account: String) throws {
        storage.removeValue(forKey: key(service, account))
    }

    func readCount(service: String = KeychainVault.service, account: String) -> Int {
        reads[key(service, account), default: 0]
    }

    func legacyKey(_ kind: KeychainVault.CredentialKind, _ hostID: String) -> String {
        "\(KeychainVault.service)|\(kind.rawValue):\(hostID)"
    }
}

@Suite("凭据保险库")
struct KeychainVaultTests {
    @Test("旧版凭据只读一次，之后都走保险库")
    func migratesLegacyOnce() throws {
        let backend = FakeKeychain()
        backend.storage[backend.legacyKey(.password, "h1")] = "s3cret"
        let vault = KeychainVault(backend: backend, logger: { _ in })

        #expect(try vault.secret(hostID: "h1", kind: .password) == "s3cret")
        #expect(try vault.secret(hostID: "h1", kind: .password) == "s3cret")
        #expect(backend.readCount(account: "password:h1") == 1)
        #expect(backend.storage["\(KeychainVault.service)|\(KeychainVault.vaultAccount)"] != nil)
    }

    @Test("重新启动后仍从保险库读取，不再碰旧条目")
    func readsVaultAcrossLaunches() throws {
        let backend = FakeKeychain()
        backend.storage[backend.legacyKey(.password, "h1")] = "s3cret"
        let first = KeychainVault(backend: backend, logger: { _ in })
        _ = try first.secret(hostID: "h1", kind: .password)

        let second = KeychainVault(backend: backend, logger: { _ in })
        #expect(try second.secret(hostID: "h1", kind: .password) == "s3cret")
        #expect(backend.readCount(account: "password:h1") == 1)
        // 每个实例只读一次保险库：终端与文件面板同时取值也不会重复访问钥匙串。
        #expect(backend.readCount(account: KeychainVault.vaultAccount) == 2)
    }

    @Test("清空密码后不会从旧条目复活")
    func clearedSecretDoesNotResurrect() throws {
        let backend = FakeKeychain()
        backend.storage[backend.legacyKey(.password, "h1")] = "s3cret"
        let vault = KeychainVault(backend: backend, logger: { _ in })
        _ = try vault.secret(hostID: "h1", kind: .password)

        try vault.setSecret(nil, hostID: "h1", kind: .password)
        #expect(try vault.secret(hostID: "h1", kind: .password) == nil)
        #expect(!vault.hasSecret(hostID: "h1", kind: .password))
        #expect(backend.readCount(account: "password:h1") == 1)

        // 应用重启后也不能复活。
        let restarted = KeychainVault(backend: backend, logger: { _ in })
        #expect(try restarted.secret(hostID: "h1", kind: .password) == nil)
    }

    @Test("一台主机的两个字段互不影响")
    func kindsAreSeparate() throws {
        let backend = FakeKeychain()
        let vault = KeychainVault(backend: backend, logger: { _ in })
        try vault.setSecret("pw", hostID: "h1", kind: .password)
        #expect(vault.hasSecret(hostID: "h1", kind: .password))
        #expect(!vault.hasSecret(hostID: "h1", kind: .passphrase))
        #expect(try vault.secret(hostID: "h1", kind: .passphrase) == nil)
        #expect(try vault.secret(hostID: "h1", kind: .password) == "pw")
    }

    @Test("同一个实例里写多次也只读一次保险库")
    func loadsVaultOnlyOnce() throws {
        let backend = FakeKeychain()
        let vault = KeychainVault(backend: backend, logger: { _ in })
        try vault.setSecret("a", hostID: "h1", kind: .password)
        try vault.setSecret("b", hostID: "h2", kind: .password)
        #expect(try vault.secret(hostID: "h1", kind: .password) == "a")
        #expect(try vault.secret(hostID: "h2", kind: .password) == "b")
        #expect(backend.readCount(account: KeychainVault.vaultAccount) == 1)
    }

    @Test("hasSecret 不读取旧条目内容，避免弹授权框")
    func hasSecretOnlyChecksAttributes() {
        let backend = FakeKeychain()
        backend.storage[backend.legacyKey(.passphrase, "h1")] = "phrase"
        let vault = KeychainVault(backend: backend, logger: { _ in })
        #expect(vault.hasSecret(hostID: "h1", kind: .passphrase))
        #expect(backend.readCount(account: "passphrase:h1") == 0)
    }

    @Test("删除主机时清掉保险库里的值与旧条目")
    func removeSecretsCleansBoth() throws {
        let backend = FakeKeychain()
        backend.storage[backend.legacyKey(.password, "h1")] = "old"
        let vault = KeychainVault(backend: backend, logger: { _ in })
        try vault.setSecret("new", hostID: "h1", kind: .password)

        vault.removeSecrets(hostID: "h1")
        #expect(try vault.secret(hostID: "h1", kind: .password) == nil)
        #expect(backend.storage[backend.legacyKey(.password, "h1")] == nil)

        let restarted = KeychainVault(backend: backend, logger: { _ in })
        #expect(try restarted.secret(hostID: "h1", kind: .password) == nil)
    }

    @Test("保险库损坏时退回旧条目并重建成可用内容")
    func corruptVaultRecoversFromLegacy() throws {
        let backend = FakeKeychain()
        backend.storage["\(KeychainVault.service)|\(KeychainVault.vaultAccount)"] = "{ 不是 JSON"
        backend.storage[backend.legacyKey(.password, "h1")] = "old"
        let vault = KeychainVault(backend: backend, logger: { _ in })

        #expect(try vault.secret(hostID: "h1", kind: .password) == "old")
        let restarted = KeychainVault(backend: backend, logger: { _ in })
        #expect(try restarted.secret(hostID: "h1", kind: .password) == "old")
        #expect(backend.readCount(account: "password:h1") == 1)
    }
}
