import AppKit
@testable import Donkey
import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation
import Testing

/// Live, doubly-gated: exercises the production `VertexVisionDriver` (the
/// gemini-3.5 screenshot loop the Live controller escalates to) directly, driving
/// Spotify to play. (For the full hybrid — 2.5 command session escalating to this
/// via `vision_control` — see `GeminiLiveHybridSpotifySmokeTests`.) Reports total
/// latency to real playback (verified via Automation).
///
/// Gated behind `DONKEY_LIVE_SMOKE=1` and `DONKEY_LIVE_INPUT=1`. Run live:
///
///     env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       DONKEY_LIVE_SMOKE=1 DONKEY_LIVE_INPUT=1 DONKEY_WEB_BASE_URL=http://localhost:3000 \
///       DONKEY_DEV_AUTH_BYPASS=1 swift test --filter GeminiLiveVisionSpotifyLiveSmokeTests
@Suite
struct GeminiLiveVisionSpotifyLiveSmokeTests {
    @Test
    @MainActor
    func visionDriverPlaysSpotify() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DONKEY_LIVE_SMOKE"] == "1", environment["DONKEY_LIVE_INPUT"] == "1",
              let config = try? DonkeyBackendInferenceConfiguration.fromEnvironment()
        else { return }
        let goal = environment["DONKEY_GOAL"] ?? "Search for the artist Coldplay and play their most popular song."
        let visionModel = GeminiLiveConfiguration.fromEnvironment().visionModel

        NSWorkspace.shared.launchApplication("Spotify")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        LiveSmokeMusicProbe.pauseAll()

        let auth = try await GeminiVertexVisionPlanner.mintAuth(
            backend: DonkeyBackendInferenceClient(configuration: config)
        )

        let start = Date()
        let outcome = await VertexVisionDriver.drive(
            appName: "Spotify",
            bundleIdentifier: "com.spotify.client",
            goal: goal,
            auth: auth,
            model: visionModel,
            verify: { LiveSmokeMusicProbe.playerState(ofApp: "Spotify") == "playing" }
        )
        let total = Date().timeIntervalSince(start)

        print(String(format: "[vision smoke / %@] %@ in %.2fs over %d turns (%.2fs/turn)\n  trace: %@",
                     visionModel, outcome.completed ? "PLAYING" : "DID NOT PLAY", total, outcome.turns,
                     outcome.turns > 0 ? total / Double(outcome.turns) : total,
                     outcome.history.joined(separator: " | ")))
        // Probe (vision grounding is probabilistic): require the driver actually ran.
        #expect(outcome.turns > 0, "Vision driver never took a turn (infra failure).")
    }
}
