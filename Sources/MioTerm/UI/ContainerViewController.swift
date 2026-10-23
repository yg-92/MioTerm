import AppKit

/// 同一个槽位里换入不同的子控制器：左侧在主机列表与文件树之间切，
/// 右侧在欢迎页与终端标签之间切。
@MainActor
final class ContainerViewController: NSViewController {
    private(set) var current: NSViewController?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
    }

    func show(_ viewController: NSViewController) {
        guard viewController !== current else { return }
        // removeFromParent 只解父子关系，视图仍留在层级里；不摘掉就会和新的那层叠着画。
        current?.view.removeFromSuperview()
        current?.removeFromParent()
        addChild(viewController)
        let child = viewController.view
        child.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.topAnchor.constraint(equalTo: view.topAnchor),
            child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        current = viewController
    }
}
