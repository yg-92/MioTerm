import AppKit
import MioTermCore
import SwiftTerm
import Testing

/// 用户实际敲击的字节先进 SwiftTerm，屏幕安静后由通路把提示符读回来。
/// 这一层以前只能在控制器里跑，出过「Tab 补全之后跟随整个停摆」却测不到，
/// 现在判定与读屏都收在 TerminalFollowPipeline，就用真实字节把它钉住。
@MainActor
struct TerminalFollowPipelineTests {
    private final class Probe: TerminalViewDelegate {
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }

    /// 一台既不报 OSC 7、也没有 shell 集成的普通机器：只剩屏幕上的提示符可读。
    @MainActor
    private final class Rig {
        let view: TerminalView
        let pipeline: TerminalFollowPipeline
        private(set) var broadcasts: [TerminalContext] = []

        init() {
            let view = TerminalView(
                frame: NSRect(x: 0, y: 0, width: 640, height: 320),
                font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                options: TerminalOptions()
            )
            view.terminalDelegate = Probe()
            self.view = view
            let pipeline = TerminalFollowPipeline()
            pipeline.isLive = true
            pipeline.setScreenLineProvider { [weak view] in
                guard let view,
                      let snapshot = view.terminalContentSnapshot(region: .history(maximumScrollbackRows: -1))
                else { return nil }
                for row in snapshot.rows.reversed() {
                    let text = row.text.trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { return text }
                }
                return nil
            }
            self.pipeline = pipeline
            pipeline.onChange = { [weak self] context in self?.broadcasts.append(context) }
            pipeline.settleProbe = .init(
                idleFor: { [weak self] in self.map { Date().timeIntervalSince($0.lastOutput) } ?? 0 },
                inAlternateScreen: { [weak self] in self?.inAlternateScreen ?? false },
                hasOutputSince: { _ in true }
            )
        }

        var inAlternateScreen: Bool { view.terminalInputStateSnapshot()?.isAlternateBuffer ?? false }

        private(set) var lastOutput = Date()

        func remote(_ text: String) {
            lastOutput = Date()
            view.feed(text: text)
        }

        /// 模拟解析线程：只报告「又来了输出」，不等屏幕内容变化。
        func touchOutput() {
            lastOutput = Date()
            pipeline.noteOutput()
        }

        /// Telnet/串口：委托直接送来原始字节。
        func type(_ text: String) {
            let bytes = ArraySlice(Array(text.utf8))
            view.feed(text: text)
            pipeline.userInput(bytes, inAlternateScreen: inAlternateScreen)
        }

        /// 认证提示多半不回显：字节只进通路，屏幕上看不见。
        func typeBlind(_ text: String) {
            pipeline.userInput(ArraySlice(Array(text.utf8)), inAlternateScreen: inAlternateScreen)
        }

        /// SSH/本地 shell：按键从窗口事件层旁听，翻译后再进通路。
        func typeKey(_ text: String) {
            for character in text {
                view.feed(text: String(character))
                deliver(TerminalKeyStroke(characters: String(character), keyCode: 0))
            }
        }

        func pressReturn() {
            view.feed(text: "\r")
            deliver(TerminalKeyStroke(characters: "\r", keyCode: 36))
        }

        private func deliver(_ stroke: TerminalKeyStroke) {
            switch TerminalKeyTranslator.translate(stroke) {
            case .bytes(let bytes):
                pipeline.userInput(bytes[...], inAlternateScreen: inAlternateScreen)
            case .invalidatesLine:
                pipeline.invalidateLine()
            case .ignored:
                break
            }
        }

        @discardableResult
        func settle() -> Bool { pipeline.settleNow(idleFor: 1, inAlternateScreen: inAlternateScreen) }
    }

    /// 主用例：`cd /var/lo<Tab>` 让命令行还原不出来，跟随仍要从新提示符里接住目录。
    @Test func tabCompletedCdStillMovesTheDirectory() {
        let rig = Rig()
        rig.remote("[root@134 ~]# ")
        rig.pipeline.sessionDidOpen()
        #expect(rig.settle())
        #expect(rig.pipeline.context.promptHomeHint == "")

        rig.type("cd /var/lo\u{09}g\r")
        rig.remote("\r\n[root@134 /var/log]# ")
        #expect(rig.settle())
        #expect(rig.pipeline.context.directory == "/var/log")
        #expect(rig.broadcasts.last?.directory == "/var/log")
        rig.pipeline.stop()
    }

