import Foundation

/// 串口会话：打开 /dev/cu.* 设备，把 termios 原始字节流接到终端视图。
///
/// 与 Telnet 共用一个控制器的原因：界面上收发、状态、标题、设置热更新全都同构，
/// 区别只在“另一端是设备而不是网络”。
///
/// 打开设备可能耗时（驱动探测），因此放在并发队列上执行，结果再交回 engine 串行队列，
/// 状态与描述符因此不需要加锁。
public final class SerialStream: TerminalStream, @unchecked Sendable {
    /// 单次 read 的上限。串口速率有限，4KB 已经远快于人眼。
    private static let maximumReadLength = 4096

    private let stream: AsyncStream<StreamEvent>
    private let continuation: AsyncStream<StreamEvent>.Continuation
    public var events: AsyncStream<StreamEvent> { stream }

    private let configuration: SerialConfig
    /// 设备枚举在测试里换成假列表；生产走 SerialDevices.discover。
    private let deviceList: @Sendable () -> [String]
    private let engine = DispatchQueue(label: "mioTerm.serial.engine")
    private let openQueue = DispatchQueue(label: "mioTerm.serial.open", attributes: .concurrent)

    private var port: SerialPort?
    private var readSource: DispatchSourceRead?
    private var isClosed = false

    public init(configuration: SerialConfig, deviceList: @escaping @Sendable () -> [String] = { SerialDevices.discover() }) {
        self.configuration = configuration
        self.deviceList = deviceList
        let (stream, continuation) = AsyncStream.makeStream(of: StreamEvent.self)
        self.stream = stream
        self.continuation = continuation
    }

    public func start() async {
        let configuration = self.configuration
        let candidates = deviceList()
        let opened: (port: SerialPort?, failure: String?) = await withCheckedContinuation { box in
            openQueue.async {
                do {
                    // 先验形状再查枚举：放过 /dev/../etc/passwd 这类路径就等于把普通文件当终端读写，
                    // 提示也要比“设备不存在”更准确。
                    guard SerialDevices.isAcceptablePath(configuration.device) else {
                        throw SerialPort.SerialError.pathRejected(configuration.device)
                    }
                    guard SerialDevices.isAvailable(configuration.device, among: candidates) else {
                        throw SerialPort.SerialError.deviceMissing(configuration.device)
                    }
                    box.resume(returning: (try SerialPort.open(path: configuration.device, settings: configuration), nil))
                } catch {
                    box.resume(returning: (nil, error.localizedDescription))
                }
            }
        }
        await onEngine {
            guard !self.isClosed else {
                opened.port?.close()
                return
            }
            if let device = opened.port {
                self.adopt(device)
            } else {
                self.finish(with: .failed(opened.failure ?? "串口打开失败"))
            }
        }
    }

    public func write(_ data: Data) async {
        await onEngine { self.send(data) }
    }

    /// 串口没有窗口尺寸：设备那头是一个固定的控制台，不接收行列协商。
    public func resize(columns: Int, rows: Int) async {}

    public func sendBreak() async {
        await onEngine {
            guard let device = self.port, !self.isClosed else {
                self.continuation.yield(.notice("串口尚未连接，中断没有发出"))
                return
            }
            do {
                try device.sendBreak()
                self.continuation.yield(.notice("已发送串口中断（BREAK）"))
            } catch {
                self.continuation.yield(.notice(error.localizedDescription))
            }
        }
    }

    public func close() async {
        await onEngine { self.finish(with: nil) }
    }

    /// 把一段工作交给 engine 串行队列并等它跑完。用 withCheckedContinuation 而不是
    /// DispatchQueue 的 async 重载：后者在这个工具链上会退化成“投递即返回”。
    private func onEngine(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (box: CheckedContinuation<Void, Never>) in
            engine.async {
                work()
                box.resume()
            }
        }
    }

    // MARK: - engine 队列内部

    private func adopt(_ device: SerialPort) {
        port = device
        continuation.yield(.connected)
        let source = DispatchSource.makeReadSource(fileDescriptor: device.descriptor, queue: engine)
        source.setEventHandler { [weak self] in self?.drain() }
        // 描述符只在取消处理器里关一次：提前 close 会让内核复用同号描述符。
        source.setCancelHandler { device.close() }
        readSource = source
        source.resume()
    }

    private func drain() {
        guard let device = port, !isClosed else { return }
        while true {
            let chunk: SerialPort.ReadResult
            do {
                chunk = try device.read(maximumCount: Self.maximumReadLength)
            } catch {
                finish(with: .failed(error.localizedDescription))
                return
            }
            switch chunk {
            case .bytes(let bytes):
                continuation.yield(.data(bytes))
                if isClosed { return }
            case .wouldBlock:
                return
            case .ended(let reason):
                finish(with: .closed(reason: reason ?? "串口已断开"))
                return
            }
        }
    }

    private func send(_ data: Data) {
        guard let device = port, !isClosed else { return }
        let encoded = configuration.encodeInput(data)
        guard !encoded.isEmpty else { return }
        do {
            try device.write(encoded)
        } catch {
            finish(with: .failed(error.localizedDescription))
            return
        }
        // 控制台设备通常不回显自己收到的字节，勾上本地回显才能看见在敲什么。
        if configuration.localEcho, !isClosed { continuation.yield(.data(encoded)) }
    }

    /// 唯一的收尾路径：先投最后一枚事件，再关描述符并结束事件流。
    private func finish(with event: StreamEvent?) {
        guard !isClosed else { return }
        isClosed = true
        if let event { continuation.yield(event) }
        continuation.finish()
        readSource?.cancel()
        readSource = nil
        port = nil
    }
}
