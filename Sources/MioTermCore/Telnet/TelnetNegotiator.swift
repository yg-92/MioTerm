import Foundation

/// RFC 854 的 Telnet 协商状态机。
///
/// 只做纯计算：输入网络字节，输出“终端可见的数据”与“要写回服务器的应答”，
/// 不碰 socket。这样协商逻辑可以脱离网络逐条钉死，而 Telnet 的坑几乎全在协商里。
///
/// 支持的选项与 webterm 保持一致：BINARY(0)、ECHO(1)、SGA(3)、NAWS(31, RFC 1073)、
/// TTYPE(24, RFC 1091)。其余一律拒绝；拒绝过的选项记入 refusal 集合，
/// 服务器反复询问时不再重复答复，否则两边会陷入 WILL/WONT 协商风暴。
public struct TelnetNegotiator {
    enum Control {
        static let iac: UInt8 = 255
        static let dont: UInt8 = 254
        static let doOption: UInt8 = 253
        static let wont: UInt8 = 252
        static let will: UInt8 = 251
        static let sb: UInt8 = 250
        static let se: UInt8 = 240
    }

    enum Option {
        static let binary: UInt8 = 0
        static let echo: UInt8 = 1
        static let suppressGoAhead: UInt8 = 3
        static let terminalType: UInt8 = 24
        static let naws: UInt8 = 31
        static let subIs: UInt8 = 0
        static let subSend: UInt8 = 1
    }

    /// 一次 feed 的结果。
    public struct Outcome: Equatable {
        /// 剥掉协商字节后应交给终端的净负载。
        public var data = Data()
        /// 应写回服务器的协商应答（已按线上格式转义）。
        public var replies = Data()
        /// 非 nil 表示协议格式非法，连接应当关闭。
        public var failure: String?
    }

    /// 服务器不愿回显（WONT ECHO）时，本地要把键入原样显示出来，
    /// 否则用户在网络设备上是盲打的。
    public private(set) var localEchoRequired = false
    /// 双方约定 BINARY 后，行结束就交给远端程序，不再按 NVT 改写成 CRLF。
    public private(set) var binaryOutputActive = false
    /// 只有服务器同意 NAWS 后发窗口尺寸才有意义。
    public private(set) var canReportWindowSize = false

    private var localEnabled: Set<UInt8> = []
    private var remoteEnabled: Set<UInt8> = []
    private var refusedLocal: Set<UInt8> = []
    private var refusedRemote: Set<UInt8> = []
    /// BINARY 在服务端侧开启时，收到的数据不做 CR NUL 折叠。
    private var remoteBinary = false

    private var pendingVerb: UInt8?
    private var subnegotiation: [UInt8] = []
    private var sawIAC = false
    private var inSubnegotiation = false
    private var subIAC = false
    private var pendingCarriageReturn = false

    private let terminalType: String
    private var columns: Int
    private var rows: Int
    /// 子协商缓冲区上限：超过它的一定是畸形报文，直接断开而不是无限吃内存。
    static let maximumSubnegotiationLength = 4096

    public init(terminalType: String = TerminalTypes.fallback, columns: Int = 80, rows: Int = 24) {
        self.terminalType = TerminalTypes.resolved(terminalType, default: TerminalTypes.fallback)
        self.columns = columns
        self.rows = rows
    }

    /// 处理一批收到的字节。协商状态跨调用保留，所以 IAC 落在分包边界上也安全。
    public mutating func feed(_ bytes: ArraySlice<UInt8>) -> Outcome {
        var outcome = Outcome()
        for byte in bytes {
            if let verb = pendingVerb {
                pendingVerb = nil
                handleNegotiation(verb: verb, option: byte, outcome: &outcome)
            } else if sawIAC {
                handleControl(byte, outcome: &outcome)
            } else if inSubnegotiation {
                handleSubnegotiation(byte, outcome: &outcome)
            } else {
                appendData(byte, outcome: &outcome)
            }
            if outcome.failure != nil { return outcome }
            if subnegotiation.count > Self.maximumSubnegotiationLength {
                outcome.failure = "Telnet 子协商数据过长"
                return outcome
            }
        }
        return outcome
    }

    /// 把用户键入的字节编码成线上格式：按 NVT 归一化行尾，再转义 IAC。
    public func encodeOutput(_ data: Data) -> Data {
        let value = binaryOutputActive ? data : data.normalizingTelnetLineEndings()
        return value.escapingTelnetIAC()
    }

    /// 尺寸变化。返回需要立即写回服务器的 NAWS 报文，未协商 NAWS 时返回 nil。
    public mutating func setWindowSize(columns: Int, rows: Int) -> Data? {
        self.columns = columns
        self.rows = rows
        return nawsPacket()
    }

    // MARK: - 状态机

    private mutating func appendData(_ byte: UInt8, outcome: inout Outcome) {
        if byte == Control.iac {
            sawIAC = true
            return
        }
        // CR 后跟 NUL 是 RFC 854 表达“真正的回车”的写法，NUL 本身不该进终端。
        if pendingCarriageReturn && byte == 0 && !remoteBinary {
            pendingCarriageReturn = false
            return
        }
        pendingCarriageReturn = !remoteBinary && byte == 0x0D
        outcome.data.append(byte)
    }

