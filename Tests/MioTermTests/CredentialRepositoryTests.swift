import Foundation
import Testing
@testable import MioTermCore

@Suite("凭据库")
@MainActor
struct CredentialRepositoryTests {
    @Test("保存、重载、搜索与删除凭据，且不落明文密码")
    func saveReloadFilterAndDelete() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MioTermCredTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("credentials.json")
        let repo = CredentialRepository(url: file)
        let saved = try repo.save(CredentialProfile(name: "生产 root", username: "root", notes: "核心集群"))
        #expect(saved.menuTitle == "生产 root (root)")
        #expect(saved.vaultKey == "credential.\(saved.id)")
        #expect(repo.credentials.count == 1)

        let reloaded = CredentialRepository(url: file)
        reloaded.load()
        #expect(reloaded.credentials.count == 1)
        #expect(reloaded.credential(id: saved.id)?.username == "root")
        #expect(reloaded.filter("集群").count == 1)
        #expect(reloaded.filter("不存在").isEmpty)

        #expect(try reloaded.delete(id: saved.id) == true)
        #expect(reloaded.credentials.isEmpty)
    }

    @Test("名称与用户名同时为空时拒绝保存")
    func rejectsEmptyCredential() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MioTermCredTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = CredentialRepository(url: dir.appendingPathComponent("credentials.json"))
        #expect(throws: CredentialProfile.ValidationError.emptyNameAndUsername) {
            try repo.save(CredentialProfile(name: "   ", username: ""))
        }
    }

    @Test("HostProfile 兼容 credentialID 编码与旧 JSON 缺失字段")
    func hostProfileCredentialIDCompatibility() throws {
        let host = HostProfile(name: "Win228", protocolKind: .rdp, address: "192.168.30.228", port: 3389, username: "Administrator", credentialID: "cred-123")
        let data = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(HostProfile.self, from: data)
        #expect(decoded.credentialID == "cred-123")
        #expect(decoded.rdpAudioEnabled == false)
    }
}
