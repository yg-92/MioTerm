import AppKit
import MioTermCore

/// 设置面板。所有改动即时生效并落盘，无需点击保存按钮。
/// 视觉上跟主机表单一致：标签左对齐、控件左端对齐，窗口按内容自适应高度。
@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSComboBoxDelegate {
    private let store: SettingsStore
    private var styleWindow: StylePreferencesWindowController?
    private var isLoading = false
    private var opacitySaveWorkItem: DispatchWorkItem?

    private let languagePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
    private let appearancePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
    private let contrastPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
    private let accentPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
    private lazy var opacitySlider: NSSlider = {
        let slider = NSSlider(
            value: 1.0,
            minValue: AppSettings.minimumWindowOpacity,
            maxValue: AppSettings.maximumWindowOpacity,
            target: self,
            action: #selector(opacityChanged(_:))
        )
        slider.isContinuous = true
        return slider
    }()
    private let opacityValueLabel = NSTextField(labelWithString: "100%")
    private let fontPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    private let fontSizePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 90, height: 24))
    /// 终端类型既能从常用 TERM 里挑，也能直接输入对端要求的名字。
    private let terminalTypeCombo = NSComboBox()
    private let terminalTypeHint = NSTextField(wrappingLabelWithString: "")
    private let treeFontSizePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 90, height: 24))
    private let treeIconSizePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 90, height: 24))
    private let scrollbackField = NSTextField()
    private let bellCheckbox = NSButton(checkboxWithTitle: L10n.tr(.prefBellTitle), target: nil, action: nil)
    private let followCheckbox = NSButton(checkboxWithTitle: L10n.tr(.prefFollowDirectoryTitle), target: nil, action: nil)
    private let chunkField = NSTextField()
    private let concurrencyField = NSTextField()
    private let timeoutField = NSTextField()
    private let keepaliveField = NSTextField()
    private let commandKeyPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    private let controlKeyPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    private let optionKeyPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 24))

    private let styleButton = NSButton(title: L10n.tr(.prefStyleButton), target: nil, action: nil)
    private let tabView = NSTabView()
    private var tabItems: [(NSTabViewItem, L10nKey)] = []
    private var localizedLabels: [(NSTextField, L10nKey)] = []

    private static let labelWidth: CGFloat = 128
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
        window.title = L10n.tr(.preferencesTitle)
        // 窗口归控制器长期持有：关掉再打开时要能复用，不然第二次打开控件会失灵。
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContents()
        load(store.settings)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsDidChange),
            name: .mioTermSettingsDidChange,
            object: nil
        )
        window.center()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    private func buildContents() {
        guard let window else { return }

        languagePopup.addItems(withTitles: AppLanguage.allCases.map { $0.displayName })
        languagePopup.toolTip = L10n.tr(.prefLanguageHint)
        appearancePopup.addItems(withTitles: AppearanceMode.allCases.map { $0.displayName })
        contrastPopup.addItems(withTitles: UIContrast.allCases.map { $0.displayName })
        accentPopup.addItems(withTitles: AccentColor.allCases.map { $0.displayName })
        accentPopup.toolTip = L10n.tr(.prefAccentTooltip)
        fontPopup.addItems(withTitles: availableFonts)
        if fontPopup.itemTitles.isEmpty { fontPopup.addItem(withTitle: "Menlo Regular") }
        fontSizePopup.addItems(withTitles: Self.fontSizes.map { "\($0)" })
        treeFontSizePopup.addItems(withTitles: Self.treeFontSizes.map { "\($0)" })
        treeIconSizePopup.addItems(withTitles: Self.treeIconSizes.map { "\($0)" })
        terminalTypeCombo.addItems(withObjectValues: TerminalTypes.options)
        terminalTypeCombo.numberOfVisibleItems = 8
        terminalTypeCombo.delegate = self
        terminalTypeHint.stringValue = L10n.tr(.prefTerminalTypeHint)
        for popup in [commandKeyPopup, controlKeyPopup, optionKeyPopup] {
            popup.addItems(withTitles: RemoteModifierTarget.allCases.map { $0.displayName })
            popup.widthAnchor.constraint(equalToConstant: 240).isActive = true
        }

        for control: NSControl in [
            languagePopup, appearancePopup, contrastPopup, accentPopup,
            fontPopup, fontSizePopup, treeFontSizePopup, treeIconSizePopup,
            bellCheckbox, followCheckbox,
            commandKeyPopup, controlKeyPopup, optionKeyPopup,
        ] {
            control.target = self
            control.action = #selector(controlChanged(_:))
        }

        for field in [scrollbackField, chunkField, concurrencyField, timeoutField, keepaliveField] {
            field.alignment = .left
            field.widthAnchor.constraint(equalToConstant: 140).isActive = true
            field.delegate = self
            field.target = self
            field.action = #selector(controlChanged(_:))
        }
        // 下拉框统一宽度，点开菜单时标题不会被挤成省略号。
        languagePopup.widthAnchor.constraint(equalToConstant: 240).isActive = true
        appearancePopup.widthAnchor.constraint(equalToConstant: 240).isActive = true
        contrastPopup.widthAnchor.constraint(equalToConstant: 240).isActive = true
        accentPopup.widthAnchor.constraint(equalToConstant: 240).isActive = true
        fontPopup.widthAnchor.constraint(equalToConstant: 240).isActive = true
        fontSizePopup.widthAnchor.constraint(equalToConstant: 90).isActive = true
        terminalTypeCombo.widthAnchor.constraint(equalToConstant: 240).isActive = true
        terminalTypeHint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        terminalTypeHint.textColor = .secondaryLabelColor
        terminalTypeHint.widthAnchor.constraint(equalToConstant: 240).isActive = true
        treeFontSizePopup.widthAnchor.constraint(equalToConstant: 90).isActive = true
        treeIconSizePopup.widthAnchor.constraint(equalToConstant: 90).isActive = true

        styleButton.target = self
        styleButton.action = #selector(openStyles(_:))
        styleButton.bezelStyle = .rounded

        opacitySlider.widthAnchor.constraint(equalToConstant: 190).isActive = true
        opacityValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        opacityValueLabel.alignment = .right
        opacityValueLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true
        let opacityRow = NSStackView(views: [opacitySlider, opacityValueLabel])
        opacityRow.orientation = .horizontal
        opacityRow.spacing = 8

        tabView.tabViewType = .topTabsBezelBorder
        tabItems = [
            makeTab(key: .prefTabAppearance, rows: [
                [label(.prefLanguage), languagePopup],
                [label(.prefAppearance), appearancePopup],
                [label(.prefContrast), contrastPopup],
                [label(.prefAccent), accentPopup],
                [label(.prefCustomTheme), styleButton],
                [label(.prefWindowOpacity), opacityRow],
                [label(.prefTreeFontSize), treeFontSizePopup],
                [label(.prefTreeIconSize), treeIconSizePopup],
            ]),
            makeTab(key: .prefTabTerminal, rows: [
                [label(.prefTerminalFont), fontPopup],
                [label(.prefTerminalFontSize), fontSizePopup],
                [label(.prefTerminalType), terminalTypeCombo],
                [NSView(), terminalTypeHint],
                [label(.prefScrollback), scrollbackField],
                [label(.prefBell), bellCheckbox],
                [label(.prefFollowDirectory), followCheckbox],
            ]),
            makeTab(key: .prefTabConnection, rows: [
                [label(.prefConnectTimeout), timeoutField],
                [label(.prefKeepalive), keepaliveField],
                [label(.prefUploadChunk), chunkField],
                [label(.prefMaxConcurrent), concurrencyField],
            ]),
            makeTab(key: .prefTabRemoteDesktop, rows: [
                [label(.prefRemoteCommandKey), commandKeyPopup],
                [label(.prefRemoteControlKey), controlKeyPopup],
                [label(.prefRemoteOptionKey), optionKeyPopup],
            ]),
        ]
        for (item, _) in tabItems {
            tabView.addTabViewItem(item)
        }

        let container = NSView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            tabView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            tabView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            tabView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
        window.contentView = container
        // 按内容定高宽：以前写死 420，行数一多底部按钮就被裁掉，点起来像没反应。
        window.setContentSize(container.fittingSize)
        window.minSize = window.frame.size
    }

    private func makeTab(key: L10nKey, rows: [[NSView]]) -> (NSTabViewItem, L10nKey) {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading

        let page = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: page.topAnchor, constant: 18),
            grid.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 18),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: page.trailingAnchor, constant: -18),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: page.bottomAnchor, constant: -18),
        ])

        let item = NSTabViewItem(identifier: key)
        item.label = L10n.tr(key)
        item.view = page
        return (item, key)
    }

    /// 标签与内容都靠左；固定标签列宽，右侧控件才会在同一条竖线上。
    private func label(_ key: L10nKey) -> NSTextField {
        let field = NSTextField(labelWithString: L10n.tr(key))
        field.alignment = .left
        field.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        localizedLabels.append((field, key))
        return field
    }

    @objc private func settingsDidChange() {
        applyLocalization()
    }

    private func applyLocalization() {
        window?.title = L10n.tr(.preferencesTitle)
        for (item, key) in tabItems {
            item.label = L10n.tr(key)
        }
        for (field, key) in localizedLabels {
            field.stringValue = L10n.tr(key)
        }
        let selectedLang = languagePopup.indexOfSelectedItem
        languagePopup.removeAllItems()
        languagePopup.addItems(withTitles: AppLanguage.allCases.map { $0.displayName })
        if selectedLang >= 0 { languagePopup.selectItem(at: selectedLang) }
        languagePopup.toolTip = L10n.tr(.prefLanguageHint)

        let selectedAppearance = appearancePopup.indexOfSelectedItem
        appearancePopup.removeAllItems()
        appearancePopup.addItems(withTitles: AppearanceMode.allCases.map { $0.displayName })
        if selectedAppearance >= 0 { appearancePopup.selectItem(at: selectedAppearance) }

        let selectedContrast = contrastPopup.indexOfSelectedItem
        contrastPopup.removeAllItems()
        contrastPopup.addItems(withTitles: UIContrast.allCases.map { $0.displayName })
        if selectedContrast >= 0 { contrastPopup.selectItem(at: selectedContrast) }

        let selectedAccent = accentPopup.indexOfSelectedItem
        accentPopup.removeAllItems()
        accentPopup.addItems(withTitles: AccentColor.allCases.map { $0.displayName })
        if selectedAccent >= 0 { accentPopup.selectItem(at: selectedAccent) }
        accentPopup.toolTip = L10n.tr(.prefAccentTooltip)

        styleButton.title = L10n.tr(.prefStyleButton)
        terminalTypeHint.stringValue = L10n.tr(.prefTerminalTypeHint)
        bellCheckbox.title = L10n.tr(.prefBellTitle)
        followCheckbox.title = L10n.tr(.prefFollowDirectoryTitle)
        scrollbackField.toolTip = L10n.tr(.prefScrollbackTooltip)
    }

    private func load(_ settings: AppSettings) {
        isLoading = true
        defer { isLoading = false }
        languagePopup.selectItem(at: AppLanguage.allCases.firstIndex(of: settings.language) ?? 0)
        appearancePopup.selectItem(at: AppearanceMode.allCases.firstIndex(of: settings.appearance) ?? 0)
        contrastPopup.selectItem(at: UIContrast.allCases.firstIndex(of: settings.contrast) ?? 0)
        accentPopup.selectItem(at: AccentColor.allCases.firstIndex(of: settings.accent) ?? 0)
        opacitySlider.doubleValue = settings.windowOpacity
        updateOpacityLabel(settings.windowOpacity)
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
        scrollbackField.toolTip = L10n.tr(.prefScrollbackTooltip)
        terminalTypeCombo.stringValue = settings.terminalType
        bellCheckbox.state = settings.playBellSound ? .on : .off
        followCheckbox.state = settings.followTerminalDirectory ? .on : .off
        chunkField.stringValue = String(format: "%.1f", Double(settings.uploadChunkBytes) / 1_048_576)
        concurrencyField.stringValue = "\(settings.maxConcurrentTransfers)"
        timeoutField.stringValue = "\(settings.defaultConnectTimeout)"
        keepaliveField.stringValue = "\(settings.defaultKeepaliveInterval)"
        commandKeyPopup.selectItem(at: RemoteModifierTarget.allCases.firstIndex(of: settings.remoteKeyMapping.commandKey) ?? 0)
        controlKeyPopup.selectItem(at: RemoteModifierTarget.allCases.firstIndex(of: settings.remoteKeyMapping.controlKey) ?? 0)
        optionKeyPopup.selectItem(at: RemoteModifierTarget.allCases.firstIndex(of: settings.remoteKeyMapping.optionKey) ?? 0)
    }

    /// 下拉框选项顺序就是枚举 allCases 的顺序，按索引反查即可。
    private func selected<T>(_ popup: NSPopUpButton, _ values: [T]) -> T {
        values[min(max(popup.indexOfSelectedItem, 0), values.count - 1)]
    }

    func show(relativeTo anchorWindow: NSWindow?) {
        window?.positionCentered(relativeTo: anchorWindow)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func controlChanged(_ sender: Any?) {
        persistSettings()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        persistSettings()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            close()
            return true
        }
        return false
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        // 下拉选择变更时 stringValue 尚未同步为选中项，延后一个主循环周期读取。
        DispatchQueue.main.async { [weak self] in
            self?.persistSettings()
        }
    }

    private func persistSettings() {
        guard !isLoading else { return }
        let fontName = fontPopup.titleOfSelectedItem ?? "Menlo Regular"
        do {
            try store.update { settings in
                settings.language = selected(languagePopup, AppLanguage.allCases)
                settings.appearance = selected(appearancePopup, AppearanceMode.allCases)
                settings.contrast = selected(contrastPopup, UIContrast.allCases)
                settings.accent = selected(accentPopup, AccentColor.allCases)
                settings.windowOpacity = opacitySlider.doubleValue
                settings.terminalFontName = fontName
                settings.terminalFontSize = Double(fontSizePopup.titleOfSelectedItem ?? "13") ?? 13
                // 输入框可以留空，但设置里的默认值必须是能直接当 TERM 用的具体名字。
                settings.terminalType = TerminalTypes.resolved(terminalTypeCombo.stringValue,
                                                              default: TerminalTypes.fallback)
                settings.fileTreeFontSize = Double(treeFontSizePopup.titleOfSelectedItem ?? "12") ?? 12
                settings.fileTreeIconSize = Double(treeIconSizePopup.titleOfSelectedItem ?? "13") ?? 13
                settings.scrollbackLines = Int(scrollbackField.stringValue) ?? settings.scrollbackLines
                settings.playBellSound = bellCheckbox.state == .on
                settings.followTerminalDirectory = followCheckbox.state == .on
                settings.uploadChunkBytes = Int((Double(chunkField.stringValue) ?? 8) * 1_048_576)
                settings.maxConcurrentTransfers = Int(concurrencyField.stringValue) ?? settings.maxConcurrentTransfers
                settings.defaultConnectTimeout = Int(timeoutField.stringValue) ?? settings.defaultConnectTimeout
                settings.defaultKeepaliveInterval = Int(keepaliveField.stringValue) ?? settings.defaultKeepaliveInterval
                settings.remoteKeyMapping = RemoteKeyMapping(
                    commandKey: selected(commandKeyPopup, RemoteModifierTarget.allCases),
                    controlKey: selected(controlKeyPopup, RemoteModifierTarget.allCases),
                    optionKey: selected(optionKeyPopup, RemoteModifierTarget.allCases)
                )
            }
        } catch {
            AlertPresenter.fail(title: L10n.tr(.prefSaveFailedTitle), message: error.localizedDescription, in: window)
        }
    }

    func showStyles() {
        if styleWindow == nil {
            let editor = StylePreferencesWindowController(store: store)
            editor.onApply = { [weak self] settings in
                guard let self else { return }
                // 页面样式中的字体变更回填到普通设置，保留其它尚未保存的输入。
                if !self.fontPopup.itemTitles.contains(settings.terminalFontName) {
                    self.fontPopup.addItem(withTitle: settings.terminalFontName)
                }
                self.fontPopup.selectItem(withTitle: settings.terminalFontName)
                let size = "\(settings.terminalFontSize)"
                if !self.fontSizePopup.itemTitles.contains(size) { self.fontSizePopup.addItem(withTitle: size) }
                self.fontSizePopup.selectItem(withTitle: size)
            }
            styleWindow = editor
        }
        styleWindow?.show()
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        let value = sender.doubleValue
        updateOpacityLabel(value)
        NotificationCenter.default.post(
            name: .mioTermWindowOpacityPreview,
            object: nil,
            userInfo: ["opacity": value]
        )
        opacitySaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.persistSettings()
        }
        opacitySaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func updateOpacityLabel(_ value: Double) {
        opacityValueLabel.stringValue = "\(Int(round(value * 100)))%"
    }

    @objc private func openStyles(_ sender: Any?) { showStyles() }

    func windowWillClose(_ notification: Notification) {
        opacitySaveWorkItem?.cancel()
        opacitySaveWorkItem = nil
        window?.makeFirstResponder(nil)
        persistSettings()
    }
}

extension NSWindow {
    /// 水平居中于锚点窗口，顶部比锚点窗口顶部低 `topOffset`（避开工具栏），并限制在屏幕可视区域内。
    func positionCentered(relativeTo anchorWindow: NSWindow?, topOffset: CGFloat = 56) {
        guard let anchor = anchorWindow else {
            center()
            return
        }
        let anchorFrame = anchor.frame
        let size = frame.size
        let visible = (anchor.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rawX = anchorFrame.midX - size.width / 2
        let rawY = anchorFrame.maxY - topOffset - size.height
        let x = min(max(rawX, visible.minX), max(visible.minX, visible.maxX - size.width))
        let y = min(max(rawY, visible.minY), max(visible.minY, visible.maxY - size.height))
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
