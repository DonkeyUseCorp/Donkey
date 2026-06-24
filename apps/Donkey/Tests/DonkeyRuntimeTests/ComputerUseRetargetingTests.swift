import DonkeyAI
import DonkeyContracts
import DonkeyHarness
import DonkeyRuntime
import Foundation
import Testing

/// Locks the structural unbinding of a computer-use run from a single pinned app: the run carries one
/// shared, mutable `HarnessTargetContext`, and the see-tools advertise an `app` input so the planner can
/// retarget per step (observe X → act on X; observe Y → act on Y), the way computer use does.
@Suite
@MainActor
struct ComputerUseRetargetingTests {
    @Test
    func targetContextSeedsAndRetargets() {
        let target = HarnessTargetContext(appName: "Music", bundleIdentifier: "com.apple.Music")
        #expect(!target.isEmpty)
        #expect(target.appName == "Music")
        #expect(target.appKey == "com.apple.Music")

        // An observe step naming a different app retargets the run; later actions read the new identity.
        target.retarget(appName: "Preview", bundleIdentifier: "com.apple.Preview")
        #expect(target.appName == "Preview")
        #expect(target.bundleIdentifier == "com.apple.Preview")
        #expect(target.appKey == "com.apple.Preview")
    }

    @Test
    func anAppLessRunStartsEmptyAndAcquiresAnApp() {
        // An app-less run (artifact/system work) seeds an empty target — there is no app to drive yet.
        let target = HarnessTargetContext(appName: "", bundleIdentifier: nil)
        #expect(target.isEmpty)
        // The cache key degrades to the (empty) name rather than crashing on a nil bundle.
        #expect(target.appKey == "")

        // It acquires its first app the moment the planner observes one by name.
        target.retarget(appName: "Numbers", bundleIdentifier: nil)
        #expect(!target.isEmpty)
        #expect(target.appKey == "Numbers")
    }

    @Test
    func appKeyPrefersBundleButFallsBackToName() {
        #expect(HarnessTargetContext(appName: "Notes", bundleIdentifier: nil).appKey == "Notes")
        #expect(HarnessTargetContext(appName: "Notes", bundleIdentifier: "").appKey == "Notes")
        #expect(HarnessTargetContext(appName: "Notes", bundleIdentifier: "com.apple.Notes").appKey == "com.apple.Notes")
    }

    @Test
    func observeToolsAdvertiseTheAppRetargetInput() {
        // The planner-facing contract that makes retargeting reachable: both see-tools accept `app`. Without
        // this on the descriptor, the model could never name an app to switch to and the run would stay
        // pinned to whatever it started on.
        let axObserve = AXComputerUseToolProvider.descriptors.first { $0.name == "ax.observe" }
        #expect(axObserve?.optionalInputKeys.contains("app") == true)
        #expect(axObserve?.inputSchema["app"] != nil)

        let visionCapture = VisionComputerUseToolProvider.descriptors.first { $0.name == "vision.capture" }
        #expect(visionCapture?.optionalInputKeys.contains("app") == true)
        #expect(visionCapture?.inputSchema["app"] != nil)
    }
}
