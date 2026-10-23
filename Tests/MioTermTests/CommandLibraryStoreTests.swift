import Foundation
import Testing

@testable import MioTermCore

/// 用例全部打在临时文件上：这个存储会真的落盘，用默认路径会把开发机上的统计清掉。
@MainActor
private func makeStore(name: String) -> (store: CommandLibraryStore, url: URL, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mioTerm-command-tests-\(UUID().uuidString)", isDirectory: true)
    let url = directory.appendingPathComponent("\(name).json")
    return (CommandLibraryStore(url: url, logger: { _ in }), url, directory)
}

@MainActor
@Suite("命令库")
struct CommandLibraryStoreTests {
    @Test("同一条命令只累积次数，不新增记录")
    func repeatedCommandAccumulates() {
        let (store, _, _) = makeStore(name: "repeat")
        #expect(store.record(scope: "h1", command: "ls -la"))
        #expect(store.record(scope: "h1", command: "ls -la"))
        #expect(store.record(scope: "h1", command: "  ls -la  "))
        let all = store.records(scope: "h1")
        #expect(all.count == 1)
        #expect(all.first?.executionCount == 3)
        #expect(all.first?.command == "ls -la")
    }

    @Test("不同作用域各自记账")
    func scopesAreIsolated() {
        let (store, _, _) = makeStore(name: "scopes")
        store.record(scope: "h1", command: "df -h")
        store.record(scope: "h2", command: "df -h")
        store.record(scope: "h2", command: "uptime")
        #expect(store.records(scope: "h1").count == 1)
        #expect(store.records(scope: "h2").count == 2)
        #expect(store.entry(scope: "h1", command: "df -h")?.executionCount == 1)
    }

    @Test("粘贴的多行脚本与控制串不入库", arguments: [
        "echo a\necho b", "show version\rinterface", "", "   ", "\u{07}", "ping\u{07}host",
    ])
    func rejectsUnusableText(_ raw: String) {
        let (store, _, _) = makeStore(name: "reject")
        #expect(!store.record(scope: "h1", command: raw))
        #expect(store.records(scope: "h1").isEmpty)
    }

    @Test("行尾的回车与空白只是输入噪声，不是命令的一部分")
    func stripsTrailingEnterAndSpaces() {
        let (store, _, _) = makeStore(name: "trim")
        #expect(store.record(scope: "h1", command: "  show version \r\n"))
        #expect(store.records(scope: "h1").first?.command == "show version")
    }

    @Test("超过长度上限的命令不入库")
    func rejectsOverlongCommand() {
        let (store, _, _) = makeStore(name: "long")
        let huge = String(repeating: "a", count: CommandLibraryStore.maximumCommandLength + 1)
        #expect(!store.record(scope: "h1", command: huge))
        let justFits = String(repeating: "b", count: CommandLibraryStore.maximumCommandLength)
        #expect(store.record(scope: "h1", command: justFits))
    }

    @Test("引号里的双空格原样保存")
    func keepsInnerSpacing() {
        let (store, _, _) = makeStore(name: "spacing")
        store.record(scope: "h1", command: "grep \"a  b\" f")
        #expect(store.records(scope: "h1").first?.command == "grep \"a  b\" f")
    }

    @Test("淘汰时先踢用得最少的，收藏的不参与")
    func trimsLeastUsedFirst() {
        let (store, _, _) = makeStore(name: "trim")
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // 50 条一次性命令，外加一条从没跑过、因此次数为 0 的收藏：它最弱，但收藏不参与淘汰。
        for index in 0..<CommandLibraryStore.maximumTrackedCommands {
            store.record(scope: "h1", command: "cmd-\(index)", at: base.addingTimeInterval(TimeInterval(index)))
        }
        store.setFavorite("keep-me", scope: "h1", favorite: true)
        #expect(store.records(scope: "h1").count == CommandLibraryStore.maximumTrackedCommands + 1)

        store.record(scope: "h1", command: "trigger", at: base.addingTimeInterval(10_000))
        let after = store.records(scope: "h1")
        #expect(after.count == CommandLibraryStore.maximumTrackedCommands + 1)
        #expect(after.first { $0.command == "keep-me" }?.favorite == true)
        #expect(after.contains { $0.command == "trigger" })
        // cmd-0 与其余记录同为 1 次，但它最久没被使用，因此是它出局。
        #expect(after.first { $0.command == "cmd-0" } == nil)
        #expect(after.first { $0.command == "cmd-1" } != nil)
    }

