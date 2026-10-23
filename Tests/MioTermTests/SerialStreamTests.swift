import Foundation
import Testing
@testable import MioTermCore

/// 串口会话在伪终端上的端到端行为。这些用例盯的是“界面上看见什么”：
/// 收到的字节、键入的换行、本地回显、开不了设备时的提示。
struct SerialStreamTests {
    private func configuration(for device: PtyDevice, mutate: (inout SerialConfig) -> Void = { _ in }) -> SerialConfig {
        var config = SerialConfig(device: device.path, baudRate: 115200, dataBits: 8, stopBits: "1", parity: .none)
        mutate(&config)
        return config
    }

    private func startStream(_ config: SerialConfig, listing devices: [String]? = nil) async -> (SerialStream, StreamHarness.Recorder) {
        let listed = devices ?? [config.device]
        let stream = SerialStream(configuration: config, deviceList: { listed })
        let recorder = StreamHarness.record(stream.events)
        await stream.start()
        return (stream, recorder)
    }

    @Test func opensTheDeviceAndFeedsIncomingBytesToTheTerminal() async throws {
        guard let device = PtyDevice() else { return }
        defer { device.close() }
        let (stream, recorder) = await startStream(configuration(for: device))
        #expect(await StreamHarness.waitUntil { recorder.contains(.connected) })

        device.sendToTerminal(Data("console ready\r\n".utf8))
        // 净负载原样进终端：串口没有任何协议字节要剥。
        #expect(await StreamHarness.waitUntil { String(decoding: recorder.received, as: UTF8.self) == "console ready\r\n" })

        await stream.close()
        // 用户主动关标签不投终止事件：界面自己知道发生了什么，Telnet 同样如此。
        #expect(recorder.terminalEvent == nil)
        device.sendToTerminal(Data("after close".utf8))
        try? await Task.sleep(nanoseconds: 50_000_000)
        // 关闭之后再来的字节不该再出现在终端上。
        #expect(String(decoding: recorder.received, as: UTF8.self) == "console ready\r\n")
    }

    @Test func typedEnterFollowsTheConfigurationAndLocalEchoShowsIt() async throws {
        guard let device = PtyDevice() else { return }
        defer { device.close() }
        let (stream, recorder) = await startStream(configuration(for: device) {
            $0.lineEnding = .cr
            $0.localEcho = true
        })
        #expect(await StreamHarness.waitUntil { recorder.contains(.connected) })

        await stream.write(Data("show version\r\nquit\n".utf8))
        // 设备上收到的必须是 CR，而且 CRLF 不能变成两个 CR。
        let sent = device.waitForOutput(minimumCount: 17)
        #expect(sent == Data("show version\rquit\r".utf8))
        // 设备不回显，所以界面要自己把改写后的字节画出来。
        #expect(await StreamHarness.waitUntil { recorder.received == Data("show version\rquit\r".utf8) })
        await stream.close()
    }

    @Test func anUnavailableDeviceFailsBeforeTouchingTheFilesystem() async throws {
        let (stream, recorder) = await startStream(SerialConfig(device: "/dev/cu.usbserial-9999"), listing: ["/dev/cu.usbserial-1111"])
        // 只允许打开枚举出来的设备，否则配置里的字符串就是任意路径。
        #expect(await StreamHarness.waitUntil { recorder.terminalEvent != nil })
        #expect(failureReason(of: recorder)?.contains("不存在或未被系统识别") == true)
        await stream.close()
    }

    @Test func aPathOutsideDevIsRefusedEvenWhenTheListingMentionsIt() async throws {
        let (stream, recorder) = await startStream(SerialConfig(device: "/etc/passwd"), listing: ["/etc/passwd"])
        #expect(await StreamHarness.waitUntil { recorder.terminalEvent != nil })
        // 提示要说清是路径不合法，而不是含糊的“打不开”。
        #expect(failureReason(of: recorder)?.contains("只允许 /dev/ 下的设备路径") == true)
        await stream.close()
    }

    @Test func unsupportedParityFailsWithAReasonTheUserCanActOn() async throws {
        guard let device = PtyDevice() else { return }
        defer { device.close() }
        let (stream, recorder) = await startStream(configuration(for: device) { $0.parity = .mark })
        #expect(await StreamHarness.waitUntil { recorder.terminalEvent != nil })
        #expect(failureReason(of: recorder)?.contains("校验") == true)
        await stream.close()
    }

    @Test func breakIsAnnouncedAndLeavesTheSessionOpen() async throws {
        guard let device = PtyDevice() else { return }
        defer { device.close() }
        let (stream, recorder) = await startStream(configuration(for: device))
        #expect(await StreamHarness.waitUntil { recorder.contains(.connected) })

        await stream.sendBreak()
        #expect(await StreamHarness.waitUntil { !recorder.notices.isEmpty })
        // 中断失败也只是提示，不能把一次好好的控制台会话判死。
        #expect(recorder.terminalEvent == nil)

        device.sendToTerminal(Data("still here".utf8))
        #expect(await StreamHarness.waitUntil { String(decoding: recorder.received, as: UTF8.self).contains("still here") })
        await stream.close()
    }

    private func failureReason(of recorder: StreamHarness.Recorder) -> String? {
        guard case .failed(let reason)? = recorder.terminalEvent else { return nil }
        return reason
    }
}
