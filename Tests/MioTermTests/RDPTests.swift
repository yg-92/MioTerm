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
        _ = FreeRDPAvailability.withOverride(false) {
            #expect(throws: HostProfile.ValidationError.rdpDependencyMissing) {
                try host.validate()
            }
        }
    }

    @Test func remoteKeyMappingSupportsCommandToControlAndRoundTrips() throws {
        let mapping = RemoteKeyMapping(commandKey: .control, controlKey: .win, optionKey: .alt)
        #expect(mapping.commandKey.rdpScancode == 0x1D)
        #expect(mapping.controlKey.rdpScancode == 0x15B)
        #expect(mapping.optionKey.rdpScancode == 0x38)
        #expect(RemoteModifierTarget.disabled.rdpScancode == nil)

        var settings = AppSettings.default
        settings.remoteKeyMapping = mapping
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.remoteKeyMapping == mapping)
    }

    @Test func rdpClientClipboardMethodsReturnSafelyBeforeConnect() {
        let client = RDPClient(host: "127.0.0.1")
        #expect(!client.sendClipboardText("hello"))
        #expect(!client.sendClipboardFiles([]))
        #expect(!client.sendClipboardFiles([URL(string: "https://example.com/file.txt")!]))
        #expect(client.fetchRemoteClipboardText() == nil)
        #expect(!client.publishRemoteClipboardFiles())
    }
}
