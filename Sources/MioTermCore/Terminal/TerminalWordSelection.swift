import AppKit
import SwiftTerm

/// 终端双击选词扩展：把路径分隔符、波浪号与常见文件令牌字符纳入同一个可双击选中的整体，
/// 并支持跨宽字符（中文等双列字符）与软折行（长路径折到下一行）连续选中。
public enum TerminalWordSelection {
    /// 属于同一条路径或标识符的字符集合。
    /// 保留空格、冒号、等号、引号、括号与提示符结尾（`$ # % >`）作为边界，
    /// 这样无论双击 `pwd` 输出的整行路径，还是双击 `root@host:/var/log/nginx#` 里的路径段，
    /// 都能精准选中完整路径而不会把提示符前缀吞进来。
    public static func isWordOrPathCharacter(_ ch: Character) -> Bool {
        if ch.isLetter || ch.isNumber { return true }
        switch ch {
        case "/", ".", "_", "-", "~", "+", "@":
            return true
        default:
            return false
        }
    }

    /// 给定终端缓冲里的起始点，向左右（含软折行与双宽字符续格）扩展出完整路径/单词区间。
    public static func expandSpan(in terminal: Terminal, from seed: Position) -> (start: Position, end: Position)? {
        let cols = terminal.cols
        guard cols > 0 else { return nil }
        let buffer = terminal.buffer
        let trimmed = buffer.totalLinesTrimmed

        func bufferLine(at row: Int) -> BufferLine? {
            terminal.getScrollInvariantLine(row: row + trimmed)
        }

        func cellCharacter(in line: BufferLine, col: Int) -> Character {
            guard col >= 0, col < line.count else { return Character(UnicodeScalar(0)) }
            return terminal.getCharacter(for: line[col])
        }

        func cellWidth(in line: BufferLine, col: Int) -> Int {
            guard col >= 0, col < line.count else { return 1 }
            return line.getWidth(index: col)
        }

        guard let initialLine = bufferLine(at: seed.row) else { return nil }
        var startRow = seed.row
        var startCol = min(max(0, seed.col), cols - 1)
        // 点在双宽字符的右半格（width == 0）时，先退回左半格再取字符。
        if startCol > 0, cellWidth(in: initialLine, col: startCol) == 0 {
            startCol -= 1
        }
        guard isWordOrPathCharacter(cellCharacter(in: initialLine, col: startCol)) else {
            return nil
        }

        var endRow = startRow
        var endCol = min(cols, startCol + max(1, cellWidth(in: initialLine, col: startCol)))

        // 向左扫描（含跨软折行向上一行尾回溯）
        while true {
            guard let line = bufferLine(at: startRow) else { break }
            if startCol > 0 {
                var prevCol = startCol - 1
                if prevCol > 0, cellWidth(in: line, col: prevCol) == 0 {
                    prevCol -= 1
                }
                if isWordOrPathCharacter(cellCharacter(in: line, col: prevCol)) {
                    startCol = prevCol
                    continue
                }
                break
            }
            // 已到行首：若本行是上一行软折行过来的，继续检查上一行末尾。
            guard line.isWrapped, startRow > 0, let prevLine = bufferLine(at: startRow - 1) else {
                break
            }
            var prevCol = cols - 1
            if prevCol > 0, cellWidth(in: prevLine, col: prevCol) == 0 {
                prevCol -= 1
            }
            if isWordOrPathCharacter(cellCharacter(in: prevLine, col: prevCol)) {
                startRow -= 1
                startCol = prevCol
                continue
            }
            break
        }

        // 向右扫描（含跨软折行向下一行首延伸）
        while true {
            guard let line = bufferLine(at: endRow) else { break }
            if endCol < cols {
                if isWordOrPathCharacter(cellCharacter(in: line, col: endCol)) {
                    let step = max(1, cellWidth(in: line, col: endCol))
                    endCol = min(cols, endCol + step)
                    continue
                }
                break
            }
            // 已到行尾：若下一行是软折行延续，继续检查下一行首格。
            guard let nextLine = bufferLine(at: endRow + 1), nextLine.isWrapped else {
                break
            }
            if isWordOrPathCharacter(cellCharacter(in: nextLine, col: 0)) {
                endRow += 1
                let step = max(1, cellWidth(in: nextLine, col: 0))
                endCol = min(cols, step)
                continue
            }
            break
        }

        let start = Position(col: startCol, row: startRow)
        let end: Position
        // SelectionService.setSelection 在非 exclusiveEnd 模式下会把 end.col 夹到 cols - 1，
        // 而 Terminal._getSelectedLines 在同行时把 end.col 当作开区间上界。
        // 与 SwiftTerm 内部 SearchService 一致，刚好停在行尾时把终点落到下一行第 0 列。
        if endCol >= cols, bufferLine(at: endRow + 1) != nil {
            end = Position(col: 0, row: endRow + 1)
        } else {
            end = Position(col: endCol, row: endRow)
        }
        return (start, end)
    }

    /// 在持有 `terminalLock` 的前提下，把双击产生的选区扩展为完整路径或令牌。
    public static func expandSelection(in terminal: Terminal, selection: SelectionService) {
        guard let span = expandSpan(in: terminal, from: selection.start) else { return }
        selection.selectionMode = .character
        selection.pivot = span.start
        selection.setSelection(start: span.start, end: span.end)
    }

    /// 从 `TerminalView` 反射取出其内部的 `SelectionService`（创建后生命周期与视图一致，可由调用方缓存）。
    public static func selectionService(in view: TerminalView) -> SelectionService? {
        var mirror: Mirror? = Mirror(reflecting: view)
        while let current = mirror {
            for child in current.children where child.label == "selection" {
                if let service = child.value as? SelectionService {
                    return service
                }
            }
            mirror = current.superclassMirror
        }
        return nil
    }
}
