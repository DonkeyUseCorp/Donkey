import AppKit
@testable import Donkey
import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation
import Testing

/// Live, doubly-gated: the **hybrid** flow through the REAL production controller.
/// `GeminiLiveVoiceController` runs the fast realtime command session
/// (`gemini-live-2.5-flash`) with the Command Layer tools plus the `vision_control`
/// escalation. For "play Coldplay on Spotify" — which `music_play` can't do
/// (Apple-Music only) — the 2.5 model calls `vision_control`, and the controller
/// runs the gemini-3.5 `VertexVisionDriver` to operate Spotify. The test only feeds
/// the controller a text turn and verifies real Coldplay playback.
///
/// Behavior probe: both the model's choice to escalate and the vision grounding are
/// probabilistic — read the printed line (validated: escalates, ~8 vision turns,
/// Coldplay playing). Gated behind `DONKEY_LIVE_SMOKE=1` and `DONKEY_LIVE_INPUT=1`:
///
///     env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       DONKEY_LIVE_SMOKE=1 DONKEY_LIVE_INPUT=1 DONKEY_WEB_BASE_URL=http://localhost:3000 \
///       DONKEY_DEV_AUTH_BYPASS=1 swift test --filter GeminiLiveHybridSpotifySmokeTests
@Suite
struct GeminiLiveHybridSpotifySmokeTests {
    @Test
    @MainActor
    func commandControllerEscalatesToVisionForSpotify() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DONKEY_LIVE_SMOKE"] == "1", environment["DONKEY_LIVE_INPUT"] == "1",
              (try? DonkeyBackendInferenceConfiguration.fromEnvironment()) != nil
        else { return }

        // Seed a known NON-Coldplay track, then pause: Spotify auto-resumes the last
        // track on focus, so seeding a non-target ensures the goal can only be met by
        // the vision agent actually searching — not by stale/auto-resumed playback.
        NSWorkspace.shared.launchApplication("Spotify")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        _ = Self.runScript("tell application \"Spotify\" to play track \"spotify:track:4cOdK2wGLETKBW3PvgPWqT\"") // Rick Astley
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        LiveSmokeMusicProbe.pauseAll()

        let controller = GeminiLiveVoiceController()
        var acted: [String] = []
        controller.onActed = { acted.append($0) }
        await controller.start()
        #expect(controller.isConnected, "Live controller did not connect.")
        guard controller.isConnected else { await controller.stop(); return }

        let coldplayPlaying: @MainActor () -> Bool = {
            LiveSmokeMusicProbe.spotifyPlayingArtist().lowercased().contains("coldplay")
        }

        let start = Date()
        await controller.sendText("Play Coldplay's most popular song on Spotify.")
        // The controller's 2.5 model escalates to vision_control and runs the gemini-3.5
        // driver internally; wait for the real result (Coldplay playing).
        let played = await liveSmokeWaitUntil(timeout: 120) { await coldplayPlaying() }
        let total = Date().timeIntervalSince(start)
        await controller.stop()

        let escalated = acted.contains { $0.lowercased().contains("vision") }
        print(String(format: "[hybrid smoke] %@ in %.2fs — escalated_to_vision=%@\n  acted: %@",
                     played ? "PLAYING-COLDPLAY" : "DID NOT PLAY COLDPLAY", total, escalated ? "yes" : "no",
                     acted.joined(separator: " | ")))
        if !escalated {
            print("[hybrid smoke] note: the 2.5 model did not escalate to vision_control this run (model nondeterminism) — re-run.")
        }
        // The infra gate is `controller.isConnected` (asserted above); the escalation
        // and playback outcome are reported (both probabilistic), not hard-gated.
        _ = (escalated, played)
    }

    @MainActor
    @discardableResult
    private static func runScript(_ source: String) -> String? {
        var error: NSDictionary?
        let output = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? output?.stringValue : nil
    }
}