    @Test("按次数与按时间各自排序")
    func sorting() {
        let (store, _, _) = makeStore(name: "sort")
        let old = Date(timeIntervalSince1970: 1_000)
        for _ in 0..<3 { store.record(scope: "h1", command: "often", at: old) }
        store.record(scope: "h1", command: "fresh", at: old.addingTimeInterval(500))
        #expect(store.mostUsed(scope: "h1").first?.command == "often")
        #expect(store.mostRecent(scope: "h1").first?.command == "fresh")
    }

    @Test("本机忽略挡住记录并清掉历史")
    func hostIgnoreSuppressesAndCleans() {
        let (store, _, _) = makeStore(name: "host-ignore")
        store.record(scope: "h1", command: "passwd")
        #expect(store.records(scope: "h1").count == 1)
        store.addIgnore("passwd", scope: "h1")
        #expect(store.records(scope: "h1").isEmpty)
        #expect(!store.record(scope: "h1", command: "passwd"))
        // 只挡这台主机：另一台照记。
        #expect(store.record(scope: "h2", command: "passwd"))
        #expect(store.records(scope: "h2").count == 1)
        #expect(store.ignoredCommands(scope: "h2").isEmpty)
    }

    @Test("忽略命中但没有历史可清时，不重复落盘也不刷新面板")
    func ignoredCommandWithoutHistoryDoesNotRewrite() throws {
        let (store, url, _) = makeStore(name: "ignore-idle")
        store.addIgnore("passwd", scope: "h1")
        var changes = 0
        store.onChange = { changes += 1 }
        let before = try Data(contentsOf: url)

        #expect(!store.record(scope: "h1", command: "passwd"))
        #expect(changes == 0)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("全局忽略挡住所有作用域")
    func globalIgnoreAppliesEverywhere() {
        let (store, _, _) = makeStore(name: "global-ignore")
        store.record(scope: "h1", command: "history -c")
        store.record(scope: "h2", command: "history -c")
        store.addIgnore("history -c", scope: nil)
        #expect(store.records(scope: "h1").isEmpty)
        #expect(store.records(scope: "h2").isEmpty)
        #expect(!store.record(scope: "h3", command: "history -c"))
        #expect(store.ignoredCommands(scope: "h3") == [IgnoredCommand(command: "history -c", global: true)])
    }

    @Test("忽略清单能移除，也能升级成全局")
    func ignoreMaintenance() {
        let (store, _, _) = makeStore(name: "ignore-ops")
        store.addIgnore("vim", scope: "h1")
        #expect(store.ignoredCommands(scope: "h1") == [IgnoredCommand(command: "vim", global: false)])
        store.promoteIgnoreToGlobal("vim", scope: "h1")
        #expect(store.ignoredCommands(scope: "h1") == [IgnoredCommand(command: "vim", global: true)])
        #expect(store.ignoredCommands(scope: "h2") == [IgnoredCommand(command: "vim", global: true)])
        store.removeIgnore("vim", scope: nil)
        #expect(store.ignoredCommands(scope: "h1").isEmpty)
        #expect(store.record(scope: "h1", command: "vim"))
    }

    @Test("收藏保留次数并可取消")
    func favoriteKeepsCount() {
        let (store, _, _) = makeStore(name: "favorite")
        store.record(scope: "h1", command: "git status")
        store.record(scope: "h1", command: "git status")
        store.setFavorite("git status", scope: "h1", favorite: true)
        let favorited = store.favorites(scope: "h1")
        #expect(favorited.count == 1)
        #expect(favorited.first?.executionCount == 2)
        #expect(favorited.first?.favoritedAt != nil)
        store.setFavorite("git status", scope: "h1", favorite: false)
        #expect(store.favorites(scope: "h1").isEmpty)
        store.record(scope: "h1", command: "git status")
        #expect(store.entry(scope: "h1", command: "git status")?.executionCount == 3)
    }

    @Test("从没跑过的命令也能收藏，次数从 0 起")
    func favoriteWithoutHistory() {
        let (store, _, _) = makeStore(name: "favorite-new")
        store.setFavorite("tail -f log", scope: "h1", favorite: true)
        #expect(store.favorites(scope: "h1").first?.executionCount == 0)
    }

    @Test("删除单条与清空作用域")
    func removalAndClear() {
        let (store, _, _) = makeStore(name: "remove")
        store.record(scope: "h1", command: "a")
        store.record(scope: "h1", command: "b")
        store.remove(command: "a", scope: "h1")
        #expect(store.records(scope: "h1").map(\.command) == ["b"])
        store.addIgnore("skip", scope: "h1")
        #expect(store.ignoredCommands(scope: "h1").count == 1)
        store.clear(scope: "h1")
        #expect(store.records(scope: "h1").isEmpty)
        #expect(store.ignoredCommands(scope: "h1").isEmpty)
    }

    @Test("主机删除后清理孤儿统计与忽略")
    func prunesDeadScopes() {
        let (store, _, _) = makeStore(name: "prune")
        store.record(scope: "h1", command: "ls")
        store.record(scope: CommandScope.localShell, command: "ls")
        store.addIgnore("rm -rf", scope: "h2")
        store.prune(validScopes: ["h1"])
        #expect(store.records(scope: "h1").count == 1)
        #expect(store.records(scope: CommandScope.localShell).count == 1)
        #expect(store.ignoredCommands(scope: "h2").isEmpty)
    }

    @Test("落盘后重新载入，统计与忽略都在")
    func survivesReload() {
        let (store, url, _) = makeStore(name: "reload")
        store.record(scope: "h1", command: "uptime")
        store.setFavorite("uptime", scope: "h1", favorite: true)
        store.addIgnore("passwd", scope: "h1")
        store.addIgnore("history -c", scope: nil)

        let other = CommandLibraryStore(url: url, logger: { _ in })
        #expect(other.load())
        #expect(other.entry(scope: "h1", command: "uptime")?.executionCount == 1)
        #expect(other.favorites(scope: "h1").count == 1)
        store.record(scope: "h1", command: "uptime")
        #expect(store.entry(scope: "h1", command: "uptime")?.executionCount == 2)
        #expect(!other.record(scope: "h1", command: "passwd"))
        #expect(!other.record(scope: "h2", command: "history -c"))
    }

    @Test("损坏的主文件退回备份")
    func corruptFallsBackToBackup() throws {
        let (store, url, _) = makeStore(name: "corrupt")
        store.record(scope: "h1", command: "date")
        // 备份是写主文件之前留下的上一版本：此刻 .bak 里只有 date，主文件有 date + who。
        store.record(scope: "h1", command: "who")
        try Data("{{{ 不是 JSON".utf8).write(to: url)

        let revived = CommandLibraryStore(url: url, logger: { _ in })
        #expect(revived.load())
        #expect(revived.records(scope: "h1").map(\.command) == ["date"])
        // 坏文件被挪去 .corrupt-*，不是被覆盖。
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(leftovers.contains { $0.hasPrefix("\(url.lastPathComponent).corrupt-") })
    }

    @Test("备份也坏时从空库开始")
    func bothUnreadableStartsEmpty() throws {
        let (store, url, _) = makeStore(name: "both-broken")
        store.record(scope: "h1", command: "date")
        try Data("still not json".utf8).write(to: url)
        try Data("broken too".utf8).write(to: URL(fileURLWithPath: url.path + ".bak"))
        let revived = CommandLibraryStore(url: url, logger: { _ in })
        #expect(!revived.load())
        #expect(revived.records(scope: "h1").isEmpty)
        // 从空库开始也能继续写。
        #expect(revived.record(scope: "h1", command: "uptime"))
    }

    @Test("缺键的旧文件按默认值补齐")
    func tolerantDecoding() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mioTerm-command-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("legacy.json")
        // 手写一份只有 records 的文件：favoritedAt、hostIgnores、globalIgnores 全缺。
        try """
        {"records":{"h1":{"ls":{"command":"ls","executionCount":4,"lastExecutedAt":"2026-01-01T00:00:00Z"}}}}
        """.write(to: url, atomically: true, encoding: .utf8)
        let store = CommandLibraryStore(url: url, logger: { _ in })
        #expect(store.load())
        let entry = try #require(store.entry(scope: "h1", command: "ls"))
        #expect(entry.executionCount == 4)
        #expect(!entry.favorite)
        #expect(entry.favoritedAt == nil)
        #expect(store.ignoredCommands(scope: "h1").isEmpty)
        // 忽略清单缺失时，记录照常写入并从旧次数继续累加。
        store.record(scope: "h1", command: "ls")
        #expect(store.entry(scope: "h1", command: "ls")?.executionCount == 5)
    }

    @Test("本地终端单独占一个作用域")
    func localShellScope() {
        let host = HostProfile(name: "路由器", address: "")
        #expect(CommandScope.key(host: nil) == CommandScope.localShell)
        #expect(CommandScope.key(host: host) == host.id)
        #expect(CommandScope.key(host: host) != CommandScope.localShell)
    }
}
