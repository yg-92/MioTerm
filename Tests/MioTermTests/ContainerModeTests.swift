import Foundation
import Testing
@testable import MioTermCore

/// 进入容器后，终端里的路径属于容器内部，宿主机 SFTP 读不到；
/// 这些用例把“何时冻结、何时解冻、显示哪种模式”固定下来。
struct ContainerModeTests {
    /// 先让会话落在外层宿主的一个目录上，提示符主机名作为基线。
    private func trackerOnHost() -> TerminalContextTracker {
        var tracker = TerminalContextTracker()
        tracker.submit(command: nil)
        _ = tracker.settle(promptLine: "[root@target /var]#", inAlternateScreen: false)
        return tracker
    }

    @Test func dockerExecFreezesFollowAndShowsDockerMode() {
        var tracker = trackerOnHost()
        tracker.submit(command: "docker exec -it web bash")
        #expect(tracker.context.mode == .docker(container: "web"))
        #expect(tracker.context.followAllowed == false)

        // 容器内的 cd 与提示符都不能再改目录。
        tracker.submit(command: "cd /app")
        _ = tracker.settle(promptLine: "bash-5.1#", inAlternateScreen: false)
        #expect(tracker.context.directory == "/var")
        #expect(tracker.context.mode == .docker(container: "web"))
    }

    /// 容器里的提示符即使带主机名，也不该把模式改成“远程 Shell”。
    @Test func containerPromptKeepsDockerMode() {
        var tracker = trackerOnHost()
        tracker.submit(command: "docker exec -it web bash")
        _ = tracker.settle(promptLine: "[root@web /app]#", inAlternateScreen: false)
        #expect(tracker.context.mode == .docker(container: "web"))
        #expect(tracker.context.directory == "/var")
        #expect(tracker.context.followAllowed == false)
    }

    @Test func exitUnfreezesAndAdoptsTheOuterPrompt() {
        var tracker = trackerOnHost()
        tracker.submit(command: "docker exec -it web bash")
        _ = tracker.settle(promptLine: "[root@web /app]#", inAlternateScreen: false)

        tracker.submit(command: "exit")
        _ = tracker.settle(promptLine: "[root@target /root]#", inAlternateScreen: false)
        #expect(tracker.context.mode == .shell)
        #expect(tracker.context.followAllowed)
        #expect(tracker.context.directory == "/root")
    }

    /// Ctrl+D 退出时没有 `exit` 命令可还原，只能靠提示符回到基线主机名。
    @Test func promptBackOnTheOuterHostEndsContainerMode() {
        var tracker = trackerOnHost()
        tracker.submit(command: "docker exec -it web bash")
        _ = tracker.settle(promptLine: "[root@web /app]#", inAlternateScreen: false)

        tracker.submit(command: nil)
        _ = tracker.settle(promptLine: "[root@target /home]#", inAlternateScreen: false)
        #expect(tracker.context.mode == .shell)
        #expect(tracker.context.directory == "/home")
    }

    /// 容器常与宿主同名：容器自己的提示符不能被当成“已经回到宿主”。
    @Test func sameNameContainerPromptDoesNotUnfreeze() {
        var tracker = trackerOnHost()
        tracker.submit(command: "docker exec -it target bash")
        _ = tracker.settle(promptLine: "[root@target /app]#", inAlternateScreen: false)
        #expect(tracker.context.mode == .docker(container: "target"))
        #expect(tracker.context.followAllowed == false)

        // 后续提示符仍同名，读屏也不能把容器模式洗掉。
        tracker.submit(command: nil)
        _ = tracker.settle(promptLine: "[root@target /app/logs]#", inAlternateScreen: false)
        #expect(tracker.context.mode == .docker(container: "target"))
        #expect(tracker.context.followAllowed == false)
        #expect(tracker.context.directory == "/var")
    }

    /// Ctrl+D 没有命令行文本，回车层单独报告“这一层 shell 结束了”。
    @Test func controlDLeavesTheContainer() {
        var tracker = trackerOnHost()
        tracker.submit(command: "docker exec -it web bash")
        _ = tracker.settle(promptLine: "[root@web /app]#", inAlternateScreen: false)

        tracker.submit(command: nil, shellExited: true)
        _ = tracker.settle(promptLine: "[root@target /root]#", inAlternateScreen: false)
        #expect(tracker.context.mode == .shell)
        #expect(tracker.context.followAllowed)
        #expect(tracker.context.directory == "/root")
    }

