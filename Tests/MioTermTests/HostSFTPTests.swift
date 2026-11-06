import Foundation
import MioTermCore
import Testing

@Suite("主机 SFTP 开关")
struct HostSFTPTests {
    @Test func legacyHostsKeepSFTPEnabled() throws {
        let original = HostProfile(name: "旧主机", address: "example.com")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "sftpEnabled")
        let decoded = try JSONDecoder().decode(HostProfile.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == original)
        #expect(decoded.supportsSFTP)
    }

    @Test func disabledSettingSurvivesSaveAndNormalization() throws {
        let host = HostProfile(name: "仅终端", address: "example.com", sftpEnabled: false)
        let decoded = try JSONDecoder().decode(HostProfile.self, from: JSONEncoder().encode(host.normalized()))
        #expect(!decoded.sftpEnabled)
        #expect(!decoded.supportsSFTP)
        #expect(decoded.protocolKind == .ssh)
    }

    @Test func onlyEnabledSSHHostsProvideFiles() {
        for kind in ConnectionProtocol.allCases {
            for enabled in [true, false] {
                let host = HostProfile(protocolKind: kind, sftpEnabled: enabled)
                #expect(host.supportsSFTP == (kind == .ssh && enabled))
            }
        }
    }
}
