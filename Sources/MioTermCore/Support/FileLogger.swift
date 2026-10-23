import Foundation

/// 极简行日志：stderr 加一个自截断文件，方便复现问题时直接从
/// `~/Library/Application Support/MioTerm/logs` 取证。
public final class FileLogger: @unchecked Sendable {
    public static let shared = FileLogger()

    private let queue = DispatchQueue(label: "com.mio.term.log")
    private let url: URL
    private let maximumBytes: UInt64 = 5_000_000

    public init(url: URL = AppPaths.logDirectory.appendingPathComponent("mioterm.log")) {
        self.url = url
        try? AppPaths.ensureDirectories()
    }

    public func info(_ message: String) { write(level: "info", message: message) }
    public func warning(_ message: String) { write(level: "warn", message: message) }
    public func error(_ message: String) { write(level: "error", message: message) }

    private func write(level: String, message: String) {
        FileHandle.standardError.write(Data("MioTerm[\(level)]: \(message)\n".utf8))
        queue.async { [url, maximumBytes] in
            let line = "\(Self.timestamp()) [\(level)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            guard let handle = try? FileHandle(forWritingTo: url) else {
                try? data.write(to: url)
                return
            }
            defer { try? handle.close() }
            let end = (try? handle.seekToEnd()) ?? 0
            if end > maximumBytes { try? handle.truncate(atOffset: 0) }
            try? handle.write(contentsOf: data)
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}
