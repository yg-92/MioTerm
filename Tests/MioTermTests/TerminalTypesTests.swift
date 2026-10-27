import Foundation
import Testing
@testable import MioTermCore

@Suite("终端类型")
struct TerminalTypesTests {
    @Test("候选列表本身就是合法值")
    func optionsAreUsableAsIs() {
        #expect(!TerminalTypes.options.isEmpty)
        #expect(TerminalTypes.options.first == TerminalTypes.fallback)
        // 重复项会让下拉框出现两个一样的条目，选了也看不出区别。
        #expect(Set(TerminalTypes.options).count == TerminalTypes.options.count)
        for option in TerminalTypes.options {
            #expect(TerminalTypes.sanitized(option) == option)
            #expect(option.count <= TerminalTypes.maximumLength)
            #expect(!option.contains(" "))
        }
    }

    @Test("清洗只去空白，超长与空值归零")
    func sanitizedTrimsAndRejectsUnusable() {
        #expect(TerminalTypes.sanitized("  vt220 \n") == "vt220")
        #expect(TerminalTypes.sanitized("") == "")
        #expect(TerminalTypes.sanitized("   ") == "")
        // Telnet 的 TERMTYPE 子协商只有 64 字节，塞不下的值不如当没填。
        #expect(TerminalTypes.sanitized(String(repeating: "x", count: 65)) == "")
        #expect(TerminalTypes.sanitized(String(repeating: "x", count: 64)).count == 64)
    }

    @Test("主机没填就用设置里的默认，默认也不可用才兜底")
    func resolvedPrefersHostThenSettingsThenFallback() {
        #expect(TerminalTypes.resolved("vt100", default: "screen") == "vt100")
        #expect(TerminalTypes.resolved("", default: "screen") == "screen")
        #expect(TerminalTypes.resolved("  linux ", default: "screen") == "linux")
        #expect(TerminalTypes.resolved("", default: "") == TerminalTypes.fallback)
        // 主机值超长时不能原样送出去，退回默认。
        #expect(TerminalTypes.resolved(String(repeating: "x", count: 90), default: "screen") == "screen")
        // TERM 绝不能是空串：ssh 拿到空 TERM 会当成 dumb 终端，颜色和能力全丢。
        #expect(!TerminalTypes.resolved("", default: "").isEmpty)
    }

    @Test("主机默认不指定终端类型，留空表示跟随设置")
    func hostDefaultsToFollowingSettings() {
        let host = HostProfile(name: "h", address: "1.2.3.4", username: "u")
        #expect(host.terminalType.isEmpty)
        #expect(TerminalTypes.resolved(host.terminalType, default: "tmux-256color") == "tmux-256color")
    }

    @Test("落盘前清洗主机填的终端类型")
    func normalizingHostSanitizesTerminalType() {
        var host = HostProfile(name: "h", address: "1.2.3.4", username: "u")
        host.terminalType = " screen-256color "
        #expect(host.normalized().terminalType == "screen-256color")
        // 填了个发不出去的值，等于没填，而不是把脏数据存进配置。
        host.terminalType = String(repeating: "y", count: 80)
        #expect(host.normalized().terminalType.isEmpty)
    }
}
