import Foundation

/// 一个打开的串口：termios 参数、非阻塞读写、BREAK 与调制解调器信号线。
///
/// 一律配成原始模式（无回显、非规范、不解释信号、无 XON/XOFF 流控），
/// 因为串口对端是单片机或交换机控制台，任何本地加工都会把字节流搅乱。
public struct SerialPort: Sendable {
    public enum ReadResult: Equatable {
        case bytes(Data)
        /// 暂时没数据，等下一次可读通知。
        case wouldBlock
        /// 设备不再可读写（多为 USB 串口被拔出），带中文原因。
        case ended(String?)
    }

    public enum SerialError: LocalizedError, Equatable {
        case pathRejected(String)
        case deviceMissing(String)
        case openFailed(String, String)
        case modeFailed(String, String)
        case parityUnsupported(String, String)
        case stopBitsUnsupported(String, String)
        case baudRateUnsupported(String, Int)
        case writeFailed(String, String)
        case readFailed(String, String)
        case breakFailed(String, String)

        public var errorDescription: String? {
            switch self {
            case .pathRejected(let device):
                return "串口设备名无效：\(device)。只允许 /dev/ 下的设备路径。"
            case .deviceMissing(let device):
                return "串口 \(device) 不存在或未被系统识别，请刷新设备列表。"
            case .openFailed(let device, let reason):
                return "打开串口 \(device) 失败（请检查是否被其他程序占用、驱动与权限）：\(reason)"
            case .modeFailed(let device, let reason):
                return "配置串口 \(device) 参数失败：\(reason)"
            case .parityUnsupported(let device, let parity):
                return "串口 \(device) 的驱动不支持 \(parity) 校验，请改用无、奇或偶校验。"
            case .stopBitsUnsupported(let device, let stopBits):
                return "串口 \(device) 的驱动不支持 \(stopBits) 停止位，请改用 1 或 2。"
            case .baudRateUnsupported(let device, let baudRate):
                return "串口 \(device) 不支持 \(baudRate) 波特率，请改用驱动支持的速率。"
            case .writeFailed(let device, let reason):
                return "串口 \(device) 发送失败：\(reason)"
            case .readFailed(let device, let reason):
                return "串口 \(device) 读取失败：\(reason)"
            case .breakFailed(let device, let reason):
                return "串口 \(device) 发送中断失败：\(reason)"
            }
        }
    }

    /// 单次 write 等待可写的上限。tty 写通常立即返回，留超时是为了对端流控拉死时不钉住线程。
    public var writeTimeout: TimeInterval = 10

    public let descriptor: Int32
    public let path: String

    public init(descriptor: Int32, path: String) {
        self.descriptor = descriptor
        self.path = path
    }

    /// 打开并配置设备。失败时不留下已打开的描述符，免得用户重试时撞 EBUSY。
    public static func open(path: String, settings: SerialConfig) throws -> SerialPort {
        guard SerialDevices.isAcceptablePath(path) else { throw SerialError.pathRejected(path) }
        let descriptor = Darwin.open(path, O_RDWR | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw SerialError.openFailed(path, String(cString: strerror(errno)))
        }
        let port = SerialPort(descriptor: descriptor, path: path)
        do {
            try port.apply(settings)
        } catch {
            port.close()
            throw error
        }
        return port
    }

