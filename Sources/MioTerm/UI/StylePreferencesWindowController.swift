import AppKit
import UniformTypeIdentifiers
import MioTermCore

/// 颜色草稿只影响右侧预览；应用后才持久化并通知所有已打开窗口。
@MainActor
final class StylePreferencesWindowController: NSWindowController, NSTextFieldDelegate {
    private let store: SettingsStore
    var onApply: ((AppSettings) -> Void)?
    private var draft = AppSettings.default
    private let presetPopup = NSPopUpButton()
    private let mode = NSSegmentedControl(labels: [L10n.tr(.styleModeDarkPalette), L10n.tr(.styleModeLightPalette)], trackingMode: .selectOne, target: nil, action: nil)
    private let fontPopup = NSPopUpButton()
    private let sizePopup = NSPopUpButton()
    private let preview = StylePreviewView()
    private var wells: [ThemeColorRole: NSColorWell] = [:]
    private var fields: [ThemeColorRole: NSTextField] = [:]
    private var editingModes: [ObjectIdentifier: Bool] = [:]
    private var editingDark: Bool { mode.selectedSegment == 0 }

    init(store: SettingsStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 930, height: 650),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.tr(.styleWindowTitle)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        window.minSize = NSSize(width: 840, height: 560)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    func show() {
        draft = store.settings
        editingModes.removeAll()
        mode.selectedSegment = Theme.isDark() ? 0 : 1
        presetPopup.selectItem(at: 0)
        loadFonts()
        reloadColors()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func row(_ title: String, _ controls: [NSView]) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.widthAnchor.constraint(equalToConstant: 128).isActive = true
        let row = NSStackView(views: [label] + controls)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        return row
    }

