import AppKit

/// 没有任何会话时的右侧占位页：把常用入口摆在眼前，省得去菜单里翻。
/// 按钮不设 target，动作沿响应链落到 WorkspaceViewController。
@MainActor
final class WelcomeViewController: NSViewController {
    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        view = root

        let title = NSTextField(labelWithString: "MioTerm")
        title.font = .systemFont(ofSize: 30, weight: .semibold)
        title.alignment = .center

        let subtitle = NSTextField(labelWithString: "选择左侧主机回车连接，或直接开一个本地终端")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 2

        let actions = NSStackView(views: [
            button("新建本地终端", #selector(WorkspaceViewController.newLocalTerminal(_:))),
            button("连接所选主机", #selector(WorkspaceViewController.connectSelectedHost(_:))),
            button("新增主机…", #selector(WorkspaceViewController.newHost(_:))),
            button("设置…", #selector(WorkspaceViewController.showPreferences(_:))),
        ])
        actions.orientation = .vertical
        actions.alignment = .centerX
        actions.spacing = 8

        let stack = NSStackView(views: [title, subtitle, actions])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -30),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            actions.widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
        ])
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: nil, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }
}