    /// 提示符只报末级目录（PS1 的 `\W`）时，Tab 补全的 cd 仍要从屏幕回显里接住：
    /// 本端只知道用户敲了 `cd /var/lo`，补出来的 `g` 只在屏幕上。
    @Test func tabCompletedCdWithBasenamePromptUsesTheEcho() {
        let rig = Rig()
        rig.remote("[root@134 ~]# ")
        rig.pipeline.sessionDidOpen()
        _ = rig.settle()

        let prefix = "cd /var/lo"
        rig.view.feed(text: prefix)
        rig.pipeline.userInput(ArraySlice(Array(prefix.utf8)), inAlternateScreen: false)
        rig.pipeline.userInput([0x09][...], inAlternateScreen: false)
        // 补全结果由 shell 写回屏幕，本端并没有收到这个按键。
        rig.view.feed(text: "g")
        var commands: [String] = []
        rig.pipeline.onCommand = { commands.append($0) }
        rig.pressReturn()
        rig.remote("\r\n[root@134 log]# ")

        #expect(rig.settle())
        #expect(rig.pipeline.context.directory == "/var/log")
        #expect(commands == ["cd /var/log"])
        rig.pipeline.stop()
    }

    /// 命令还在刷屏时读屏看到的是旧提示符，得等安静下来。
    @Test func settleWaitsUntilTheScreenGoesQuiet() {
        let rig = Rig()
        rig.remote("[root@134 ~]# ")
        rig.pipeline.sessionDidOpen()
        _ = rig.settle()
        rig.type("cd /etc\r")
        rig.remote("\r\n[root@134 /etc]# ")
        let early = rig.pipeline.settleNow(idleFor: 0.05, inAlternateScreen: rig.inAlternateScreen)
        #expect(!early)
        #expect(rig.pipeline.context.directory == nil)
        #expect(rig.pipeline.isWaitingForScreen)
        #expect(rig.settle())
        #expect(rig.pipeline.context.directory == "/etc")
        rig.pipeline.stop()
    }

    /// vim 里敲的回车不是命令，但退出编辑器后屏幕上就是新提示符，目录要跟上。
    @Test func promptAfterVimIsReadOnceTheEditorCloses() {
        let rig = Rig()
        rig.remote("[root@134 ~]# ")
        rig.pipeline.sessionDidOpen()
        _ = rig.settle()

        var lines: [String] = []
        rig.pipeline.onCommand = { lines.append($0) }
        rig.remote("\u{1B}[?1049hvim:q\r")
        #expect(rig.inAlternateScreen)
        #expect(lines.isEmpty)
        // 编辑器还开着：这一次不判定，等它退出。
        _ = rig.pipeline.settleNow(idleFor: 1, inAlternateScreen: true)
        #expect(rig.pipeline.context.directory == nil)

        rig.remote("\u{1B}[?1049lcd /opt/app\r\n[root@134 /opt/app]# ")
        #expect(rig.settle())
        #expect(rig.pipeline.context.directory == "/opt/app")
        #expect(lines.isEmpty)
        rig.pipeline.stop()
    }

    /// 空回车也要重读一次：用户可能刚用别的方式换了目录（比如 rvm、conda）。
    @Test func plainEnterArmsAnotherScreenRead() {
        let rig = Rig()
        rig.remote("[root@134 ~]# ")
        rig.pipeline.sessionDidOpen()
        _ = rig.settle()
        rig.type("\r")
        #expect(rig.pipeline.isWaitingForScreen)
        rig.pipeline.stop()
    }

    /// 空回车不制造“文件变了”的假信号，否则面板会跟着每条空命令白读一次。
    @Test func plainEnterDoesNotFakeAFileChange() {
        let rig = Rig()
        rig.remote("[root@134 ~]# ")
        rig.pipeline.sessionDidOpen()
        _ = rig.settle()
        rig.type("\r")
        rig.remote("\r\n[root@134 ~]# ")
        #expect(rig.settle())
        #expect(rig.pipeline.context.filesystemRevision == 0)
        rig.pipeline.stop()
    }

