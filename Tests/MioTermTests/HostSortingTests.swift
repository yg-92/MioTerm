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
}
