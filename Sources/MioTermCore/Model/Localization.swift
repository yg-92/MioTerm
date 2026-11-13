import Foundation

/// 界面显示语言偏好。
/// 除内置的简体中文（`zhHans`）与英文（`en`）外，支持通过 `LocalizationPack` 注册更多语种。
public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case zhHans = "zh-Hans"
    case en

    /// 具体语种对应的 BCP-47 语言代码；`system` 由运行时根据系统首选语言解析。
    public var languageCode: String? {
        switch self {
        case .system: return nil
        case .zhHans: return "zh-Hans"
        case .en: return "en"
        }
    }

    /// 下拉菜单中展示的名称。具体语种始终显示其母语名称，避免切换语言后找不到切回来的选项。
    public var displayName: String {
        switch self {
        case .system: return L10n.tr(.languageSystem)
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }
}

/// 单个语种的翻译包定义。新增语种只需构造一个 `LocalizationPack` 并通过 `L10n.register(_:)` 接入。
public struct LocalizationPack: Sendable {
    public let code: String
    public let nativeName: String
    public let fallbackCode: String?
    public let strings: [L10nKey: String]

    public init(
        code: String,
        nativeName: String,
        fallbackCode: String? = "en",
        strings: [L10nKey: String]
    ) {
        self.code = code
        self.nativeName = nativeName
        self.fallbackCode = fallbackCode
        self.strings = strings
    }
}

/// 全部可本地化的界面文案键。通过强类型枚举保证编译期校验与测试全覆盖。
public enum L10nKey: String, CaseIterable, Sendable {
    // MARK: - 通用操作
    case commonSave
    case commonCancel
    case commonClose
    case commonOK
    case commonDelete
    case commonRetry
    case commonAdd
    case commonBrowse
    case commonCreate
    case commonRename
    case commonGoTo
    case commonDone
    case commonApply
    case commonRefresh
    case commonConfirm
    case commonOpen

    // MARK: - 外观与语言枚举
    case languageSystem
    case appearanceSystem
    case appearanceDark
    case appearanceLight
    case contrastSoft
    case contrastStandard
    case contrastHigh
    case accentBlue
    case accentPurple
    case accentGreen
    case accentRose
    case accentGraphite

    // MARK: - 设置窗口
    case preferencesTitle
    case prefLanguage
    case prefLanguageHint
    case prefAppearance
    case prefContrast
    case prefAccent
    case prefAccentTooltip
    case prefCustomTheme
    case prefStyleButton
    case prefTerminalFont
    case prefTerminalFontSize
    case prefTerminalType
    case prefTerminalTypeHint
    case prefTreeFontSize
    case prefTreeIconSize
    case prefScrollback
    case prefScrollbackTooltip
    case prefBell
    case prefBellTitle
    case prefFollowDirectory
    case prefFollowDirectoryTitle
    case prefUploadChunk
    case prefMaxConcurrent
    case prefConnectTimeout
    case prefKeepalive
    case prefSaveFailedTitle
    case prefInvalidTitle
    case prefInvalidScrollback
    case prefInvalidChunk
    case prefInvalidConcurrency
    case prefInvalidTimeout
    case prefInvalidKeepalive

    // MARK: - 页面样式窗口 & 主题角色
    case themeRoleBackground
    case themeRoleSidebar
    case themeRoleTabBar
    case themeRoleSurface
    case themeRoleText
    case themeRoleSecondaryText
    case themeRoleAccent
    case themeRoleSelectedTab
    case themeRoleTerminalBackground
    case themeRoleTerminalForeground
    case themeRoleSelectionBackground
    case themeRoleSelectionForeground
    case themeRoleCursor
    case styleWindowTitle
    case styleModeDark
    case styleModeLight
    case styleResetCurrent
    case styleResetAll
    case styleExport
    case styleImport
    case styleHint
    case styleImportFailedTitle
    case styleExportFailedTitle
    case styleModeDarkPalette
    case styleModeLightPalette
    case stylePresetLabel
    case styleCustomPreset
    case styleColorHint
    case styleHexAccessibility
    case styleResetAccessibility
    case styleResetItem
    case stylePreviewTitle
    case stylePreviewHint
    case styleInvalidColorTitle
    case styleInvalidColorMsg
    case styleSaveFailedTitle
    case stylePreviewDevServer
    case stylePreviewLocalTerm
    case stylePreviewHostList
    case stylePreviewDevEnv
    case stylePreviewProdEnv

