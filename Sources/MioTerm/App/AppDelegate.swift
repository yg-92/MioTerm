import AppKit
import MioTermCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: MainWindowController?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try AskpassLauncher.install(
                executablePath: Bundle.main.executablePath ?? "/Applications/MioTerm.app/Contents/MacOS/MioTerm"
            )
            // 上次异常退出可能留下含口令的临时文件，启动即清扫。
            AskpassHelper.cleanupStaleFiles()
        } catch {
            presentLaunchFailure(error)
        }
        MenuBuilder.install()
        let controller = MainWindowController()
        mainWindow = controller
        controller.show()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 退出前确认还有活动会话；这里的阻塞式弹窗是有意的，
    /// 终止流程不能再依赖异步续体，否则子进程来不及回收。
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let mainWindow, mainWindow.sessionsAreActive else { return .terminateNow }
        guard AppEnvironment.shared.settings.settings.confirmBeforeClose else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "仍有会话在运行"
        alert.informativeText = "退出 MioTerm 会断开全部 SSH 连接并删除一次性口令文件。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    public func applicationWillTerminate(_ notification: Notification) {
        mainWindow?.closeSessions()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow?.show() }
        return true
    }

    private func presentLaunchFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "MioTerm 无法准备运行目录"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
    }
}
