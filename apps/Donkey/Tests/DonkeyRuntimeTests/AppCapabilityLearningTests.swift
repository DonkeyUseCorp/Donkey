import DonkeyRuntime
import Foundation
import Testing

@Suite
struct AppCapabilityLearningTests {
    // MARK: Resolver — runtime evidence overrides the static probe

    @Test
    func usesProbeWhenNoRuntimeEvidence() {
        let obs = AppScriptabilityObservation(bundleIdentifier: "x", probed: .scriptable)
        #expect(AppScriptabilityResolver.resolve(obs) == .scriptable)
        let obs2 = AppScriptabilityObservation(bundleIdentifier: "y", probed: .notScriptable)
        #expect(AppScriptabilityResolver.resolve(obs2) == .notScriptable)
    }

    @Test
    func repeatedFailuresOverrideAScriptableProbe() {
        let obs = AppScriptabilityObservation(bundleIdentifier: "x", probed: .scriptable, appleScriptFailures: 2)
        #expect(AppScriptabilityResolver.resolve(obs) == .notScriptable)
    }

    @Test
    func aSuccessOverridesEvenANotScriptableProbe() {
        let obs = AppScriptabilityObservation(
            bundleIdentifier: "x", probed: .notScriptable, appleScriptSuccesses: 1, appleScriptFailures: 5
        )
        #expect(AppScriptabilityResolver.resolve(obs) == .scriptable)
    }

    @Test
    func oneFailureIsNotEnoughToFlip() {
        let obs = AppScriptabilityObservation(bundleIdentifier: "x", probed: .scriptable, appleScriptFailures: 1)
        #expect(AppScriptabilityResolver.resolve(obs) == .scriptable)
    }

    // MARK: Service — probes once, then learns from outcomes

    /// Thread-safe call counter usable from a @Sendable probe closure.
    final class Counter: @unchecked Sendable {
        private var value = 0
        private let lock = NSLock()
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test
    func probesOnFirstEncounterThenLearnsFromFailures() {
        let store = InMemoryAppScriptabilityStore()
        let probeCalls = Counter()
        let service = AppCapabilityService(store: store) { _, _ in
            probeCalls.increment()
            return .scriptable   // bundle says scriptable
        }

        // First lookup probes and caches.
        #expect(service.scriptability(bundleIdentifier: "com.example.app") == .scriptable)
        #expect(probeCalls.count == 1)
        // Cached: no re-probe.
        #expect(service.scriptability(bundleIdentifier: "com.example.app") == .scriptable)
        #expect(probeCalls.count == 1)

        // Two real AppleScript failures on this machine flip it to accessibility/UI.
        service.recordAppleScriptOutcome(bundleIdentifier: "com.example.app", succeeded: false)
        service.recordAppleScriptOutcome(bundleIdentifier: "com.example.app", succeeded: false)
        #expect(service.scriptability(bundleIdentifier: "com.example.app") == .notScriptable)
    }

    @Test
    func fileStorePersistsLearningAcrossInstances() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("donkey-scriptability-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = FileAppScriptabilityStore(url: url)
        first.record(AppScriptabilityObservation(bundleIdentifier: "com.example.app", probed: .scriptable, appleScriptFailures: 3))

        let reopened = FileAppScriptabilityStore(url: url)
        let restored = reopened.observation(bundleIdentifier: "com.example.app")
        #expect(restored?.appleScriptFailures == 3)
        #expect(restored.map(AppScriptabilityResolver.resolve) == .notScriptable)
    }
}