    // MARK: - 主菜单
    case menuAbout
    case menuSettings
    case menuServices
    case menuHideApp
    case menuHideOthers
    case menuShowAll
    case menuQuitApp
    case menuSession
    case menuHome
    case menuNewLocalTerminal
    case menuNextTab
    case menuPrevTab
    case menuSwitchToTab
    case menuTabNumber
    case menuConnectSelected
    case menuReconnect
    case menuCloseTab
    case menuFilePanel
    case menuSerialBreak
    case menuHostList
    case menuCommandLibrary
    case menuToggleSidebar
    case menuHost
    case menuNewHost
    case menuEditHost
    case menuDuplicateHost
    case menuDeleteHost
    case menuTestHost
    case menuRefreshFingerprint
    case menuEdit
    case menuCut
    case menuCopy
    case menuPaste
    case menuSelectAll
    case menuFind
    case menuFindNext
    case menuFindPrevious
    case menuUseSelectionForFind
    case menuView
    case menuConfigureSplit
    case menuSplitLeftRight
    case menuPageStyle
    case menuFontIncrease
    case menuFontDecrease
    case menuFontReset
    case menuSplitWith
    case menuUnsplit
    case menuSplitNoOtherSession
    case menuEnterFullScreen
    case menuWindow
    case menuMinimize
    case menuZoom
    case menuBringAllToFront

    // MARK: - 主窗口工具栏与欢迎页
    case toolbarToggleSidebar
    case toolbarHome
    case toolbarConnect
    case toolbarNewHost
    case toolbarLocalTerminal
    case toolbarCommandLibrary
    case toolbarSettings
    case toolbarPageActionsGroup
    case toolbarWindowActionsGroup
    case welcomeSubtitle
    case welcomeHint
    case welcomeFooter
    case welcomeNewHost
    case welcomeNewHostDetail
    case welcomeLocalTerminal
    case welcomeLocalTerminalDetail
    case welcomeConnectTitle
    case welcomeConnectDetail
    case welcomeSettingsTitle
    case welcomeSettingsDetail
    case welcomeQuickStart
    case welcomeRecentHosts
    case welcomeEmptyHosts

    // MARK: - 工作区与侧栏
    case sidePanelHosts
    case sidePanelFiles
    case sidePanelAccessibility
    case sidebarSearchPlaceholder
    case sidebarAddHost
    case sidebarLocalTerminal
    case sidebarHostCount
    case sidebarEmptyNoHost
    case sidebarEmptyNoMatch
    case sidebarMenuConnect
    case sidebarMenuTest
    case sidebarMenuEdit
    case sidebarMenuDuplicate
    case sidebarMenuFavorite
    case sidebarMenuRefreshFingerprint
    case sidebarMenuDelete
    case sidebarCollapseGroup
    case sidebarExpandGroup
    case sidebarFavorited
    case workspaceHomeSubtitle
    case workspaceNoSFTPTitle
    case workspaceNoSFTPMsg
    case workspaceNoHostSelectedTitle
    case workspaceNoHostSelectedMsg
    case workspaceSessionRunningTitle
    case workspaceSessionRunningMsg
    case workspaceDuplicateFailedTitle
    case workspaceDeleteHostTitle
    case workspaceDeleteHostMsg
    case workspaceDeleteFailedTitle
    case workspaceTestResultTitle
    case workspaceTestSuccess
    case workspaceSubtitleFollowing
    case workspaceSubtitlePaused

