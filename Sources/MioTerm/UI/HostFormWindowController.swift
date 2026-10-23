import AppKit
import MioTermCore

/// 主机配置表单。口令字段留空表示“不修改已保存的值”，避免每次编辑都要重打密码；
/// 机密只进 Keychain，JSON 配置里不落任何口令。
@MainActor
final class HostFormWindowController: NSWindowController {
    private let original: HostProfile
    private let environment: AppEnvironment

    private let nameField = NSTextField()
    private let groupField = NSTextField()
    private let tagsField = NSTextField()
    private let protocolPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
    private let addressField = NSTextField()
    private let portField = NSTextField()
    private let usernameField = NSTextField()
    private let authPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    private let identityField = NSTextField()
    private let secretField = NSSecureTextField()
    private let clearSecretCheckbox = NSButton(checkboxWithTitle: "清除已保存的口令", target: nil, action: nil)
    private let timeoutField = NSTextField()
    private let keepaliveField = NSTextField()
    private let startupDirectoryField = NSTextField()
    private let terminalTypeField = NSTextField()
    private let favoriteCheckbox = NSButton(checkboxWithTitle: "收藏", target: nil, action: nil)
    private let notesView = NSTextView()
    private let fingerprintLabel = NSTextField(labelWithString: "")
    private var grid = NSGridView()

    private var selectedMethod: AuthMethod {
        AuthMethod.allCases[min(max(authPopup.indexOfSelectedItem, 0), AuthMethod.allCases.count - 1)]
    }

