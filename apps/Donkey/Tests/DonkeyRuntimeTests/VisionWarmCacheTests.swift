@testable import DonkeyAI
import DonkeyRuntime
import Testing

/// Coverage for the always-on warm-cache monitor's pure change/debounce decision and the activity
/// gate that pauses it during an active drive. The capture+parse side effects are integration-only.
@Suite
struct VisionWarmCacheTests {
    private func signature(fill: UInt8) -> ScreenshotSignature {
        ScreenshotSignature(pixels: [UInt8](repeating: fill, count: 64 * 64), dimension: 64)
    }

    @Test
    func firstSightingAlwaysParses() {
        let decision = VisionWarmCachePolicy.decide(
            previous: nil,
            next: signature(fill: 100),
            bigChangeThreshold: 0.10,
            lastParseUptimeMS: nil,
            nowUptimeMS: 0,
            minReparseIntervalMS: 1_500
        )
        #expect(decision == .parse)
    }

    @Test
    func unchangedScreenSkips() {
        let decision = VisionWarmCachePolicy.decide(
            previous: signature(fill: 100),
            next: signature(fill: 100),
            bigChangeThreshold: 0.10,
            lastParseUptimeMS: 0,
            nowUptimeMS: 10_000,
            minReparseIntervalMS: 1_500
        )
        #expect(decision == .skipUnchanged)
    }

    @Test
    func bigChangeWithinDebounceIsDeferred() {
        let decision = VisionWarmCachePolicy.decide(
            previous: signature(fill: 0),
            next: signature(fill: 255),
            bigChangeThreshold: 0.10,
            lastParseUptimeMS: 500,
            nowUptimeMS: 1_000, // 500ms since last parse, under the 1500ms window
            minReparseIntervalMS: 1_500
        )
        #expect(decision == .skipDebounced)
    }

    @Test
    func bigChangeAfterDebounceParses() {
        let decision = VisionWarmCachePolicy.decide(
            previous: signature(fill: 0),
            next: signature(fill: 255),
            bigChangeThreshold: 0.10,
            lastParseUptimeMS: 500,
            nowUptimeMS: 5_000,
            minReparseIntervalMS: 1_500
        )
        #expect(decision == .parse)
    }

    @Test
    func activityGateTracksSuspendDepth() {
        let gate = VisionWarmCacheActivity()
        #expect(!gate.isSuspended)
        gate.suspend()
        gate.suspend()
        #expect(gate.isSuspended)
        gate.resume()
        #expect(gate.isSuspended) // still one suspend outstanding
        gate.resume()
        #expect(!gate.isSuspended)
    }
}