    // MARK: - 主机表单与模型
    case protocolSSH
    case protocolTelnet
    case protocolSerial
    case authAutomatic
    case authPassword
    case authPrivateKey
    case hostDefaultGroup
    case hostFormNewTitle
    case hostFormEditTitle
    case hostFormName
    case hostFormGroup
    case hostFormProtocol
    case hostFormAddress
    case hostFormPort
    case hostFormUsername
    case hostFormAuth
    case hostFormPassword
    case hostFormPrivateKey
    case hostFormPassphrase
    case hostFormTerminalType
    case hostFormTimeout
    case hostFormKeepalive
    case hostFormX11
    case hostFormX11Off
    case hostFormX11Restricted
    case hostFormX11Trusted
    case hostFormSFTP
    case hostFormFavorite
    case hostFormNotes
    case hostFormPasswordPlaceholder
    case hostFormPassphrasePlaceholder
    case hostFormKeyPlaceholder
    case hostFormX11Title
    case hostFormSFTPTitle
    case hostFormFavoriteTitle
    case hostFormValidationTitle
    case hostFormMissingAddress
    case hostFormInvalidPort
    case hostFormMissingSerialDevice
    case hostFormEditHostTitle
    case hostFormClearSecret
    case hostFormSFTPCheckbox
    case hostFormSFTPTooltip
    case hostFormLocalEcho
    case hostFormRaiseDTR
    case hostFormRaiseRTS
    case hostFormTags
    case hostFormTagsPlaceholder
    case hostFormAddressPlaceholder
    case hostFormGroupPlaceholder
    case hostFormDefaultTermPlaceholder
    case hostFormSecretUnsaved
    case hostFormSecretSaved
    case hostFormPickButton
    case hostFormPickKeyMessage
    case hostFormAuthMethod
    case hostFormIdentityFile
    case hostFormSecret
    case hostFormStartupDir
    case hostFormFingerprint
    case hostFormFingerprintUnconfirmed
    case hostFormDevice
    case hostFormBaudRate
    case hostFormFrameFormat
    case hostFormDataBits
    case hostFormParity
    case hostFormStopBits
    case hostFormLineEnding
    case hostFormControlLines
    case hostFormSerialHintNormal
    case hostFormSerialHintEmpty
    case hostFormSaveFailedTitle

    // MARK: - 会话标签栏与终端状态
    case tabHome
    case tabNewLocalTip
    case tabSplitTip
    case tabClosePaneTip
    case tabDisconnectTitle
    case tabReconnect
    case tabReconnecting
    case tabModeHost
    case tabModeContainer
    case tabModeNestedSSH
    case tabModeAlternate
    case tabDropToSplit
    case tabSplitMenuCaption
    case tabSplitNoOtherOpen
    case tabSplitLocalDetail
    case tabSplitConnectHostItem
    case tabSplitSelectHostMenu
    case tabSplitNewConnTip
    case tabSplitNoSavedHosts
    case tabSplitNewHostInOtherPane
    case tabSplitNewLocalInOtherPane
    case tabSplitExitKeepSession
    case tabSplitWithSelected
    case tabSplitChooseTerminal
    case tabScrollLeftTip
    case tabScrollRightTip
    case tabChipTooltip
    case tabSplitButtonTip
    case tabSplitConfigureAcc
    case tabSplitChooseAcc
    case tabSessionEnded
    case tabExitCodeDetail
    case tabConnectFailed
    case tabReconnectTooltip
    case tabReconnectingShort
    case tabDirectoryUnknown
    case paneHeaderActiveSuffix
    case paneHeaderInactiveSuffix
    case terminalLocalTitle
    case terminalStateIdle
    case terminalStateStarting
    case terminalStateRunning
    case terminalStateDisconnected
    case terminalStateEnded
    case terminalStateExitedWithCode
    case terminalStateFailed
    case terminalProcessSignaled
    case terminalProcessEnded
    case terminalProcessExitCode
    case terminalStartFailed
    case terminalReconnectingLine
    case terminalDisconnectPromptLine
    case terminalLaunchFailedPrefix
    case terminalStatusDirectory
    case terminalStatusFollowOn
    case terminalStatusFollowOff
    case terminalStatusFollowPaused

