import Testing
@testable import MioTermCore

/// 服务器拒绝 SFTP 子系统时，面板要给出“未启用 SFTP”的提示而不是异常框，
/// 所以这些 stderr 话术必须被准确识别；认证、网络错误不能被误判。
struct SFTPSubsystemDetectionTests {
    @Test func detectsSubsystemRejection() {
        let cases = [
            "subsystem request failed on channel 0",
            "channel 0: open failed: administratively prohibited: open failed",
            "exec request failed on channel 0",
            "Unknown subsystem: sftp",
            "subsystem not found",
            "bash: /usr/lib/openssh/sftp-server: No such file or directory",
            "sftp-server: not found",
        ]
        for text in cases {
            #expect(
                SFTPConnection.ConnectionError.looksLikeMissingSubsystem(text),
                "应识别为未启用 SFTP：\(text)"
            )
        }
    }

    @Test func ignoresAuthenticationAndNetworkFailures() {
        let cases = [
            "Permission denied (publickey,password).",
            "Host key verification failed.",
            "ssh: connect to host 10.0.0.1 port 22: Connection refused",
            "Connection timed out",
            "SFTP 连接已关闭",
        ]
        for text in cases {
            #expect(
                !SFTPConnection.ConnectionError.looksLikeMissingSubsystem(text),
                "不应误判：\(text)"
            )
        }
    }

    @Test func classificationOnlyAppliesToClosedReason() {
        #expect(
            SFTPConnection.ConnectionError.closed("subsystem request failed on channel 0")
                .indicatesMissingSubsystem
        )
        #expect(!SFTPConnection.ConnectionError.handshakeTimeout.indicatesMissingSubsystem)
        #expect(!SFTPConnection.ConnectionError.alreadyConnected.indicatesMissingSubsystem)
    }
}
