import Foundation

/// 文件面板双击的落点判定。
///
/// 双击要认「被双击的那一行」，不能认整个选区：选区里可能只剩目录，
/// 也可能因为列表刚重读过而和指针下那一行对不上。按选区走会弹「未选择文件」，
/// 从用户角度看就是双击没反应。
public enum FilePanelDoubleClick {
    public enum Action: Equatable {
        /// 目录：列表只显示一层，双击就是进去。
        case open(String)
        case download([SFTPFileEntry])
        case nothing
    }

    public static func decide(clicked: SFTPFileEntry?, selected: [SFTPFileEntry]) -> Action {
        guard let clicked else { return .nothing }
        if clicked.isDirectory { return .open(clicked.path) }
        let files = selected.filter { !$0.isDirectory }
        // 双击的那一行在选区里就整批下载，不在就只下它自己。
        return .download(files.contains(where: { $0.id == clicked.id }) ? files : [clicked])
    }
}
