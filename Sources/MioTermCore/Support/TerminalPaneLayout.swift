import Foundation

/// 两个可见槽位与当前输入会话；分屏后两个会话组成独立分组，切到组外会话时不会混入分组。
public struct TerminalPaneLayout {
    public struct SplitGroup: Equatable, Sendable {
        public let id: UUID
        public var primary: UUID
        public var secondary: UUID

        public init(id: UUID = UUID(), primary: UUID, secondary: UUID) {
            self.id = id
            self.primary = primary
            self.secondary = secondary
        }

        public func contains(_ sessionID: UUID) -> Bool {
            primary == sessionID || secondary == sessionID
        }
    }

    public private(set) var primary: UUID?
    public private(set) var secondary: UUID?
    public private(set) var selected: UUID?
    public private(set) var groups: [SplitGroup] = []

    public init() {}

    public var isSplit: Bool { secondary != nil }

    public func group(containing id: UUID) -> SplitGroup? {
        groups.first { $0.contains(id) }
    }

    public func groupID(for id: UUID) -> UUID? {
        group(containing: id)?.id
    }

    public mutating func select(_ id: UUID) {
        if let group = group(containing: id) {
            primary = group.primary
            secondary = group.secondary
        } else {
            primary = id
            secondary = nil
        }
        selected = id
    }

    public mutating func showHome() { selected = nil }

    public mutating func split(with id: UUID) {
        guard let selected, !isSplit, selected != id else { return }
        pair(selected, with: id)
    }

    /// 显式组合两个会话为一个分屏组；若任一方原属于其他组则先脱离旧组。
    public mutating func pair(_ primary: UUID, with secondary: UUID) {
        guard primary != secondary else { return }
        if let index = groups.firstIndex(where: { $0.contains(primary) && $0.contains(secondary) }) {
            groups[index].primary = primary
            groups[index].secondary = secondary
        } else {
            groups.removeAll { $0.contains(primary) || $0.contains(secondary) }
            groups.append(SplitGroup(primary: primary, secondary: secondary))
        }
        self.primary = primary
        self.secondary = secondary
        self.selected = secondary
    }

    /// 拖标签落屏：落点屏的会话留在原侧，被拖会话去另一侧。
    public mutating func drop(_ dragged: UUID, onto base: UUID, baseOnLeft: Bool) {
        guard dragged != base else { return }
        if baseOnLeft {
            pair(base, with: dragged)
        } else {
            pair(dragged, with: base)
        }
    }

    public mutating func unsplit() {
        let target = selected ?? primary
        if let target {
            groups.removeAll { $0.contains(target) }
        }
        primary = target
        secondary = nil
    }

    public mutating func remove(_ id: UUID) {
        if let index = groups.firstIndex(where: { $0.contains(id) }) {
            let group = groups.remove(at: index)
            let partner = group.primary == id ? group.secondary : group.primary
            if primary == id || secondary == id {
                primary = partner
                secondary = nil
            }
            if selected == id {
                selected = partner
            }
            return
        }
        if primary == id {
            primary = nil
            secondary = nil
        }
        if selected == id { selected = primary }
    }
}
