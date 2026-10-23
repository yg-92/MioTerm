import Testing
import Foundation
@testable import MioTermCore

struct HostKeyProberTests {
    @Test func hostTokenOnlyBracketsWhenNeeded() {
        #expect(HostKeyProber.hostToken(host: "example.com", port: 22) == "example.com")
        #expect(HostKeyProber.hostToken(host: "example.com", port: 2222) == "[example.com]:2222")
        #expect(HostKeyProber.hostToken(host: "::1", port: 22) == "[::1]:22")
    }

    @Test func parsesKeyscanOutputAndRewritesNames() {
        let text = """
        # github.com:22 SSH-2.0-6615c807
        github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
        # github.com:22 SSH-2.0-6615c807
        # 140.82.112.10 ssh-ed25519
        github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDx

        """
        let keys = HostKeyProber.parseKeyscanLines(text, token: "[github.com]:2222")
        #expect(keys.count == 2)
        // 名字字段统一改写成要连接的地址，避免 keyscan 按 IP 或别名输出时对不上。
        #expect(Set(keys.map(\.hostToken)) == ["[github.com]:2222"])
        #expect(keys.map(\.algorithm) == ["ssh-ed25519", "ssh-rsa"])
        #expect(keys[0].keyLine.hasPrefix("[github.com]:2222 ssh-ed25519 AAAAC3"))
    }

    @Test func ignoresMalformedKeyscanLines() {
        let text = """
        # host:22 SSH-2.0-libssh
        garbage line
        host ssh-ed25519
        """
        #expect(HostKeyProber.parseKeyscanLines(text, token: "host").isEmpty)
    }

    @Test func parsesKeygenFingerprintLine() {
        let parsed = HostKeyProber.parseKeygenOutput("256 SHA256:nThbg6kXZ example@git (ED25519)\n")
        #expect(parsed?.fingerprint == "SHA256:nThbg6kXZ")
        #expect(parsed?.keyType == "ED25519")
        #expect(parsed?.bits == 256)
        #expect(HostKeyProber.parseKeygenOutput("couldn't open /dev/stdin") == nil)
    }

    @Test func prefersStrongestAlgorithm() {
        let prober = HostKeyProber()
        let keys = [
            ScannedHostKey(hostToken: "h", algorithm: "ssh-rsa", publicKey: "a", fingerprint: "f1", keyType: "RSA", bits: 3072),
            ScannedHostKey(hostToken: "h", algorithm: "ecdsa-sha2-nistp256", publicKey: "b", fingerprint: "f2", keyType: "ECDSA", bits: 256),
            ScannedHostKey(hostToken: "h", algorithm: "ssh-ed25519", publicKey: "c", fingerprint: "f3", keyType: "ED25519", bits: 256),
        ]
        #expect(prober.sorted(keys).map(\.algorithm) == ["ssh-ed25519", "ecdsa-sha2-nistp256", "ssh-rsa"])
        #expect(prober.sorted(keys).preferred?.algorithm == "ssh-ed25519")
    }
}

/// 只喂固定结果的探测替身，让裁决逻辑可以离线测试。
private struct StubProber: HostKeyScanning {
    let keys: [ScannedHostKey]
    let fingerprints: [String: String]

    func probe(host: String, port: Int, timeout: Int) async throws -> [ScannedHostKey] { keys }
    func fingerprint(keyLine: String) async throws -> String {
        if let value = fingerprints[keyLine] { return value }
        throw HostKeyProbeError.fingerprintFailed("no stub for \(keyLine)")
    }
}

struct HostKeyGuardTests {
    private func makeHost(fingerprint: String = "", algorithm: String = "") -> HostProfile {
        var host = HostProfile(name: "h", address: "h.example", username: "u")
        host.port = 22
        host.hostKeyFingerprint = fingerprint
        host.hostKeyAlgorithm = algorithm
        return host
    }

    private let ed25519 = ScannedHostKey(
        hostToken: "h.example",
        algorithm: "ssh-ed25519",
        publicKey: "AAAAed",
        fingerprint: "SHA256:ED",
        keyType: "ED25519",
        bits: 256
    )
    private let rsa = ScannedHostKey(
        hostToken: "h.example",
        algorithm: "ssh-rsa",
        publicKey: "AAAARSA",
        fingerprint: "SHA256:RSA",
        keyType: "RSA",
        bits: 3072
    )

