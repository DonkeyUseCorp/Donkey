@testable import DonkeyHarness
@testable import DonkeyRuntime
import Testing

@Suite
struct HarnessSystemPermissionBridgeTests {
    @Test
    func tccBackedCapabilitiesMapToSystemPermissions() {
        #expect(HarnessSystemPermissionBridge.systemPermission(for: .screenCapture) == .screenRecording)
        #expect(HarnessSystemPermissionBridge.systemPermission(for: .accessibility) == .accessibility)
        // Synthetic input needs Accessibility, so it rides the same macOS grant.
        #expect(HarnessSystemPermissionBridge.systemPermission(for: .input) == .accessibility)
    }

    @Test
    func internalCapabilitiesHaveNoSystemPermission() {
        for capability in [HarnessPermission.conversation, .memory, .appLookup, .appControl,
                           .verification, .lifecycle, .userPrompt, .skillLookup] {
            #expect(HarnessSystemPermissionBridge.systemPermission(for: capability) == nil)
        }
    }

    @Test
    func grantingKeepsInternalCapabilitiesRegardlessOfSystemState() {
        // Internal capabilities never consult macOS, so they always survive narrowing.
        let internalOnly: Set<HarnessPermission> = [.conversation, .lifecycle, .appLookup]
        #expect(HarnessSystemPermissionBridge.granting(internalOnly) == internalOnly)
    }

    @Test
    func grantingKeepsTccCapabilityIffSystemGrantsIt() {
        // A TCC-backed capability survives narrowing exactly when macOS currently grants its backing
        // permission; otherwise it drops so the first tool needing it trips the in-conversation gate.
        let narrowed = HarnessSystemPermissionBridge.granting([.lifecycle, .screenCapture, .accessibility, .input])
        #expect(narrowed.contains(.lifecycle))
        for capability in [HarnessPermission.screenCapture, .accessibility, .input] {
            let system = HarnessSystemPermissionBridge.systemPermission(for: capability)!
            #expect(narrowed.contains(capability) == SystemPermissionCoordinator.isGranted(system))
        }
    }

    @Test
    func permissionRequestSummaryNamesTheMacOSAccess() {
        #expect(
            HarnessPermission.permissionRequestSummary(for: [.accessibility])
                == "Donkey needs Accessibility access to continue."
        )
        // Duplicate-backed capabilities (input -> Accessibility) don't repeat the name.
        #expect(
            HarnessPermission.permissionRequestSummary(for: [.accessibility, .input])
                == "Donkey needs Accessibility access to continue."
        )
        // Internal-only capabilities fall back to the generic line.
        #expect(
            HarnessPermission.permissionRequestSummary(for: [.lifecycle])
                == "Donkey needs your permission to continue."
        )
    }
}
