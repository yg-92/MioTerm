import AppKit
import MioTermCore
import SwiftTerm
import Testing

@MainActor
@Suite("终端双击整段路径选中")
struct TerminalWordSelectionTests {
    private final class State: @unchecked Sendable {
        var pendingDoubleClick = false
        weak var cachedSelection: SelectionService?
    }

    private final class TestableTerminalView: TerminalView {
        private let state = State()

        override func mouseDown(with event: NSEvent) {
            state.pendingDoubleClick = event.clickCount == 2
            super.mouseDown(with: event)
            state.pendingDoubleClick = false
        }

        nonisolated override func selectionChanged(source: Terminal) {
            if state.pendingDoubleClick {
                state.pendingDoubleClick = false
                let selection = state.cachedSelection ?? {
                    let resolved = TerminalWordSelection.selectionService(in: self)
                    state.cachedSelection = resolved
                    return resolved
                }()
                if let selection {
                    TerminalWordSelection.expandSelection(in: source, selection: selection)
                }
            }
            super.selectionChanged(source: source)
        }

        func selectPathAt(col: Int, row: Int) {
            guard let selection = TerminalWordSelection.selectionService(in: self) else { return }
            selection.setSelection(start: Position(col: col, row: row), end: Position(col: col + 1, row: row))
            state.pendingDoubleClick = true
            // 通过 selectionChanged 走同一条扩展链路：selection.setSelection 内部会触发 selectionChanged。
            selection.setSelection(start: Position(col: col, row: row), end: Position(col: col + 1, row: row))
        }
    }

    private func makeView(width: CGFloat = 640, height: CGFloat = 320) -> TestableTerminalView {
        TestableTerminalView(
            frame: NSRect(x: 0, y: 0, width: width, height: height),
            font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            options: TerminalOptions()
        )
    }

    @Test("双击 pwd 输出的任一段或斜杠都选中整条路径")
    func doubleClickSelectsFullPwdPath() {
        let view = makeView()
        let path = "/Users/yanggang/workspace/mioTerm/Sources/MioTerm"
        view.feed(text: "\(path)\r\n")

        // 双击中间某个单词（workspace）
        view.selectPathAt(col: 18, row: 0)
        #expect(view.getSelection() == path)

        // 直接双击斜杠分隔符 '/'
        view.selectPathAt(col: 15, row: 0)
        #expect(view.getSelection() == path)
    }

    @Test("双击提示符里的路径只选中路径本身，不吞入主机名和结尾符号")
    func doubleClickInPromptSelectsOnlyThePath() {
        let view = makeView()
        view.feed(text: "root@kylin-node:/var/lib/docker/overlay2# ")

        // 双击 /var/lib/docker/overlay2 中的 docker
        view.selectPathAt(col: 26, row: 0)
        #expect(view.getSelection() == "/var/lib/docker/overlay2")

        // 双击 root@kylin-node 选中用户与主机段
        view.selectPathAt(col: 6, row: 0)
        #expect(view.getSelection() == "root@kylin-node")
    }

    @Test("双击含中文双宽字符的路径也能完整选中")
    func doubleClickSelectsPathWithCJKCharacters() {
        let view = makeView()
        let path = "/Users/yanggang/文档/项目/mioTerm"
        view.feed(text: "\(path)\r\n")

        view.selectPathAt(col: 17, row: 0)
        #expect(view.getSelection() == path)
    }

    @Test("超长路径跨行软折行后双击依然整条选中")
    func doubleClickSelectsSoftWrappedLongPath() {
        let view = makeView(width: 240, height: 200)
        let longPath = "/var/lib/docker/overlay2/8f3a1b2c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e/merged/usr/local/share"
        view.feed(text: "\(longPath)\r\n")

        // 在第一行双击，应连同折到后续行的路径一并选中
        view.selectPathAt(col: 5, row: 0)
        #expect(view.getSelection() == longPath)

        // 在折行后的第二行双击，也应向前回溯选中整条路径
        view.selectPathAt(col: 3, row: 1)
        #expect(view.getSelection() == longPath)
    }
}
