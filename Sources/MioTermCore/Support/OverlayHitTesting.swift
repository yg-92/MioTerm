import CoreGraphics

/// 自绘控件的命中判定。
///
/// AppKit 传给 `hitTest(_:)` 的点在**父视图**坐标系里，不是自己的 bounds 坐标系。
/// 拿 `bounds.contains(point)` 判定会永远不命中，于是点击落到父视图上；父视图若
/// 不实现 `mouseDown`，从用户角度看就是「这个按钮点了没反应」。断线提示条上的
/// 「重新连接」正是这样死的。
public enum OverlayHitTesting {
    /// - Parameters:
    ///   - point: `hitTest(_:)` 收到的点，父视图坐标系。
    ///   - frame: 视图在父视图里的 frame，与 point 同一个坐标系。
    public static func contains(_ point: CGPoint, frame: CGRect) -> Bool {
        frame.contains(point)
    }

    /// 松开鼠标时判断落点还在不在控件里：拖出去再松手不该算一次点击。
    /// `locationInWindow` 经 `convert(_:from: nil)` 换算后就是控件自己的坐标系，
    /// 这里比的才是 bounds——两个坐标系别混用。
    public static func containsInBounds(_ pointInSelf: CGPoint, bounds: CGRect) -> Bool {
        bounds.contains(pointInSelf)
    }
}
