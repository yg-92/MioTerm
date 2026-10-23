import Foundation

/// 连接前对服务器身份的判断，语义与 webterm 的
/// “首连确认、后续严格比对” 保持一致。
public enum HostKeyDecision: Equatable, Sendable {
    case trusted(ScannedHostKey)
    /// 首次连接：把候选公钥交给用户确认。
    case unconfirmed([ScannedHostKey])
    /// 已记录的指纹与当前不符，属于高危情况。
    case changed(storedFingerprint: String, current: ScannedHostKey)

    public var requiresUserAction: Bool {
        switch self {
        case .trusted: return false
        case .unconfirmed, .changed: return true
        }
    }
}

/// 结合主机配置里记录的指纹与应用 own known_hosts 做判断。
/// 两层记录看似重复，但 ssh 真正校验的是 known_hosts，
/// 配置文件里的指纹只用于展示与变更告警。
public struct HostKeyGuard {
    private let prober: any HostKeyScanning
    private let knownHosts: KnownHostsStore

    public init(prober: any HostKeyScanning = HostKeyProber(), knownHosts: KnownHostsStore = KnownHostsStore()) {
        self.prober = prober
        self.knownHosts = knownHosts
    }

    /// 探测失败（网络不通、端口关闭）直接抛错，由调用方与 “指纹不符” 区分处理。
    public func evaluate(host: HostProfile) async throws -> HostKeyDecision {
        let scanned = try await prober.probe(host: host.address, port: host.port, timeout: max(3, host.connectTimeout))
        return await decision(for: host, scanned: scanned)
    }

    func decision(for host: HostProfile, scanned: [ScannedHostKey]) async -> HostKeyDecision {
        let token = HostKeyProber.hostToken(host: host.address, port: host.port)
        let stored = host.hostKeyFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)

        if !stored.isEmpty, let matched = scanned.first(where: { $0.fingerprint == stored }) {
            return .trusted(matched)
        }
        // 配置里没有记录时，known_hosts 可能已有条目（手工导入，或删掉配置记录后
        // 重来）。按文件内容算指纹，命中就不必再打扰用户。
        if stored.isEmpty {
            for line in knownHosts.rawLines(matching: token) {
                if let fingerprint = try? await prober.fingerprint(keyLine: line),
                   let matched = scanned.first(where: { $0.fingerprint == fingerprint }) {
                    return .trusted(matched)
                }
            }
            return .unconfirmed(scanned)
        }

        // 走到这里说明配置里有记录，但本次探测没有任何一把公钥与之相符。
        guard let current = scanned.first else { return .unconfirmed(scanned) }
        return .changed(storedFingerprint: stored, current: current)
    }

    /// 用户确认后才写 known_hosts：先清掉同一 host:port 的旧条目，
    /// 再把本次探测到的全部算法写入，避免 ssh 协商到另一种算法时找不到记录。
    public func confirm(host: HostProfile, keys: [ScannedHostKey]) throws -> HostProfile {
        guard !keys.isEmpty else { throw HostKeyProbeError.noHostKey(host.address, host.port) }
        try knownHosts.trust(keys)
        var updated = host
        updated.hostKeyAlgorithm = keys[0].algorithm
        updated.hostKeyFingerprint = keys[0].fingerprint
        updated.updatedAt = Date()
        return updated
    }

    /// 指纹变更后的 “我确认服务器真的换密钥了”：同时清掉文件与记录，
    /// 下一次连接会重新走首连确认流程。
    public func forget(host: HostProfile) throws -> HostProfile {
        try knownHosts.revoke(token: HostKeyProber.hostToken(host: host.address, port: host.port))
        var updated = host
        updated.hostKeyAlgorithm = ""
        updated.hostKeyFingerprint = ""
        updated.updatedAt = Date()
        return updated
    }
}
