import AppKit
import MioTermCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var mainWindow: MainWindowController?
    private var pendingOpenURLs: [URL] = []

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
        if !pendingOpenURLs.isEmpty {
            let urls = pendingOpenURLs
            pendingOpenURLs.removeAll()
            DefaultTerminalManager.handleOpenURLs(urls, in: controller.workspaceController)
        }
    }

    @objc(application:openURLs:)
    public func application(_ application: NSApplication, open urls: [URL]) {
        guard let mainWindow else {
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
        mainWindow.show()
        DefaultTerminalManager.handleOpenURLs(urls, in: mainWindow.workspaceController)
    }

    @objc func makeDefaultTerminal(_ sender: Any?) {
        let status = DefaultTerminalManager.makeMioTermDefault()
        if status == noErr {
            AlertPresenter.notify(
                title: L10n.tr(.defaultTerminalSetTitle),
                message: L10n.tr(.defaultTerminalSetMsg),
                in: mainWindow?.window
            )
        } else {
            AlertPresenter.fail(
                title: L10n.tr(.defaultTerminalFailedTitle),
                message: L10n.tr(.defaultTerminalFailedMsg, Int(status)),
                in: mainWindow?.window
            )
        }
    }

    @objc func restoreSystemDefaultTerminal(_ sender: Any?) {
        let status = DefaultTerminalManager.restoreAppleTerminalDefault()
        if status == noErr {
            AlertPresenter.notify(
                title: L10n.tr(.defaultTerminalRestoredTitle),
                message: L10n.tr(.defaultTerminalRestoredMsg),
                in: mainWindow?.window
            )
        } else {
            AlertPresenter.fail(
                title: L10n.tr(.defaultTerminalFailedTitle),
                message: L10n.tr(.defaultTerminalFailedMsg, Int(status)),
                in: mainWindow?.window
            )
        }
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(makeDefaultTerminal(_:)) {
            menuItem.state = DefaultTerminalManager.isDefaultTerminal ? .on : .off
        }
        return true
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
