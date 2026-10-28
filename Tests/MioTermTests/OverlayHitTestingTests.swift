import AppKit
import MioTermCore
import Testing

/// 断线提示条上那颗自绘「重新连接」的命中判定。
///
/// 这颗按钮曾经完全点不动：`hitTest(_:)` 收到的点在**父视图**坐标系里，
/// 却拿去和 `bounds`（原点 0,0）比，永远不命中，点击落到不处理 `mouseDown`
/// 的横幅上。界面看不出任何异常，也没有测试拦得住。
@MainActor
@Suite("断线提示条按钮命中判定")
struct OverlayHitTestingTests {
    /// 提示条与按钮的真实尺寸：横幅 360×38，按钮 96×24、右内缩 8、垂直居中。
    private let bannerFrame = CGRect(x: 0, y: 0, width: 360, height: 38)
    private let buttonFrame = CGRect(x: 256, y: 7, width: 96, height: 24)

    @Test func hitsWhereTheButtonActuallyIs() {
        // 正中间、四条边内侧都该算命中。
        #expect(OverlayHitTesting.contains(CGPoint(x: 304, y: 19), frame: buttonFrame))
        #expect(OverlayHitTesting.contains(CGPoint(x: 257, y: 8), frame: buttonFrame))
        #expect(OverlayHitTesting.contains(CGPoint(x: 351, y: 30), frame: buttonFrame))
    }

    @Test func missesTheRestOfTheBanner() {
        // 横幅左侧的图标与文字、按钮右外侧那 8pt 都不该触发重连。
        #expect(!OverlayHitTesting.contains(CGPoint(x: 12, y: 19), frame: buttonFrame))
        #expect(!OverlayHitTesting.contains(CGPoint(x: 356, y: 19), frame: buttonFrame))
        #expect(!OverlayHitTesting.contains(CGPoint(x: 304, y: 2), frame: buttonFrame))
    }

    /// 旧写法为什么是错的：同一个点，比 bounds 就不命中。
    @Test func comparingAgainstBoundsNeverHits() {
        let point = CGPoint(x: 304, y: 19)
        let bounds = CGRect(origin: .zero, size: buttonFrame.size)
        #expect(!bounds.contains(point))
        #expect(OverlayHitTesting.contains(point, frame: buttonFrame))
    }

    /// 在真实的视图层级里走一遍 AppKit 的命中测试：
    /// 用 frame 判定的子视图能吃到点击，用 bounds 判定的那一份只会把点击让给横幅。
    @Test func clickReachesTheButtonInARealHierarchy() {
        let clickPoint = CGPoint(x: 304, y: 19)
        #expect(bannerFrame.contains(clickPoint))

        let good = Probe(frame: buttonFrame) { point, view in
            OverlayHitTesting.contains(point, frame: view.frame)
        }
        let goodBanner = NSView(frame: bannerFrame)
        goodBanner.addSubview(good)
        #expect(goodBanner.hitTest(clickPoint) === good)

        let bad = Probe(frame: buttonFrame) { point, view in
            view.bounds.contains(point)
        }
        let badBanner = NSView(frame: bannerFrame)
        badBanner.addSubview(bad)
        // 按钮不认领，横幅自己兜住这次点击——而横幅不实现 mouseDown，于是毫无反应。
        #expect(badBanner.hitTest(clickPoint) === badBanner)
    }

    /// 松手时落点还在不在控件里：这里的点是控件自己的坐标系，比的才是 bounds。
    @Test func releaseOutsideDoesNotFire() {
        let bounds = CGRect(origin: .zero, size: buttonFrame.size)
        #expect(OverlayHitTesting.containsInBounds(CGPoint(x: 48, y: 12), bounds: bounds))
        // 按下后往左拖到横幅文字上再松手，不该把会话重连了。
        #expect(!OverlayHitTesting.containsInBounds(CGPoint(x: -60, y: 12), bounds: bounds))
    }

    private final class Probe: NSView {
        private let rule: (CGPoint, NSView) -> Bool
        init(frame: CGRect, rule: @escaping (CGPoint, NSView) -> Bool) {
            self.rule = rule
            super.init(frame: frame)
        }
        required init?(coder: NSCoder) { fatalError("不使用 xib") }
        override func hitTest(_ point: NSPoint) -> NSView? {
            rule(point, self) ? self : nil
        }
    }
}
