import AppKit
import MioTermCore

/// 主机配置表单。口令字段留空表示“不修改已保存的值”，避免每次编辑都要重打密码；
/// 机密只进 Keychain，JSON 配置里不落任何口令。
@MainActor
final class HostFormWindowController: NSWindowController {
    private let original: HostProfile
    private let environment: AppEnvironment

    private let nameField = NSTextField()
    /// 分组既可从已有分组里挑，也可直接输入新名字。
    private let groupField = NSComboBox()
    private let tagsField = NSTextField()
    private let protocolPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
    private let addressField = NSTextField()
    private let portField = NSTextField()
    private let usernameField = NSTextField()
    private let authPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    private let identityField = NSTextField()
    private let secretField = NSSecureTextField()
    private let clearSecretCheckbox = NSButton(checkboxWithTitle: L10n.tr(.hostFormClearSecret), target: nil, action: nil)
    private let timeoutField = NSTextField()
    private let keepaliveField = NSTextField()
    private let startupDirectoryField = NSTextField()
    /// 终端类型可从常用 TERM 里挑，也能直接输入；留空表示跟随设置里的默认值。
    private let terminalTypeField = NSComboBox()
    /// X11 转发：远端跑图形程序，窗口由本机 XQuartz 显示。
    private let x11Popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    private let sftpCheckbox = NSButton(checkboxWithTitle: L10n.tr(.hostFormSFTPCheckbox), target: nil, action: nil)
    private let favoriteCheckbox = NSButton(checkboxWithTitle: L10n.tr(.hostFormFavorite), target: nil, action: nil)
    private let notesView = NSTextView()
    private let fingerprintLabel = NSTextField(labelWithString: "")

