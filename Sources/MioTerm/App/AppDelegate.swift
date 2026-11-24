import AppKit
import Carbon.HIToolbox
import MioTermCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var mainWindow: MainWindowController?
    private var pendingOpenURLs: [URL] = []
    private var windowCycleMonitor: Any?

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
        windowCycleMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleWindowCycleKeyEvent(event) else { return event }
            return nil
        }
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
        if let windowCycleMonitor {
            NSEvent.removeMonitor(windowCycleMonitor)
            self.windowCycleMonitor = nil
        }
        mainWindow?.closeSessions()
    }

    /// 统一接管 ⌘` / ⌘⇧` 窗口轮换：避免被远端 RDP/VNC 视图拦截，并兼容中文输入法下按键字符为 `·` 的情况。
    private func handleWindowCycleKeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let allowed: NSEvent.ModifierFlags = [.command, .shift]
        guard flags.contains(.command),
              flags.subtracting(allowed).isEmpty,
              Int(event.keyCode) == kVK_ANSI_Grave else {
            return false
        }
        if let vncView = NSApp.keyWindow?.firstResponder as? VNCView {
            vncView.resetRemoteModifiers()
        }
        cycleAppWindows(reverse: flags.contains(.shift))
        return true
    }

    private func cycleAppWindows(reverse: Bool) {
        let candidates = NSApp.orderedWindows.filter { window in
            window.isVisible && !window.isMiniaturized && window.canBecomeKey && !window.isExcludedFromWindowsMenu
        }
        guard candidates.count > 1, let current = candidates.first else { return }
        if reverse {
            candidates.last?.makeKeyAndOrderFront(nil)
        } else {
            let next = candidates[1]
            let backmost = candidates.last
            next.makeKeyAndOrderFront(nil)
            if let backmost, backmost !== current {
                current.order(.below, relativeTo: backmost.windowNumber)
            }
        }
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