    /// vim 里新建文件后退出：屏幕回到普通缓冲，面板要重读当前目录。
    @Test func closingTheEditorMarksTheFilesystemChanged() {
        let rig = Rig()
        rig.remote("[root@134 ~]# ")
        rig.pipeline.sessionDidOpen()
        _ = rig.settle()

        rig.typeKey("vim new.txt")
        rig.pressReturn()
        rig.remote("\u{1B}[?1049h")
        // 编辑器还开着，这时不能重读：目录里看到的会是写盘前的内容。
        _ = rig.pipeline.settleNow(idleFor: 1, inAlternateScreen: true)
        #expect(rig.pipeline.context.filesystemRevision == 0)

        rig.remote("\u{1B}[?1049l\r\n[root@134 ~]# ")
        #expect(rig.settle())
        #expect(rig.pipeline.context.filesystemRevision == 1)
        #expect(rig.broadcasts.last?.filesystemRevision == 1)
        rig.pipeline.stop()
    }

    /// 粘贴/Tab 补全让命令行文本丢了，但 `rm -rf` 之类照样可能改了文件：
    /// 既然猜不出跑了什么，就保守地重读一次。
    @Test func unreliableSubmissionStillRefreshesTheListing() {
        let rig = Rig()
        rig.remote("root@target:~# ")
        rig.pipeline.sessionDidOpen()
        _ = rig.settle()

        rig.pipeline.invalidateLine()
        rig.pressReturn()
        rig.remote("\r\nroot@target:~# ")
        #expect(rig.settle())
        #expect(rig.pipeline.context.filesystemRevision == 1)
        rig.pipeline.stop()
    }

    /// 会话已经断了，屏幕上剩的还是最后的残字，不该再当成提示符广播出去。
    @Test func closedSessionStopsReadingTheScreen() {
        let rig = Rig()
        rig.remote("[root@134 ~]# ")
        rig.pipeline.sessionDidOpen()
        _ = rig.settle()
        rig.pipeline.isLive = false
        rig.type("ls\r")
        #expect(!rig.pipeline.isWaitingForScreen)
        rig.pipeline.stop()
    }

    /// OSC 7 是主动上报，不用等屏幕安静：立刻改目录并广播。
    @Test func oscSevenBroadcastsWithoutWaitingForTheScreen() {
        let rig = Rig()
        rig.remote("[root@134 ~]# ")
        rig.pipeline.sessionDidOpen()
        var seen: [TerminalContext] = []
        rig.pipeline.onChange = { seen.append($0) }
        #expect(rig.pipeline.reportOSC7("file://134/var/log"))
        #expect(seen.last?.directory == "/var/log")
        // 谁最后说话听谁的：这条提示符是回车之后才吐出来的，比启动时报的那一次新。
        rig.type("cd /etc\r")
        rig.remote("\r\n[root@134 /etc]# ")
        _ = rig.settle()
        #expect(rig.pipeline.context.directory == "/etc")
        rig.pipeline.stop()
    }

    /// 用户现场的主路径：SSH 会话里敲 cd，按键经窗口事件层翻译后仍要驱动跟随。
    @Test func sshKeyStrokesDriveTheFollow() {
        let rig = Rig()
        rig.remote("root@target:~# ")
        rig.pipeline.sessionDidOpen()
        _ = rig.settle()
        var commands: [String] = []
        rig.pipeline.onCommand = { commands.append($0) }

        rig.typeKey("cd /var")
        rig.pressReturn()
        #expect(rig.pipeline.isWaitingForScreen)
        rig.remote("\r\nroot@target:/var# ")
        #expect(rig.settle())
        #expect(commands == ["cd /var"])
        #expect(rig.pipeline.context.directory == "/var")
        rig.pipeline.stop()
    }

    /// 回车后回显还没到，屏幕上仍是命令执行前的旧提示符，这时候读屏只会白读。
    @Test func stalePromptIsNotReadBeforeTheEchoArrives() {
        let rig = Rig()
        rig.remote("[root@134 ~]# ")
        rig.pipeline.sessionDidOpen()
        _ = rig.settle()

        rig.typeKey("cd /opt")
        rig.pressReturn()
        #expect(!rig.pipeline.settleNow(idleFor: 1, inAlternateScreen: false, outputSinceSubmit: false))
        #expect(rig.pipeline.isWaitingForScreen)

        rig.remote("\r\n[root@134 /opt]# ")
        #expect(rig.settle())
        #expect(rig.pipeline.context.directory == "/opt")
        rig.pipeline.stop()
    }

