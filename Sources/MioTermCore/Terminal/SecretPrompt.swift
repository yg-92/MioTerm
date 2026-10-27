import Foundation

/// 回车前的屏幕底行是不是在要凭据。
///
/// 逐字节攒行分不出「敲给 shell 的命令」和「敲给认证提示的口令」：设备控制台登录、
/// `sudo`、`ssh` 的口令提示，本端看到的都只是一串字符加一个回车。只能看提示语。
/// 判成提示语的代价是这条不进命令库、日志里也不写原文——命令库的条目是能点回终端的，
/// 把口令留在里面等于在界面上摆一份明文凭据，日志又是要拿出去排障的。
/// 反过来误判的代价小得多：少记一条命令、cd 预测晚一拍，屏幕读回来目录照样跟上。
public enum SecretPrompt {
    private static let secretKeywords = [
        "password", "passwd", "passcode", "pass phrase", "passphrase",
        "otp", "secret", "verification code", "one-time code",
        "密码", "口令", "验证码", "动态码",
    ]

    /// 控制台登录时用户名和口令是连着敲的，两条都不该留在命令库里。
    private static let identityKeywords = ["login", "username", "user name", "用户名", "账号", "帐号"]

    /// shell 提示符的结尾符：它出现在关键词之前，说明这是一条命令行而不是提示语。
    /// 后两个是 oh-my-zsh 与 starship 一类主题的箭头，同样只出现在提示符里。
    private static let promptMarkers = ["# ", "$ ", "% ", "> ", "❯", "➜"]

    /// 每开一个本地 shell 都要打的登录横幅，长得像提示语但不是。
    private static let bannerPrefixes = ["last login", "上次登录"]

    public static func isAskingForSecret(_ screenLine: String?) -> Bool {
        guard let line = screenLine?.trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty, line.count <= 120 else { return false }
        let lowered = line.lowercased()
        guard !bannerPrefixes.contains(where: { lowered.hasPrefix($0) }) else { return false }
        let keywords = secretKeywords + identityKeywords
        // 取最靠前的那个关键词：前缀里有没有提示符要按它的位置判。
        guard let match = keywords.compactMap({ lowered.range(of: $0) })
            .min(by: { $0.lowerBound < $1.lowerBound }) else { return false }
        let prefix = lowered[lowered.startIndex..<match.lowerBound]
        guard !promptMarkers.contains(where: { prefix.contains($0) }) else { return false }

        let word = lowered[match]
        let after = lowered[match.upperBound...]
        // 冒号可以紧跟关键词——控制台回显时后面还拖着刚敲进去的那一段
        // （`134 login: admin`），也可以垫几个词再出现（`[sudo] password for yanggang:`）。
        if after.contains(":") || after.contains("：") { return true }
        // 不带冒号的写法（`Input Password`、`请输入登录口令`）要求关键词就是行尾那个词的收尾，
        // 且这个词不是路径的一段：`cd ~/password` 是命令，不是提示语。
        guard after.isEmpty else { return false }
        let token = lowered.split(whereSeparator: \.isWhitespace).last ?? ""
        guard token.hasSuffix(word) else { return false }
        let stem = token.dropLast(word.count)
        return stem.count <= 6 && !stem.contains("/") && !stem.contains("~")
    }
}
