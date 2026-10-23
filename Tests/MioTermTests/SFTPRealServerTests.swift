import Foundation
import Testing
@testable import MioTermCore

/// 直接驱动 macOS 自带的 OpenSSH sftp-server。
/// 内存假服务端会跟着客户端的错误假设一起自洽，只有真服务端能证明
/// 报文类型表、应答分支这些协议细节没写错。
struct SFTPRealServerTests {
    private static let serverPath = "/usr/libexec/sftp-server"

    @Test func browsesAndStatsWithOpenSSHSftpServer() async throws {
        guard FileManager.default.isExecutableFile(atPath: Self.serverPath) else {
            Issue.record("本机没有 \(Self.serverPath)，无法验证真实 SFTP 协议")
            return
        }
        let transport = SSHSubsystemTransport(
            launch: ProcessLaunch(executable: Self.serverPath, arguments: ["-e", "-l", "ERROR"], environment: ["LANG=en_US.UTF-8"])
        )
        let client = try await SFTPClient.connect(transport: transport, handshakeTimeout: 10)
        defer { transport.terminateNow() }

        // 文件面板打开时走的就是这两步：realpath 定位，opendir + readdir 列目录。
        let directory = try await client.realpath(".")
        #expect(directory.hasPrefix("/"))
        let entries = try await client.list(directory, showHidden: true)
        #expect(!entries.isEmpty)
        // 名字必须是纯文件名：把 ls -l 长名当名字，拼出来的路径全是死的。
        for entry in entries {
            #expect(entry.name == SFTPPath.lastComponent(entry.path))
            #expect(entry.name != "." && entry.name != "..")
            #expect(!entry.name.hasPrefix("drwx") && !entry.name.hasPrefix("-rw"))
        }

        // stat 成功时 OpenSSH 回 SSH_FXP_ATTRS，不是带属性的 STATUS。
        let attributes = try await client.attributes(of: directory)
        #expect(attributes.isDirectory)

        let missing = try await client.exists("\(directory)/mio-term-definitely-absent")
        #expect(missing == false)

        await client.close()
    }

    // MARK: - 真实服务端上的上传下载

