import Foundation
import Testing
@testable import MioTermCore

/// 上传下载队列的行为验证：分片落地、续传起点、失败状态与并发上限。
/// 全程走 FakeSFTPServer，不需要真实主机。
struct SFTPTransferTests {
    private static let remoteDirectory = "/home/user"

    @Test func uploadSlicesIntoFramesAndLandsOnTheFinalName() async throws {
        let directory = try makeScratchDirectory("upload")
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = FakeSFTPServer()
        let client = try await SFTPClient.connect(transport: server)
        let payload = Data((0..<100_000).map { UInt8($0 % 251) })
        let local = try writeFile(payload, named: "report.bin", in: directory)
        let updates = Recorder()
        let coordinator = SFTPTransferCoordinator(client: client, bufferBytes: 65_536, maxConcurrent: 2, onUpdate: updates.append)

        await coordinator.enqueueUploads([local], to: Self.remoteDirectory)
        let finished = await wait(coordinator, expecting: 1)

        #expect(finished.first?.state == .completed)
        #expect(finished.first?.transferredBytes == Int64(payload.count))
        #expect(server.contents(of: "/home/user/report.bin") == payload)
        // 半成品必须在改名后消失，否则下次续传会接到一个过期尾巴上。
        #expect(server.node(at: "/home/user/report.bin" + SFTPTransferCoordinator.partSuffix) == nil)
        let sizes = server.writeRequestSizes()
        #expect(!sizes.isEmpty)
        #expect(sizes.allSatisfy { $0 <= SFTPClient.maximumChunkSize })
        await client.close()
    }

