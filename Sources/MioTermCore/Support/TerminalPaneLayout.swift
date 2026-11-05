import Foundation

/// 两个可见槽位与当前输入会话；主页只隐藏槽位，不结束其中的会话。
public struct TerminalPaneLayout {
    public private(set) var primary: UUID?
    public private(set) var secondary: UUID?
    public private(set) var selected: UUID?

    public init() {}

    public var isSplit: Bool { secondary != nil }

    public mutating func select(_ id: UUID) {
        if id != primary && id != secondary {
            if secondary != nil && selected == secondary {
                secondary = id
            } else {
                primary = id
            }
        }
        selected = id
    }

    public mutating func showHome() { selected = nil }

    public mutating func split(with id: UUID) {
        guard let selected, !isSplit, selected != id else { return }
        pair(selected, with: id)
    }

    /// 显式组合两个会话；也用于替换已有分屏组合，不依赖异步连接结束时的焦点。
    public mutating func pair(_ primary: UUID, with secondary: UUID) {
        guard primary != secondary else { return }
        self.primary = primary
        self.secondary = secondary
        selected = secondary
    }

    public mutating func unsplit() {
        primary = selected ?? primary
        secondary = nil
    }

    public mutating func remove(_ id: UUID) {
        if primary == id {
            primary = secondary
            secondary = nil
        } else if secondary == id {
            secondary = nil
        }
        if selected == id { selected = primary }
    }
}