    /// 粘贴进来的命令文本拿不到，但回车计时照常：目录仍要从新提示符里读出来。
    @Test func pastedTextIsNotGuessedButStillFollows() {
        let rig = Rig()
        rig.remote("root@target:~# ")
        rig.pipeline.sessionDidOpen()
        _ = rig.settle()
        var commands: [String] = []
        rig.pipeline.onCommand = { commands.append($0) }

        rig.pipeline.invalidateLine()
        rig.pressReturn()
        #expect(commands.isEmpty)
        rig.remote("\r\nroot@target:/opt/app# ")
        #expect(rig.settle())
        #expect(rig.pipeline.context.directory == "/opt/app")
        rig.pipeline.stop()
    }

    /// 输出事件把读屏不断往后推：磁盘还在写的时候不读，最后一帧落下 200ms 才读。
    @Test func outputKeepsPushingTheScreenReadBack() async throws {
        let rig = Rig()
        rig.remote("root@target:~# ")
        rig.pipeline.sessionDidOpen()
        #expect(rig.pipeline.isWaitingForScreen)

        for _ in 0..<6 {
            try await Task.sleep(nanoseconds: 50_000_000)
            rig.touchOutput()
        }
        #expect(rig.pipeline.context.promptHomeHint == nil)
        #expect(rig.pipeline.isWaitingForScreen)

        try await Task.sleep(nanoseconds: 450_000_000)
        #expect(rig.pipeline.context.promptHomeHint == "")
        #expect(!rig.pipeline.isWaitingForScreen)
        rig.pipeline.stop()
    }

    /// 会话里再 ssh 到别处：内层目录属于另一台机器，文件面板要停下来。
    @Test func nestedShellFreezesBroadcastsFollowNotAllowed() {
        let rig = Rig()
        rig.remote("[root@134 ~]# ")
        rig.pipeline.sessionDidOpen()
        _ = rig.settle()
        rig.type("ssh 10.0.0.8\r")
        rig.remote("\r\nroot@other:/etc # ")
        #expect(rig.settle())
        #expect(rig.pipeline.context.followAllowed == false)
        #expect(rig.pipeline.context.directory == nil)
        rig.pipeline.stop()
    }

    /// 设备控制台登录：用户名和口令都只是一串字符加回车，攒行器分不出来。
    /// 口令进了命令库就等于在界面上摆一份能点回终端的明文凭据，日志同理。
    @Test func consoleCredentialsStayOutOfTheCommandLibrary() {
        let rig = Rig()
        var commands: [String] = []
        rig.pipeline.onCommand = { commands.append($0) }

        // 用户名是回显的：屏幕上已经和提示语连成了一行。
        rig.remote("134 login: ")
        rig.type("admin\r")
        // 口令不回显：回车那一刻屏幕底行还停在提示语上。
        rig.remote("\r\nInput Password")
        rig.typeBlind("hunter2\r")
        #expect(commands == [])

        // 挡掉凭据不能把跟随带偏：登录成功后目录照旧从提示符里读，命令照旧记账。
        rig.remote("\r\n\r\n[root@134 ~]# ")
        _ = rig.settle()
        rig.type("cd /var/log\r")
        rig.remote("\r\n[root@134 /var/log]# ")
        #expect(rig.settle())
        #expect(rig.pipeline.context.directory == "/var/log")
        #expect(commands == ["cd /var/log"])
        rig.pipeline.stop()
    }

    /// shell 里的 sudo 口令同样不进命令库，前后的命令照常记账。
    @Test func sudoPasswordIsNotRecordedAsACommand() {
        let rig = Rig()
        rig.remote("[root@134 ~]# ")
        rig.pipeline.sessionDidOpen()
        _ = rig.settle()
        var commands: [String] = []
        rig.pipeline.onCommand = { commands.append($0) }

        rig.type("sudo -i\r")
        rig.remote("\r\n[sudo] password for root: ")
        rig.typeBlind("hunter2\r")
        rig.remote("\r\n[root@134 ~]# ")
        _ = rig.settle()
        rig.type("cd /var/log\r")
        rig.remote("\r\n[root@134 /var/log]# ")
        #expect(rig.settle())
        #expect(commands == ["sudo -i", "cd /var/log"])
        #expect(rig.pipeline.context.directory == "/var/log")
        rig.pipeline.stop()
    }
}