    private func build() {
        let root = NSView()
        window?.contentView = root
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let document = FlippedStyleDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let controls = NSStackView()
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(controls)
        presetPopup.addItems(withTitles: [L10n.tr(.styleCustomPreset)] + ThemePreset.allCases.map(\.displayName))
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged(_:))
        presetPopup.widthAnchor.constraint(equalToConstant: 200).isActive = true
        controls.addArrangedSubview(row(L10n.tr(.stylePresetLabel), [presetPopup]))
        mode.target = self
        mode.action = #selector(modeChanged(_:))
        controls.addArrangedSubview(mode)
        let hint = NSTextField(wrappingLabelWithString: L10n.tr(.styleColorHint))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.widthAnchor.constraint(equalToConstant: 346).isActive = true
        controls.addArrangedSubview(hint)
        for (index, role) in ThemeColorRole.allCases.enumerated() {
            let well = NSColorWell()
            well.tag = index
            well.target = self
            well.action = #selector(colorChanged(_:))
            well.widthAnchor.constraint(equalToConstant: 38).isActive = true
            well.heightAnchor.constraint(equalToConstant: 25).isActive = true
            let field = NSTextField()
            field.tag = index
            field.delegate = self
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.widthAnchor.constraint(equalToConstant: 86).isActive = true
            field.setAccessibilityLabel(L10n.tr(.styleHexAccessibility, role.displayName))
            well.setAccessibilityLabel(role.displayName)
            let reset = button(L10n.tr(.styleResetItem), #selector(resetColor(_:)))
            reset.tag = index
            reset.setAccessibilityLabel(L10n.tr(.styleResetAccessibility, role.displayName))
            reset.controlSize = .small
            wells[role] = well
            fields[role] = field
            controls.addArrangedSubview(row(role.displayName, [well, field, reset]))
        }
        for name in ["Menlo-Regular", "Monaco", "SFMono-Regular", "JetBrainsMono-Regular", "Hack-Regular", "FiraCode-Regular"] {
            if let font = NSFont(name: name, size: 13) { fontPopup.addItem(withTitle: font.fontName) }
        }
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged(_:))
        fontPopup.widthAnchor.constraint(equalToConstant: 200).isActive = true
        sizePopup.addItems(withTitles: ["11", "12", "13", "14", "15", "16", "18", "20", "24", "28", "32"])
        sizePopup.target = self
        sizePopup.action = #selector(fontChanged(_:))
        controls.addArrangedSubview(row(L10n.tr(.prefTerminalFont), [fontPopup]))
        controls.addArrangedSubview(row(L10n.tr(.prefTerminalFontSize), [sizePopup]))
        let doneButton = button(L10n.tr(.commonDone), #selector(done(_:)))
        doneButton.keyEquivalent = "\r"
        let cancelButton = button(L10n.tr(.commonCancel), #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [button(L10n.tr(.styleImport), #selector(importTheme(_:))),
                                         button(L10n.tr(.styleExport), #selector(exportTheme(_:))), NSView(),
                                         button(L10n.tr(.styleResetAll), #selector(resetAll(_:))),
                                         cancelButton,
                                         button(L10n.tr(.commonApply), #selector(apply(_:))),
                                         doneButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        let previewTitle = NSTextField(labelWithString: L10n.tr(.stylePreviewTitle))
        previewTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        let previewHint = NSTextField(wrappingLabelWithString: L10n.tr(.stylePreviewHint))
        previewHint.font = .systemFont(ofSize: 12)
        previewHint.textColor = .secondaryLabelColor
        for child in [scroll, previewTitle, previewHint, preview, footer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalToConstant: 392),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            controls.topAnchor.constraint(equalTo: document.topAnchor),
            controls.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -8),
            controls.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
            previewTitle.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 20),
            previewTitle.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            previewHint.leadingAnchor.constraint(equalTo: previewTitle.leadingAnchor),
            previewHint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            previewHint.topAnchor.constraint(equalTo: previewTitle.bottomAnchor, constant: 8),
            preview.leadingAnchor.constraint(equalTo: previewTitle.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            preview.topAnchor.constraint(equalTo: previewHint.bottomAnchor, constant: 20),
            preview.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -20),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
    }

    private func loadFonts() {
        if !fontPopup.itemTitles.contains(draft.terminalFontName) { fontPopup.addItem(withTitle: draft.terminalFontName) }
        fontPopup.selectItem(withTitle: draft.terminalFontName)
        let size = String(format: "%g", draft.terminalFontSize)
        if !sizePopup.itemTitles.contains(size) { sizePopup.addItem(withTitle: size) }
        sizePopup.selectItem(withTitle: size)
    }

    private func reloadColors() {
        let palette = ThemePalette.palette(dark: editingDark, contrast: draft.contrast, accent: draft.accent)
        for role in ThemeColorRole.allCases {
            let rgb = draft.themeCustomization.resolved(role, palette: palette, dark: editingDark)
            wells[role]?.color = NSColor(srgbRed: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255, alpha: 1)
            fields[role]?.stringValue = rgb.hexString
            fields[role]?.textColor = .labelColor
        }
        refreshPreview()
    }

    private func refreshPreview() {
        preview.settings = draft
        preview.dark = editingDark
        preview.needsDisplay = true
    }

    @objc private func modeChanged(_ sender: Any?) { reloadColors() }
    @objc private func presetChanged(_ sender: Any?) {
        guard presetPopup.indexOfSelectedItem > 0 else { return }
        draft.themeCustomization = ThemePreset.allCases[presetPopup.indexOfSelectedItem - 1].customization
        reloadColors()
    }
    @objc private func colorChanged(_ sender: NSColorWell) {
        guard let color = sender.color.usingColorSpace(.sRGB) else { return }
        func channel(_ value: CGFloat) -> UInt8 { UInt8((min(1, max(0, value)) * 255).rounded()) }
        let rgb = ThemeRGB(channel(color.redComponent), channel(color.greenComponent), channel(color.blueComponent))
        draft.themeCustomization.set(rgb, for: ThemeColorRole.allCases[sender.tag], dark: editingDark)
        presetPopup.selectItem(at: 0)
        reloadColors()
    }
    func controlTextDidBeginEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField { editingModes[ObjectIdentifier(field)] = editingDark }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              ThemeColorRole.allCases.indices.contains(field.tag) else { return }
        let dark = editingModes.removeValue(forKey: ObjectIdentifier(field)) ?? editingDark
        guard let rgb = ThemeRGB(hex: field.stringValue) else { field.textColor = .systemRed; return }
        draft.themeCustomization.set(rgb, for: ThemeColorRole.allCases[field.tag], dark: dark)
        presetPopup.selectItem(at: 0)
        reloadColors()
    }
    @objc private func resetColor(_ sender: NSButton) {
        draft.themeCustomization.set(nil, for: ThemeColorRole.allCases[sender.tag], dark: editingDark)
        presetPopup.selectItem(at: 0)
        reloadColors()
    }
    @objc private func resetAll(_ sender: Any?) {
        draft.themeCustomization = ThemeCustomization()
        presetPopup.selectItem(at: 1)
        reloadColors()
    }
    @objc private func fontChanged(_ sender: Any?) {
        draft.terminalFontName = fontPopup.titleOfSelectedItem ?? draft.terminalFontName
        draft.terminalFontSize = Double(sizePopup.titleOfSelectedItem ?? "13") ?? 13
        refreshPreview()
    }
    private func finishColorEditing() -> Bool {
        window?.makeFirstResponder(nil)
        guard fields.values.allSatisfy({ ThemeRGB(hex: $0.stringValue) != nil }) else {
            AlertPresenter.fail(title: L10n.tr(.styleInvalidColorTitle), message: L10n.tr(.styleInvalidColorMsg), in: window)
            return false
        }
        return true
    }
    private func save() -> Bool {
        guard finishColorEditing() else { return false }
        do {
            try store.update {
                $0.themeCustomization = draft.themeCustomization
                $0.terminalFontName = draft.terminalFontName
                $0.terminalFontSize = draft.terminalFontSize
            }
            onApply?(store.settings)
            return true
        } catch { AlertPresenter.fail(title: L10n.tr(.styleSaveFailedTitle), message: error.localizedDescription, in: window); return false }
    }
    @objc private func apply(_ sender: Any?) { _ = save() }
    @objc private func done(_ sender: Any?) { if save() { close() } }
    @objc private func cancel(_ sender: Any?) { close() }
    @objc private func importTheme(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: ThemeCustomization.maximumFileBytes + 1) ?? Data()
            draft.themeCustomization = try ThemeCustomization.imported(from: data)
            presetPopup.selectItem(at: 0)
            reloadColors()
        } catch { AlertPresenter.fail(title: L10n.tr(.styleImportFailedTitle), message: error.localizedDescription, in: window) }
    }
    @objc private func exportTheme(_ sender: Any?) {
        guard finishColorEditing() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MioTerm-theme.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try draft.themeCustomization.exportedData().write(to: url, options: .atomic) }
        catch { AlertPresenter.fail(title: L10n.tr(.styleExportFailedTitle), message: error.localizedDescription, in: window) }
    }
    override func close() {
        for well in wells.values { well.deactivate() }
        super.close()
    }
}

