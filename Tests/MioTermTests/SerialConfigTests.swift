import Foundation
import Testing
@testable import MioTermCore

/// 串口参数与设备路径的规则。这里的每个位与每条文案都对应一次真机上的失败现象，
/// 所以断言写的是数字而不是 termios 常量名——常量名记错的时候，测试必须红。
struct SerialConfigTests {
    private var configuration: SerialConfig {
        SerialConfig(device: "/dev/cu.usbserial-1111", baudRate: 115200, dataBits: 8, stopBits: "1", parity: .none)
    }

    // MARK: - 换行改写

    @Test(arguments: [
        (LineEnding.cr, "a\rb\rc\r"),
        (LineEnding.lf, "a\nb\nc\n"),
        (LineEnding.crlf, "a\r\nb\r\nc\r\n"),
    ] as [(LineEnding, String)])
    func everyIncomingLineEndingBecomesTheConfiguredSeparator(_ pair: (LineEnding, String)) {
        var config = configuration
        config.lineEnding = pair.0
        // 输入里三种换行混在一起（回车、粘贴的 LF、Windows 剪贴板的 CRLF），
        // 出来必须只剩一种，而且 CRLF 不能变成 CR CR。
        let typed = Data("a\rb\nc\r\n".utf8)
        #expect(config.encodeInput(typed) == Data(pair.1.utf8))
    }

    @Test func controlBytesAndArabicNumeralsPassThroughUntouched() {
        // Ctrl-C 与方向键不能因为“换行改写”被改动。
        let typed = Data([0x03, 0x1B]) + Data("[A".utf8)
        #expect(configuration.encodeInput(typed) == typed)
    }

    // MARK: - 帧格式

    @Test(arguments: [
        // (数据位, 停止位, 校验, 期望的 c_cflag)
        (8, "1", Parity.none, 0x8B00),
        (7, "1", Parity.even, 0x9A00),
        (8, "2", Parity.odd, 0xBF00),
        (5, "1", Parity.none, 0x8800),
        (6, "2", Parity.none, 0x8D00),
    ] as [(Int, String, Parity, UInt)])
    func frameSettingsMapToTheExactTermiosBits(dataBits: Int, stopBits: String, parity: Parity, expected: UInt) throws {
        var config = configuration
        config.dataBits = dataBits
        config.stopBits = stopBits
        config.parity = parity
        let flags = UInt(try SerialPort.controlFlags(for: config))
        // CLOCAL(0x8000) | CREAD(0x800) 起步，再按字段叠数据位、校验与停止位。
        #expect(flags == expected)
        // 绝不开 HUPCL(0x4000)：关闭会话不该去抖调制解调器线。
        #expect(flags & 0x4000 == 0)
    }

    @Test func markAndSpaceParityAreRefusedBecauseBSDHasNoBitForThem() {
        for parity in [Parity.mark, .space] {
            var config = configuration
            config.parity = parity
            // 抛错而不是悄悄改成无校验：静默降级会让用户对着乱码猜半天。
            #expect(throws: SerialPort.SerialError.self) { try SerialPort.controlFlags(for: config) }
        }
    }

    @Test func onePointFiveStopBitsIsRefused() {
        var config = configuration
        config.stopBits = "1.5"
        #expect(throws: SerialPort.SerialError.self) { try SerialPort.controlFlags(for: config) }
    }

    @Test(arguments: [(-1, Optional<Int>.none), (0, .none), (4_000_001, .none), (115200, 115200), (230400, 230400), (921600, Optional<Int>.none)] as [(Int, Int?)])
    func onlyStandardRatesComeFromTheTermiosTable(_ pair: (Int, Int?)) {
        #expect(SerialPort.standardBaudCode(pair.0) == pair.1)
    }

    // MARK: - 设备路径

    @Test(arguments: ["/etc/passwd", "/dev/../etc/passwd", "", "COM1\0", "/dev/cu.ok\r", "cu.usbserial"] as [String])
    func onlyPlainPathsUnderDevAreAcceptable(_ device: String) {
        #expect(SerialDevices.isAcceptablePath(device) == false)
    }

