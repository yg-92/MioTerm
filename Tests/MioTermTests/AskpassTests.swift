import Testing
import Foundation
@testable import MioTermCore

struct AskpassTests {
    @Test func detectsAskpassInvocation() {
        #expect(AskpassHelper.isAskpassInvocation(arguments: ["/Applications/MioTerm.app/Contents/MacOS/MioTerm", "--askpass", "password"]))
        #expect(!AskpassHelper.isAskpassInvocation(arguments: ["/Applications/MioTerm.app/Contents/MacOS/MioTerm"]))
        #expect(!AskpassHelper.isAskpassInvocation(arguments: ["MioTerm", "--other", "--askpass"]))
    }

    @Test func splitsPasswordAndPassphraseByPrompt() throws {
        let store = """
        password=\(AskpassMaterial.encode("hunter2"))
        passphrase=\(AskpassMaterial.encode("key pass"))
        """
        #expect(AskpassHelper.selectSecret(in: store, matching: "yanggang's password: ") == "hunter2")
        #expect(AskpassHelper.selectSecret(in: store, matching: "Enter passphrase for key '/Users/yanggang/.ssh/id_ed25519':") == "key pass")
        #expect(AskpassHelper.selectSecret(in: "password=\(AskpassMaterial.encode("only-one"))", matching: "") == "only-one")
        #expect(AskpassHelper.selectSecret(in: "", matching: "password:").isEmpty)
    }

    @Test func multilineSecretSurvives() {
        // 口令本身含换行时，base64 保证行式存储不被破坏。
        let store = "password=\(AskpassMaterial.encode("line1\nline2"))\npassphrase=\(AskpassMaterial.encode("x"))"
        #expect(AskpassHelper.selectSecret(in: store, matching: "password:") == "line1\nline2")
        #expect(AskpassHelper.selectSecret(in: store, matching: "passphrase:") == "x")
    }

    @Test func launcherScriptRoutesBackToExecutable() throws {
        let script = "#!/bin/sh\nexec '/tmp/MioTerm' --askpass \"$@\"\n"
        #expect(script.contains(AskpassHelper.modeArgument))
    }

    @Test func destroysSessionSecretFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let secret = directory.appendingPathComponent(UUID().uuidString)
        try "password=\(AskpassMaterial.encode("hunter2"))".data(using: .utf8)!.write(to: secret)
        let launcher = directory.appendingPathComponent("askpass.sh")
        try "#!/bin/sh\n".data(using: .utf8)!.write(to: launcher)

        AskpassHelper.destroy(fileAt: secret)
        #expect(!FileManager.default.fileExists(atPath: secret.path))

        // 崩溃残留的口令文件由启动清扫处理，但包装脚本必须留下。
        let leftover = directory.appendingPathComponent(UUID().uuidString)
        try "password=x".data(using: .utf8)!.write(to: leftover)
        AskpassHelper.cleanupStaleFiles(in: directory)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(FileManager.default.fileExists(atPath: launcher.path))
    }
}
