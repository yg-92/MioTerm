import AppKit
import MioTermCore

/// 设置面板。改动点“保存”后一次性写盘，避免输入一半就触发全局刷新。
/// 视觉上跟主机表单一致：标签左对齐、控件左端对齐，窗口按内容自适应高度，
/// 免得底部按钮被挤到窗口外，点了像没反应。
@MainActor
final class PreferencesWindowController: NSWindowController {
    private let store: SettingsStore

    private let appearancePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
    private let contrastPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
    private let accentPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
    private let fontPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    private let fontSizePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 90, height: 24))
    private let treeFontSizePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 90, height: 24))
    private let treeIconSizePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 90, height: 24))
    private let scrollbackField = NSTextField()
    private let bellCheckbox = NSButton(checkboxWithTitle: "响铃", target: nil, action: nil)
    private let followCheckbox = NSButton(checkboxWithTitle: "跟随终端当前目录（OSC 7）", target: nil, action: nil)
    private let chunkField = NSTextField()
    private let concurrencyField = NSTextField()
    private let timeoutField = NSTextField()
    private let keepaliveField = NSTextField()

    private static let labelWidth: CGFloat = 104
    private static let fontSizes: [Double] = [11, 12, 13, 14, 15, 16, 18, 20, 22, 24]
    private static let treeFontSizes: [Double] = [10, 11, 12, 13, 14, 15, 16, 18, 20]
    private static let treeIconSizes: [Double] = [11, 12, 13, 14, 16, 18, 20, 22]
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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        // 窗口归控制器长期持有：关掉再打开时要能复用，不然第二次打开控件会失灵。
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContents()
        load(store.settings)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    private func buildContents() {
        guard let window else { return }

        appearancePopup.addItems(withTitles: AppearanceMode.allCases.map { $0.displayName })
        contrastPopup.addItems(withTitles: UIContrast.allCases.map { $0.displayName })
        accentPopup.addItems(withTitles: AccentColor.allCases.map { $0.displayName })
        fontPopup.addItems(withTitles: availableFonts)
        if fontPopup.itemTitles.isEmpty { fontPopup.addItem(withTitle: "Menlo Regular") }
        fontSizePopup.addItems(withTitles: Self.fontSizes.map { "\($0)" })
        treeFontSizePopup.addItems(withTitles: Self.treeFontSizes.map { "\($0)" })
        treeIconSizePopup.addItems(withTitles: Self.treeIconSizes.map { "\($0)" })

        let saveButton = NSButton(title: "保存", target: self, action: #selector(save(_:)))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), saveButton, cancelButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        for field in [scrollbackField, chunkField, concurrencyField, timeoutField, keepaliveField] {
            field.alignment = .left
            field.widthAnchor.constraint(equalToConstant: 140).isActive = true
        }
        // 三个下拉框统一宽度，点开菜单时标题不会被挤成省略号。
        appearancePopup.widthAnchor.constraint(equalToConstant: 240).isActive = true
        contrastPopup.widthAnchor.constraint(equalToConstant: 240).isActive = true
        accentPopup.widthAnchor.constraint(equalToConstant: 240).isActive = true
        fontPopup.widthAnchor.constraint(equalToConstant: 240).isActive = true
        fontSizePopup.widthAnchor.constraint(equalToConstant: 90).isActive = true
        treeFontSizePopup.widthAnchor.constraint(equalToConstant: 90).isActive = true
        treeIconSizePopup.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let grid = NSGridView(views: [
            [label("外观"), appearancePopup],
            [label("对比度"), contrastPopup],
            [label("强调色"), accentPopup],
            [label("终端字体"), fontPopup],
            [label("字号"), fontSizePopup],
            [label("目录树字号"), treeFontSizePopup],
            [label("目录树图标"), treeIconSizePopup],
            [label("回滚行数"), scrollbackField],
            [label("提示音"), bellCheckbox],
            [label("目录跟随"), followCheckbox],
            [label("上传分片 (MB)"), chunkField],
            [label("并发传输数"), concurrencyField],
            [label("默认超时 (秒)"), timeoutField],
            [label("默认保活 (秒)"), keepaliveField],
            [NSView(), buttons],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading

        let container = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -22),
        ])
        window.contentView = container
        // 按内容定高宽：以前写死 420，行数一多底部按钮就被裁掉，点起来像没反应。
        window.setContentSize(container.fittingSize)
        window.minSize = window.frame.size
    }

    /// 标签与内容都靠左；固定标签列宽，右侧控件才会在同一条竖线上。
    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .left
        field.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        return field
    }

    private func load(_ settings: AppSettings) {
        appearancePopup.selectItem(at: AppearanceMode.allCases.firstIndex(of: settings.appearance) ?? 0)
        contrastPopup.selectItem(at: UIContrast.allCases.firstIndex(of: settings.contrast) ?? 0)
        accentPopup.selectItem(at: AccentColor.allCases.firstIndex(of: settings.accent) ?? 0)
        if let index = availableFonts.firstIndex(of: settings.terminalFontName) {
            fontPopup.selectItem(at: index)
        } else {
            fontPopup.selectItem(withTitle: settings.terminalFontName)
        }
        if let nearest = Self.fontSizes.min(by: { abs($0 - settings.terminalFontSize) < abs($1 - settings.terminalFontSize) }) {
            fontSizePopup.selectItem(withTitle: "\(nearest)")
        }
        if let nearest = Self.treeFontSizes.min(by: { abs($0 - settings.fileTreeFontSize) < abs($1 - settings.fileTreeFontSize) }) {
            treeFontSizePopup.selectItem(withTitle: "\(nearest)")
        }
        if let nearest = Self.treeIconSizes.min(by: { abs($0 - settings.fileTreeIconSize) < abs($1 - settings.fileTreeIconSize) }) {
            treeIconSizePopup.selectItem(withTitle: "\(nearest)")
        }
        scrollbackField.stringValue = "\(settings.scrollbackLines)"
        bellCheckbox.state = settings.playBellSound ? .on : .off
        followCheckbox.state = settings.followTerminalDirectory ? .on : .off
        chunkField.stringValue = String(format: "%.1f", Double(settings.uploadChunkBytes) / 1_048_576)
        concurrencyField.stringValue = "\(settings.maxConcurrentTransfers)"
        timeoutField.stringValue = "\(settings.defaultConnectTimeout)"
        keepaliveField.stringValue = "\(settings.defaultKeepaliveInterval)"
    }

    /// 下拉框选项顺序就是枚举 allCases 的顺序，按索引反查即可。
    private func selected<T>(_ popup: NSPopUpButton, _ values: [T]) -> T {
        values[min(max(popup.indexOfSelectedItem, 0), values.count - 1)]
    }

    @objc private func save(_ sender: NSButton) {
        let fontName = fontPopup.titleOfSelectedItem ?? "Menlo Regular"
        do {
            try store.update { settings in
                settings.appearance = selected(appearancePopup, AppearanceMode.allCases)
                settings.contrast = selected(contrastPopup, UIContrast.allCases)
                settings.accent = selected(accentPopup, AccentColor.allCases)
                settings.terminalFontName = fontName
                settings.terminalFontSize = Double(fontSizePopup.titleOfSelectedItem ?? "13") ?? 13
                settings.fileTreeFontSize = Double(treeFontSizePopup.titleOfSelectedItem ?? "12") ?? 12
                settings.fileTreeIconSize = Double(treeIconSizePopup.titleOfSelectedItem ?? "13") ?? 13
                settings.scrollbackLines = Int(scrollbackField.stringValue) ?? settings.scrollbackLines
                settings.playBellSound = bellCheckbox.state == .on
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

    @objc private func cancel(_ sender: NSButton) {
        close()
    }
}
