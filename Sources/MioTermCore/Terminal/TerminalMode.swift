import Foundation

/// 终端此刻所在的“环境”。目录跟随只能在本机 shell 里进行：
/// 进入容器或再 ssh 到别的机器后，内层报的路径属于另一套文件系统，
/// SFTP 拿宿主机去读只会报错，于是这两种情况都要把跟随冻结。
public enum TerminalMode: Equatable, Sendable {
    /// 会话建立时的那台机器的普通 shell。
    case shell
    /// Docker / Podman / nerdctl 容器。
    case docker(container: String?)
    /// 其他形式的容器或隔离环境（Kubernetes、LXC、chroot…）。
    case container(runtime: String, name: String?)
    /// 会话里又 ssh 到了另一台机器。
    case remoteShell

    public var shortName: String {
        switch self {
        case .shell: return "普通 Shell"
        case .docker: return "Docker"
        case .container(let runtime, _): return runtime
        case .remoteShell: return "远程 Shell"
        }
    }

    /// 容器名/ID 之类的补充信息，给悬停提示用。
    public var detail: String? {
        switch self {
        case .docker(let container): return container
        case .container(_, let name): return name
        case .shell, .remoteShell: return nil
        }
    }

    public var isFollowingAllowed: Bool { self == .shell }

    public var pauseReason: String? {
        switch self {
        case .shell:
            return nil
        case .docker:
            return "已进入 Docker 容器，宿主机文件树暂停跟随"
        case .container(let runtime, _):
            return "已进入 \(runtime) 容器，宿主机文件树暂停跟随"
        case .remoteShell:
            return "终端进入了别的机器，已暂停跟随"
        }
    }
}

/// 从用户输入的命令判断“这一下会不会进入容器”。
/// 终端看不到进程，`docker exec` 之后 shell 的目录属于容器内部，
/// 只能靠这条命令本身提前把跟随冻结，不能等 SFTP 报错才发现。
public enum ContainerCommandDetector {
    /// 这些选项后面跟的是一个值，解析容器名时要连着跳过去。
    private static let optionsWithValue: Set<String> = [
        "-u", "--user", "-e", "--env", "--env-file", "-w", "--workdir",
        "--detach-keys", "--name", "-v", "--volume", "-p", "--publish",
        "--network", "--net", "--entrypoint", "--platform", "-m", "--memory",
        "--cpus", "--dns", "--add-host", "--label", "-l", "--restart",
        "--hostname", "-h", "--pid", "--ipc", "--uts", "--mount",
        "-c", "--container", "-n", "--namespace",
    ]

    /// 交互式容器会话里常见的壳与登录入口；若 `exec` 跑的是 `ls`/`cat` 这类单次命令，跑完即退，不该冻结跟随。
    private static let interactiveShells: Set<String> = [
        "sh", "bash", "zsh", "ash", "dash", "fish", "ksh", "csh", "tcsh", "su", "login",
    ]

    public static func enteringContainer(_ line: String) -> TerminalMode? {
        let words = normalizedWords(line)
        guard let tool = words.first else { return nil }
        let args = Array(words.dropFirst())
        switch tool {
        case "docker", "podman", "nerdctl":
            return dockerMode(args)
        case "docker-compose":
            return composeMode(verb: args.first, rest: Array(args.dropFirst()))
        case "kubectl", "oc":
            guard let verb = args.first else { return nil }
            let rest = Array(args.dropFirst())
            if verb == "attach" {
                return .container(runtime: "Kubernetes", name: firstOperand(rest))
            }
            guard verb == "exec", isInteractive(rest), executesShellOrDefault(rest) else { return nil }
            return .container(runtime: "Kubernetes", name: firstOperand(rest))
        case "lxc", "lxd":
            guard let verb = args.first, ["exec", "shell", "attach"].contains(verb) else { return nil }
            let rest = Array(args.dropFirst())
            if verb == "exec", !executesShellOrDefault(rest) { return nil }
            return .container(runtime: "LXC", name: firstOperand(rest))
        case "lxc-attach":
            return .container(runtime: "LXC", name: nil)
        case "nsenter":
            return .container(runtime: "nsenter", name: nil)
        case "chroot":
            return .container(runtime: "chroot", name: firstOperand(args))
        case "machinectl":
            guard args.first == "shell" else { return nil }
            return .container(runtime: "systemd-nspawn", name: firstOperand(Array(args.dropFirst())))
        case "systemd-nspawn":
            return .container(runtime: "systemd-nspawn", name: nil)
        default:
            return nil
        }
    }

