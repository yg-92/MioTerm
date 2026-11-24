import AppKit
import MioTermCore

/// 凭据库管理窗口：统一维护可复用的用户名与密码（密码保存在系统 Keychain 中）。
/// 左侧检索并选择凭据，右侧编辑名称、用户名、密码与备注，并显示当前关联的主机数量。
@MainActor
final class CredentialLibraryWindowController: NSWindowController, NSWindowDelegate {
    var onDidClose: (() -> Void)?

    private let environment: AppEnvironment
    private var filtered: [CredentialProfile] = []
    private var editingCredential: CredentialProfile?
    private var isCreatingNew = false
    private var showingPassword = false
    private var credentialsObserver: NSObjectProtocol?

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let addButton = NSButton()
    private let removeButton = NSButton()

    private let detailContainer = NSView()
    private let emptyHintLabel = NSTextField(labelWithString: "选择左侧凭据进行编辑，或点击「+」新建凭据")
    private let nameField = NSTextField()
    private let usernameField = NSTextField()
    private let securePasswordField = NSSecureTextField()
    private let plainPasswordField = NSTextField()
    private let togglePasswordButton = NSButton()
    private let clearPasswordCheckbox = NSButton(checkboxWithTitle: "清除已保存的密码", target: nil, action: nil)
    private let notesField = NSTextField()
    private let linkedHostsLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton()

    init(environment: AppEnvironment) {
        self.environment = environment
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 430),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "凭据库"
        window.minSize = NSSize(width: 600, height: 380)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
        reloadList(selectingID: nil)
        credentialsObserver = NotificationCenter.default.addObserver(
            forName: .mioTermCredentialsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reloadList(selectingID: self.editingCredential?.id)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("不使用 xib") }

    deinit {
        if let credentialsObserver {
            NotificationCenter.default.removeObserver(credentialsObserver)
        }
    }

    func show(relativeTo anchor: NSWindow?) {
        guard let window else { return }
        if !window.isVisible {
            window.positionCentered(relativeTo: anchor, topOffset: 36)
        }
        reloadList(selectingID: editingCredential?.id)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onDidClose?()
    }

    // MARK: - 界面搭建

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let leftPane = buildLeftPane()
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let rightPane = buildRightPane()

        contentView.addSubview(leftPane)
        contentView.addSubview(separator)
        contentView.addSubview(rightPane)

        NSLayoutConstraint.activate([
            leftPane.topAnchor.constraint(equalTo: contentView.topAnchor),
            leftPane.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            leftPane.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            leftPane.widthAnchor.constraint(equalToConstant: 245),

            separator.topAnchor.constraint(equalTo: contentView.topAnchor),
            separator.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),

            rightPane.topAnchor.constraint(equalTo: contentView.topAnchor),
            rightPane.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            rightPane.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rightPane.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func buildLeftPane() -> NSView {
        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "搜索名称、用户名或备注"
        searchField.controlSize = .small
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cred"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 46
        tableView.style = .sourceList
        tableView.dataSource = self
        tableView.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "新建凭据")
        addButton.title = "新建凭据"
        addButton.imagePosition = .imageLeading
        addButton.bezelStyle = .rounded
        addButton.controlSize = .small
        addButton.target = self
        addButton.action = #selector(createNewCredential(_:))
        addButton.translatesAutoresizingMaskIntoConstraints = false

        removeButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "删除凭据")
        removeButton.bezelStyle = .rounded
        removeButton.controlSize = .small
        removeButton.target = self
        removeButton.action = #selector(deleteSelectedCredential(_:))
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(addButton)
        footer.addSubview(removeButton)

