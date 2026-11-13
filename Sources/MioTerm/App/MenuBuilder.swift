import AppKit
import MioTermCore

/// 程序化构建主菜单：没有 Xcode 的 nib，菜单全部在这里组装。
/// 会话与主机相关动作不写 target，交给响应链落到 WorkspaceViewController。
enum MenuBuilder {
    static func install() {
        let mainMenu = NSMenu()
        mainMenu.addItem(applicationMenu())
        mainMenu.addItem(sessionMenu())
        mainMenu.addItem(hostMenu())
        mainMenu.addItem(editMenu())
        mainMenu.addItem(viewMenu())
        mainMenu.addItem(windowMenu())
        NSApp.mainMenu = mainMenu
    }

    private static func applicationMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "MioTerm")
        menu.addItem(withTitle: L10n.tr(.menuAbout), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.tr(.menuSettings), action: Selector(("showPreferences:")), keyEquivalent: ",")
        menu.addItem(.separator())
        let services = NSMenuItem(title: L10n.tr(.menuServices), action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: L10n.tr(.menuServices))
        NSApp.servicesMenu = services.submenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.tr(.menuHideApp), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: L10n.tr(.menuHideOthers), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: L10n.tr(.menuShowAll), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.tr(.menuQuitApp), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = menu
        return item
    }

    private static func sessionMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L10n.tr(.menuSession))
        let home = menu.addItem(withTitle: L10n.tr(.menuHome), action: Selector(("showHome:")), keyEquivalent: "h")
        home.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.tr(.menuNewLocalTerminal), action: Selector(("newLocalTerminal:")), keyEquivalent: "t")
        // 名字刻意避开 selectNextTab:：那是 NSWindow 的“窗口标签”动作，
        // 落到它身上会去切换窗口而不是本窗内的标签。
        let next = menu.addItem(withTitle: L10n.tr(.menuNextTab), action: Selector(("selectNextTerminalTab:")), keyEquivalent: "]")
        next.keyEquivalentModifierMask = [.command]
        let previous = menu.addItem(withTitle: L10n.tr(.menuPrevTab), action: Selector(("selectPreviousTerminalTab:")), keyEquivalent: "[")
        previous.keyEquivalentModifierMask = [.command]
        // 系统 NSTabViewController 自带的 ⌘1…9 已随自绘标签栏一起消失，这里补回来。
        let tabsItem = NSMenuItem(title: L10n.tr(.menuSwitchToTab), action: nil, keyEquivalent: "")
        let tabsMenu = NSMenu(title: L10n.tr(.menuSwitchToTab))
        for number in 1...9 {
            let tab = tabsMenu.addItem(
                withTitle: L10n.tr(.menuTabNumber, number),
                action: Selector(("selectTerminalTab:")),
                keyEquivalent: "\(number)"
            )
            tab.tag = number
        }
        tabsItem.submenu = tabsMenu
        menu.addItem(tabsItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.tr(.menuConnectSelected), action: Selector(("connectSelectedHost:")), keyEquivalent: "")
        menu.addItem(withTitle: L10n.tr(.menuReconnect), action: Selector(("reconnectTerminal:")), keyEquivalent: "r")
        menu.addItem(withTitle: L10n.tr(.menuCloseTab), action: Selector(("closeTerminalTab:")), keyEquivalent: "w")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.tr(.menuFilePanel), action: Selector(("showFilePanel:")), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .option]
        // 只在串口会话下亮起：交换机与开发板控制台靠 BREAK 唤出提示符，
        // SSH 与 Telnet 没有这个信号。
        menu.addItem(withTitle: L10n.tr(.menuSerialBreak), action: Selector(("sendSerialBreak:")), keyEquivalent: "")
        menu.addItem(withTitle: L10n.tr(.menuHostList), action: Selector(("showHostList:")), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: L10n.tr(.menuCommandLibrary), action: Selector(("showCommandLibrary:")), keyEquivalent: "k")
            .keyEquivalentModifierMask = [.command]
        menu.addItem(withTitle: L10n.tr(.menuToggleSidebar), action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .control]
        item.submenu = menu
        return item
    }

    private static func hostMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L10n.tr(.menuHost))
        menu.addItem(withTitle: L10n.tr(.menuNewHost), action: Selector(("newHost:")), keyEquivalent: "n")
        menu.addItem(withTitle: L10n.tr(.menuEditHost), action: Selector(("editSelectedHost:")), keyEquivalent: "")
        menu.addItem(withTitle: L10n.tr(.menuDuplicateHost), action: Selector(("duplicateSelectedHost:")), keyEquivalent: "")
        menu.addItem(withTitle: L10n.tr(.menuDeleteHost), action: Selector(("deleteSelectedHost:")), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.tr(.menuTestHost), action: Selector(("testSelectedHost:")), keyEquivalent: "")
        menu.addItem(withTitle: L10n.tr(.menuRefreshFingerprint), action: Selector(("refreshFingerprintSelectedHost:")), keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func editMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L10n.tr(.menuEdit))
        menu.addItem(withTitle: L10n.tr(.menuCut), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: L10n.tr(.menuCopy), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: L10n.tr(.menuPaste), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: L10n.tr(.menuSelectAll), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        addItem(menu, title: L10n.tr(.menuFind), tag: NSTextFinder.Action.showFindInterface.rawValue, keyEquivalent: "f")
        addItem(menu, title: L10n.tr(.menuFindNext), tag: NSTextFinder.Action.nextMatch.rawValue, keyEquivalent: "g")
        addItem(menu, title: L10n.tr(.menuFindPrevious), tag: NSTextFinder.Action.previousMatch.rawValue, keyEquivalent: "g")
            .keyEquivalentModifierMask = [.command, .shift]
        addItem(menu, title: L10n.tr(.menuUseSelectionForFind), tag: NSTextFinder.Action.setSearchString.rawValue, keyEquivalent: "e")
        item.submenu = menu
        return item
    }

    /// SwiftTerm 与 NSTextView 都靠 performTextFinderAction: + tag 驱动查找面板。
    @discardableResult
    private static func addItem(_ menu: NSMenu, title: String, tag: Int, keyEquivalent: String) -> NSMenuItem {
        let menuItem = menu.addItem(withTitle: title, action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: keyEquivalent)
        menuItem.tag = tag
        return menuItem
    }

    private static func viewMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L10n.tr(.menuView))
        menu.addItem(withTitle: L10n.tr(.menuConfigureSplit), action: Selector(("configureTerminalSplit:")), keyEquivalent: "d")
            .keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.tr(.menuPageStyle), action: Selector(("showStylePreferences:")), keyEquivalent: "")
        menu.addItem(.separator())
        let bigger = menu.addItem(withTitle: L10n.tr(.menuFontIncrease), action: Selector(("adjustTerminalFontSize:")), keyEquivalent: "+")
        bigger.tag = 1
        let smaller = menu.addItem(withTitle: L10n.tr(.menuFontDecrease), action: Selector(("adjustTerminalFontSize:")), keyEquivalent: "-")
        smaller.tag = -1
        menu.addItem(withTitle: L10n.tr(.menuFontReset), action: Selector(("resetTerminalFontSize:")), keyEquivalent: "0")
        item.submenu = menu
        return item
    }

    private static func windowMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L10n.tr(.menuWindow))
        menu.addItem(withTitle: L10n.tr(.menuMinimize), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: L10n.tr(.menuZoom), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.tr(.menuBringAllToFront), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }
}
