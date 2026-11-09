import AppKit

/// 拖标签到终端画面的落点：未分屏时整块画面是一个落点。
enum TerminalTabDropSide {
    case left, right, single
}

/// 两个持久槽位共享可拖动分隔带，切标签时保留分隔比例。
@MainActor
final class TerminalSplitViewController: NSViewController, NSSplitViewDelegate {
    let splitView = TerminalPaneSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
    private let left = ContainerViewController()
    private let right = ContainerViewController()
    private var primary: NSViewController?
    private var secondary: NSViewController?

    override func loadView() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.registerForDraggedTypes([SessionTabBarView.dragType])
        view = splitView
        addChild(left)
        splitView.addArrangedSubview(left.view)
    }

    func clear() {
        left.clear()
        right.clear()
        right.view.removeFromSuperview()
        right.removeFromParent()
        primary = nil
        secondary = nil
        splitView.adjustSubviews()
    }

    func show(primary: NSViewController, secondary: NSViewController?) {
        _ = view
        guard primary !== self.primary || secondary !== self.secondary else { return }
        let wasSplit = self.secondary != nil
        // 先摘下两边，右侧提升到左侧时，同一个会话不会同时属于两个容器。
        left.clear()
        right.clear()
        self.primary = primary
        self.secondary = secondary
        if let secondary {
            if !wasSplit {
                addChild(right)
                splitView.addArrangedSubview(right.view)
            }
            left.show(primary)
            right.show(secondary)
            if !wasSplit {
                splitView.adjustSubviews()
                splitView.setPosition((splitView.bounds.width - splitView.dividerThickness) / 2, ofDividerAt: 0)
            }
        } else {
            right.view.removeFromSuperview()
            right.removeFromParent()
            left.show(primary)
            splitView.adjustSubviews()
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(proposedMinimumPosition, 160)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(proposedMaximumPosition, max(160, splitView.bounds.width - splitView.dividerThickness - 160))
    }
}

/// 留出独立的中性分隔带；整条带都能拖动，不靠活动窗格的外框制造边界。
/// 同时是标签拖拽的落点：拖到左/右屏就把被拖会话与该屏组合分屏。
@MainActor
final class TerminalPaneSplitView: NSSplitView {
    var onTabDropHint: ((UUID, TerminalTabDropSide) -> String?)?
    var onTabDropPerform: ((UUID, TerminalTabDropSide) -> Bool)?
    var onTabDropHighlight: ((TerminalTabDropSide, String) -> Void)?
    var onTabDropHide: (() -> Void)?

    override var dividerThickness: CGFloat { 9 }
    private var dividerHovered = false
    private var hoverTracking: NSTrackingArea?

    override func drawDivider(in rect: NSRect) {
        (dividerHovered ? Theme.surfaceRaised : Theme.background).setFill()
        rect.fill()
        (dividerHovered ? Theme.accent.withAlphaComponent(0.55) : Theme.borderStrong).setFill()
        NSRect(x: floor(rect.midX), y: rect.minY, width: 1, height: rect.height).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hovered = subviews.count == 2 && point.x >= subviews[0].frame.maxX && point.x < subviews[1].frame.minX
        if hovered != dividerHovered {
            dividerHovered = hovered
            needsDisplay = true
        }
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        dividerHovered = false
        needsDisplay = true
        super.mouseExited(with: event)
    }

    // MARK: 标签拖拽落点

    private func tabDrop(_ sender: NSDraggingInfo) -> (id: UUID, side: TerminalTabDropSide)? {
        guard sender.draggingSource is SessionTabChip,
              let raw = sender.draggingPasteboard.string(forType: SessionTabBarView.dragType),
              let id = UUID(uuidString: raw) else { return nil }
        let point = convert(sender.draggingLocation, from: nil)
        let side: TerminalTabDropSide
        if subviews.count >= 2 {
            side = point.x < subviews[0].frame.maxX ? .left : .right
        } else {
            side = .single
        }
        return (id, side)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let drop = tabDrop(sender), let hint = onTabDropHint?(drop.id, drop.side) else {
            onTabDropHide?()
            return []
        }
        onTabDropHighlight?(drop.side, hint)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onTabDropHide?() }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let drop = tabDrop(sender) else { return false }
        return onTabDropHint?(drop.id, drop.side) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTabDropHide?()
        guard let drop = tabDrop(sender) else { return false }
        return onTabDropPerform?(drop.id, drop.side) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { onTabDropHide?() }
}
