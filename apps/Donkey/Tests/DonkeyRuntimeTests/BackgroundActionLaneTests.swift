import CoreGraphics
import DonkeyContracts
@testable import DonkeyRuntime
import Foundation
import Testing

/// Unit coverage for the background Accessibility action lane (cursor-independent input slice): the
/// typed `TargetActionGuard` policy, and the action backend's background pid path, which must drop the
/// frontmost requirement that the foreground path keeps.
@Suite
struct TargetActionGuardTests {
    private func candidate(
        safety: WindowTargetSafetyStatus,
        processID: Int32 = 4242,
        windowID: UInt32 = 7
    ) -> MacWindowTargetCandidate {
        MacWindowTargetCandidate(
            windowID: windowID,
            processID: processID,
            appName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            title: "Notes",
            bounds: WindowTargetBounds(x: 10, y: 20, width: 300, height: 200),
            isVisible: true,
            isOnScreen: true,
            isFrontmost: false,
            isFocused: false,
            isIPhoneMirroring: false,
            safetyAssessment: WindowTargetSafetyAssessment(status: safety, summary: "test")
        )
    }

    @Test
    func backgroundPreferenceOnSafeControlYieldsPinnedTarget() {
        let decision = TargetActionGuard.resolve(
            candidate: candidate(safety: .allowed),
            preference: .background,
            lane: .axAction
        )
        guard case .background(let target) = decision else {
            Issue.record("expected a background decision, got \(decision)")
            return
        }
        #expect(target.processID == 4242)
        #expect(target.windowID == 7)
        #expect(target.bundleIdentifier == "com.apple.Notes")
    }

    @Test
    func foregroundPreferenceAlwaysYieldsForeground() {
        #expect(
            TargetActionGuard.resolve(
                candidate: candidate(safety: .allowed),
                preference: .foreground,
                lane: .axAction
            ) == .foreground
        )
    }

    @Test
    func unsafeSurfaceDegradesToForegroundEvenOnBackgroundTurn() {
        #expect(
            TargetActionGuard.resolve(
                candidate: candidate(safety: .blocked),
                preference: .background,
                lane: .axAction
            ) == .foreground
        )
        #expect(
            TargetActionGuard.resolve(
                candidate: candidate(safety: .reviewRequired),
                preference: .background,
                lane: .axAction
            ) == .foreground
        )
    }

    @Test
    func backgroundPreferenceOnPidEventPostLaneYieldsBackground() {
        let decision = TargetActionGuard.resolve(
            candidate: candidate(safety: .allowed),
            preference: .background,
            lane: .pidEventPost
        )
        guard case .background(let target) = decision else {
            Issue.record("expected a background decision for the pid-event-post lane, got \(decision)")
            return
        }
        #expect(target.processID == 4242)
    }

    @Test
    func unsafeSurfaceDegradesToForegroundOnPidEventPostLaneToo() {
        #expect(
            TargetActionGuard.resolve(
                candidate: candidate(safety: .blocked),
                preference: .background,
                lane: .pidEventPost
            ) == .foreground
        )
    }
}

@Suite
struct SkyLightEventPostBridgeTests {
    /// When the SkyLight symbols don't resolve, the bridge reports unavailable and both post methods
    /// return false, so the caller falls back to the public per-process post (and ultimately the HID tap)
    /// rather than silently dropping the input. This is the capability-detection fallback the whole
    /// background event lane rests on.
    @Test
    func reportsUnavailableAndFallsBackWhenSymbolsAreMissing() {
        let bridge = SkyLightEventPost.unavailableForTesting()
        #expect(bridge.isAvailable == false)
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else {
            return // Headless env can't synthesize a CGEvent; the availability check already covers the gate.
        }
        #expect(bridge.postKey(event, toPid: 1234) == false)
        #expect(bridge.postMouse(event, toPid: 1234, windowID: 1, windowLocalPoint: .zero) == false)
    }
}

@Suite
struct BackgroundAXActionBackendTests {
    private func command(nodeID: String, extra: [String: String]) -> ActionEngineCommand {
        ActionEngineCommand(
            id: UUID().uuidString,
            traceID: "ax-bg-test",
            targetID: nodeID,
            kind: .tap,
            issuedAt: RunTraceTimestamp(
                wallClock: Date(),
                monotonicUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            ),
            metadata: [
                "accessibility.nodeID": nodeID,
                "accessibility.action": "AXPress",
                "bundleIdentifier": "com.donkey.test.not-frontmost",
                "controlID": nodeID
            ].merging(extra) { _, new in new }
        )
    }

    /// Background mode routes to the supplied pid and must never be refused for not being frontmost,
    /// regardless of which app is in front (or whether the test runner holds Accessibility trust). With a
    /// pid that owns no window the action can't land, but the refusal reason is about staleness/trust —
    /// never `targetAppNotFrontmost`, which is exactly the gate background mode drops.
    @Test
    func backgroundModeNeverRequiresFrontmost() async {
        let backend = MacAccessibilityActionEngineInputBackend()
        let result = await backend.execute(command(
            nodeID: "ax-1.99999.99999",
            extra: ["accessibility.executionMode": "background", "accessibility.processID": "999999"]
        ))
        #expect(result.executed == false)
        #expect(result.metadata["accessibility.result"] != "targetAppNotFrontmost")
    }

    /// Foreground mode (no execution-mode metadata) keeps the frontmost guard: a bundle that is not in
    /// front never executes. A trusted runner refuses with `targetAppNotFrontmost`; an untrusted one
    /// short-circuits earlier with `accessibilityNotTrusted`. Either way it does not act.
    @Test
    func foregroundModeStillEnforcesFrontmost() async {
        let backend = MacAccessibilityActionEngineInputBackend()
        let result = await backend.execute(command(nodeID: "ax-1.99999.99999", extra: [:]))
        #expect(result.executed == false)
        let reason = result.metadata["accessibility.result"] ?? ""
        #expect(["targetAppNotFrontmost", "accessibilityNotTrusted"].contains(reason))
    }
}