    public func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
    }

    // MARK: - 参数

    /// 一次写好速率、帧格式与原始模式，并把驱动里积压的输入丢弃：
    /// 上一段会话留下的半个字节会让新会话第一条命令看起来像乱码。
    public func apply(_ settings: SerialConfig) throws {
        var modes = termios()
        guard tcgetattr(descriptor, &modes) == 0 else {
            throw SerialError.modeFailed(path, String(cString: strerror(errno)))
        }
        try applyBaudRate(settings.baudRate, to: &modes)
        modes.c_cflag = try Self.controlFlags(for: settings)
        modes.c_iflag = 0
        modes.c_oflag = 0
        modes.c_lflag = 0
        Self.clearControlCharacters(&modes)
        try setModes(&modes, flushInput: true)
        setModemLines(dtr: settings.dtr, rts: settings.rts)
    }

    /// 帧格式全部从 0 构造，不继承驱动旧值：上一次会话可能留着奇偶校验或 7 位帧。
    static func controlFlags(for settings: SerialConfig) throws -> tcflag_t {
        guard (5...8).contains(settings.dataBits) else {
            throw SerialError.modeFailed(settings.device, "数据位 \(settings.dataBits) 超出 5–8")
        }
        let dataBits = Self.dataBitsFlag(settings.dataBits)
        var flags: tcflag_t = 0
        switch settings.stopBits {
        case "1": break
        case "2": flags |= tcflag_t(CSTOPB)
        case "1.5":
            // BSD termios 只有“两位停止位”这一位，1.5 表达不出来。
            throw SerialError.stopBitsUnsupported(settings.device, "1.5")
        default:
            throw SerialError.modeFailed(settings.device, "停止位 \(settings.stopBits) 无效")
        }
        switch settings.parity {
        case .none: break
        case .even: flags |= tcflag_t(PARENB)
        case .odd: flags |= tcflag_t(PARENB | PARODD)
        case .mark, .space:
            // BSD 的 termios 没有 CMSPAR 这一位，Mark/Space 表达不出来。
            throw SerialError.parityUnsupported(settings.device, settings.parity.displayName)
        }
        return flags | tcflag_t(CLOCAL) | tcflag_t(CREAD) | dataBits
    }

    static func dataBitsFlag(_ bits: Int) -> tcflag_t {
        switch bits {
        case 6: return tcflag_t(CS6)
        case 7: return tcflag_t(CS7)
        case 8: return tcflag_t(CS8)
        default: return tcflag_t(CS5)   // CS5 就是全 0，5 位帧是默认值
        }
    }

    /// 原始模式不需要任何控制字符，整片清零后驱动不再把 Ctrl-Q、DEL 之类当本地命令。
    /// VMIN/VTIME 留 1/0：配合 O_NONBLOCK，读要么给数据要么立刻 EAGAIN。
    static func clearControlCharacters(_ modes: inout termios) {
        let count = MemoryLayout.size(ofValue: modes.c_cc) / MemoryLayout<cc_t>.size
        withUnsafeMutablePointer(to: &modes.c_cc) { storage in
            storage.withMemoryRebound(to: cc_t.self, capacity: count) { bytes in
                for index in 0..<count { bytes[index] = 0 }
                bytes[Int(VMIN)] = 1
            }
        }
    }

    private func applyBaudRate(_ rate: Int, to modes: inout termios) throws {
        if let code = Self.standardBaudCode(rate) {
            let speed = speed_t(code)
            guard cfsetospeed(&modes, speed) == 0, cfsetispeed(&modes, speed) == 0 else {
                throw SerialError.modeFailed(path, String(cString: strerror(errno)))
            }
            return
        }
        // 高于 230400 的速率不在 BSD 的固定表里，只能让驱动自己设。
        var speed = UInt32(rate)
        guard ioctl(descriptor, IOSSIOSPEED, &speed) == 0 else {
            throw SerialError.baudRateUnsupported(path, rate)
        }
    }

    /// BSD termios 认得的速率。表外的一律走 IOSSIOSPEED。
    static func standardBaudCode(_ rate: Int) -> Int? {
        switch rate {
        case 50: return Int(B50)
        case 75: return Int(B75)
        case 110: return Int(B110)
        case 134: return Int(B134)
        case 150: return Int(B150)
        case 200: return Int(B200)
        case 300: return Int(B300)
        case 600: return Int(B600)
        case 1200: return Int(B1200)
        case 1800: return Int(B1800)
        case 2400: return Int(B2400)
        case 4800: return Int(B4800)
        case 9600: return Int(B9600)
        case 19200: return Int(B19200)
        case 38400: return Int(B38400)
        case 7200: return Int(B7200)
        case 14400: return Int(B14400)
        case 28800: return Int(B28800)
        case 57600: return Int(B57600)
        case 76800: return Int(B76800)
        case 115200: return Int(B115200)
        case 230400: return Int(B230400)
        default: return nil
        }
    }

    private func setModes(_ modes: inout termios, flushInput: Bool) throws {
        // tcsetattr 要的是 TCSANOW/TCSADRAIN/TCSAFLUSH 这三个小整数，不是 TIOCSETA 那组
        // ioctl 编号——传后者会得到 EINVAL。
        let action: Int32 = flushInput ? TCSAFLUSH : TCSANOW
        guard tcsetattr(descriptor, action, &modes) == 0 else {
            throw SerialError.modeFailed(path, String(cString: strerror(errno)))
        }
    }

    // MARK: - 信号线

    /// cu.* 打开时驱动默认就把 DTR/RTS 拉高了，配置说不要就显式落下，
    /// 否则“取消勾选”在用户眼里等于没生效。
    public func setModemLines(dtr: Bool, rts: Bool) {
        if dtr {
            _ = ioctl(descriptor, TIOCSDTR)
        } else {
            _ = ioctl(descriptor, TIOCCDTR)
        }
        var bits = Int32(TIOCM_RTS)
        if rts {
            _ = ioctl(descriptor, TIOCMBIS, &bits)
        } else {
            _ = ioctl(descriptor, TIOCMBIC, &bits)
        }
    }

    /// BREAK：把发送线拉低一段时间，交换机与旧设备用它唤出控制台。
    public func sendBreak(duration: TimeInterval = 0.25) throws {
        guard ioctl(descriptor, TIOCSBRK) == 0 else {
            throw SerialError.breakFailed(path, String(cString: strerror(errno)))
        }
        Thread.sleep(forTimeInterval: min(1, max(0.05, duration)))
        guard ioctl(descriptor, TIOCCBRK) == 0 else {
            throw SerialError.breakFailed(path, String(cString: strerror(errno)))
        }
    }

    // MARK: - 收发

    public func read(maximumCount: Int) throws -> ReadResult {
        var buffer = [UInt8](repeating: 0, count: maximumCount)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
        if count > 0 { return .bytes(Data(buffer[0..<count])) }
        if count == 0 { return .ended(nil) }
        switch errno {
        case EINTR, EAGAIN, EWOULDBLOCK: return .wouldBlock
        case EIO: return .ended("设备已断开连接（可能被拔出）")
        default: throw SerialError.readFailed(path, String(cString: strerror(errno)))
        }
    }

    public func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        let deadline = Date().addingTimeInterval(writeTimeout)
        var sent = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while sent < data.count {
                let count = Darwin.write(descriptor, base.advanced(by: sent), data.count - sent)
                if count > 0 { sent += count; continue }
                if errno == EINTR { continue }
                guard errno == EAGAIN || errno == EWOULDBLOCK else {
                    throw SerialError.writeFailed(path, String(cString: strerror(errno)))
                }
                try waitUntilWritable(deadline: deadline)
            }
        }
    }

    private func waitUntilWritable(deadline: Date) throws {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            throw SerialError.writeFailed(path, "设备长时间未接收数据")
        }
        var events = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let ready = withUnsafeMutablePointer(to: &events) { poll($0, 1, Int32(max(1, remaining * 1000))) }
        if ready == 0 { throw SerialError.writeFailed(path, "设备长时间未接收数据") }
        guard ready > 0 else {
            if errno == EINTR { return }
            throw SerialError.writeFailed(path, String(cString: strerror(errno)))
        }
    }
}

/// 非标准速率用的驱动 ioctl。SDK 头文件里没有 ioss.h，数值按 _IOW('t', 100, int) 组装：
/// 方向位 0x80000000、长度 4、组 't'(0x74)、序号 100(0x64)。
private let IOSSIOSPEED: UInt = 0x8004_74_64
