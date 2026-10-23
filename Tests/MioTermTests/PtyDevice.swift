import Foundation
@testable import MioTermCore

/// 伪终端对：串口测试不需要真设备。`openpty` 给出的 /dev/ttysNNN 同样是一块
/// 走 termios 的字符设备，参数设置、换行改写、回显与 BREAK 都能在它上面验证，
/// 而且不会碰用户插着的开发板（打开真串口可能让板子复位）。
final class PtyDevice: @unchecked Sendable {
    let path: String
    let master: Int32
    /// 从端留一个描述符不关：伪终端的从端节点在两侧都关闭后消失。
    private let slave: Int32
    private let lock = NSLock()
    private var closed = false

    /// 打开失败返回 nil：CI 上可能没有可用的伪终端编号，测试直接跳过而不是误报协议错。
    init?() {
        var master: Int32 = 0
        var slave: Int32 = 0
        var name = [Int8](repeating: 0, count: 128)
        guard openpty(&master, &slave, &name, nil, nil) == 0 else { return nil }
        self.master = master
        self.slave = slave
        self.path = String(cString: name)
        // 主端非阻塞：读不到就立刻返回，免得测试卡在无人写入的终端上。
        let current = fcntl(master, F_GETFL, 0)
        _ = fcntl(master, F_SETFL, current | O_NONBLOCK)
    }

    /// 从设备外侧送进输入队列，等同于对方发来的字节。
    func sendToTerminal(_ data: Data) {
        data.withUnsafeBytes { raw in
            _ = Darwin.write(master, raw.baseAddress, raw.count)
        }
    }

    /// 设备这一侧写到线上的全部字节（终端的输出）。一次调用把当前可读的取干净。
    func receivedFromTerminal() -> Data {
        var bytes = Data()
        while true {
            var buffer = [UInt8](repeating: 0, count: 1024)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(master, $0.baseAddress, $0.count) }
            if count > 0 {
                bytes.append(contentsOf: buffer[0..<count])
                continue
            }
            if count < 0, errno == EINTR { continue }
            return bytes
        }
    }

    /// 等设备这一侧产出足量字节；伪终端是异步的，写下去不一定立刻能读。
    func waitForOutput(minimumCount: Int, timeout: TimeInterval = 2) -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var collected = Data()
        while Date() < deadline {
            collected.append(receivedFromTerminal())
            if collected.count >= minimumCount { return collected }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return collected
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            Darwin.close(master)
            Darwin.close(slave)
        }
    }
}
