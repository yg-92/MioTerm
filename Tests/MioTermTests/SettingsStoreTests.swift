import Foundation
import Testing
@testable import MioTermCore

@MainActor
@Suite("设置存储")
struct SettingsStoreTests {
    /// 每个用例独立的临时文件，避免碰真实的支持目录。
    private func makeStore(name: String) throws -> (SettingsStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mioTerm-settings-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (SettingsStore(url: directory.appendingPathComponent("settings.json")), directory.appendingPathComponent("settings.json"))
    }

    /// 老文件里的一个子集字段，模拟版本升级前后缺键的情况。
    private func writeLegacyJSON(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    @Test("缺字段的老文件只回退那一项")
    func toleratesMissingKeys() throws {
        let (store, url) = try makeStore(name: "partial")
        // 模拟早期版本：没有 followTerminalDirectory，也没有传输并发数。
        try writeLegacyJSON("""
        {"appearance":"dark","terminalFontName":"Monaco","terminalFontSize":15,\
        "scrollbackLines":5000,"playBellSound":true,"confirmBeforeClose":false,\
        "uploadChunkBytes":524288,"defaultConnectTimeout":7,"defaultKeepaliveInterval":45}
        """, to: url)
        store.load()
        let settings = store.settings
        #expect(settings.appearance == .dark)
        #expect(settings.terminalFontName == "Monaco")
        #expect(settings.terminalFontSize == 15)
        #expect(settings.scrollbackLines == 5000)
        #expect(settings.playBellSound)
        #expect(settings.uploadChunkBytes == 524_288)
        #expect(settings.defaultConnectTimeout == 7)
        #expect(settings.defaultKeepaliveInterval == 45)
        // 缺的两项退回默认值，而不是整份清零。
        #expect(settings.followTerminalDirectory)
        #expect(settings.maxConcurrentTransfers == 3)
        #expect(settings.fileTreeFontSize == 12)
        #expect(settings.fileTreeIconSize == 13)
        // 配色档位与强调色是后加的，老文件没有这两个键也要退回默认。
        #expect(settings.contrast == .soft)
        #expect(settings.accent == .blue)
        // 终端类型同理：老文件没这个键，默认值必须是个能直接当 TERM 用的名字。
        #expect(settings.terminalType == TerminalTypes.fallback)
    }

    @Test("存进去的每一项都能读回来")
    func roundTripsEveryField() throws {
        let (store, url) = try makeStore(name: "round")
        try store.update { next in
            next.appearance = .light
            next.contrast = .high
            next.accent = .green
            next.terminalFontName = "Menlo Bold"
            next.terminalFontSize = 18
            next.terminalType = "vt220"
            next.fileTreeFontSize = 14
            next.fileTreeIconSize = 18
            next.scrollbackLines = 40_000
            next.playBellSound = true
            next.followTerminalDirectory = false
            next.uploadChunkBytes = 1_048_576
            next.maxConcurrentTransfers = 5
            next.defaultConnectTimeout = 20
            next.defaultKeepaliveInterval = 0
        }
        let reloaded = SettingsStore(url: url)
        #expect(reloaded.settings == store.settings)
    }

    @Test("坏文件退回默认设置，不抛异常")
    func unreadableFileFallsBack() throws {
        let (store, url) = try makeStore(name: "broken")
        try Data("这不是 JSON".utf8).write(to: url)
        store.load()
        #expect(store.settings == .default)
    }

    @Test("越界的值在读写两侧都被收敛")
    func clampsOutOfRangeValues() throws {
        let (store, url) = try makeStore(name: "clamp")
        try store.update { next in
            next.terminalFontSize = 200
            next.fileTreeFontSize = 1
            next.fileTreeIconSize = 999
            next.scrollbackLines = 1
            next.maxConcurrentTransfers = 99
            next.terminalType = "  screen-256color  "
        }
        #expect(store.settings.terminalFontSize == 32)
        #expect(store.settings.fileTreeFontSize == 10)
        #expect(store.settings.fileTreeIconSize == 24)
        #expect(store.settings.scrollbackLines == 200)
        #expect(store.settings.maxConcurrentTransfers == 8)
        #expect(store.settings.terminalType == "screen-256color")
        // 设置里的默认值是所有留空主机的兜底，不能是空串。
        try store.update { $0.terminalType = "" }
        #expect(store.settings.terminalType == TerminalTypes.fallback)
        // 落盘的已经是收敛后的值，重读不会再变一次。
        store.load()
        #expect(store.settings.terminalFontSize == 32)
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: url)).maxConcurrentTransfers == 8)
    }

    @Test("没有文件时用默认值启动")
    func startsWithDefaults() throws {
        let (store, url) = try makeStore(name: "absent")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(store.settings == .default)
    }
}