    /// 上传到临时目录、列目录取条目、再下载回另一个目录。
    /// 分片、part 改名、覆盖这些只在真服务端才暴露问题：
    /// 内存假服务端会跟着客户端一起相信 v3 的 rename 能覆盖。
    @Test func transfersFilesWithOpenSSHSftpServer() async throws {
        let server = try await makeServer()
        let client = server.client
        defer { server.finish() }

        let source = try TransferHarness.makeScratchDirectory("real-src")
        let target = try TransferHarness.makeScratchDirectory("real-target")
        let back = try TransferHarness.makeScratchDirectory("real-back")
        defer { server.remove(source, target, back) }

        // 超过单帧上限，逼出 32 KiB 切帧。
        let payload = TransferHarness.payload(100_000, 251)
        let local = try TransferHarness.writeFile(payload, named: "report.bin", in: source)
        let remote = try await client.realpath(target.path)

        let coordinator = SFTPTransferCoordinator(client: client, bufferBytes: 65_536, maxConcurrent: 1, onUpdate: { _ in })
        await coordinator.enqueueUploads([local], to: remote)
        let uploaded = await TransferHarness.wait(coordinator, expecting: 1, timeout: 30)

        #expect(uploaded.first?.state == .completed)
        #expect(uploaded.first?.transferredBytes == Int64(payload.count))
        #expect(try Data(contentsOf: target.appendingPathComponent("report.bin")) == payload)
        // part 必须被改名带走，否则下次续传会接到过期尾巴上。
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("report.bin" + SFTPTransferCoordinator.partSuffix).path) == false)

        // 下载用的路径必须来自列目录报文，而不是测试自己拼的字符串。
        let listed = try await client.list(remote, showHidden: true)
        let entry = try #require(listed.first { $0.name == "report.bin" })
        #expect(entry.size == UInt64(payload.count))
        #expect(entry.isDirectory == false)

        await coordinator.clearFinished()
        await coordinator.enqueueDownloads([entry], to: back)
        let downloaded = await TransferHarness.wait(coordinator, expecting: 1, timeout: 30)

        #expect(downloaded.first?.state == .completed)
        #expect(try Data(contentsOf: back.appendingPathComponent("report.bin")) == payload)
        #expect(FileManager.default.fileExists(atPath: back.appendingPathComponent("report.bin" + SFTPTransferCoordinator.partSuffix).path) == false)

        await client.close()
    }

    @Test func reuploadReplacesTheOlderRemoteBytes() async throws {
        let server = try await makeServer()
        let client = server.client
        defer { server.finish() }

        let source = try TransferHarness.makeScratchDirectory("overwrite-src")
        let target = try TransferHarness.makeScratchDirectory("overwrite-target")
        defer { server.remove(source, target) }

        let remote = try await client.realpath(target.path)
        // 先留一个更长的旧文件：改名落地若没先删目标，尾巴会残留。
        try await client.write(TransferHarness.payload(80_000, 97), to: SFTPPath.join(remote, "notes.txt"))
        let local = try TransferHarness.writeFile(Data("new".utf8), named: "notes.txt", in: source)

        let coordinator = SFTPTransferCoordinator(client: client, bufferBytes: 65_536, maxConcurrent: 1, onUpdate: { _ in })
        await coordinator.enqueueUploads([local], to: remote)
        let uploaded = await TransferHarness.wait(coordinator, expecting: 1, timeout: 30)

        #expect(uploaded.first?.state == .completed)
        #expect(try Data(contentsOf: target.appendingPathComponent("notes.txt")) == Data("new".utf8))

        await client.close()
    }

    @Test func uploadResumesFromThePartFileOnTheRealServer() async throws {
        let server = try await makeServer()
        let client = server.client
        defer { server.finish() }

        let source = try TransferHarness.makeScratchDirectory("resume-src")
        let target = try TransferHarness.makeScratchDirectory("resume-target")
        defer { server.remove(source, target) }

        let payload = TransferHarness.payload(70_000, 197)
        let local = try TransferHarness.writeFile(payload, named: "resume.bin", in: source)
        let remote = try await client.realpath(target.path)
        let partPath = SFTPPath.join(remote, "resume.bin") + SFTPTransferCoordinator.partSuffix
        // 上次中断留下的前 30_000 字节。
        try await client.write(payload.prefix(30_000), to: partPath)

        let updates = TransferHarness.Recorder()
        let coordinator = SFTPTransferCoordinator(client: client, bufferBytes: 65_536, maxConcurrent: 1, onUpdate: updates.append)
        await coordinator.enqueueUploads([local], to: remote)
        let finished = await TransferHarness.wait(coordinator, expecting: 1, timeout: 30)

        #expect(finished.first?.state == .completed)
        // 续传从 part 的长度起步，而不是从 0 重搬。
        #expect(updates.progresses.contains { $0.state == .running && $0.transferredBytes == 30_000 })
        #expect(try Data(contentsOf: target.appendingPathComponent("resume.bin")) == payload)
        let partSurvived = try await client.exists(partPath)
        #expect(partSurvived == false)

        await client.close()
    }

    // MARK: - 辅助

    /// 一次一个 sftp-server 子进程；用例负责关掉客户端，这里的 finish 兜底杀进程。
    private func makeServer() async throws -> (client: SFTPClient, finish: @Sendable () -> Void, remove: @Sendable (URL...) -> Void) {
        guard FileManager.default.isExecutableFile(atPath: Self.serverPath) else {
            throw TestError("本机没有 \(Self.serverPath)，无法验证真实 SFTP 传输")
        }
        let transport = SSHSubsystemTransport(
            launch: ProcessLaunch(executable: Self.serverPath, arguments: ["-e", "-l", "ERROR"], environment: ["LANG=en_US.UTF-8"])
        )
        let client = try await SFTPClient.connect(transport: transport, handshakeTimeout: 10)
        return (client, { transport.terminateNow() }, { urls in
            for url in urls { try? FileManager.default.removeItem(at: url) }
        })
    }

    private struct TestError: Error, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
