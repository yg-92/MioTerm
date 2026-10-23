import Foundation
import Testing
@testable import MioTermCore

/// RFC 854 协商状态机的逐条约束。这里钉住的每个字节都对应真实设备上的一次交互，
/// 写错一处通常表现为“连上了但没有回显”或“服务器卡住等 IAC”。
struct TelnetNegotiatorTests {
    private static let iac = TelnetNegotiator.Control.iac
    private static let will = TelnetNegotiator.Control.will
    private static let wont = TelnetNegotiator.Control.wont
    private static let doOption = TelnetNegotiator.Control.doOption
    private static let dont = TelnetNegotiator.Control.dont

    /// 便于用字节字面量描述报文。
    private func feed(_ negotiator: inout TelnetNegotiator, _ bytes: [UInt8]) -> TelnetNegotiator.Outcome {
        negotiator.feed(ArraySlice(bytes))
    }

    @Test func willEchoIsAcceptedAndServerKeepsEchoing() {
        var negotiator = TelnetNegotiator()
        let outcome = feed(&negotiator, [Self.iac, Self.will, 1])
        #expect(outcome.replies == Data([Self.iac, Self.doOption, 1]))
        #expect(outcome.data.isEmpty)
        #expect(!negotiator.localEchoRequired)
    }

    @Test func wontEchoTurnsOnLocalEcho() {
        var negotiator = TelnetNegotiator()
        // 服务器主动声明“我不回显”，客户端不必再回 DONT（并未开启过），但必须接管回显，
        // 否则用户在网络设备上是盲打的。
        let refused = feed(&negotiator, [Self.iac, Self.wont, 1])
        #expect(refused.replies.isEmpty)
        #expect(negotiator.localEchoRequired)

        let resumed = feed(&negotiator, [Self.iac, Self.will, 1])
        #expect(resumed.replies == Data([Self.iac, Self.doOption, 1]))
        #expect(!negotiator.localEchoRequired)

        // 已经同意过 ECHO 后服务器再撤回，就要按规矩回一句 DONT。
        let revoked = feed(&negotiator, [Self.iac, Self.wont, 1])
        #expect(revoked.replies == Data([Self.iac, Self.dont, 1]))
        #expect(negotiator.localEchoRequired)
    }