        pane.addSubview(searchField)
        pane.addSubview(scroll)
        pane.addSubview(footer)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: pane.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -10),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 40),

            addButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 10),
            addButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),

            removeButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -10),
            removeButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
        return pane
    }

    private func buildRightPane() -> NSView {
        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false

        emptyHintLabel.textColor = .secondaryLabelColor
        emptyHintLabel.font = .systemFont(ofSize: 13)
        emptyHintLabel.alignment = .center
        emptyHintLabel.translatesAutoresizingMaskIntoConstraints = false

        detailContainer.translatesAutoresizingMaskIntoConstraints = false

        nameField.placeholderString = "例如：生产环境 root / Windows 运维账号"
        usernameField.placeholderString = "例如：root / Administrator"
        securePasswordField.placeholderString = "输入密码（安全保存在系统钥匙串）"
        plainPasswordField.placeholderString = "输入密码（安全保存在系统钥匙串）"
        plainPasswordField.isHidden = true
        notesField.placeholderString = "可选备注"

        togglePasswordButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "显示密码")
        togglePasswordButton.bezelStyle = .rounded
        togglePasswordButton.controlSize = .small
        togglePasswordButton.toolTip = "显示 / 隐藏密码"
        togglePasswordButton.target = self
        togglePasswordButton.action = #selector(togglePasswordVisibility(_:))

        clearPasswordCheckbox.target = self
        clearPasswordCheckbox.action = #selector(clearPasswordToggled(_:))

        let passwordHost = NSView()
        passwordHost.translatesAutoresizingMaskIntoConstraints = false
        securePasswordField.translatesAutoresizingMaskIntoConstraints = false
        plainPasswordField.translatesAutoresizingMaskIntoConstraints = false
        passwordHost.addSubview(securePasswordField)
        passwordHost.addSubview(plainPasswordField)
        NSLayoutConstraint.activate([
            securePasswordField.topAnchor.constraint(equalTo: passwordHost.topAnchor),
            securePasswordField.bottomAnchor.constraint(equalTo: passwordHost.bottomAnchor),
            securePasswordField.leadingAnchor.constraint(equalTo: passwordHost.leadingAnchor),
            securePasswordField.trailingAnchor.constraint(equalTo: passwordHost.trailingAnchor),
            plainPasswordField.topAnchor.constraint(equalTo: passwordHost.topAnchor),
            plainPasswordField.bottomAnchor.constraint(equalTo: passwordHost.bottomAnchor),
            plainPasswordField.leadingAnchor.constraint(equalTo: passwordHost.leadingAnchor),
            plainPasswordField.trailingAnchor.constraint(equalTo: passwordHost.trailingAnchor),
            passwordHost.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])

        let passwordRow = NSStackView(views: [passwordHost, togglePasswordButton])
        passwordRow.orientation = .horizontal
        passwordRow.spacing = 6

        linkedHostsLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        linkedHostsLabel.textColor = .secondaryLabelColor
        linkedHostsLabel.maximumNumberOfLines = 3

        saveButton.title = "保存"
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(saveCredential(_:))

        let formGrid = NSGridView(views: [
            [fieldLabel("名称"), nameField],
            [fieldLabel("用户名"), usernameField],
            [fieldLabel("密码"), passwordRow],
            [NSView(), clearPasswordCheckbox],
            [fieldLabel("备注"), notesField],
            [fieldLabel("关联主机"), linkedHostsLabel],
        ])
        formGrid.rowSpacing = 10
        formGrid.columnSpacing = 10
        formGrid.column(at: 0).xPlacement = .trailing
        formGrid.translatesAutoresizingMaskIntoConstraints = false

        for field in [nameField, usernameField, notesField] {
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        }

        let footerBar = NSStackView(views: [NSView(), saveButton])
        footerBar.orientation = .horizontal
        footerBar.translatesAutoresizingMaskIntoConstraints = false

        detailContainer.addSubview(formGrid)
        detailContainer.addSubview(footerBar)

        NSLayoutConstraint.activate([
            formGrid.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: 24),
            formGrid.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 20),
            formGrid.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -24),

            footerBar.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 20),
            footerBar.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -24),
            footerBar.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor, constant: -18),
        ])

        pane.addSubview(emptyHintLabel)
        pane.addSubview(detailContainer)

        NSLayoutConstraint.activate([
            emptyHintLabel.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
            emptyHintLabel.centerYAnchor.constraint(equalTo: pane.centerYAnchor),
            emptyHintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: pane.leadingAnchor, constant: 24),
            emptyHintLabel.trailingAnchor.constraint(lessThanOrEqualTo: pane.trailingAnchor, constant: -24),

            detailContainer.topAnchor.constraint(equalTo: pane.topAnchor),
            detailContainer.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            detailContainer.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            detailContainer.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])
        return pane
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    // MARK: - 数据刷新与表单填充

    private func reloadList(selectingID: String?) {
        filtered = environment.credentials.filter(searchField.stringValue)
        tableView.reloadData()

        if let selectingID, let idx = filtered.firstIndex(where: { $0.id == selectingID }) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            loadDetail(for: filtered[idx], isNew: false)
        } else if !isCreatingNew, let first = filtered.first {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            loadDetail(for: first, isNew: false)
        } else if !isCreatingNew {
            editingCredential = nil
            updateDetailVisibility()
        }
    }

    private func loadDetail(for credential: CredentialProfile, isNew: Bool) {
        editingCredential = credential
        isCreatingNew = isNew
        showingPassword = false
        securePasswordField.isHidden = false
        plainPasswordField.isHidden = true
        togglePasswordButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "显示密码")

        nameField.stringValue = credential.name
        usernameField.stringValue = credential.username
        notesField.stringValue = credential.notes
        securePasswordField.stringValue = ""
        plainPasswordField.stringValue = ""
        clearPasswordCheckbox.state = .off

        let hasSavedPassword = !isNew && environment.vault.hasSecret(hostID: credential.vaultKey, kind: .password)
        let placeholder = hasSavedPassword
            ? "已保存密码（留空表示不修改）"
            : "输入密码（安全保存在系统钥匙串）"
        securePasswordField.placeholderString = placeholder
        plainPasswordField.placeholderString = placeholder
        clearPasswordCheckbox.isEnabled = hasSavedPassword
        securePasswordField.isEnabled = true
        plainPasswordField.isEnabled = true

        let linked = linkedHosts(for: credential.id)
        if linked.isEmpty {
            linkedHostsLabel.stringValue = "暂无主机关联此凭据"
        } else {
            let names = linked.prefix(5).map(\.displayName).joined(separator: "、")
            let suffix = linked.count > 5 ? " 等" : ""
            linkedHostsLabel.stringValue = "已关联 \(linked.count) 台主机：\(names)\(suffix)（修改后自动同步生效）"
        }

        updateDetailVisibility()
    }

    private func updateDetailVisibility() {
        let hasEditor = editingCredential != nil
        detailContainer.isHidden = !hasEditor
        emptyHintLabel.isHidden = hasEditor
        removeButton.isEnabled = !isCreatingNew && editingCredential != nil
    }

    private func linkedHosts(for credentialID: String) -> [HostProfile] {
        environment.hosts.hosts.filter { $0.credentialID == credentialID }
    }

    private var currentPasswordInput: String {
        showingPassword ? plainPasswordField.stringValue : securePasswordField.stringValue
    }

    // MARK: - 动作

    @objc private func searchChanged(_ sender: NSSearchField) {
        isCreatingNew = false
        reloadList(selectingID: editingCredential?.id)
    }

    @objc private func createNewCredential(_ sender: Any?) {
        tableView.deselectAll(nil)
        let fresh = CredentialProfile()
        loadDetail(for: fresh, isNew: true)
        window?.makeFirstResponder(nameField)
    }

    @objc private func togglePasswordVisibility(_ sender: Any?) {
        if showingPassword {
            securePasswordField.stringValue = plainPasswordField.stringValue
            showingPassword = false
            plainPasswordField.isHidden = true
            securePasswordField.isHidden = false
            togglePasswordButton.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "显示密码")
        } else {
            var text = securePasswordField.stringValue
            // 编辑已有凭据且输入框为空时，点击小眼睛直接从 Keychain 读取已存密码方便核对。
            if text.isEmpty, !isCreatingNew, let cred = editingCredential,
               let saved = try? environment.vault.secret(hostID: cred.vaultKey, kind: .password) {
                text = saved
            }
            plainPasswordField.stringValue = text
            showingPassword = true
            securePasswordField.isHidden = true
            plainPasswordField.isHidden = false
            togglePasswordButton.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "隐藏密码")
        }
    }

    @objc private func clearPasswordToggled(_ sender: NSButton) {
        let clearing = sender.state == .on
        securePasswordField.isEnabled = !clearing
        plainPasswordField.isEnabled = !clearing
        if clearing {
            securePasswordField.stringValue = ""
            plainPasswordField.stringValue = ""
        }
    }

    @objc private func saveCredential(_ sender: Any?) {
        guard var cred = editingCredential else { return }
        cred.name = nameField.stringValue
        cred.username = usernameField.stringValue
        cred.notes = notesField.stringValue
        do {
            let saved = try environment.credentials.save(cred)
            if clearPasswordCheckbox.state == .on {
                try environment.vault.setSecret(nil, hostID: saved.vaultKey, kind: .password)
            } else {
                let enteredPassword = currentPasswordInput
                if !enteredPassword.isEmpty {
                    try environment.vault.setSecret(enteredPassword, hostID: saved.vaultKey, kind: .password)
                }
            }
            isCreatingNew = false
            editingCredential = saved
            reloadList(selectingID: saved.id)
        } catch {
            AlertPresenter.fail(title: "保存凭据失败", message: error.localizedDescription, in: window)
        }
    }

    @objc private func deleteSelectedCredential(_ sender: Any?) {
        guard let cred = editingCredential, !isCreatingNew else { return }
        let linked = linkedHosts(for: cred.id)
        let alert = NSAlert()
        alert.messageText = "删除凭据「\(cred.displayName)」？"
        alert.informativeText = linked.isEmpty
            ? "删除后将同时清除钥匙串中保存的密码。"
            : "当前有 \(linked.count) 台主机关联了此凭据，删除后这些主机将解除关联并改为手动输入。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr(.commonDelete))
        alert.addButton(withTitle: L10n.tr(.commonCancel))
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            for var host in linked {
                host.credentialID = nil
                _ = try? environment.hosts.save(host)
            }
            environment.vault.removeSecrets(hostID: cred.vaultKey)
            try environment.credentials.delete(id: cred.id)
            editingCredential = nil
            isCreatingNew = false
            reloadList(selectingID: nil)
        } catch {
            AlertPresenter.fail(title: "删除凭据失败", message: error.localizedDescription, in: window)
        }
    }
}

