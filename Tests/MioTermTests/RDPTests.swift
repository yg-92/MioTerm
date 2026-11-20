import Foundation
@testable import MioTermCore
import Testing

@Suite("RDP 协议与 FreeRDP 依赖检测")
struct RDPTests {
    @Test func freeRDPDetectedOnLocalSystem() {
        #expect(FreeRDPAvailability.isInstalled)
        let path = FreeRDPAvailability.libraryPath
        #expect(path?.contains("libfreerdp3.dylib") == true)
    }

    @Test func rdpHostProfileDefaultsAndValidation() throws {
        #expect(ConnectionProtocol.rdp.defaultPort == 3389)
        #expect(!ConnectionProtocol.rdp.supportsSFTP)
        #expect(!ConnectionProtocol.rdp.usesHostKey)

        let raw = HostProfile(name: "Win11", protocolKind: .rdp, address: "10.0.0.8", port: 22)
        let normalized = raw.normalized()
        #expect(normalized.port == 3389)

        try FreeRDPAvailability.withOverride(true) {
            try normalized.validate()
        }
    }

    @Test func blocksAddingRDPWhenFreeRDPDependencyIsMissing() {
        let host = HostProfile(name: "Win11", protocolKind: .rdp, address: "10.0.0.8", port: 3389)
        FreeRDPAvailability.withOverride(false) {
            #expect(throws: HostProfile.ValidationError.rdpDependencyMissing) {
                try host.validate()
            }
        }
    }
}