    @Test func nawsRequestIsAcceptedWithCurrentWindowSize() {
        var negotiator = TelnetNegotiator(terminalType: "xterm-256color", columns: 132, rows: 43)
        let outcome = feed(&negotiator, [Self.iac, Self.doOption, 31])
        #expect(outcome.replies == Data([Self.iac, Self.will, 31])
            + Data([Self.iac, 250, 31, 0, 132, 0, 43, Self.iac, 240]))
        #expect(negotiator.canReportWindowSize)
    }

    @Test func windowSizeOnlyReportsAfterNegotiation() {
        var negotiator = TelnetNegotiator(columns: 80, rows: 24)
        // 没谈成 NAWS 就发子协商，老设备会当成畸形报文断开。
        #expect(negotiator.setWindowSize(columns: 100, rows: 30) == nil)

        _ = feed(&negotiator, [Self.iac, Self.doOption, 31])
        #expect(negotiator.setWindowSize(columns: 100, rows: 30)
            == Data([Self.iac, 250, 31, 0, 100, 0, 30, Self.iac, 240]))

        _ = feed(&negotiator, [Self.iac, Self.dont, 31])
        #expect(!negotiator.canReportWindowSize)
        #expect(negotiator.setWindowSize(columns: 120, rows: 40) == nil)
    }

    @Test func ttypeSendIsAnsweredWithConfiguredTerminalType() {
        var negotiator = TelnetNegotiator(terminalType: "vt100")
        _ = feed(&negotiator, [Self.iac, Self.doOption, 24])
        let request = [Self.iac, 250, 24, 1, Self.iac, 240]
        let outcome = feed(&negotiator, request)
        var answer = Data([Self.iac, 250, 24, 0])
        answer.append(contentsOf: Array("vt100".utf8))
        answer.append(contentsOf: [Self.iac, 240])
        #expect(outcome.replies == answer)

        // 没谈成 TTYPE 时不能自作主张地报类型，服务器会视其为畸形子协商。
        var cold = TelnetNegotiator()
        #expect(feed(&cold, request).replies.isEmpty)
    }

    @Test func doubledIACReachesTerminalAsOneByte() {
        var negotiator = TelnetNegotiator()
        let outcome = feed(&negotiator, [0x41, Self.iac, Self.iac, 0x42])
        #expect(outcome.data == Data([0x41, 0xFF, 0x42]))
        #expect(outcome.replies.isEmpty)
    }

    @Test func crNulUnwrapsToPlainCarriageReturn() {
        var negotiator = TelnetNegotiator()
        let outcome = feed(&negotiator, Array("bye\r\0".utf8))
        #expect(outcome.data == Data("bye\r".utf8))

        // BINARY 之后 NUL 是真数据，不能被当成 CR 的补位吃掉。
        _ = feed(&negotiator, [Self.iac, Self.will, 0])
        #expect(feed(&negotiator, Array("\r\0".utf8)).data == Data([0x0D, 0x00]))
    }

    @Test func unsupportedOptionsAreRefusedOnlyOnce() {
        var negotiator = TelnetNegotiator()
        // 服务器问 LF（线性空白，早已废弃），拒绝一次即可。
        #expect(feed(&negotiator, [Self.iac, Self.doOption, 5]).replies == Data([Self.iac, Self.wont, 5]))
        #expect(feed(&negotiator, [Self.iac, Self.doOption, 5]).replies.isEmpty)

        // 服务器要开 LINEMODE(34)，客户端不支持就 DONT，同样不重复。
        #expect(feed(&negotiator, [Self.iac, Self.will, 34]).replies == Data([Self.iac, Self.dont, 34]))
        #expect(feed(&negotiator, [Self.iac, Self.will, 34]).replies.isEmpty)
    }

    /// 协商风暴的成因：客户端对同一选项反复 WILL/WONT。服务器收回请求后重新询问，
    /// 才再答复一次。
    @Test func refusalIsForgottenOnlyWhenTheServerChangesItsMind() {
        var negotiator = TelnetNegotiator()
        #expect(feed(&negotiator, [Self.iac, Self.doOption, 5]).replies == Data([Self.iac, Self.wont, 5]))
        #expect(feed(&negotiator, [Self.iac, Self.doOption, 5]).replies.isEmpty)
        #expect(feed(&negotiator, [Self.iac, Self.dont, 5]).replies.isEmpty)
        #expect(feed(&negotiator, [Self.iac, Self.doOption, 5]).replies == Data([Self.iac, Self.wont, 5]))
    }

    @Test func negotiationSplitAcrossPacketsKeepsState() {
        var negotiator = TelnetNegotiator(columns: 80, rows: 24)
        // 命令前缀正好落在分包边界上：下一包只剩 verb 与选项两个字节。
        let first = feed(&negotiator, [0x48, Self.iac])
        #expect(first.data == Data([0x48]))
        #expect(first.replies.isEmpty)
        let second = feed(&negotiator, [Self.doOption, 31, 0x69])
        #expect(second.data == Data([0x69]))
        #expect(second.replies == Data([Self.iac, Self.will, 31])
            + Data([Self.iac, 250, 31, 0, 80, 0, 24, Self.iac, 240]))
    }

    @Test func subnegotiationSplitAcrossPacketsIsStillAnswered() {
        var negotiator = TelnetNegotiator(terminalType: "xterm")
        _ = feed(&negotiator, [Self.iac, Self.doOption, 24])
        #expect(feed(&negotiator, [Self.iac, 250, 24]).replies.isEmpty)
        let answer = feed(&negotiator, [1, Self.iac, 240])
        #expect(answer.replies == Data([Self.iac, 250, 24, 0]) + Data("xterm".utf8) + Data([Self.iac, 240]))
    }

    @Test func malformedSubnegotiationAndRunawayLengthFailClosed() {
        var negotiator = TelnetNegotiator()
        let broken = feed(&negotiator, [Self.iac, 250, 24, 1, Self.iac, 0x41])
        #expect(broken.failure == "Telnet 子协商格式无效")

        var runaway = TelnetNegotiator()
        var bytes = [UInt8]([Self.iac, 250])
        bytes += [UInt8](repeating: 0x41, count: TelnetNegotiator.maximumSubnegotiationLength + 1)
        #expect(feed(&runaway, bytes).failure == "Telnet 子协商数据过长")
    }

    @Test func typedOutputUsesNVTLineEndingsAndEscapesIAC() {
        let negotiator = TelnetNegotiator()
        #expect(negotiator.encodeOutput(Data("a\rb\nc\r\nd".utf8)) == Data("a\r\nb\r\nc\r\nd".utf8))
        #expect(negotiator.encodeOutput(Data([0xFF])) == Data([0xFF, 0xFF]))

        // 谈成 BINARY 后原样发送，否则会被改写二进制传输的协议（如文件流）会坏。
        var binary = TelnetNegotiator()
        _ = feed(&binary, [Self.iac, Self.doOption, 0])
        #expect(binary.encodeOutput(Data([0x0A, 0x0D])) == Data([0x0A, 0x0D]))
        #expect(binary.encodeOutput(Data([0xFF])) == Data([0xFF, 0xFF]))
    }

    /// 配置里的终端类型为空或过长时不能把畸形字符串发到线上。
    @Test func terminalTypeFallsBackWhenUnusable() {
        var empty = TelnetNegotiator(terminalType: "")
        _ = feed(&empty, [Self.iac, Self.doOption, 24])
        var answer = Data([Self.iac, 250, 24, 0])
        answer.append(contentsOf: Array("xterm-256color".utf8))
        answer.append(contentsOf: [Self.iac, 240])
        #expect(feed(&empty, [Self.iac, 250, 24, 1, Self.iac, 240]).replies == answer)
    }
}