extension CredentialLibraryWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let cred = filtered[row]
        let cellID = NSUserInterfaceItemIdentifier("CredentialRowCell")
        let cell = (tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView) ?? {
            let view = NSTableCellView()
            view.identifier = cellID
            let title = NSTextField(labelWithString: "")
            title.font = .systemFont(ofSize: 13, weight: .medium)
            title.lineBreakMode = .byTruncatingTail
            title.translatesAutoresizingMaskIntoConstraints = false
            let sub = NSTextField(labelWithString: "")
            sub.font = .systemFont(ofSize: 11)
            sub.textColor = .secondaryLabelColor
            sub.lineBreakMode = .byTruncatingTail
            sub.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(title)
            view.addSubview(sub)
            view.textField = title
            sub.tag = 101
            NSLayoutConstraint.activate([
                title.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
                title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
                title.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
                sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
                sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                sub.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            ])
            return view
        }()
        cell.textField?.stringValue = cred.displayName
        let count = linkedHosts(for: cred.id).count
        let userPart = cred.username.isEmpty ? "无用户名" : cred.username
        let countPart = count > 0 ? " · \(count) 台主机" : ""
        (cell.viewWithTag(101) as? NSTextField)?.stringValue = "\(userPart)\(countPart)"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard filtered.indices.contains(row) else {
            if !isCreatingNew {
                editingCredential = nil
                updateDetailVisibility()
            }
            return
        }
        loadDetail(for: filtered[row], isNew: false)
    }
}