private final class FlippedStyleDocumentView: NSView { override var isFlipped: Bool { true } }

/// 原生轻量预览：不创建 PTY、SSH 连接或 SwiftTerm 缓冲。
@MainActor
private final class StylePreviewView: NSView {
    var settings = AppSettings.default
    var dark = true
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let base = ThemePalette.palette(dark: dark, contrast: settings.contrast, accent: settings.accent)
        func color(_ role: ThemeColorRole) -> NSColor {
            let value = settings.themeCustomization.resolved(role, palette: base, dark: dark)
            return NSColor(srgbRed: Double(value.red) / 255, green: Double(value.green) / 255, blue: Double(value.blue) / 255, alpha: 1)
        }
        func fill(_ role: ThemeColorRole, _ rect: NSRect) { color(role).setFill(); rect.fill() }
        func text(_ value: String, x: CGFloat, y: CGFloat, role: ThemeColorRole, font: NSFont) {
            (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.foregroundColor: color(role), .font: font])
        }
        fill(.background, bounds)
        fill(.tabBar, NSRect(x: 0, y: 0, width: bounds.width, height: 40))
        fill(.selectedTab, NSRect(x: 12, y: 7, width: 138, height: 28))
        let ui = NSFont.systemFont(ofSize: 11, weight: .medium)
        text(L10n.tr(.stylePreviewDevServer), x: 22, y: 14, role: .text, font: ui)
        text(L10n.tr(.stylePreviewLocalTerm), x: 170, y: 14, role: .secondaryText, font: ui)
        fill(.sidebar, NSRect(x: 0, y: 41, width: 112, height: bounds.height - 41))
        text(L10n.tr(.stylePreviewHostList), x: 14, y: 56, role: .secondaryText, font: ui)
        fill(.surface, NSRect(x: 7, y: 84, width: 98, height: 28))
        text(L10n.tr(.stylePreviewDevEnv), x: 14, y: 93, role: .accent, font: ui)
        text(L10n.tr(.stylePreviewProdEnv), x: 24, y: 134, role: .text, font: ui)
        fill(.terminalBackground, NSRect(x: 113, y: 41, width: bounds.width - 113, height: bounds.height - 41))
        let font = NSFont(name: settings.terminalFontName, size: CGFloat(settings.terminalFontSize)) ?? .monospacedSystemFont(ofSize: CGFloat(settings.terminalFontSize), weight: .regular)
        let x: CGFloat = 128
        let line = max(22, font.pointSize + 7)
        text("user@server ~ %", x: x, y: 62, role: .accent, font: font)
        text("ls -la", x: x, y: 62 + line, role: .terminalForeground, font: font)
        text("drwxr-xr-x  projects", x: x, y: 62 + line * 3, role: .terminalForeground, font: font)
        fill(.selectionBackground, NSRect(x: x - 3, y: 59 + line * 4, width: max(0, bounds.width - x - 14), height: line))
        text("-rw-r--r--  README.md", x: x, y: 62 + line * 4, role: .selectionForeground, font: font)
        fill(.cursor, NSRect(x: x, y: 64 + line * 6, width: 8, height: font.pointSize + 2))
    }
}
