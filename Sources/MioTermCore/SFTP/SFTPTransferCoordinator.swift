import Foundation

public enum SFTPTransferKind: String, Sendable {
    case upload
    case download

    public var displayName: String { self == .upload ? L10n.tr(.sftpTransferUpload) : L10n.tr(.sftpTransferDownload) }
}

public enum SFTPTransferState: Equatable, Sendable {
    case queued
    case running
    case paused
    case cancelled
    case completed
    case failed(String)

    public var displayName: String {
        switch self {
        case .queued: return L10n.tr(.sftpTransferQueued)
        case .running: return L10n.tr(.sftpTransferRunning)
        case .paused: return L10n.tr(.sftpTransferPaused)
        case .cancelled: return L10n.tr(.sftpTransferCancelled)
        case .completed: return L10n.tr(.sftpTransferCompleted)
        case .failed: return L10n.tr(.sftpTransferFailed)
        }
    }
}

/// 传输队列一行。UI 只认这个值类型，队列内部状态不外泄。
public struct SFTPTransferProgress: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let kind: SFTPTransferKind
    public let totalBytes: Int64
    public let transferredBytes: Int64
    public let state: SFTPTransferState

    public init(id: UUID, name: String, kind: SFTPTransferKind, totalBytes: Int64, transferredBytes: Int64, state: SFTPTransferState) {
        self.id = id
        self.name = name
        self.kind = kind
        self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes
        self.state = state
    }

    public var fraction: Double {
        guard totalBytes > 0 else { return state == .completed ? 1 : 0 }
        return min(1, Double(transferredBytes) / Double(totalBytes))
    }

    public var isFinished: Bool {
        switch state {
        case .completed, .failed, .cancelled: return true
        case .queued, .running, .paused: return false
        }
    }

    public var detailText: String {
        let moved = L10n.formatByteCount(transferredBytes)
        if totalBytes > 0 {
            return "\(moved) / \(L10n.formatByteCount(totalBytes))"
        }
        return moved
    }
}