    private func temporaryKnownHosts() -> (store: KnownHostsStore, url: URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("known_hosts-\(UUID().uuidString)")
        return (KnownHostsStore(url: url), url)
    }

    @Test func firstContactAsksForConfirmation() async throws {
        let (store, url) = temporaryKnownHosts()
        let guard0 = HostKeyGuard(prober: StubProber(keys: [ed25519, rsa], fingerprints: [:]), knownHosts: store)
        let decision = try await guard0.evaluate(host: makeHost())
        if case .unconfirmed(let keys) = decision {
            #expect(keys.count == 2)
        } else {
            Issue.record("首连应当要求确认，实际得到 \(decision)")
        }
        try? FileManager.default.removeItem(at: url)
    }

    @Test func matchingFingerprintIsTrusted() async throws {
        let (store, url) = temporaryKnownHosts()
        let guard0 = HostKeyGuard(prober: StubProber(keys: [ed25519, rsa], fingerprints: [:]), knownHosts: store)
        let decision = try await guard0.evaluate(host: makeHost(fingerprint: "SHA256:RSA", algorithm: "ssh-rsa"))
        #expect(decision == .trusted(rsa))
        try? FileManager.default.removeItem(at: url)
    }

    @Test func changedKeyIsReportedAsDanger() async throws {
        let (store, url) = temporaryKnownHosts()
        let guard0 = HostKeyGuard(prober: StubProber(keys: [ed25519, rsa], fingerprints: [:]), knownHosts: store)
        let decision = try await guard0.evaluate(host: makeHost(fingerprint: "SHA256:OLD", algorithm: "ssh-ed25519"))
        #expect(decision == .changed(storedFingerprint: "SHA256:OLD", current: ed25519))
        try? FileManager.default.removeItem(at: url)
    }

    @Test func knownHostsEntryWithoutProfileRecordStillTrusted() async throws {
        let (store, url) = temporaryKnownHosts()
        try "h.example ssh-ed25519 AAAAed\n".data(using: .utf8)!.write(to: url)
        let guard0 = HostKeyGuard(
            prober: StubProber(keys: [ed25519], fingerprints: ["h.example ssh-ed25519 AAAAed": "SHA256:ED"]),
            knownHosts: store
        )
        let decision = try await guard0.evaluate(host: makeHost())
        #expect(decision == .trusted(ed25519))
        try? FileManager.default.removeItem(at: url)
    }

    @Test func confirmationWritesEveryAlgorithmThenRecordsPreferred() async throws {
        let (store, url) = temporaryKnownHosts()
        let guard0 = HostKeyGuard(prober: StubProber(keys: [ed25519, rsa], fingerprints: [:]), knownHosts: store)
        let updated = try guard0.confirm(host: makeHost(), keys: [ed25519, rsa])
        #expect(updated.hostKeyFingerprint == "SHA256:ED")
        #expect(updated.hostKeyAlgorithm == "ssh-ed25519")
        #expect(store.rawLines(matching: "h.example").count == 2)

        // 再次确认要整体替换，不能把旧密钥留在文件里。
        let changed = ScannedHostKey(hostToken: "h.example", algorithm: "ssh-ed25519", publicKey: "AAAAnew", fingerprint: "SHA256:NEW", keyType: "ED25519", bits: 256)
        _ = try guard0.confirm(host: updated, keys: [changed])
        #expect(store.rawLines(matching: "h.example") == ["h.example ssh-ed25519 AAAAnew"])

        let forgotten = try guard0.forget(host: updated)
        #expect(forgotten.hostKeyFingerprint.isEmpty)
        #expect(store.rawLines(matching: "h.example").isEmpty)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func probeErrorIsThrownToCaller() async {
        struct Boom: HostKeyScanning {
            func probe(host: String, port: Int, timeout: Int) async throws -> [ScannedHostKey] {
                throw HostKeyProbeError.unreachable(host, port)
            }
            func fingerprint(keyLine: String) async throws -> String { "" }
        }
        let guard0 = HostKeyGuard(prober: Boom(), knownHosts: temporaryKnownHosts().store)
        await #expect(throws: HostKeyProbeError.unreachable("h.example", 22)) {
            try await guard0.evaluate(host: makeHost())
        }
    }
}
