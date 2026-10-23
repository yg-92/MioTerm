import AppKit
import MioTermCore

/// 标签页容器：一个终端会话对应一个标签。
/// 用 NSTabViewController 而不是自绘标签栏，是为了白拿 ⌘1..9 切换、
/// 键盘移动焦点等原生行为。
@MainActor
final class SessionTabViewController: NSTabViewController {
    private var environment: AppEnvironment { .shared }

    /// 外层要同时知道“选中了哪个会话”和“还剩几个标签”：
    /// 右侧欢迎页与左侧面板的切换都靠这一个回调。
    var onSessionsChange: ((TerminalController?) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .unspecified
        tabView.controlSize = .small
    }

    var selectedController: TerminalController? {
        guard selectedTabViewItemIndex >= 0, selectedTabViewItemIndex < tabViewItems.count else { return nil }
        return (tabViewItems[selectedTabViewItemIndex].viewController as? TerminalTabViewController)?.controller
    }

    var controllers: [TerminalController] {
        tabViewItems.compactMap { ($0.viewController as? TerminalTabViewController)?.controller }
    }

    var isEmpty: Bool { tabViewItems.isEmpty }

    func append(_ controller: TerminalController) {
        let item = NSTabViewItem(viewController: TerminalTabViewController(controller: controller))
        item.label = controller.title
        item.toolTip = controller.tooltip
        addTabViewItem(item)
        selectedTabViewItemIndex = tabViewItems.count - 1
        Self.setStatusIcon(on: item, state: controller.state)

        controller.onTitleChange = { [weak item] _ in item?.label = controller.title }
        controller.onStateChange = { [weak item] state in
            guard let item else { return }
            item.toolTip = controller.tooltip
            if state.isAlive {
                item.label = controller.title
            } else {
                // 会话结束后在标题上留后缀，一眼能看出哪个标签已经断了。
                item.label = "\(controller.title) — \(state.label)"
            }
            Self.setStatusIcon(on: item, state: state)
        }
        onSessionsChange?(controller)
    }

    /// NSTabViewItem 没有背景色可用，状态只能用图标表达。
    private static func setStatusIcon(on item: NSTabViewItem, state: TerminalController.State) {
        let symbol: String
        let color: NSColor
        switch state {
        case .starting: (symbol, color) = ("circle.dotted", .secondaryLabelColor)
        case .running: (symbol, color) = ("circle.fill", .systemGreen)
        case .failed: (symbol, color) = ("xmark.circle.fill", .systemRed)
        case .exited(let code?) where code != 0: (symbol, color) = ("exclamationmark.circle.fill", .systemYellow)
        case .exited: (symbol, color) = ("circle", .tertiaryLabelColor)
        case .idle: (symbol, color) = ("circle", .clear)
        }
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: state.label) else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        item.image = base.withSymbolConfiguration(configuration) ?? base
    }

    @discardableResult
    func closeSelectedTab() -> Bool {
        guard selectedTabViewItemIndex >= 0, selectedTabViewItemIndex < tabViewItems.count else { return false }
        let item = tabViewItems[selectedTabViewItemIndex]
        guard let tab = item.viewController as? TerminalTabViewController else { return false }
        tab.controller.stop()
        environment.unregister(tab.controller)
        let index = selectedTabViewItemIndex
        removeTabViewItem(item)
        if !tabViewItems.isEmpty {
            selectedTabViewItemIndex = min(index, tabViewItems.count - 1)
        }
        onSessionsChange?(selectedController)
        return true
    }

    func closeAll() {
        for controller in controllers {
            controller.stop()
            environment.unregister(controller)
        }
        for item in tabViewItems.reversed() { removeTabViewItem(item) }
        onSessionsChange?(nil)
    }

    func selectNextTab() {
        guard !tabViewItems.isEmpty else { return }
        selectedTabViewItemIndex = (selectedTabViewItemIndex + 1) % tabViewItems.count
    }

    func selectPreviousTab() {
        guard !tabViewItems.isEmpty else { return }
        let index = selectedTabViewItemIndex - 1
        selectedTabViewItemIndex = index < 0 ? tabViewItems.count - 1 : index
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let controller = (tabViewItem?.viewController as? TerminalTabViewController)?.controller else { return }
        controller.focus()
        onSessionsChange?(controller)
    }
}

/// 承载单个终端视图的标签内容控制器。
@MainActor
final class TerminalTabViewController: NSViewController {
    let controller: TerminalController

    init(controller: TerminalController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        controller.terminalView.frame = container.bounds
        controller.terminalView.autoresizingMask = [.width, .height]
        container.addSubview(controller.terminalView)
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        controller.focus()
    }
}