    @Test func uploadReplacesAnExistingRemoteFile() async throws {
        let directory = try makeScratchDirectory("overwrite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = FakeSFTPServer()
        let client = try await SFTPClient.connect(transport: server)
        try await client.write(Data("old content that is longer".utf8), to: "/home/user/hello.txt")
        let local = try writeFile(Data("new".utf8), named: "hello.txt", in: directory)
        let coordinator = SFTPTransferCoordinator(client: client, bufferBytes: 65_536, maxConcurrent: 1, onUpdate: { _ in })

        await coordinator.enqueueUploads([local], to: Self.remoteDirectory)
        let finished = await wait(coordinator, expecting: 1)

        #expect(finished.first?.state == .completed)
        #expect(server.contents(of: "/home/user/hello.txt") == Data("new".utf8))
        await client.close()
    }

    @Test func uploadResumesFromTheRemotePartFile() async throws {
        let directory = try makeScratchDirectory("resume")
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = FakeSFTPServer()
        let client = try await SFTPClient.connect(transport: server)
        let payload = Data((0..<5_000).map { UInt8($0 % 197) })
        let local = try writeFile(payload, named: "resume.bin", in: directory)
        // 上次中断留下的前 1_000 字节。
        try await client.write(payload.prefix(1_000), to: "/home/user/resume.bin" + SFTPTransferCoordinator.partSuffix)
        let seededFrames = server.writeRequestSizes().count
        let coordinator = SFTPTransferCoordinator(client: client, bufferBytes: 65_536, maxConcurrent: 1, onUpdate: { _ in })

        await coordinator.enqueueUploads([local], to: Self.remoteDirectory)
        let finished = await wait(coordinator, expecting: 1)

        #expect(finished.first?.state == .completed)
        #expect(server.contents(of: "/home/user/resume.bin") == payload)
        // 续传只补剩下的字节，不该把已存在的前缀重发一遍。
        #expect(server.writeRequestSizes().dropFirst(seededFrames).reduce(0, +) == payload.count - 1_000)
        await client.close()
    }

    @Test func downloadWritesTheLocalFileAndLeavesNoPartBehind() async throws {
        let directory = try makeScratchDirectory("download")
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = FakeSFTPServer()
        let client = try await SFTPClient.connect(transport: server)
        let coordinator = SFTPTransferCoordinator(client: client, bufferBytes: 65_536, maxConcurrent: 1, onUpdate: { _ in })
        let entry = SFTPFileEntry(path: "/home/user/sub/nested.bin", name: "nested.bin", isDirectory: false, size: 5_000, modifiedAt: nil)

        await coordinator.enqueueDownloads([entry], to: directory)
        let finished = await wait(coordinator, expecting: 1)

        #expect(finished.first?.state == .completed)
        let written = try Data(contentsOf: directory.appendingPathComponent("nested.bin"))
        #expect(written == Data(repeating: 0xAB, count: 5_000))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("nested.bin" + SFTPTransferCoordinator.partSuffix).path))
        await client.close()
    }

    @Test func downloadFromMissingPathFailsWithTheServerMessage() async throws {
        let directory = try makeScratchDirectory("missing")
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = FakeSFTPServer()
        let client = try await SFTPClient.connect(transport: server)
        let updates = Recorder()
        let coordinator = SFTPTransferCoordinator(client: client, bufferBytes: 65_536, maxConcurrent: 1, onUpdate: updates.append)
        let entry = SFTPFileEntry(path: "/home/user/nope.bin", name: "nope.bin", isDirectory: false, size: 0, modifiedAt: nil)

        await coordinator.enqueueDownloads([entry], to: directory)
        let finished = await wait(coordinator, expecting: 1)

        if case .failed(let message) = finished.first?.state {
            #expect(message.contains("不存在"))
        } else {
            Issue.record("远端缺文件应当以失败状态收尾，实际是 \(String(describing: finished.first?.state))")
        }
        // 失败不会留下看起来完整的半截文件。
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("nope.bin").path))
        #expect(await coordinator.hasActiveTransfers == false)
        await client.close()
    }

    @Test func cancelRemovesTheJobFromTheQueue() async throws {
        let directory = try makeScratchDirectory("cancel")
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = FakeSFTPServer()
        let client = try await SFTPClient.connect(transport: server)
        let local = try writeFile(Data(repeating: 7, count: 4_096), named: "gone.bin", in: directory)
        let updates = Recorder()
        let coordinator = SFTPTransferCoordinator(client: client, bufferBytes: 65_536, maxConcurrent: 1, onUpdate: updates.append)

        await coordinator.enqueueUploads([local], to: Self.remoteDirectory)
        let id = try #require(updates.progresses.first?.id)
        await coordinator.cancel(id)

        #expect(await coordinator.snapshot().isEmpty)
        #expect(updates.progresses.filter { $0.id == id }.map(\.state).last == .cancelled)
        await client.close()
    }

    @Test func queueRunsEveryJobUnderTheConcurrencyLimit() async throws {
        let directory = try makeScratchDirectory("serial")
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = FakeSFTPServer()
        let client = try await SFTPClient.connect(transport: server)
        let updates = Recorder()
        let coordinator = SFTPTransferCoordinator(client: client, bufferBytes: 32_768, maxConcurrent: 1, onUpdate: updates.append)
        var files: [URL] = []
        for index in 0..<3 {
            files.append(try writeFile(Data(repeating: UInt8(index), count: 2_048), named: "part\(index).txt", in: directory))
        }

        await coordinator.enqueueUploads(files, to: Self.remoteDirectory)
        let finished = await wait(coordinator, expecting: 3)

        #expect(finished.count == 3)
        #expect(finished.allSatisfy { $0.state == .completed })
        for index in 0..<3 {
            #expect(server.contents(of: "/home/user/part\(index).txt") == Data(repeating: UInt8(index), count: 2_048))
        }
        // 单并发时，任何时刻最多只能有一个任务处于 running。
        var peak = 0
        var active: Set<UUID> = []
        for progress in updates.progresses {
            if progress.state == .running {
                active.insert(progress.id)
                peak = max(peak, active.count)
            } else if progress.isFinished {
                active.remove(progress.id)
            }
        }
        #expect(peak == 1)
        await client.close()
    }

    @Test func clearFinishedEmptiesTheQueueOnceJobsClose() async throws {
        let directory = try makeScratchDirectory("clear")
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = FakeSFTPServer()
        let client = try await SFTPClient.connect(transport: server)
        let local = try writeFile(Data("done".utf8), named: "done.txt", in: directory)
        let coordinator = SFTPTransferCoordinator(client: client, bufferBytes: 65_536, maxConcurrent: 1, onUpdate: { _ in })

        await coordinator.enqueueUploads([local], to: Self.remoteDirectory)
        _ = await wait(coordinator, expecting: 1)
        await coordinator.clearFinished()

        #expect(await coordinator.snapshot().isEmpty)
        await client.close()
    }

    @Test func dismissDropsAFinishedRecordButKeepsTheRemoteFile() async throws {
        let directory = try makeScratchDirectory("dismiss")
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = FakeSFTPServer()
        let client = try await SFTPClient.connect(transport: server)
        let local = try writeFile(Data("done".utf8), named: "done.txt", in: directory)
        let coordinator = SFTPTransferCoordinator(client: client, bufferBytes: 65_536, maxConcurrent: 1, onUpdate: { _ in })

        await coordinator.enqueueUploads([local], to: Self.remoteDirectory)
        let finished = await wait(coordinator, expecting: 1)
        let id = try #require(finished.first?.id)
        await coordinator.dismiss(id)

        #expect(await coordinator.snapshot().isEmpty)
        // 移除的只是列表记录，已落地的文件不受影响。
        #expect(server.contents(of: "/home/user/done.txt") == Data("done".utf8))
        await client.close()
    }

    // MARK: - 辅助

    private func wait(_ coordinator: SFTPTransferCoordinator, expecting count: Int, timeout: TimeInterval = 5) async -> [SFTPTransferProgress] {
        await TransferHarness.wait(coordinator, expecting: count, timeout: timeout)
    }

    private func makeScratchDirectory(_ name: String) throws -> URL {
        try TransferHarness.makeScratchDirectory(name)
    }

    private func writeFile(_ contents: Data, named name: String, in directory: URL) throws -> URL {
        try TransferHarness.writeFile(contents, named: name, in: directory)
    }

    private typealias Recorder = TransferHarness.Recorder
}
