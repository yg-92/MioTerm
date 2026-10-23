import Foundation

/// OpenSSH 的 askpass 通道。ssh/sftp 运行在我们持有的 PTY 里，若让它向 tty 索要
/// 口令，密码会混进终端输出；用 SSH_ASKPASS_REQUIRE=force 强制走 askpass，
/// 机密只从一次性文件读取，路径通过环境变量传给子进程。
public enum AskpassHelper {
    public static let fileEnvironmentKey = "MIOTERM_ASKPASS_FILE"
    public static let modeArgument = "--askpass"

    public static func isAskpassInvocation(arguments: [String]) -> Bool {
        arguments.count > 1 && arguments[1] == modeArgument
    }

    /// 由 ssh 调用：打印本次连接对应的机密后立即退出，不初始化任何界面。
    public static func runAndExit(arguments: [String]) -> Never {
        let prompt = arguments.count > 2 ? arguments[2] : ""
        let path = ProcessInfo.processInfo.environment[fileEnvironmentKey] ?? ""
        var secret = ""
        if !path.isEmpty, let data = FileManager.default.contents(atPath: path),
           let text = String(data: data, encoding: .utf8) {
            secret = selectSecret(in: text, matching: prompt)
        }
        FileHandle.standardOutput.write(Data((secret + "\n").utf8))
        exit(0)
    }

    /// 会话结束后清理一次性口令文件；进程被强杀时可能没机会调用，
    /// 所以启动时清扫整个目录（包装脚本除外）。
    public static func cleanupStaleFiles(in directory: URL = AppPaths.askpassDirectory) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name != "askpass.sh" {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    public static func destroy(fileAt url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 同一会话可能先后索要连接口令与私钥口令，因此文件里按键值行存放。
    static func selectSecret(in text: String, matching prompt: String) -> String {
        var password = ""
        var passphrase = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<separator]
            guard let decoded = Data(base64Encoded: String(line[line.index(after: separator)...])),
                  let value = String(data: decoded, encoding: .utf8) else { continue }
            switch key {
            case "password": password = value
            case "passphrase": passphrase = value
            default: break
            }
        }
        let lower = prompt.lowercased()
        if lower.contains("passphrase") || lower.contains("private key") {
            return passphrase
        }
        return password
    }
}

/// 一次会话的 askpass 材料：写入 0600 临时文件，会话结束时删除。
/// base64 保证含换行的口令也不会破坏行式存储。
public struct AskpassMaterial: CustomStringConvertible, CustomDebugStringConvertible {
    public let url: URL
    private let fileManager = FileManager.default

    public init(password: String?, privateKeyPassphrase: String?) throws {
        let directory = AppPaths.askpassDirectory
        try AppPaths.ensureDirectories()
        url = directory.appendingPathComponent(UUID().uuidString)
        var lines: [String] = []
        if let password, !password.isEmpty {
            lines.append("password=\(Self.encode(password))")
        }
        if let privateKeyPassphrase, !privateKeyPassphrase.isEmpty {
            lines.append("passphrase=\(Self.encode(privateKeyPassphrase))")
        }
        let contents = lines.joined(separator: "\n") + "\n"
        try contents.data(using: .utf8)?.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func destroy() {
        try? fileManager.removeItem(at: url)
    }

    public var description: String { "AskpassMaterial(\(url.lastPathComponent))" }
    public var debugDescription: String { description }

    static func encode(_ value: String) -> String { Data(value.utf8).base64EncodedString() }
}

/// ssh 会把提示语作为第一个参数交给 SSH_ASKPASS 程序，而我们的可执行文件需要用
/// `--askpass` 区分自身角色，因此生成一个转发用的包装脚本。
public enum AskpassLauncher {
    public static var url: URL { AppPaths.askpassDirectory.appendingPathComponent("askpass.sh") }

    /// ssh 在 exec 时不解析 GUI 会话的环境，可执行文件路径必须写死在脚本里。
    public static func install(executablePath: String) throws {
        try AppPaths.ensureDirectories()
        let script = "#!/bin/sh\nexec '\(executablePath)' \(AskpassHelper.modeArgument) \"$@\"\n"
        try script.data(using: .utf8)!.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
