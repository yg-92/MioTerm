import Foundation
@testable import MioTermCore

/// 传输队列测试共用的脚手架。
///
/// 假服务端（内存）和真服务端（/usr/libexec/sftp-server）两套用例都要排队、
/// 轮询收尾、准备临时文件，逻辑一模一样，只放这一份。
enum TransferHarness {
    /// 队列任务在后台跑，轮询到全部收尾（或超时）再返回。
    static func wait(_ coordinator: SFTPTransferCoordinator, expecting count: Int, timeout: TimeInterval = 5) async -> [SFTPTransferProgress] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = await coordinator.snapshot()
            if snapshot.count == count, snapshot.allSatisfy(\.isFinished) {
                return snapshot
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await coordinator.snapshot()
    }

    /// 每个用例一个独立临时目录，调用方负责删除。
    static func makeScratchDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mioTerm-transfer-tests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func writeFile(_ contents: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    /// 有内容又不全是同一个字节，能查出分片错位。
    static func payload(_ count: Int, _ modulus: Int) -> Data {
        Data((0..<count).map { UInt8($0 % modulus) })
    }

    /// 收集回投的进度，用于断言状态机与并发。
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [SFTPTransferProgress] = []

        func append(_ progress: SFTPTransferProgress) {
            lock.withLock { storage.append(progress) }
        }

        var progresses: [SFTPTransferProgress] {
            lock.withLock { storage }
        }
    }
}