    /// `exit` / `logout`：容器里的 shell 结束，跟随应该解冻。
    public static func isShellExit(_ line: String) -> Bool {
        let words = normalizedWords(line)
        guard let first = words.first, first == "exit" || first == "logout" else { return false }
        return words.count <= 2
    }

    private static func dockerMode(_ args: [String]) -> TerminalMode? {
        guard let first = args.first else { return nil }
        if first == "compose" {
            guard args.count > 1 else { return nil }
            return composeMode(verb: args[1], rest: Array(args.dropFirst(2)))
        }
        // `docker container exec …` 与 `docker exec …` 等价。
        let verb = first == "container" && args.count > 1 ? args[1] : first
        let rest = first == "container" ? Array(args.dropFirst(2)) : Array(args.dropFirst())
        switch verb {
        case "attach":
            return .docker(container: firstOperand(rest))
        case "exec":
            // `docker exec web ls` 或 `docker exec -it web ls` 都是跑完即退的单次命令，不能把跟随冻死。
            guard isInteractive(rest), executesShellOrDefault(rest) else { return nil }
            return .docker(container: firstOperand(rest))
        case "run", "start":
            // 只有交互式启动才会留在一个可操作的容器 shell 里；
            // `docker run hello-world` 跑完就退，不该冻结跟随。
            return isInteractive(rest) ? .docker(container: firstOperand(rest)) : nil
        default:
            return nil
        }
    }

    private static func composeMode(verb: String?, rest: [String]) -> TerminalMode? {
        guard let verb else { return nil }
        switch verb {
        case "attach":
            return .docker(container: firstOperand(rest))
        case "exec":
            guard !rest.contains("-T"), !rest.contains("--no-TTY"), executesShellOrDefault(rest) else { return nil }
            return .docker(container: firstOperand(rest))
        case "run":
            return isInteractive(rest) ? .docker(container: firstOperand(rest)) : nil
        default:
            return nil
        }
    }

    /// 去掉 `sudo` 与其后的选项，让 `sudo docker exec …` 也能认出来。
    private static func normalizedWords(_ line: String) -> [String] {
        var words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if words.first == "sudo" {
            words.removeFirst()
            while let first = words.first, first.hasPrefix("-") {
                words.removeFirst()
            }
        }
        return words
    }

    private static func firstOperand(_ tokens: [String]) -> String? {
        operands(tokens).first
    }

    /// 提取去掉选项后的位置参数：到了容器内命令（第二个位置参数）或 `--` 之后，后续的 `-c` 等参数原样保留。
    private static func operands(_ tokens: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        var literal = false
        while index < tokens.count {
            let token = tokens[index]
            if !literal {
                if token == "--" {
                    literal = true
                    index += 1
                    continue
                }
                if token.hasPrefix("-") {
                    index += optionsWithValue.contains(token) ? 2 : 1
                    continue
                }
            }
            result.append(token)
            if result.count >= 2 {
                literal = true
            }
            index += 1
        }
        return result
    }

    /// 位置参数里若显式给出了容器内要跑的程序，只有它是交互式 shell（且不带 `-c`）才算进入容器会话。
    private static func executesShellOrDefault(_ tokens: [String]) -> Bool {
        let positional = operands(tokens)
        guard positional.count >= 2 else { return true }
        let executable = (positional[1] as NSString).lastPathComponent
        guard interactiveShells.contains(executable) else { return false }
        let shellArgs = positional.dropFirst(2)
        return !shellArgs.contains("-c")
    }

    private static func isInteractive(_ tokens: [String]) -> Bool {
        for token in tokens {
            if token == "--interactive" || token == "--tty" { return true }
            guard token.hasPrefix("-"), !token.hasPrefix("--"), token.count > 1 else { continue }
            // `-it`、`-dit` 这类短选项可合并，出现 i 或 t 就按交互式处理。
            if token.dropFirst().contains("i") || token.dropFirst().contains("t") { return true }
        }
        return false
    }
}