    private mutating func handleControl(_ byte: UInt8, outcome: inout Outcome) {
        switch byte {
        case Control.iac:
            // IAC IAC 是一个真 0xFF 的转义写法。
            pendingCarriageReturn = false
            outcome.data.append(byte)
            sawIAC = false
        case Control.will, Control.wont, Control.doOption, Control.dont:
            pendingVerb = byte
            sawIAC = false
        case Control.sb:
            subnegotiation.removeAll(keepingCapacity: true)
            inSubnegotiation = true
            sawIAC = false
        default:
            // 其余命令（GA、AYT、EC…）客户端无需响应，丢掉即可。
            sawIAC = false
        }
    }

    private mutating func handleSubnegotiation(_ byte: UInt8, outcome: inout Outcome) {
        if subIAC {
            subIAC = false
            if byte == Control.se {
                inSubnegotiation = false
                answerSubnegotiation(outcome: &outcome)
            } else if byte == Control.iac {
                subnegotiation.append(byte)
            } else {
                outcome.failure = "Telnet 子协商格式无效"
            }
            return
        }
        if byte == Control.iac {
            subIAC = true
            return
        }
        subnegotiation.append(byte)
    }

    private mutating func answerSubnegotiation(outcome: inout Outcome) {
        defer { subnegotiation.removeAll(keepingCapacity: true) }
        // SB TTYPE SEND → 报上终端类型，设备据此选择转义序列集合。
        guard subnegotiation.count == 2,
              subnegotiation[0] == Option.terminalType,
              subnegotiation[1] == Option.subSend,
              localEnabled.contains(Option.terminalType) else { return }
        var payload = Data([Option.terminalType, Option.subIs])
        payload.append(contentsOf: terminalType.utf8)
        outcome.replies.append(Self.subnegotiationPacket(payload))
    }

    private mutating func handleNegotiation(verb: UInt8, option: UInt8, outcome: inout Outcome) {
        switch verb {
        case Control.will:
            // 服务器说“我要开启”：能配合的就 DO，不能配合的就 DONT。
            guard option == Option.binary || option == Option.echo || option == Option.suppressGoAhead else {
                refuseRemote(option, outcome: &outcome)
                return
            }
            guard !remoteEnabled.contains(option) else { return }
            remoteEnabled.insert(option)
            switch option {
            case Option.echo: localEchoRequired = false
            case Option.binary: remoteBinary = true
            default: break
            }
            outcome.replies.append(Self.command(Control.doOption, option))
        case Control.wont:
            refusedRemote.remove(option)
            if option == Option.echo { localEchoRequired = true }
            if option == Option.binary { remoteBinary = false }
            guard remoteEnabled.contains(option) else { return }
            remoteEnabled.remove(option)
            outcome.replies.append(Self.command(Control.dont, option))
        case Control.doOption:
            // 服务器请求“请你开启”：能开的就 WILL；NAWS 同意后立刻补一份窗口尺寸。
            guard option == Option.binary || option == Option.suppressGoAhead
                    || option == Option.terminalType || option == Option.naws else {
                refuseLocal(option, outcome: &outcome)
                return
            }
            guard !localEnabled.contains(option) else { return }
            localEnabled.insert(option)
            if option == Option.binary { binaryOutputActive = true }
            outcome.replies.append(Self.command(Control.will, option))
            if option == Option.naws {
                canReportWindowSize = true
                if let packet = nawsPacket() { outcome.replies.append(packet) }
            }
        case Control.dont:
            refusedLocal.remove(option)
            if option == Option.naws { canReportWindowSize = false }
            if option == Option.binary { binaryOutputActive = false }
            guard localEnabled.contains(option) else { return }
            localEnabled.remove(option)
            outcome.replies.append(Self.command(Control.wont, option))
        default:
            break
        }
    }

    private mutating func refuseRemote(_ option: UInt8, outcome: inout Outcome) {
        guard !refusedRemote.contains(option) else { return }
        refusedRemote.insert(option)
        outcome.replies.append(Self.command(Control.dont, option))
    }

    private mutating func refuseLocal(_ option: UInt8, outcome: inout Outcome) {
        guard !refusedLocal.contains(option) else { return }
        refusedLocal.insert(option)
        outcome.replies.append(Self.command(Control.wont, option))
    }

    private func nawsPacket() -> Data? {
        guard canReportWindowSize else { return nil }
        let width = UInt16(max(0, min(65535, columns)))
        let height = UInt16(max(0, min(65535, rows)))
        let payload = Data([Option.naws, UInt8(width >> 8), UInt8(width & 0xFF), UInt8(height >> 8), UInt8(height & 0xFF)])
        return Self.subnegotiationPacket(payload)
    }

    private static func command(_ verb: UInt8, _ option: UInt8) -> Data {
        Data([Control.iac, verb, option])
    }

    private static func subnegotiationPacket(_ payload: Data) -> Data {
        var packet = Data([Control.iac, Control.sb])
        packet.append(payload.escapingTelnetIAC())
        packet.append(contentsOf: [Control.iac, Control.se])
        return packet
    }
}

extension Data {
    /// Telnet 线上格式里 0xFF 是命令前缀，数据中的 0xFF 必须写成 0xFF 0xFF。
    func escapingTelnetIAC() -> Data {
        guard contains(0xFF) else { return self }
        var value = Data()
        value.reserveCapacity(count + 4)
        for byte in self {
            value.append(byte)
            if byte == 0xFF { value.append(0xFF) }
        }
        return value
    }

    /// CR、LF、CRLF 统一成 NVT 要求的 CRLF：网络设备大多按 CR 收命令。
    func normalizingTelnetLineEndings() -> Data {
        normalizingLineEndingsToLF().expandingLineFeeds(to: Data([0x0D, 0x0A]))
    }
}