    init(host: HostProfile, environment: AppEnvironment) {
        self.original = host
        self.environment = environment
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = host.name.isEmpty ? "新增主机" : "编辑 \(host.name)"
        super.init(window: window)
        buildContents()
        load(from: host)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    private func buildContents() {
        guard let window else { return }

        protocolPopup.addItem(withTitle: ConnectionProtocol.ssh.displayName)
        protocolPopup.selectItem(at: 0)
        protocolPopup.isEnabled = false

        authPopup.addItems(withTitles: AuthMethod.allCases.map { $0.displayName })
        authPopup.target = self
        authPopup.action = #selector(authChanged(_:))

        clearSecretCheckbox.target = self
        clearSecretCheckbox.action = #selector(clearSecretChanged(_:))

        portField.placeholderString = "22"
        timeoutField.placeholderString = "10"
        keepaliveField.placeholderString = "30"
        terminalTypeField.placeholderString = "xterm-256color"
        addressField.placeholderString = "host.example.com 或 192.168.1.10"
        usernameField.placeholderString = NSUserName()
        startupDirectoryField.placeholderString = "/var/log"
        tagsField.placeholderString = "逗号分隔"
        secretField.placeholderString = "未保存"

        let pickButton = NSButton(title: "选择…", target: self, action: #selector(pickIdentity(_:)))
        pickButton.bezelStyle = .rounded
        let identityStack = NSStackView(views: [identityField, pickButton])
        identityStack.orientation = .horizontal
        identityStack.spacing = 6

        notesView.isRichText = false
        notesView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        notesView.isVerticallyResizable = true
        notesView.textContainer?.widthTracksTextView = true
        let notesScroll = NSScrollView()
        notesScroll.documentView = notesView
        notesScroll.hasVerticalScroller = true
        notesScroll.borderType = .bezelBorder
        notesScroll.heightAnchor.constraint(equalToConstant: 76).isActive = true

        let saveButton = NSButton(title: "保存", target: self, action: #selector(save(_:)))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), saveButton, cancelButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        grid = NSGridView(views: [
            [label("名称"), nameField],
            [label("分组"), groupField],
            [label("标签"), tagsField],
            [label("协议"), protocolPopup],
            [label("地址"), addressField],
            [label("端口"), portField],
            [label("用户名"), usernameField],
            [label("认证方式"), authPopup],
            [label("私钥文件"), identityStack],
            [label("口令"), secretField],
            [NSView(), clearSecretCheckbox],
            [label("超时 (秒)"), timeoutField],
            [label("保活 (秒)"), keepaliveField],
            [label("启动目录"), startupDirectoryField],
            [label("终端类型"), terminalTypeField],
            [NSView(), favoriteCheckbox],
            [label("备注"), notesScroll],
            [label("已记录指纹"), fingerprintLabel],
            [NSView(), buttons],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        for field in [nameField, groupField, tagsField, addressField, startupDirectoryField, terminalTypeField, secretField] {
            field.widthAnchor.constraint(equalToConstant: 330).isActive = true
        }
        identityField.widthAnchor.constraint(equalToConstant: 280).isActive = true

        let container = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
        ])
        window.contentView = container
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }

    private func load(from host: HostProfile) {
        nameField.stringValue = host.name
        groupField.stringValue = host.group
        tagsField.stringValue = host.tags.joined(separator: ", ")
        addressField.stringValue = host.address
        portField.stringValue = "\(host.port)"
        usernameField.stringValue = host.username
        authPopup.selectItem(at: AuthMethod.allCases.firstIndex(of: host.authMethod) ?? 0)
        identityField.stringValue = host.identityFile
        startupDirectoryField.stringValue = host.startupDirectory
        terminalTypeField.stringValue = host.terminalType
        timeoutField.stringValue = "\(host.connectTimeout)"
        keepaliveField.stringValue = "\(host.keepaliveInterval)"
        notesView.string = host.notes
        favoriteCheckbox.state = host.favorite ? .on : .off
        fingerprintLabel.stringValue = host.hostKeyFingerprint.isEmpty
            ? "尚未确认，首次连接时会提示"
            : "\(host.hostKeyAlgorithm) · \(host.hostKeyFingerprint)"
        if secretExists(host) {
            secretField.placeholderString = "已保存，留空表示不修改"
        }
        updateRowVisibility()
    }

    private func secretExists(_ host: HostProfile) -> Bool {
        guard let kind = credentialKind(for: host.authMethod) else { return false }
        return (try? environment.vault.secret(hostID: host.id, kind: kind))?.isEmpty == false
    }

    /// 自动模式交给 ssh 自己处理，没有需要托管的口令字段。
    private func credentialKind(for method: AuthMethod) -> KeychainVault.CredentialKind? {
        switch method {
        case .automatic: return nil
        case .password: return .password
        case .privateKey: return .passphrase
        }
    }

    @objc private func authChanged(_ sender: NSPopUpButton) { updateRowVisibility() }

    @objc private func clearSecretChanged(_ sender: NSButton) {
        secretField.isEnabled = sender.state != .on
        if sender.state == .on { secretField.stringValue = "" }
    }

    // 表单行的顺序在 buildContents 里固定，按索引隐藏比按视图查找更稳。
    private static let identityRow = 8
    private static let secretRow = 9
    private static let clearSecretRow = 10

    private func updateRowVisibility() {
        let method = selectedMethod
        setRowHidden(Self.identityRow, hidden: method == .password)
        let showsSecret = method != .automatic
        setRowHidden(Self.secretRow, hidden: !showsSecret)
        setRowHidden(Self.clearSecretRow, hidden: !showsSecret)
        clearSecretCheckbox.isEnabled = showsSecret
        if method == .automatic { clearSecretCheckbox.state = .off }
        secretField.isEnabled = clearSecretCheckbox.state != .on
    }

    private func setRowHidden(_ index: Int, hidden: Bool) {
        guard index < grid.numberOfRows else { return }
        grid.row(at: index).isHidden = hidden
    }

    @objc private func pickIdentity(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.message = "选择私钥文件（选私钥本身，不要选 .pub）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        identityField.stringValue = url.path
    }

    @objc private func save(_ sender: NSButton) {
        var host = original
        host.name = nameField.stringValue
        host.group = groupField.stringValue
        host.tags = tagsField.stringValue
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // 协议字段暂时锁死在 SSH：串口与 Telnet 传输层在阶段 2 提供，
        // 提前建好的配置会指向不存在的实现。
        host.protocolKind = .ssh
        host.address = addressField.stringValue
        host.port = Int(portField.stringValue) ?? 22
        host.username = usernameField.stringValue
        host.authMethod = selectedMethod
        host.identityFile = identityField.stringValue
        host.connectTimeout = Int(timeoutField.stringValue) ?? environment.settings.settings.defaultConnectTimeout
        host.keepaliveInterval = Int(keepaliveField.stringValue) ?? environment.settings.settings.defaultKeepaliveInterval
        host.startupDirectory = startupDirectoryField.stringValue
        host.terminalType = terminalTypeField.stringValue.isEmpty ? "xterm-256color" : terminalTypeField.stringValue
        host.favorite = favoriteCheckbox.state == .on
        host.notes = notesView.string

        do {
            let saved = try environment.hosts.save(host)
            try storeSecrets(for: saved)
            close()
        } catch {
            AlertPresenter.fail(title: "无法保存主机", message: error.localizedDescription, in: window)
        }
    }

    /// 口令写入 Keychain 的时机在配置落盘之后：新建主机的 ID 是那时才定型的，
    /// 先写会留下无人认领的条目。
    private func storeSecrets(for host: HostProfile) throws {
        guard let kind = credentialKind(for: host.authMethod) else { return }
        if clearSecretCheckbox.state == .on {
            try environment.vault.setSecret(nil, hostID: host.id, kind: kind)
            return
        }
        guard !secretField.stringValue.isEmpty else { return }
        try environment.vault.setSecret(secretField.stringValue, hostID: host.id, kind: kind)
        secretField.stringValue = ""
        secretField.placeholderString = "已保存，留空表示不修改"
    }

    @objc private func cancel(_ sender: NSButton) { close() }
}
