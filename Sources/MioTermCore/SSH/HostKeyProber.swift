import Foundation

/// 一次探测到的服务器公钥。指纹文本由 ssh-keygen 计算，不自己实现 SHA-256，
/// 保证和 `ssh -v` 里看到的指纹逐字一致，用户可以直接和官网比对。
public struct ScannedHostKey: Equatable, Sendable {
    /// known_hosts 里的名字字段：`host` 或 `[host]:port`。
    public let hostToken: String
    /// `ssh-ed25519` / `ecdsa-sha2-nistp256` / `ssh-rsa`
    public let algorithm: String
    public let publicKey: String
    /// `SHA256:...`
    public let fingerprint: String
    /// `ED25519` / `ECDSA` / `RSA`，仅用于展示。
    public let keyType: String
    public let bits: Int

    public var keyLine: String { "\(hostToken) \(algorithm) \(publicKey)" }

    public init(hostToken: String, algorithm: String, publicKey: String, fingerprint: String, keyType: String, bits: Int) {
        self.hostToken = hostToken
        self.algorithm = algorithm
        self.publicKey = publicKey
        self.fingerprint = fingerprint
        self.keyType = keyType
        self.bits = bits
    }
}

public enum HostKeyProbeError: LocalizedError, Equatable {
    case unreachable(String, Int)
    case noHostKey(String, Int)
    case fingerprintFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let host, let port): return "无法连接 \(host):\(port)，请检查地址、端口与网络"
        case .noHostKey(let host, let port): return "没有从 \(host):\(port) 取到主机公钥"
        case .fingerprintFailed(let detail): return "计算指纹失败：\(detail)"
        }
    }
}

/// 便于在测试里替换真实网络探测。
public protocol HostKeyScanning: Sendable {
    func probe(host: String, port: Int, timeout: Int) async throws -> [ScannedHostKey]
    func fingerprint(keyLine: String) async throws -> String
}

/// 用 ssh-keyscan 取公钥、用 ssh-keygen 算指纹。keyscan 只做握手，
/// 不带任何凭据，因此探测本身不会触发登录失败告警。
public final class HostKeyProber: HostKeyScanning, @unchecked Sendable {
    public static let keyscanPath = "/usr/bin/ssh-keyscan"
    public static let keygenPath = "/usr/bin/ssh-keygen"

    /// 越靠前优先级越高：展示与记录只用一条最强密钥。
    static let algorithmPriority = ["ssh-ed25519", "sk-ssh-ed25519@openssh.com", "ecdsa-sha2-nistp256", "ssh-rsa", "ssh-dss"]

    private let runner: ProcessRunner

    public init(runner: ProcessRunner = ProcessRunner()) {
        self.runner = runner
    }

    public func probe(host: String, port: Int, timeout: Int = 10) async throws -> [ScannedHostKey] {
        let token = Self.hostToken(host: host, port: port)
        let result = try await runner.run(
            executable: Self.keyscanPath,
            arguments: ["-p", "\(port)", "-T", "\(max(1, timeout))", "-t", "ed25519,ecdsa,rsa", host],
            timeout: TimeInterval(max(1, timeout)) + 5
        )
        let parsed = Self.parseKeyscanLines(result.outputText, token: token)
        if parsed.isEmpty {
            if result.succeeded { throw HostKeyProbeError.noHostKey(host, port) }
            throw HostKeyProbeError.unreachable(host, port)
        }
        var keyed: [ScannedHostKey] = []
        for key in parsed {
            let described = try await describe(key.keyLine)
            keyed.append(ScannedHostKey(
                hostToken: key.hostToken,
                algorithm: key.algorithm,
                publicKey: key.publicKey,
                fingerprint: described.fingerprint,
                keyType: described.keyType,
                bits: described.bits
            ))
        }
        return sorted(keyed)
    }

    /// known_hosts 的命名字段：只有非默认端口或含冒号的地址才加方括号。
    public static func hostToken(host: String, port: Int) -> String {
        let needsBrackets = port != 22 || host.contains(":")
        return needsBrackets ? "[\(host)]:\(port)" : host
    }

    static func parseKeyscanLines(_ text: String, token: String) -> [ScannedHostKey] {
        var keys: [ScannedHostKey] = []
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 3 else { continue }
            keys.append(ScannedHostKey(
                // 改写命名字段，避免 keyscan 按 IP 或别名输出时对不上要连接的地址。
                hostToken: token,
                algorithm: String(fields[1]),
                publicKey: String(fields[2]),
                fingerprint: "",
                keyType: "",
                bits: 0
            ))
        }
        return keys
    }

    static func parseKeygenOutput(_ text: String) -> (fingerprint: String, keyType: String, bits: Int)? {
        // 形如：`256 SHA256:AbC... user@host (ED25519)`
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2, fields[1].hasPrefix("SHA256:"), let bits = Int(fields[0]) else { return nil }
        var keyType = ""
        if let paren = line.lastIndex(of: "("), line.hasSuffix(")"), paren < line.endIndex {
            keyType = String(line[line.index(after: paren)..<line.index(before: line.endIndex)])
        }
        return (String(fields[1]), keyType, bits)
    }

    /// 用 ssh-keygen 计算任意 known_hosts 行的指纹，保证展示结果与 `ssh -v` 一致。
    public func fingerprint(keyLine: String) async throws -> String {
        let described = try await describe(keyLine)
        return described.fingerprint
    }

    private func describe(_ keyLine: String) async throws -> (fingerprint: String, keyType: String, bits: Int) {
        let result = try await runner.run(
            executable: Self.keygenPath,
            arguments: ["-lf", "-"],
            standardInput: Data((keyLine + "\n").utf8),
            timeout: 5
        )
        guard result.succeeded, let described = Self.parseKeygenOutput(result.outputText) else {
            throw HostKeyProbeError.fingerprintFailed(result.errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return described
    }

    func sorted(_ keys: [ScannedHostKey]) -> [ScannedHostKey] {
        keys.sorted { left, right in
            let l = Self.algorithmPriority.firstIndex(of: left.algorithm) ?? Self.algorithmPriority.count
            let r = Self.algorithmPriority.firstIndex(of: right.algorithm) ?? Self.algorithmPriority.count
            return l != r ? l < r : left.algorithm < right.algorithm
        }
    }
}

extension Array where Element == ScannedHostKey {
    /// 展示与记录用的首选密钥。
    public var preferred: ScannedHostKey? { first }
}