    @Test(arguments: ["/dev/cu.usbserial-1111", "/dev/tty.usbmodem14201", "/dev/cu.Bluetooth-Incoming-Port"] as [String])
    func deviceNodesUnderDevAreAcceptable(_ device: String) {
        #expect(SerialDevices.isAcceptablePath(device))
    }

    @Test func cuAndTtyNamesReferToTheSameDevice() {
        // 驱动有时只登记一个名字，比对前先归一化，否则“在列表里”也会被当成不存在。
        #expect(SerialDevices.canonicalPath("/dev/tty.usbserial-1111") == "/dev/cu.usbserial-1111")
        #expect(SerialDevices.isAvailable("/dev/tty.usbserial-1111", among: ["/dev/cu.usbserial-1111"]))
        #expect(SerialDevices.isAvailable("/dev/cu.wlan", among: ["/dev/cu.usbserial-1111"]) == false)
    }

    // MARK: - 配置里的老字段

    @Test func missingKeysFallBackToDefaultsInsteadOfJudgingTheWholeFileCorrupt() throws {
        // 已经落盘的配置里没有 dtr/rts；合成的解码器会把缺失键当损坏，
        // 一旦判损坏，仓库会连备份一起丢，用户看到的是“主机列表空了”。
        let legacy = Data("""
        {"device":"/dev/cu.usbserial-1111","baudRate":9600,"dataBits":7,"stopBits":"2","parity":"Even","lineEnding":"LF","localEcho":true}
        """.utf8)
        let decoded = try JSONDecoder().decode(SerialConfig.self, from: legacy)
        #expect(decoded.baudRate == 9600)
        #expect(decoded.dataBits == 7)
        #expect(decoded.stopBits == "2")
        #expect(decoded.parity == .even)
        #expect(decoded.lineEnding == .lf)
        #expect(decoded.localEcho)
        #expect(decoded.dtr == false)
        #expect(decoded.rts == false)
    }

    @Test func anEmptyObjectDecodesToTheDefaultConfiguration() throws {
        let decoded = try JSONDecoder().decode(SerialConfig.self, from: Data("{}".utf8))
        #expect(decoded == SerialConfig.default)
    }

    // MARK: - 表单与保存的校验

    private func host(_ serial: SerialConfig) -> HostProfile {
        var host = HostProfile(name: "控制台", protocolKind: .serial)
        host.serial = serial
        return host
    }

    @Test(arguments: [-1, 0, 4_000_001] as [Int])
    func savingRejectsBaudRatesOutsideTheDriverRange(_ baudRate: Int) {
        var config = configuration
        config.baudRate = baudRate
        #expect(HostProfile.ValidationError.serialBaudOutOfRange == errorOf(host(config)))
    }

    @Test func savingRejectsAPathThatEscapesDev() {
        var config = configuration
        config.device = "/dev/../etc/passwd"
        #expect(HostProfile.ValidationError.serialDevicePathInvalid == errorOf(host(config)))
    }

    @Test func savingRejectsUnknownFrameSizes() {
        var dataBits = configuration
        dataBits.dataBits = 9
        #expect(HostProfile.ValidationError.serialDataBitsOutOfRange == errorOf(host(dataBits)))
        var stopBits = configuration
        stopBits.stopBits = "3"
        #expect(HostProfile.ValidationError.serialStopBitsInvalid == errorOf(host(stopBits)))
    }

    @Test func aCompleteSerialConfigurationSaves() throws {
        try host(configuration).validate()
    }

    private func errorOf(_ host: HostProfile) -> HostProfile.ValidationError? {
        do {
            try host.validate()
            return nil
        } catch let error as HostProfile.ValidationError {
            return error
        } catch {
            return nil
        }
    }

    @Test func serialSidebarLineShowsDeviceAndRate() {
        var config = configuration
        config.baudRate = 9600
        #expect(host(config).subtitle == "/dev/cu.usbserial-1111 · 9600 baud")
        #expect(host(SerialConfig(device: "")).subtitle == "未选串口")
    }
}