    /// Ctrl+D 只在空行上才是 EOF；行内有内容时只是删字符。
    @Test func controlDReportsShellExitOnlyOnAnEmptyLine() {
        var tracker = ShellCommandTracker()
        #expect(tracker.consume([0x04])?.endedShell == true)

        var line = ShellCommandTracker()
        _ = line.consume(Array("rm x".utf8))
        #expect(line.consume([0x04]) == nil)
    }

    /// 容器里的 OSC 7 不能把树带到容器路径上。
    @Test func oscSevenInsideContainerIsIgnored() {
        var tracker = trackerOnHost()
        tracker.submit(command: "docker exec -it web bash")
        tracker.reportOSC7("file://web/app")
        #expect(tracker.context.directory == "/var")
        #expect(tracker.context.followAllowed == false)
    }

    @Test func nonInteractiveDockerRunDoesNotFreeze() {
        var tracker = trackerOnHost()
        tracker.submit(command: "docker run --rm hello-world")
        #expect(tracker.context.mode == .shell)
        #expect(tracker.context.followAllowed)
    }

    @Test func nonInteractiveOrOneShotDockerExecDoesNotFreeze() {
        var tracker = trackerOnHost()
        tracker.submit(command: "docker exec web ls /app")
        #expect(tracker.context.mode == .shell)
        #expect(tracker.context.followAllowed)

        tracker.submit(command: "docker exec -it web ls -la")
        #expect(tracker.context.mode == .shell)
        #expect(tracker.context.followAllowed)

        tracker.submit(command: "docker exec -it web bash -c \"echo ok\"")
        #expect(tracker.context.mode == .shell)
        #expect(tracker.context.followAllowed)
    }

    @Test func exitingContainerDoesNotFlashRemoteShellMode() {
        var tracker = trackerOnHost()
        tracker.submit(command: "docker exec -it web bash")
        _ = tracker.settle(promptLine: "[root@web /app]#", inAlternateScreen: false)
        #expect(tracker.context.mode == .docker(container: "web"))

        // 敲下 exit 立刻回到普通 Shell，不能因为容器提示符主机名是 web 就误判成远程 Shell。
        tracker.submit(command: "exit")
        #expect(tracker.context.mode == .shell)
        #expect(tracker.context.followAllowed)
    }

    @Test func dockerPSIsNotAnEntry() {
        var tracker = trackerOnHost()
        tracker.submit(command: "docker ps -a")
        #expect(tracker.context.mode == .shell)
    }

    @Test func sudoAndComposeFormsAreRecognized() {
        var tracker = trackerOnHost()
        tracker.submit(command: "sudo docker exec -u root -it web bash")
        #expect(tracker.context.mode == .docker(container: "web"))

        var compose = trackerOnHost()
        compose.submit(command: "docker compose exec -it api sh")
        #expect(compose.context.mode == .docker(container: "api"))
    }

    @Test func otherRuntimesReportTheirOwnMode() {
        var tracker = trackerOnHost()
        tracker.submit(command: "kubectl exec -it pod-7 -- bash")
        #expect(tracker.context.mode == .container(runtime: "Kubernetes", name: "pod-7"))

        var lxc = trackerOnHost()
        lxc.submit(command: "lxc exec c1 bash")
        #expect(lxc.context.mode == .container(runtime: "LXC", name: "c1"))
    }

    /// 容器里跟随开着时要暂停并说明原因，而不是拿宿主机去读容器路径。
    @Test func plannerPausesInsideDockerWithReason() {
        let terminal = TerminalContext(directory: "/app", followAllowed: false,
                                       mode: .docker(container: "web"))
        let facts = PanelFollowFacts(terminal: terminal, followEnabled: true,
                                     channelReady: true, targetBefore: "/app", hasAligned: true)
        guard case .pause(let reason) = DirectoryFollowPlanner.decide(facts) else {
            Issue.record("容器内应暂停跟随")
            return
        }
        #expect(reason.contains("Docker"))
    }
}
