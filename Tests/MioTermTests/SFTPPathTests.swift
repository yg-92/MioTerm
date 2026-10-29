import MioTermCore
import Testing

/// 远端路径只做词法处理（POSIX 语义），拼接过的地方出过 `/x/` 这种多一个斜杠的路径。
@Suite("远端路径拼接")
struct SFTPPathTests {
    @Test func joinsUnderARegularDirectory() {
        #expect(SFTPPath.join("/home/jenkins", "project") == "/home/jenkins/project")
        #expect(SFTPPath.join("/home/jenkins/", "/abs/path") == "/abs/path")
    }

    /// `cd ../` 从 `/home` 算出 `/`，再拼 `project-execute/`：
    /// 根目录这一支以前跳过归一化，结果带着结尾斜杠进上下文和日志。
    @Test func joiningAtTheRootNormalizesTheTail() {
        #expect(SFTPPath.join("/", "project-execute/") == "/project-execute")
        #expect(SFTPPath.join("/", "../x") == "/x")
    }

    @Test func normalizesRelativeSegments() {
        #expect(SFTPPath.normalize("/home//jenkins/../jenkins_home/") == "/home/jenkins_home")
        #expect(SFTPPath.normalize("../x") == "../x")
    }
}
