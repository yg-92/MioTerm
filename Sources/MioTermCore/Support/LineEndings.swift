import Foundation

/// 键入的换行改写。终端与串口对端要求的分隔符各不相同，而键盘、粘贴、
/// 脚本能送来的换行形态有三种，所以统一先收成 LF 再展开，避免 CRLF 变成两个 CR。
extension Data {
    /// CR、LF、CRLF 一律收成单个 LF。
    func normalizingLineEndingsToLF() -> Data {
        var value = Data()
        value.reserveCapacity(count)
        var index = startIndex
        while index < endIndex {
            let byte = self[index]
            switch byte {
            case 0x0D:
                value.append(0x0A)
                // 后面已经跟了 LF 就一并吃掉，免得展开时多出一种换行。
                if index + 1 < endIndex, self[index + 1] == 0x0A { index += 1 }
            case 0x0A:
                value.append(0x0A)
            default:
                value.append(byte)
            }
            index += 1
        }
        return value
    }

    /// 把每个 LF 换成给定分隔符，其余字节原样通过。
    func expandingLineFeeds(to separator: Data) -> Data {
        guard contains(0x0A) else { return self }
        var value = Data()
        value.reserveCapacity(count + separator.count)
        for byte in self {
            if byte == 0x0A {
                value.append(contentsOf: separator)
            } else {
                value.append(byte)
            }
        }
        return value
    }
}
