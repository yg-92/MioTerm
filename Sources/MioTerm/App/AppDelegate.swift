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
        // 外观由设置决定（跟随系统 / 深色 / 浅色），AppEnvironment 初始化时已经套用。
        MenuBuilder.install()
        let controller = MainWindowController()
        mainWindow = controller
        controller.show()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    public func applicationWillTerminate(_ notification: Notification) {
        mainWindow?.closeSessions()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { mainWindow?.show() }
        return true
    }

    private func presentLaunchFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L10n.tr(.launchDirErrorTitle)
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
    }
}
