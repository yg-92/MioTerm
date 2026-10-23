import AppKit

/// 左侧面板：主机列表与远端文件树共用一个槽位。
/// 没会话时看主机，进入主机后看文件，切换由会话状态驱动，也允许手动切。
@MainActor
final class SidePanelViewController: NSViewController {
    enum Mode: Int {
        case hosts = 0
        case files = 1
    }

    let hosts = HostSidebarViewController(repository: AppEnvironment.shared.hosts)
    let files = SFTPBrowserViewController()

    private let switcher = NSSegmentedControl(labels: ["主机", "文件"], trackingMode: .selectOne, target: nil, action: nil)
    private let content = ContainerViewController()
    private var autoSwitchedFor: UUID?
    private(set) var mode: Mode = .hosts

    override func loadView() {
        switcher.target = self
        switcher.action = #selector(switcherChanged(_:))
        switcher.segmentStyle = .capsule
        switcher.controlSize = .small
        switcher.selectedSegment = mode.rawValue
        switcher.setEnabled(false, forSegment: Mode.files.rawValue)
        switcher.translatesAutoresizingMaskIntoConstraints = false

        addChild(content)
        let contentRoot = content.view
        contentRoot.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 620))
        root.addSubview(switcher)
        root.addSubview(contentRoot)
        NSLayoutConstraint.activate([
            switcher.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            switcher.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            switcher.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -10),
            contentRoot.topAnchor.constraint(equalTo: switcher.bottomAnchor, constant: 6),
            contentRoot.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentRoot.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentRoot.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        // 若 bind(to:) 先于视图加载跑过，这里要按当前 mode 复原，否则分段控件和内容会错位。
        content.show(mode == .hosts ? hosts : files)
        view = root
    }

    /// 当前标签是否是能用文件面板的 SSH 会话。
    static func supportsFiles(_ controller: TerminalController?) -> Bool {
        controller?.host?.protocolKind.supportsSFTP == true
    }

    func bind(to controller: TerminalController?) {
        let canBrowse = Self.supportsFiles(controller)
        switcher.setEnabled(canBrowse, forSegment: Mode.files.rawValue)
        if !canBrowse {
            autoSwitchedFor = nil
            files.bind(to: nil)
            select(.hosts)
            return
        }
        guard let controller else { return }
        files.bind(to: controller)
        // 只在换会话时自动跳到文件视图，手动点回主机不该被抢回去。
        if autoSwitchedFor != controller.sessionID {
            autoSwitchedFor = controller.sessionID
            select(.files)
        }
    }

    @objc private func switcherChanged(_ sender: NSSegmentedControl) {
        select(Mode(rawValue: sender.selectedSegment) ?? .hosts)
    }

    func select(_ mode: Mode) {
        guard mode != self.mode else { return }
        self.mode = mode
        switcher.selectedSegment = mode.rawValue
        content.show(mode == .hosts ? hosts : files)
    }

    func showHosts() {
        autoSwitchedFor = nil
        select(.hosts)
    }
}
