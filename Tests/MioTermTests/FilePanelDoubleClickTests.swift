import Foundation
import MioTermCore
import Testing

/// 双击文件树的落点。
/// 以前的实现按「整个选区」决定下载什么，选区里只剩目录时会弹「未选择文件」，
/// 从用户角度看就是双击没反应。
@Suite("文件面板双击判定")
struct FilePanelDoubleClickTests {
    private func file(_ path: String) -> SFTPFileEntry {
        SFTPFileEntry(path: path, name: (path as NSString).lastPathComponent,
                      isDirectory: false, size: 12, modifiedAt: nil)
    }

    private func directory(_ path: String) -> SFTPFileEntry {
        SFTPFileEntry(path: path, name: (path as NSString).lastPathComponent,
                      isDirectory: true, size: 0, modifiedAt: nil)
    }

    @Test func doubleClickingADirectoryEntersIt() {
        let action = FilePanelDoubleClick.decide(clicked: directory("/root/logs"), selected: [directory("/root/logs")])
        #expect(action == .open("/root/logs"))
    }

    @Test func doubleClickingASingleFileDownloadsIt() {
        let target = file("/root/a.txt")
        #expect(FilePanelDoubleClick.decide(clicked: target, selected: [target]) == .download([target]))
    }

    /// 多选里双击其中一个文件，整批一起下载。
    @Test func doubleClickInsideAMultiSelectionDownloadsTheWholeSelection() {
        let a = file("/root/a.txt")
        let b = file("/root/b.txt")
        #expect(FilePanelDoubleClick.decide(clicked: b, selected: [a, b]) == .download([a, b]))
    }

    /// 选区里全是目录时，双击的那个文件仍然要能下载，不能报「未选择文件」。
    @Test func doubleClickFallsBackToTheClickedFileWhenTheSelectionHasNoFiles() {
        let clicked = file("/root/a.txt")
        let action = FilePanelDoubleClick.decide(clicked: clicked, selected: [directory("/root/logs")])
        #expect(action == .download([clicked]))
    }

    /// 列表刚重读过、选区和指针下那一行对不上时，也只下双击的那个。
    @Test func doubleClickIgnoresAnUnrelatedSelection() {
        let clicked = file("/root/a.txt")
        let action = FilePanelDoubleClick.decide(clicked: clicked, selected: [file("/root/other.txt")])
        #expect(action == .download([clicked]))
    }

    @Test func doubleClickWithoutARowDoesNothing() {
        #expect(FilePanelDoubleClick.decide(clicked: nil, selected: []) == .nothing)
    }
}