    // 串口参数：整块面板作为一行插进主表单，非串口协议时整行隐藏。
    private let devicePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
    private let baudField = NSTextField()
    private let dataBitsPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 60, height: 24))
    private let parityPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 110, height: 24))
    private let stopBitsPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 60, height: 24))
    private let lineEndingPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 90, height: 24))
    private let echoCheckbox = NSButton(checkboxWithTitle: L10n.tr(.hostFormLocalEcho), target: nil, action: nil)
    private let dtrCheckbox = NSButton(checkboxWithTitle: L10n.tr(.hostFormRaiseDTR), target: nil, action: nil)
    private let rtsCheckbox = NSButton(checkboxWithTitle: L10n.tr(.hostFormRaiseRTS), target: nil, action: nil)
    private let serialHintLabel = NSTextField(wrappingLabelWithString: "")
    private var serialPanel = NSGridView()
    private let identityStack = NSStackView()

    /// 下拉框选项顺序即对应枚举/常量的顺序，读取时按索引反查。
    private static let formDataBits = SerialConfig.supportedDataBits
    private static let formStopBits = SerialConfig.supportedStopBits

    private var grid = NSGridView()

    private var selectedMethod: AuthMethod {
        AuthMethod.allCases[min(max(authPopup.indexOfSelectedItem, 0), AuthMethod.allCases.count - 1)]
    }

    /// 下拉框的顺序就是 ConnectionProtocol.allCases 的顺序。
    /// 协议下拉框的选项顺序，与 buildContents 里的填充顺序一致。
    private static let formProtocols: [ConnectionProtocol] = ConnectionProtocol.allCases

    private var selectedProtocol: ConnectionProtocol {
        Self.formProtocols[min(max(protocolPopup.indexOfSelectedItem, 0), Self.formProtocols.count - 1)]
    }

    private func selected<T>(_ popup: NSPopUpButton, _ values: [T]) -> T {
        values[min(max(popup.indexOfSelectedItem, 0), values.count - 1)]
    }

    private var selectedDataBits: Int { selected(dataBitsPopup, Self.formDataBits) }
    private var selectedStopBits: String { selected(stopBitsPopup, Self.formStopBits) }
    private var selectedParity: Parity { selected(parityPopup, Parity.allCases) }
    private var selectedLineEnding: LineEnding { selected(lineEndingPopup, LineEnding.allCases) }
    private var selectedX11Forwarding: X11Forwarding { selected(x11Popup, X11Forwarding.allCases) }

    init(host: HostProfile, environment: AppEnvironment) {
        self.original = host
        self.environment = environment
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 650),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = host.name.isEmpty ? L10n.tr(.hostFormNewTitle) : L10n.tr(.hostFormEditHostTitle, host.name)
        super.init(window: window)
        buildContents()
        load(from: host)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    private func buildContents() {
        guard let window else { return }

        protocolPopup.addItems(withTitles: Self.formProtocols.map { $0.displayName })
        protocolPopup.target = self
        protocolPopup.action = #selector(protocolChanged(_:))

        authPopup.addItems(withTitles: AuthMethod.allCases.map { $0.displayName })
        authPopup.target = self
        authPopup.action = #selector(authChanged(_:))

        clearSecretCheckbox.target = self
        clearSecretCheckbox.action = #selector(clearSecretChanged(_:))

        x11Popup.addItems(withTitles: X11Forwarding.allCases.map { $0.displayName })
        x11Popup.toolTip = """
        远端运行图形程序、窗口显示在本机。需要本机装有 XQuartz 并在运行，\
        且远端 sshd 开了 X11Forwarding、装了 xauth。文件面板的 SFTP 通道不受这一档影响。
        """

        portField.placeholderString = "22"
        timeoutField.placeholderString = "10"
        keepaliveField.placeholderString = "30"
        terminalTypeField.addItems(withObjectValues: TerminalTypes.options)
        terminalTypeField.numberOfVisibleItems = 8
        terminalTypeField.placeholderString = L10n.tr(.hostFormDefaultTermPlaceholder, environment.settings.settings.terminalType)
        addressField.placeholderString = L10n.tr(.hostFormAddressPlaceholder)
        usernameField.placeholderString = NSUserName()
        startupDirectoryField.placeholderString = "/var/log"
        tagsField.placeholderString = L10n.tr(.hostFormTagsPlaceholder)
        secretField.placeholderString = L10n.tr(.hostFormSecretUnsaved)
        groupField.removeAllItems()
        groupField.addItems(withObjectValues: HostSorting.groupNames(environment.hosts.hosts))
        groupField.numberOfVisibleItems = 8
        groupField.placeholderString = L10n.tr(.hostFormGroupPlaceholder)

        let pickButton = NSButton(title: L10n.tr(.hostFormPickButton), target: self, action: #selector(pickIdentity(_:)))
        pickButton.bezelStyle = .rounded
        identityStack.addArrangedSubview(identityField)
        identityStack.addArrangedSubview(pickButton)
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

        let saveButton = NSButton(title: L10n.tr(.commonSave), target: self, action: #selector(save(_:)))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: L10n.tr(.commonCancel), target: self, action: #selector(cancel(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [NSView(), saveButton, cancelButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        serialPanel = buildSerialPanel()

        grid = NSGridView(views: [
            [label(L10n.tr(.hostFormName)), nameField],
            [label(L10n.tr(.hostFormGroup)), groupField],
            [label(L10n.tr(.hostFormTags)), tagsField],
            [label(L10n.tr(.hostFormProtocol)), protocolPopup],
            [NSView(), serialPanel],
            [label(L10n.tr(.hostFormAddress)), addressField],
            [label(L10n.tr(.hostFormPort)), portField],
            [label(L10n.tr(.hostFormUsername)), usernameField],
            [label(L10n.tr(.hostFormAuthMethod)), authPopup],
            [label(L10n.tr(.hostFormIdentityFile)), identityStack],
            [label(L10n.tr(.hostFormSecret)), secretField],
            [NSView(), clearSecretCheckbox],
            [label(L10n.tr(.hostFormTimeout)), timeoutField],
            [label(L10n.tr(.hostFormKeepalive)), keepaliveField],
            [label(L10n.tr(.hostFormStartupDir)), startupDirectoryField],
            [label(L10n.tr(.hostFormTerminalType)), terminalTypeField],
            [label(L10n.tr(.hostFormX11)), x11Popup],
            [NSView(), sftpCheckbox],
            [NSView(), favoriteCheckbox],
            [label(L10n.tr(.hostFormNotes)), notesScroll],
            [label(L10n.tr(.hostFormFingerprint)), fingerprintLabel],
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

    /// 串口参数只在协议为串口时显示，整块塞进一行便于统一隐藏。
    private func buildSerialPanel() -> NSGridView {
        let refreshButton = NSButton(title: L10n.tr(.commonRefresh), target: self, action: #selector(refreshSerialDevices(_:)))
        refreshButton.bezelStyle = .rounded
        let deviceStack = NSStackView(views: [devicePopup, refreshButton])
        deviceStack.orientation = .horizontal
        deviceStack.spacing = 6

        dataBitsPopup.addItems(withTitles: Self.formDataBits.map(String.init))
        parityPopup.addItems(withTitles: Parity.allCases.map { $0.displayName })
        stopBitsPopup.addItems(withTitles: Self.formStopBits)
        lineEndingPopup.addItems(withTitles: LineEnding.allCases.map { $0.rawValue })
        devicePopup.widthAnchor.constraint(equalToConstant: 250).isActive = true

        baudField.placeholderString = "115200"
        baudField.alignment = .right
        baudField.widthAnchor.constraint(equalToConstant: 76).isActive = true

        // 帧格式三个下拉并排：拆成三行会让面板比主表单还长。
        // 下拉框不写死宽度，让它们按最长条目自撑——校验位带中文说明，压窄了会截断。
        let frameStack = NSStackView(views: [
            label(L10n.tr(.hostFormDataBits)), dataBitsPopup, label(L10n.tr(.hostFormParity)), parityPopup, label(L10n.tr(.hostFormStopBits)), stopBitsPopup,
        ])
        frameStack.orientation = .horizontal
        frameStack.spacing = 4

        let inputStack = NSStackView(views: [lineEndingPopup, echoCheckbox])
        inputStack.orientation = .horizontal
        inputStack.spacing = 10
        let modemStack = NSStackView(views: [dtrCheckbox, rtsCheckbox])
        modemStack.orientation = .horizontal
        modemStack.spacing = 10

        serialHintLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        serialHintLabel.textColor = .secondaryLabelColor
        serialHintLabel.widthAnchor.constraint(equalToConstant: 380).isActive = true

        let panel = NSGridView(views: [
            [label(L10n.tr(.hostFormDevice)), deviceStack],
            [label(L10n.tr(.hostFormBaudRate)), baudField],
            [label(L10n.tr(.hostFormFrameFormat)), frameStack],
            [label(L10n.tr(.hostFormLineEnding)), inputStack],
            [label(L10n.tr(.hostFormControlLines)), modemStack],
            [NSView(), serialHintLabel],
        ])
        panel.rowSpacing = 6
        panel.columnSpacing = 8
        panel.column(at: 0).xPlacement = .trailing
        return panel
    }

    private static var serialHintNormal: String { L10n.tr(.hostFormSerialHintNormal) }
    private static var serialHintEmpty: String { L10n.tr(.hostFormSerialHintEmpty) }

    /// 刷新设备列表。编辑既有主机时把已保存的设备也留在列表里：
    /// 适配器临时不在（比如换了 USB 口）也不能悄悄改掉用户的配置。
    private func reloadSerialDevices(keeping current: String) {
        let found = SerialDevices.discover()
        var devices = found
        if !current.isEmpty, !devices.contains(current) { devices.append(current) }
        devicePopup.removeAllItems()
        devicePopup.addItems(withTitles: devices)
        if !current.isEmpty { devicePopup.selectItem(withTitle: current) }
        serialHintLabel.stringValue = found.isEmpty ? Self.serialHintEmpty : Self.serialHintNormal
        serialHintLabel.textColor = found.isEmpty ? .systemRed : .secondaryLabelColor
    }

    @objc private func refreshSerialDevices(_ sender: NSButton) {
        reloadSerialDevices(keeping: devicePopup.titleOfSelectedItem ?? "")
    }

    private func load(from host: HostProfile) {
        nameField.stringValue = host.name
        groupField.stringValue = host.group
        tagsField.stringValue = host.tags.joined(separator: ", ")
        protocolPopup.selectItem(at: Self.formProtocols.firstIndex(of: host.protocolKind) ?? 0)
        addressField.stringValue = host.address
        portField.stringValue = "\(host.port)"
        usernameField.stringValue = host.username
        authPopup.selectItem(at: AuthMethod.allCases.firstIndex(of: host.authMethod) ?? 0)
        identityField.stringValue = host.identityFile
        startupDirectoryField.stringValue = host.startupDirectory
        terminalTypeField.stringValue = host.terminalType
        x11Popup.selectItem(at: X11Forwarding.allCases.firstIndex(of: host.x11Forwarding) ?? 0)
        timeoutField.stringValue = "\(host.connectTimeout)"
        keepaliveField.stringValue = "\(host.keepaliveInterval)"
        notesView.string = host.notes
        sftpCheckbox.state = host.sftpEnabled ? .on : .off
        sftpCheckbox.toolTip = L10n.tr(.hostFormSFTPTooltip)
        favoriteCheckbox.state = host.favorite ? .on : .off
        fingerprintLabel.stringValue = host.hostKeyFingerprint.isEmpty
            ? L10n.tr(.hostFormFingerprintUnconfirmed)
            : "\(host.hostKeyAlgorithm) · \(host.hostKeyFingerprint)"
        dataBitsPopup.selectItem(at: Self.formDataBits.firstIndex(of: host.serial.dataBits) ?? 0)
        stopBitsPopup.selectItem(at: Self.formStopBits.firstIndex(of: host.serial.stopBits) ?? 0)
        parityPopup.selectItem(at: Parity.allCases.firstIndex(of: host.serial.parity) ?? 0)
        lineEndingPopup.selectItem(at: LineEnding.allCases.firstIndex(of: host.serial.lineEnding) ?? 0)
        baudField.stringValue = "\(host.serial.baudRate)"
        echoCheckbox.state = host.serial.localEcho ? .on : .off
        dtrCheckbox.state = host.serial.dtr ? .on : .off
        rtsCheckbox.state = host.serial.rts ? .on : .off
        reloadSerialDevices(keeping: host.serial.device)
        if secretExists(host) {
            secretField.placeholderString = L10n.tr(.hostFormSecretSaved)
        }
        updateRowVisibility()
    }

    private func secretExists(_ host: HostProfile) -> Bool {
        guard let kind = credentialKind(for: host.authMethod) else { return false }
        return environment.vault.hasSecret(hostID: host.id, kind: kind)
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

    @objc private func protocolChanged(_ sender: NSPopUpButton) {
        // 端口默认值跟着协议走：留着 22 去连 Telnet 一定失败，用户不必自己想到。
        let entered = Int(portField.stringValue) ?? 0
        if entered == 22 || entered == 23 { portField.stringValue = selectedProtocol.defaultPort.map(String.init) ?? "" }
        updateRowVisibility()
    }

    @objc private func clearSecretChanged(_ sender: NSButton) {
        secretField.isEnabled = sender.state != .on
        if sender.state == .on { secretField.stringValue = "" }
    }

    // 行按视图查，不按索引：串口面板插进主表单后，硬编码的行号一错就是整片。
    private func updateRowVisibility() {
        let isSerial = selectedProtocol == .serial
        // Telnet 的登录发生在会话里（设备提示 login:），既没有可托管的凭据，
        // 也没有保活、启动目录和宿主指纹这些概念。
        let isSSH = selectedProtocol == .ssh

        setRowHidden(serialPanel, hidden: !isSerial)
        setRowHidden(addressField, hidden: isSerial)
        setRowHidden(portField, hidden: isSerial)
        setRowHidden(timeoutField, hidden: isSerial)
        setRowHidden(terminalTypeField, hidden: isSerial)
        setRowHidden(usernameField, hidden: !isSSH)
        setRowHidden(authPopup, hidden: !isSSH)
        setRowHidden(keepaliveField, hidden: !isSSH)
        setRowHidden(startupDirectoryField, hidden: !isSSH)
        setRowHidden(x11Popup, hidden: !isSSH)
        setRowHidden(sftpCheckbox, hidden: !isSSH)
        setRowHidden(fingerprintLabel, hidden: !isSSH)

        let method = selectedMethod
        setRowHidden(identityStack, hidden: !isSSH || method == .password)
        let showsSecret = isSSH && method != .automatic
        setRowHidden(secretField, hidden: !showsSecret)
        setRowHidden(clearSecretCheckbox, hidden: !showsSecret)
        clearSecretCheckbox.isEnabled = showsSecret
        if method == .automatic { clearSecretCheckbox.state = .off }
        secretField.isEnabled = clearSecretCheckbox.state != .on
        portField.placeholderString = isSSH ? "22" : "23"
    }

    private func setRowHidden(_ view: NSView, hidden: Bool) {
        guard let row = grid.cell(for: view)?.row else { return }
        row.isHidden = hidden
    }

    @objc private func pickIdentity(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.message = L10n.tr(.hostFormPickKeyMessage)
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
        host.protocolKind = selectedProtocol
        host.address = addressField.stringValue
        host.port = Int(portField.stringValue) ?? (selectedProtocol.defaultPort ?? 22)
        host.username = usernameField.stringValue
        host.authMethod = selectedMethod
        host.identityFile = identityField.stringValue
        host.connectTimeout = Int(timeoutField.stringValue) ?? environment.settings.settings.defaultConnectTimeout
        host.keepaliveInterval = Int(keepaliveField.stringValue) ?? environment.settings.settings.defaultKeepaliveInterval
        host.startupDirectory = startupDirectoryField.stringValue
        // 存空串而不是当场填上默认值：这样以后改设置里的默认，未指定的主机会跟着变。
        host.terminalType = TerminalTypes.sanitized(terminalTypeField.stringValue)
        host.x11Forwarding = selectedX11Forwarding
        host.sftpEnabled = sftpCheckbox.state == .on
        host.favorite = favoriteCheckbox.state == .on
        host.notes = notesView.string
        if selectedProtocol == .serial {
            host.serial = SerialConfig(
                device: devicePopup.titleOfSelectedItem ?? "",
                baudRate: Int(baudField.stringValue) ?? 115_200,
                dataBits: selectedDataBits,
                stopBits: selectedStopBits,
                parity: selectedParity,
                lineEnding: selectedLineEnding,
                localEcho: echoCheckbox.state == .on,
                dtr: dtrCheckbox.state == .on,
                rts: rtsCheckbox.state == .on
            )
            // 串口没有地址/端口，留空免得列表副标题混进无意义的 22。
            host.address = ""
        }

        do {
            let saved = try environment.hosts.save(host)
            try storeSecrets(for: saved)
            close()
        } catch {
            AlertPresenter.fail(title: L10n.tr(.hostFormSaveFailedTitle), message: error.localizedDescription, in: window)
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
        secretField.placeholderString = L10n.tr(.hostFormSecretSaved)
    }

    @objc private func cancel(_ sender: NSButton) { close() }
}
