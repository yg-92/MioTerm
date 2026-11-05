import AppKit

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
        menu.addItem(withTitle: "关于 MioTerm", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: Selector(("showPreferences:")), keyEquivalent: ",")
        menu.addItem(.separator())
        let services = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "服务")
        NSApp.servicesMenu = services.submenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(withTitle: "隐藏 MioTerm", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 MioTerm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = menu
        return item
    }

    private static func sessionMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "会话")
        let home = menu.addItem(withTitle: "主页", action: Selector(("showHome:")), keyEquivalent: "h")
        home.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "新建本地终端标签", action: Selector(("newLocalTerminal:")), keyEquivalent: "t")
        // 名字刻意避开 selectNextTab:：那是 NSWindow 的“窗口标签”动作，
        // 落到它身上会去切换窗口而不是本窗内的标签。
        let next = menu.addItem(withTitle: "下一个标签", action: Selector(("selectNextTerminalTab:")), keyEquivalent: "]")
        next.keyEquivalentModifierMask = [.command]
        let previous = menu.addItem(withTitle: "上一个标签", action: Selector(("selectPreviousTerminalTab:")), keyEquivalent: "[")
        previous.keyEquivalentModifierMask = [.command]
        // 系统 NSTabViewController 自带的 ⌘1…9 已随自绘标签栏一起消失，这里补回来。
        let tabsItem = NSMenuItem(title: "切换到标签", action: nil, keyEquivalent: "")
        let tabsMenu = NSMenu(title: "切换到标签")
        for number in 1...9 {
            let tab = tabsMenu.addItem(
                withTitle: "标签 \(number)",
                action: Selector(("selectTerminalTab:")),
                keyEquivalent: "\(number)"
            )
            tab.tag = number
        }
        tabsItem.submenu = tabsMenu
        menu.addItem(tabsItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "连接所选主机", action: Selector(("connectSelectedHost:")), keyEquivalent: "")
        menu.addItem(withTitle: "重新连接", action: Selector(("reconnectTerminal:")), keyEquivalent: "r")
        menu.addItem(withTitle: "关闭标签", action: Selector(("closeTerminalTab:")), keyEquivalent: "w")
        menu.addItem(.separator())
        menu.addItem(withTitle: "远端文件树", action: Selector(("showFilePanel:")), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .option]
        // 只在串口会话下亮起：交换机与开发板控制台靠 BREAK 唤出提示符，
        // SSH 与 Telnet 没有这个信号。
        menu.addItem(withTitle: "发送串口中断 (BREAK)", action: Selector(("sendSerialBreak:")), keyEquivalent: "")
        menu.addItem(withTitle: "主机列表", action: Selector(("showHostList:")), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "命令库", action: Selector(("showCommandLibrary:")), keyEquivalent: "k")
            .keyEquivalentModifierMask = [.command]
        menu.addItem(withTitle: "显示/隐藏侧栏", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .control]
        item.submenu = menu
        return item
    }

    private static func hostMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "主机")
        menu.addItem(withTitle: "新增主机…", action: Selector(("newHost:")), keyEquivalent: "n")
        menu.addItem(withTitle: "编辑所选主机…", action: Selector(("editSelectedHost:")), keyEquivalent: "")
        menu.addItem(withTitle: "创建副本", action: Selector(("duplicateSelectedHost:")), keyEquivalent: "")
        menu.addItem(withTitle: "删除所选主机", action: Selector(("deleteSelectedHost:")), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "测试连接", action: Selector(("testSelectedHost:")), keyEquivalent: "")
        menu.addItem(withTitle: "刷新指纹…", action: Selector(("refreshFingerprintSelectedHost:")), keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func editMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "编辑")
        menu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        addItem(menu, title: "查找…", tag: NSTextFinder.Action.showFindInterface.rawValue, keyEquivalent: "f")
        addItem(menu, title: "查找下一个", tag: NSTextFinder.Action.nextMatch.rawValue, keyEquivalent: "g")
        addItem(menu, title: "查找上一个", tag: NSTextFinder.Action.previousMatch.rawValue, keyEquivalent: "g")
            .keyEquivalentModifierMask = [.command, .shift]
        addItem(menu, title: "使用所选内容查找", tag: NSTextFinder.Action.setSearchString.rawValue, keyEquivalent: "e")
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
        let menu = NSMenu(title: "显示")
        menu.addItem(withTitle: "左右分屏…", action: Selector(("configureTerminalSplit:")), keyEquivalent: "d")
            .keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        let bigger = menu.addItem(withTitle: "放大字号", action: Selector(("adjustTerminalFontSize:")), keyEquivalent: "+")
        bigger.tag = 1
        let smaller = menu.addItem(withTitle: "缩小字号", action: Selector(("adjustTerminalFontSize:")), keyEquivalent: "-")
        smaller.tag = -1
        menu.addItem(withTitle: "恢复字号", action: Selector(("resetTerminalFontSize:")), keyEquivalent: "0")
        item.submenu = menu
        return item
    }

    private static func windowMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "窗口")
        menu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }
}
