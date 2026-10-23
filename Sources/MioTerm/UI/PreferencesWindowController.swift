import AppKit
import MioTermCore

/// 设置面板。改动点“保存”后一次性写盘，避免输入一半就触发全局刷新。
@MainActor
final class PreferencesWindowController: NSWindowController {
    private let store: SettingsStore

    private let appearancePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
    private let fontPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    private let fontSizePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 90, height: 24))
    private let scrollbackField = NSTextField()
    private let bellCheckbox = NSButton(checkboxWithTitle: "响铃", target: nil, action: nil)
    private let confirmCheckbox = NSButton(checkboxWithTitle: "关闭会话前确认", target: nil, action: nil)
    private let followCheckbox = NSButton(checkboxWithTitle: "跟随终端当前目录（OSC 7）", target: nil, action: nil)
    private let chunkField = NSTextField()
    private let concurrencyField = NSTextField()
    private let timeoutField = NSTextField()
    private let keepaliveField = NSTextField()

    private static let fontSizes: [Double] = [11, 12, 13, 14, 15, 16, 18, 20, 22, 24]
    /// 终端必须用等宽字体。系统字体列表里混着大量比例字体，这里按候选名逐个解析，
    /// 装了 Nerd Font 之类的用户把名字加进这个列表即可。
    private static let fontCandidates = [
        "Menlo", "Monaco", "SFMono-Regular", "JetBrainsMono-Regular", "Hack-Regular",
        "FiraCode-Regular", "SourceCodePro-Regular", "DejaVuSansMono", "MesloLGS-Regular",
        "PTMono", "AndaleMono", "Courier",
    ]
    private lazy var availableFonts: [String] = {
        var result: [String] = []
        for candidate in Self.fontCandidates {
            for suffix in ["", "-Regular"] {
                if let font = NSFont(name: candidate + suffix, size: 13) {
                    result.append(font.fontName)
                    break
                }
            }
        }
        return result
    }()

    init(store: SettingsStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        super.init(window: window)
        buildContents()
        load(store.settings)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    private func buildContents() {
        guard let window else { return }

        appearancePopup.addItems(withTitles: AppearanceMode.allCases.map { $0.displayName })
        fontPopup.addItems(withTitles: availableFonts)
        if fontPopup.itemTitles.isEmpty { fontPopup.addItem(withTitle: "Menlo Regular") }
        fontSizePopup.addItems(withTitles: Self.fontSizes.map { "\($0)" })

        let saveButton = NSButton(title: "保存", target: self, action: #selector(save(_:)))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(NSWindow.performClose(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), saveButton, cancelButton])
        buttons.orientation = .horizontal

        let grid = NSGridView(views: [
            [label("外观"), appearancePopup],
            [label("终端字体"), fontPopup],
            [label("字号"), fontSizePopup],
            [label("回滚行数"), scrollbackField],
            [label("提示音"), bellCheckbox],
            [label("关闭确认"), confirmCheckbox],
            [label("目录跟随"), followCheckbox],
            [label("上传分片 (MB)"), chunkField],
            [label("并发传输数"), concurrencyField],
            [label("默认超时 (秒)"), timeoutField],
            [label("默认保活 (秒)"), keepaliveField],
            [NSView(), buttons],
        ])
        grid.rowSpacing = 9
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        for field in [scrollbackField, chunkField, concurrencyField, timeoutField, keepaliveField] {
            field.widthAnchor.constraint(equalToConstant: 140).isActive = true
        }

        let container = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 20).isActive = true
        grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20).isActive = true
        grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20).isActive = true
        grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20).isActive = true
        window.contentView = container
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }

    private func load(_ settings: AppSettings) {
        appearancePopup.selectItem(at: AppearanceMode.allCases.firstIndex(of: settings.appearance) ?? 0)
        if let index = availableFonts.firstIndex(of: settings.terminalFontName) {
            fontPopup.selectItem(at: index)
        } else {
            fontPopup.selectItem(withTitle: settings.terminalFontName)
        }
        if let nearest = Self.fontSizes.min(by: { abs($0 - settings.terminalFontSize) < abs($1 - settings.terminalFontSize) }) {
            fontSizePopup.selectItem(withTitle: "\(nearest)")
        }
        scrollbackField.stringValue = "\(settings.scrollbackLines)"
        bellCheckbox.state = settings.playBellSound ? .on : .off
        confirmCheckbox.state = settings.confirmBeforeClose ? .on : .off
        followCheckbox.state = settings.followTerminalDirectory ? .on : .off
        chunkField.stringValue = String(format: "%.1f", Double(settings.uploadChunkBytes) / 1_048_576)
        concurrencyField.stringValue = "\(settings.maxConcurrentTransfers)"
        timeoutField.stringValue = "\(settings.defaultConnectTimeout)"
        keepaliveField.stringValue = "\(settings.defaultKeepaliveInterval)"
    }

    @objc private func save(_ sender: NSButton) {
        let fontName = fontPopup.titleOfSelectedItem ?? "Menlo Regular"
        do {
            try store.update { settings in
                settings.appearance = AppearanceMode.allCases[min(max(appearancePopup.indexOfSelectedItem, 0), AppearanceMode.allCases.count - 1)]
                settings.terminalFontName = fontName
                settings.terminalFontSize = Double(fontSizePopup.titleOfSelectedItem ?? "13") ?? 13
                settings.scrollbackLines = Int(scrollbackField.stringValue) ?? settings.scrollbackLines
                settings.playBellSound = bellCheckbox.state == .on
                settings.confirmBeforeClose = confirmCheckbox.state == .on
                settings.followTerminalDirectory = followCheckbox.state == .on
                settings.uploadChunkBytes = Int((Double(chunkField.stringValue) ?? 8) * 1_048_576)
                settings.maxConcurrentTransfers = Int(concurrencyField.stringValue) ?? settings.maxConcurrentTransfers
                settings.defaultConnectTimeout = Int(timeoutField.stringValue) ?? settings.defaultConnectTimeout
                settings.defaultKeepaliveInterval = Int(keepaliveField.stringValue) ?? settings.defaultKeepaliveInterval
            }
            close()
        } catch {
            AlertPresenter.fail(title: "无法保存设置", message: error.localizedDescription, in: window)
        }
    }
}
