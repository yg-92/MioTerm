import Foundation
import MioTermCore
import Testing

/// 口令提示的判定直接关系到「用户敲的凭据会不会被写进命令库和日志」，
/// 两头都要盯：漏判等于泄漏，误判等于把正常命令挡在命令库外面。
@Suite("口令提示判定")
struct SecretPromptTests {
    @Test("各种认证提示都认得出来")
    func recognisesAuthPrompts() {
        #expect(SecretPrompt.isAskingForSecret("Input Password"))
        #expect(SecretPrompt.isAskingForSecret("Password:"))
        #expect(SecretPrompt.isAskingForSecret("password for root:"))
        #expect(SecretPrompt.isAskingForSecret("[sudo] password for yanggang:"))
        #expect(SecretPrompt.isAskingForSecret("yanggang@10.0.0.1's password:"))
        #expect(SecretPrompt.isAskingForSecret("Enter passphrase for key '~/.ssh/id_rsa':"))
        #expect(SecretPrompt.isAskingForSecret("Verification code:"))
        #expect(SecretPrompt.isAskingForSecret("密码："))
        #expect(SecretPrompt.isAskingForSecret("请输入登录口令"))
        #expect(SecretPrompt.isAskingForSecret("Login:"))
        #expect(SecretPrompt.isAskingForSecret("Username:"))
    }

    /// 控制台回显输入时，提示语后面已经拖着用户刚敲的那一段，冒号不再是行尾。
    @Test("回显了输入的提示行也算")
    func recognisesEchoedInput() {
        #expect(SecretPrompt.isAskingForSecret("134 login: admin"))
        #expect(SecretPrompt.isAskingForSecret("Password: hunter2"))
        #expect(SecretPrompt.isAskingForSecret("请输入密码：abc"))
    }

    @Test("提示符结尾的 shell 命令行不算提示语")
    func shellLinesAreNotPrompts() {
        #expect(!SecretPrompt.isAskingForSecret("root@134:~# cd ~/password"))
        #expect(!SecretPrompt.isAskingForSecret("[root@134 /var/log]# grep password auth.log"))
        #expect(!SecretPrompt.isAskingForSecret("yanggang@mac ~ % login"))
        #expect(!SecretPrompt.isAskingForSecret("mysql> select password from users"))
        #expect(!SecretPrompt.isAskingForSecret("bash-5.2$ sudo login"))
        // oh-my-zsh / starship 的箭头提示符同样只出现在命令行里。
        #expect(!SecretPrompt.isAskingForSecret("➜  ~ kubectl get secret"))
        #expect(!SecretPrompt.isAskingForSecret("❯ grep login /var/log/auth.log"))
        // 没有提示符可认时，也不能把路径里的关键词当成提示语。
        #expect(!SecretPrompt.isAskingForSecret("cd ~/password"))
        #expect(!SecretPrompt.isAskingForSecret("cat /etc/shadow/passwd"))
    }

    @Test("普通输出行不算提示语")
    func ordinaryOutputIsNotAPrompt() {
        #expect(!SecretPrompt.isAskingForSecret(nil))
        #expect(!SecretPrompt.isAskingForSecret(""))
        #expect(!SecretPrompt.isAskingForSecret("   "))
        #expect(!SecretPrompt.isAskingForSecret("Last login: Mon Oct 27 13:49:37 from 10.0.0.1"))
        #expect(!SecretPrompt.isAskingForSecret("total 48"))
        #expect(!SecretPrompt.isAskingForSecret("password changed; try to login again"))
        // 超长行多半是输出而不是提示语，一律不认。
        #expect(!SecretPrompt.isAskingForSecret(String(repeating: "password ", count: 40)))
    }
}
