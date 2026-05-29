import DonkeyRuntime
import Foundation
import Testing

@Suite
struct ExecutionStrategyTests {
    // MARK: Scriptability classification

    @Test
    func electronIsNotScriptableRegardlessOfOtherSignals() {
        let facts = AppScriptabilityFacts(bundleIdentifier: "com.spotify.client", appleScriptEnabled: true, isElectron: true)
        #expect(AppScriptabilityClassifier.classify(facts) == .notScriptable)
    }

    @Test
    func appleScriptEnabledFlagIsAuthoritative() {
        #expect(AppScriptabilityClassifier.classify(AppScriptabilityFacts(appleScriptEnabled: true)) == .scriptable)
        #expect(AppScriptabilityClassifier.classify(AppScriptabilityFacts(appleScriptEnabled: false)) == .notScriptable)
    }

    @Test
    func appWithNoScriptingSignalsIsUnknownWithoutBundleFacts() {
        // No allowlists: a bundle id alone (no Electron marker, no AppleScript flag/sdef from the
        // bundle probe) is unknown until probed/learned.
        #expect(AppScriptabilityClassifier.classify(AppScriptabilityFacts(bundleIdentifier: "com.example.mystery")) == .unknown)
    }

    @Test
    func bundleProbeFactsDriveClassificationNotAppName() {
        // Electron app (e.g. resolved for Spotify) → not scriptable from the structural marker alone.
        #expect(AppScriptabilityClassifier.classify(AppScriptabilityFacts(bundleIdentifier: "com.spotify.client", isElectron: true)) == .notScriptable)
        // Scriptable app (e.g. Music) → scriptable from its declared scripting dictionary.
        #expect(AppScriptabilityClassifier.classify(AppScriptabilityFacts(bundleIdentifier: "com.apple.Music", appleScriptEnabled: true)) == .scriptable)
    }

    // MARK: Strategy selection

    @Test
    func scriptableUsesAppleScriptAndNonScriptableUsesAccessibility() {
        #expect(ExecutionStrategySelector.strategy(scriptability: .scriptable) == .appleScript)
        #expect(ExecutionStrategySelector.strategy(scriptability: .notScriptable) == .accessibilityUI)
    }

    @Test
    func unknownTriesAppleScriptFirst() {
        #expect(ExecutionStrategySelector.strategy(scriptability: .unknown) == .appleScript)
    }

    @Test
    func appleScriptFailureFallsBackToAccessibilityEvenForScriptableApps() {
        #expect(
            ExecutionStrategySelector.strategy(
                scriptability: .scriptable,
                appleScriptAttempted: true,
                appleScriptSucceeded: false
            ) == .accessibilityUI
        )
        // A successful AppleScript attempt does not fall back.
        #expect(
            ExecutionStrategySelector.strategy(
                scriptability: .scriptable,
                appleScriptAttempted: true,
                appleScriptSucceeded: true
            ) == .appleScript
        )
    }
}
