import AppKit
import MioTermCore

// 该可执行文件在不同调用方式下扮演不同角色，都必须在初始化界面之前分流：
//   --askpass      作为 OpenSSH 的 SSH_ASKPASS 程序，打印机密后退出
//   --probe-host-key  打印服务器公钥指纹，用于排查主机密钥问题
if AskpassHelper.isAskpassInvocation(arguments: CommandLine.arguments) {
    AskpassHelper.runAndExit(arguments: CommandLine.arguments)
}

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--probe-host-key" {
    let host = CommandLine.arguments[2]
    let port = Int(CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "") ?? 22
    let wait = DispatchSemaphore(value: 0)
    Task {
        let prober = HostKeyProber()
        do {
            let keys = try await prober.probe(host: host, port: port, timeout: 10)
            print("known_hosts 命名字段：\(HostKeyProber.hostToken(host: host, port: port))")
            for key in keys {
                print("\(key.algorithm)\t\(key.bits) bit\t\(key.fingerprint)\t(\(key.keyType))")
            }
        } catch {
            FileHandle.standardError.write(Data("探测失败：\(error.localizedDescription)\n".utf8))
            exit(1)
        }
        wait.signal()
    }
    wait.wait()
    exit(0)
}

// 顶层代码不是 MainActor 隔离域，而 AppKit 的类型基本都是；这里显式声明
// “此刻就在主线程”，避免为绕开检查而把 AppDelegate 的隔离标记去掉。
MainActor.assumeIsolated {
    // AppKit 默认要悬停 2 秒才弹提示；工具栏大多只有图标，扫过去根本等不到。
    UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 500])
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}
