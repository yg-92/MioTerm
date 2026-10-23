import Foundation
import MioTermCore
import SwiftTerm

/// 唯一比 `LocalProcessTerminalView` 多做的事：把即将发给远端的按键抄一份出来。
/// 文件面板要靠命令行判断“用户刚执行了什么”，而这些字节本来只往 stdin 走。
final class TrackingTerminalView: LocalProcessTerminalView {
    var onUserInput: ((ArraySlice<UInt8>) -> Void)?

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onUserInput?(data)
        super.send(source: source, data: data)
    }
}
