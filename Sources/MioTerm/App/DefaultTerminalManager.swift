import AppKit
import CoreServices
import MioTermCore

/// 参照 iTerm2 的默认终端注册方式，通过 LaunchServices 管理脚本类型与 URL Scheme 的默认处理程序，
/// 并负责分发系统传入的目录、脚本文件及 `ssh://` / `telnet://` 链接。
@MainActor
enum DefaultTerminalManager {
    private static let appleTerminalBundleID = "com.apple.Terminal"
    private static let contentTypes: [String] = [
        "com.apple.terminal.shell-script",
        "public.shell-script",
        "public.unix-executable",
    ]

    private static var currentBundleID: String {
        Bundle.main.bundleIdentifier ?? "com.mio.term"
    }

    static var isDefaultTerminal: Bool {
        let bundleID = currentBundleID.lowercased()
        let scriptHandler = LSCopyDefaultRoleHandlerForContentType(
            "com.apple.terminal.shell-script" as CFString,
            .all
        )?.takeRetainedValue() as String?
        return scriptHandler?.lowercased() == bundleID
    }

    @discardableResult
    static func makeMioTermDefault() -> OSStatus {
        LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        return setDefaultHandler(bundleID: currentBundleID)
    }

    @discardableResult
    static func restoreAppleTerminalDefault() -> OSStatus {
        setDefaultHandler(bundleID: appleTerminalBundleID)
    }

    private static func setDefaultHandler(bundleID: String) -> OSStatus {
        var firstError: OSStatus = noErr
        for uti in contentTypes {
            let status = LSSetDefaultRoleHandlerForContentType(uti as CFString, .all, bundleID as CFString)
            if status != noErr && firstError == noErr {
                firstError = status
            }
        }
        return firstError
    }

    static func handleOpenURLs(_ urls: [URL], in workspace: WorkspaceViewController) {
        for url in urls {
            if url.isFileURL {
                handleFileURL(url, in: workspace)
            } else {
                handleRemoteURL(url, in: workspace)
            }
        }
    }

    private static func handleFileURL(_ url: URL, in workspace: WorkspaceViewController) {
        let path = url.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return }

        if isDirectory.boolValue {
            workspace.openLocalTerminal(workingDirectory: path)
            return
        }

        let parent = (path as NSString).deletingLastPathComponent
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let quotedPath = ShellQuoting.singleQuoted(path)
        let quotedShell = ShellQuoting.singleQuoted(shell)
        let command: String
        if FileManager.default.isExecutableFile(atPath: path) {
            command = "\(quotedPath); exec \(quotedShell) -l"
        } else {
            command = "\(quotedShell) \(quotedPath); exec \(quotedShell) -l"
        }
        workspace.openLocalTerminal(workingDirectory: parent, initialCommand: command)
    }

    private static func handleRemoteURL(_ url: URL, in workspace: WorkspaceViewController) {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty else { return }

        switch scheme {
        case "ssh":
            let profile = HostProfile(
                name: host,
                protocolKind: .ssh,
                address: host,
                port: url.port ?? 22,
                username: url.user ?? ""
            )
            workspace.connect(host: profile)
        case "telnet":
            let profile = HostProfile(
                name: host,
                protocolKind: .telnet,
                address: host,
                port: url.port ?? 23,
                username: url.user ?? ""
            )
            workspace.connect(host: profile)
        default:
            break
        }
    }
}