    // MARK: - SFTP 文件面板
    case sftpNoSession
    case sftpDisabledForHost
    case sftpNoticeTitle
    case sftpNoticeDetail
    case sftpFollowTitle
    case sftpFollowTooltip
    case sftpFollowAccessibility
    case sftpRetry
    case sftpRetryTooltip
    case sftpRefreshTip
    case sftpGoToTip
    case sftpNewFolderTip
    case sftpUploadTip
    case sftpDownloadTip
    case sftpHiddenTip
    case sftpMenuDownload
    case sftpMenuCopyPath
    case sftpMenuInsertPath
    case sftpMenuNewFolder
    case sftpMenuRename
    case sftpMenuDelete
    case sftpMenuPause
    case sftpMenuResume
    case sftpMenuCancel
    case sftpMenuClearFinished
    case sftpStatusLoading
    case sftpStatusItemCount
    case sftpStatusPausedByTerminal
    case sftpStatusUnavailable
    case sftpErrorOpenDir
    case sftpErrorCreateDir
    case sftpErrorRename
    case sftpErrorDelete
    case sftpErrorNoChannelTitle
    case sftpErrorNoChannelMsg
    case sftpErrorNoFileTitle
    case sftpErrorNoFileMsg
    case sftpPromptGoToTitle
    case sftpPromptGoToMsg
    case sftpPromptNewFolderTitle
    case sftpPromptNewFolderMsg
    case sftpPromptRenameTitle
    case sftpPromptDeleteTitle
    case sftpPromptDeleteMsg
    case sftpUploadPanelPrompt
    case sftpUploadPanelMsg
    case sftpDownloadPanelPrompt
    case sftpTransferUpload
    case sftpTransferDownload
    case sftpTransferQueued
    case sftpTransferRunning
    case sftpTransferPaused
    case sftpTransferCompleted
    case sftpTransferCancelled
    case sftpTransferFailed
    case sftpDismissTooltip
    case sftpStateClosed
    case sftpErrorDisabled
    case sftpErrorNotSupported
    case sftpDefaultName
    case sftpJobColumn
    case sftpFollowUnavailableHome
    case sftpFollowRelativeName
    case sftpFollowMissingDir
    case sftpLocalNoChannel
    case sftpProtocolNoPanel
    case sftpOpeningChannel
    case sftpChannelFailedReason
    case sftpOpenPanelFailed
    case sftpReadDirFailed
    case sftpNoTerminalTitle
    case sftpNoTerminalMsg
    case sftpRenameNewNameMsg
    case sftpDeleteMultipleTitle
    case sftpDeleteDirExtraMsg
    case sftpDeleteFileExtraMsg
    case sftpDeleteItemFailed
    case sftpInvalidNameTitle
    case sftpInvalidNameMsg
    case sftpGoToTitle
    case sftpGoToMsg
    case sftpTransferCompletedTip
    case sftpRemoveRecordAcc
    case sftpErrorNoChannelDownloadMsg

    // MARK: - 命令库
    case cmdTitle
    case cmdSortMostUsed
    case cmdSortRecent
    case cmdSearchPlaceholder
    case cmdAddIgnore
    case cmdClearScope
    case cmdEmptyNoSession
    case cmdEmptyNoCommand
    case cmdGroupFavorite
    case cmdGroupFrequent
    case cmdGroupLocalIgnore
    case cmdGroupGlobalIgnore
    case cmdCountTimes
    case cmdTooltipDetail
    case cmdTooltipIgnored
    case cmdHintDisconnected
    case cmdMenuInject
    case cmdMenuCopy
    case cmdMenuFavorite
    case cmdMenuUnfavorite
    case cmdMenuIgnore
    case cmdMenuDelete
    case cmdMenuUnignore
    case cmdMenuUnignoreGlobal
    case cmdMenuPromoteIgnore
    case cmdMenuEmpty
    case cmdPromptAddIgnoreTitle
    case cmdPromptAddIgnoreMsg
    case cmdErrorEmptyCmdTitle
    case cmdErrorEmptyCmdMsg
    case cmdConfirmIgnoreTitle
    case cmdConfirmIgnoreMsg
    case cmdConfirmIgnoreHost
    case cmdConfirmIgnoreAll
    case cmdConfirmClearTitle
    case cmdConfirmClearMsg
    case cmdNoSession
    case cmdHintDefault
    case cmdSortTimesShort
    case cmdSortRecentShort
    case cmdSearchTooltip
    case cmdIgnoreButton
    case cmdIgnoreTooltip
    case cmdClearButton
    case cmdClearTooltip
    case cmdColumnCommand
    case cmdScopeHost
    case cmdGroupRecent
    case cmdHintNoMatch
    case cmdHintOnlyIgnored
    case cmdHintCount
    case cmdHintEmptyRecorded
    case cmdNoSessionAlertMsg