/// 上传下载队列：分片、暂停续传、并发上限都收在这里。
///
/// 分两层切片：本地一次搬运 `bufferBytes`（控制内存占用），
/// 每个 SSH_FXP_WRITE 再按协议上限 32 KiB 切帧（服务端会拒绝超长帧）。
/// 传输一律先写 `<目标名>.mioterm-part`，成功后改名落地：
/// 中断不会留下一个看起来完整、其实半截的文件。
public actor SFTPTransferCoordinator {
    public static let partSuffix = ".mioterm-part"

    private let client: SFTPClient
    private let reportStrideBytes: Int
    private let maxConcurrent: Int

    private var jobs: [UUID: Job] = [:]
    private var order: [UUID] = []
    private var states: [UUID: SFTPTransferState] = [:]
    private var transferred: [UUID: Int64] = [:]
    private var lastReported: [UUID: Int64] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// 队列变化通过这里回投 UI；调用方保证切回主线程。
    private let onUpdate: @Sendable (SFTPTransferProgress) -> Void

    private enum Job {
        case upload(id: UUID, name: String, localURL: URL, remoteDirectory: String, size: Int64)
        case download(id: UUID, name: String, remotePath: String, localURL: URL, size: Int64)

        var id: UUID {
            switch self {
            case .upload(let id, _, _, _, _), .download(let id, _, _, _, _): return id
            }
        }

        var name: String {
            switch self {
            case .upload(_, let name, _, _, _), .download(_, let name, _, _, _): return name
            }
        }

        var size: Int64 {
            switch self {
            case .upload(_, _, _, _, let size), .download(_, _, _, _, let size): return size
            }
        }

        var kind: SFTPTransferKind {
            switch self {
            case .upload: return .upload
            case .download: return .download
            }
        }
    }

    public init(client: SFTPClient, bufferBytes: Int, maxConcurrent: Int, onUpdate: @escaping @Sendable (SFTPTransferProgress) -> Void) {
        self.client = client
        // 缓冲块至少一帧，最多 4 MiB，避免把大文件整份读进内存。
        self.reportStrideBytes = max(SFTPClient.maximumChunkSize, min(bufferBytes, 4 * 1024 * 1024))
        self.maxConcurrent = max(1, maxConcurrent)
        self.onUpdate = onUpdate
    }

    // MARK: - 入队

    public func enqueueUploads(_ files: [URL], to remoteDirectory: String) {
        for url in files {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            guard values?.isDirectory != true else { continue }
            let size = Int64(values?.fileSize ?? 0)
            let job = Job.upload(id: UUID(), name: url.lastPathComponent, localURL: url, remoteDirectory: remoteDirectory, size: size)
            enqueue(job)
        }
    }

    public func enqueueDownloads(_ entries: [SFTPFileEntry], to localDirectory: URL) {
        for entry in entries where !entry.isDirectory {
            let job = Job.download(
                id: UUID(),
                name: entry.name,
                remotePath: entry.path,
                localURL: localDirectory.appendingPathComponent(entry.name),
                size: Int64(entry.size)
            )
            enqueue(job)
        }
    }

    private func enqueue(_ job: Job) {
        jobs[job.id] = job
        order.append(job.id)
        states[job.id] = .queued
        transferred[job.id] = 0
        publish(job.id, force: true)
        startEligible()
    }

    // MARK: - 控制

    public func pause(_ id: UUID) {
        guard jobs[id] != nil, let state = states[id], !isTerminal(state) else { return }
        // 先取消任务再改状态：任务退出时会保留 part 文件，续传从它的长度接着走。
        tasks[id]?.cancel()
        tasks[id] = nil
        states[id] = .paused
        publish(id, force: true)
    }

    public func resume(_ id: UUID) {
        guard jobs[id] != nil, states[id] == .paused else { return }
        states[id] = .queued
        publish(id, force: true)
        startEligible()
    }

    public func cancel(_ id: UUID) {
        guard let job = jobs[id] else { return }
        tasks[id]?.cancel()
        tasks[id] = nil
        states[id] = .cancelled
        publish(id, force: true)
        remove(id)
        // 取消意味着这份残缺数据不要了。
        Task { await self.discardPart(of: job) }
    }

    /// 清掉已完成/失败/取消的条目，队列面板上的“清空”按钮。
    public func clearFinished() {
        for id in order where isTerminal(states[id] ?? .queued) {
            remove(id)
        }
    }

    /// 抹掉一条已结束的记录。只动列表，不碰远端文件和续传用的 part 文件；
    /// 仍在排队或传输中的条目不接受这个操作，免得任务被丢了却没人停。
    public func dismiss(_ id: UUID) {
        guard let state = states[id], isTerminal(state) else { return }
        remove(id)
    }

    /// 会话关闭时一次性停掉所有在飞任务。
    public func cancelAll() {
        for id in order {
            cancel(id)
        }
    }

    public func snapshot() -> [SFTPTransferProgress] {
        order.compactMap { progress(for: $0) }
    }

    public var hasActiveTransfers: Bool {
        !tasks.isEmpty
    }

    private func remove(_ id: UUID) {
        jobs.removeValue(forKey: id)
        states.removeValue(forKey: id)
        transferred.removeValue(forKey: id)
        lastReported.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }

    private func isTerminal(_ state: SFTPTransferState) -> Bool {
        switch state {
        case .completed, .failed, .cancelled: return true
        case .queued, .running, .paused: return false
        }
    }

    private func startEligible() {
        guard tasks.count < maxConcurrent else { return }
        for id in order {
            guard tasks.count < maxConcurrent, states[id] == .queued, let job = jobs[id] else { continue }
            tasks[id] = Task { await self.run(job) }
        }
    }

    // MARK: - 执行

    private func run(_ job: Job) async {
        states[job.id] = .running
        publish(job.id, force: true)
        do {
            switch job {
            case .upload(_, _, let localURL, let remoteDirectory, let size):
                try await upload(localURL: localURL, to: remoteDirectory, size: size, id: job.id)
            case .download(_, _, let remotePath, let localURL, let size):
                try await download(remotePath: remotePath, to: localURL, size: size, id: job.id)
            }
            if Task.isCancelled { return }
            states[job.id] = .completed
            publish(job.id, force: true)
        } catch is CancellationError {
            // pause 与 cancel 都会走到这里；状态由控制方法决定，这里只负责停手。
        } catch {
            states[job.id] = .failed(error.localizedDescription)
            publish(job.id, force: true)
        }
        tasks[job.id] = nil
        startEligible()
    }

    private func upload(localURL: URL, to remoteDirectory: String, size: Int64, id: UUID) async throws {
        let finalPath = SFTPPath.join(remoteDirectory, localURL.lastPathComponent)
        let partPath = finalPath + Self.partSuffix

        var offset = try await resumedOffset(of: partPath, cap: size)
        let handle = try await client.openAppend(partPath)
        let file = try FileHandle(forReadingFrom: localURL)
        defer { try? file.close() }

        if offset > 0 {
            transferred[id] = offset
            publish(id, force: true)
        }
        file.seek(toFileOffset: UInt64(offset))

        while true {
            try Task.checkCancellation()
            guard let slice = try file.read(upToCount: reportStrideBytes), !slice.isEmpty else { break }
            var written = 0
            while written < slice.count {
                let end = min(written + SFTPClient.maximumChunkSize, slice.count)
                try await client.write(handle: handle, offset: UInt64(offset + Int64(written)), data: slice.subdata(in: written..<end))
                written = end
            }
            offset += Int64(slice.count)
            transferred[id] = offset
            publish(id)
        }

        try await client.close(handle)

        // v3 的 rename 不覆盖：先删旧目标，再把 part 改成正式名。
        if (try? await client.exists(finalPath)) == true {
            try? await client.removeFile(finalPath)
        }
        try await client.move(from: partPath, to: finalPath)
    }

    private func download(remotePath: String, to localURL: URL, size: Int64, id: UUID) async throws {
        let partURL = Self.partURL(for: localURL)
        let handle = try await client.openRead(remotePath)

        var offset = Int64(Self.localSize(of: partURL))
        if offset > 0 {
            transferred[id] = offset
            publish(id, force: true)
        }
        let file = try Self.prepareLocalFile(at: partURL)
        defer { try? file.close() }
        file.seek(toFileOffset: UInt64(offset))

        while true {
            try Task.checkCancellation()
            guard let chunk = try await client.read(handle: handle, offset: UInt64(offset)), !chunk.isEmpty else { break }
            try file.write(contentsOf: chunk)
            offset += Int64(chunk.count)
            transferred[id] = offset
            publish(id)
        }

        try await client.close(handle)
        try Self.land(partURL: partURL, finalURL: localURL)
    }

    /// 续传起点：part 文件已有多少字节就从哪里接着传，超过源文件长度的部分按整份重来。
    private func resumedOffset(of path: String, cap: Int64) async throws -> Int64 {
        guard let attributes = try? await client.attributes(of: path), attributes.flags.contains(.size) else { return 0 }
        let existing = Int64(attributes.size)
        guard cap <= 0 || existing <= cap else { return 0 }
        return existing
    }

    private func discardPart(of job: Job) async {
        switch job {
        case .upload(_, let name, _, let directory, _):
            try? await client.removeFile(SFTPPath.join(directory, name) + Self.partSuffix)
        case .download(_, _, _, let localURL, _):
            try? FileManager.default.removeItem(at: Self.partURL(for: localURL))
        }
    }

    // MARK: - 本地文件

    /// 半成品与正式文件同名加后缀，续传靠它记住已经搬完的字节数。
    private static func partURL(for finalURL: URL) -> URL {
        URL(fileURLWithPath: finalURL.path + partSuffix)
    }

    private static func localSize(of url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }

    private static func prepareLocalFile(at url: URL) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        return try FileHandle(forWritingTo: url)
    }

    /// part → 正式名。目标已存在时替换（面板在入队前已经向用户确认过覆盖）。
    private static func land(partURL: URL, finalURL: URL) throws {
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: partURL, to: finalURL)
    }

    // MARK: - 进度

    private func progress(for id: UUID) -> SFTPTransferProgress? {
        guard let job = jobs[id] else { return nil }
        return SFTPTransferProgress(
            id: id,
            name: job.name,
            kind: job.kind,
            totalBytes: job.size,
            transferredBytes: transferred[id] ?? 0,
            state: states[id] ?? .queued
        )
    }

    /// 按缓冲块节流；状态变化一律外发，否则 UI 会停在 99%。
    private func publish(_ id: UUID, force: Bool = false) {
        let moved = transferred[id] ?? 0
        let previous = lastReported[id] ?? -1
        guard force || moved - previous >= Int64(reportStrideBytes) else { return }
        lastReported[id] = moved
        guard let snapshot = progress(for: id) else { return }
        onUpdate(snapshot)
    }
}
