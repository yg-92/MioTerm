import Foundation
import MioTermCore
import Testing

@Suite("分组下拉选项")
struct HostSortingTests {
    @Test func groupNamesAreTrimmedDeduplicatedAndSorted() {
        let hosts = [
            HostProfile(name: "a", group: " zeta "),
            HostProfile(name: "b", group: "alpha"),
            HostProfile(name: "c", group: ""),
            HostProfile(name: "d", group: "alpha"),
            HostProfile(name: "e", group: "   "),
            HostProfile(name: "f", group: "beta"),
        ]
        #expect(HostSorting.groupNames(hosts) == ["alpha", "beta", "zeta"])
    }

    @Test func groupNamesKeepChineseNamesAndSkipUngrouped() {
        let hosts = [
            HostProfile(name: "路由", group: "办公"),
            HostProfile(name: "开发板", group: "实验室"),
            HostProfile(name: "临时", group: ""),
        ]
        let names = HostSorting.groupNames(hosts)
        #expect(names.contains("办公"))
        #expect(names.contains("实验室"))
        #expect(names.contains("") == false)
        #expect(names.count == 2)
    }

    @Test @MainActor func renameGroupUpdatesMatchingHostsAndSupportsUngrouped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mioterm-rename-group-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = HostRepository(url: dir.appendingPathComponent("hosts.json"))
        _ = try repo.save(HostProfile(name: "h1", group: "测试", address: "10.0.0.1", username: "root"))
        _ = try repo.save(HostProfile(name: "h2", group: "测试", address: "10.0.0.2", username: "root"))
        _ = try repo.save(HostProfile(name: "h3", group: "", address: "10.0.0.3", username: "root"))

        let moved = try repo.renameGroup(from: "测试", to: "生产")
        #expect(moved == 2)
        #expect(repo.hosts.filter { $0.group == "生产" }.count == 2)
        #expect(repo.hosts.filter { $0.group == "测试" }.isEmpty)

        // 重命名「未分组」到具名分组
        let ungrouped = L10n.tr(.hostGroupUngrouped)
        let movedUngrouped = try repo.renameGroup(from: ungrouped, to: "办公")
        #expect(movedUngrouped == 1)
        #expect(repo.hosts.first(where: { $0.name == "h3" })?.group == "办公")

        // 留空时移回未分组
        let backToUngrouped = try repo.renameGroup(from: "办公", to: "   ")
        #expect(backToUngrouped == 1)
        #expect(repo.hosts.first(where: { $0.name == "h3" })?.group == "")
    }
}