    // MARK: - 连接与启动错误
    case launchDirErrorTitle
    case connectTitleFailed
    case connectMissingSerial
    case connectHostKeyTitle
    case connectHostKeyFirstMsg
    case connectHostKeyChangedMsg
    case connectTrustAndContinue
    case connectUpdateFingerprint
    case connectFingerprintUpdatedTitle
    case connectFingerprintUpdatedMsg
    case connectFingerprintNoChange
    case connectKeychainWarning
    case connectHostFailed
    case connectInternalSSH
    case connectReconnectFailed
    case connectTestSuccessTitle
    case connectTestSuccessMsg
    case connectTestFailedTitle
    case connectTestErrorTitle
    case connectSerialReadyTitle
    case connectSerialReadyMsg
    case connectSerialMissingTitle
    case connectSerialMissingMsg
    case connectUnreachableTitle
    case connectPortReachableTitle
    case connectPortReachableMsg
    case connectCurrentFingerprintTitle
    case connectRecordFingerprint
    case connectFetchFingerprintFailed
    case connectFirstTimeTitle
    case connectFirstTimeMsg
    case connectTrustAndConnect
    case connectKeyChangedTitle
    case connectKeyChangedDetailMsg
    case connectCancelConnection
    case connectConfirmKeyRotation
    case connectKeyBitsFormat
}

/// 轻量级多语言运行时与扩展注册表。
/// 默认内置 `zh-Hans` 与 `en`，外部可通过 `register(_:)` 注册新的语种包。
public enum L10n {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var packs: [String: LocalizationPack] = {
        var map: [String: LocalizationPack] = [:]
        for pack in LocalizationPacks.builtIn {
            map[pack.code] = pack
        }
        return map
    }()
    nonisolated(unsafe) private static var activeCode: String = "zh-Hans"

    /// 当前生效的 BCP-47 语言代码。
    public static var currentLanguageCode: String {
        lock.withLock { activeCode }
    }

    /// 所有已注册的语种包，按代码排序返回。
    public static var registeredPacks: [LocalizationPack] {
        lock.withLock { packs.values.sorted { $0.code < $1.code } }
    }

    /// 注册或覆盖一个语种包，预留给后续扩充其他语种使用。
    public static func register(_ pack: LocalizationPack) {
        lock.withLock {
            packs[pack.code] = pack
        }
    }

    /// 获取指定代码的语种包。
    public static func pack(for code: String) -> LocalizationPack? {
        lock.withLock { packs[code] }
    }

    /// 按用户偏好和系统首选语言列表解析目标语言代码。
    public static func resolveLanguageCode(
        preference: AppLanguage,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        let available = lock.withLock { Set(packs.keys) }
        if let explicit = preference.languageCode, available.contains(explicit) {
            return explicit
        }
        for preferred in preferredLanguages {
            let normalized = preferred.lowercased()
            if normalized.hasPrefix("zh") {
                if available.contains("zh-Hans") { return "zh-Hans" }
            }
            if normalized.hasPrefix("en"), available.contains("en") {
                return "en"
            }
            if let exact = available.first(where: { $0.lowercased() == normalized }) {
                return exact
            }
            let prefix = normalized.split(separator: "-").first.map(String.init) ?? normalized
            if let matched = available.first(where: { $0.lowercased().hasPrefix(prefix) }) {
                return matched
            }
        }
        return available.contains("en") ? "en" : (available.first ?? "zh-Hans")
    }

    /// 应用语言偏好设置。
    public static func configure(
        preference: AppLanguage,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        let resolved = resolveLanguageCode(preference: preference, preferredLanguages: preferredLanguages)
        lock.withLock {
            activeCode = resolved
        }
    }

    /// 直接指定当前语言代码（适用于自定义注册语种或测试）。
    public static func setLanguageCode(_ code: String) {
        lock.withLock {
            if packs[code] != nil {
                activeCode = code
            }
        }
    }

    /// 取当前语言对应的文案，按当前语种 → fallback 语种 → 英文 → 简体中文 → key 逐级回退。
    public static func tr(_ key: L10nKey) -> String {
        lock.withLock {
            if let value = packs[activeCode]?.strings[key] {
                return value
            }
            if let fallback = packs[activeCode]?.fallbackCode,
               let value = packs[fallback]?.strings[key] {
                return value
            }
            if let value = packs["en"]?.strings[key] {
                return value
            }
            if let value = packs["zh-Hans"]?.strings[key] {
                return value
            }
            return key.rawValue
        }
    }

    /// 带参数格式化的本地化文案。
    public static func tr(_ key: L10nKey, _ args: CVarArg...) -> String {
        let format = tr(key)
        let locale = Locale(identifier: currentLanguageCode)
        return String(format: format, locale: locale, arguments: args)
    }
}
