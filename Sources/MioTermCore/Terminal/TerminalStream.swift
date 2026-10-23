import Foundation

/// 字节流会话的事件。约定与 SSH 子进程会话一致：所有事件由传输层在后台线程投递，
/// 由界面层负责切回主线程。
public enum StreamEvent: Sendable, Equatable {
    /// 连接已建立，可以开始收发。
    case connected
    /// 净负载：协议协商字节已经剥掉，直接喂给终端即可。
    case data(Data)
    /// 协议层提示，例如协商到一半对端不支持某选项。不改变连接状态。
    case notice(String)
    /// 对端正常关闭，reason 为 nil；异常结束时给出中文原因。
    case closed(reason: String?)
    /// 连接没能建立，或建立后出错；这是终态。
    case failed(String)
}

/// 不依赖子进程的终端管道：Telnet 走 TCP，串口走 termios。
/// 之所以要一层抽象，是因为界面侧的收发、状态机、标签标题对这些连接完全同构。
public protocol TerminalStream: Sendable {
    /// 事件流在对象生命周期内只创建一次，多次读取会各自拿到独立迭代器。
    var events: AsyncStream<StreamEvent> { get }

    /// 建立连接。结果与后续数据都通过 events 上报，本方法不抛错。
    func start() async

    /// 发送用户键入的原始字节；传输层负责协议要求的转义与协商。
    func write(_ data: Data) async

    /// 终端尺寸变化。对 Telnet 是 NAWS，对串口没有意义，实现自行忽略即可。
    func resize(columns: Int, rows: Int) async

    /// 主动断开；幂等。
    func close() async

    /// 串口特有的 BREAK 信号（拉低发送线唤出控制台）。
    /// 其他通道没有对应动作，默认什么也不做，界面因此可以无条件提供这个命令。
    func sendBreak() async
}

public extension TerminalStream {
    func sendBreak() async {}
}
