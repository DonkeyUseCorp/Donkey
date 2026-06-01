import AppKit
@testable import Donkey
import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation
import Testing

/// Live, end-to-end smoke test that plays music through the REAL production Live
/// brain — `GeminiLiveVoiceController` — which owns the Gemini Live session
/// (`gemini-live-2.5-flash` on Vertex) and the Donkey Command Layer harness
/// registry. The test only hands the controller a text turn ("play some cold play")
/// and verifies a music app actually starts playing; the controller does the real
/// work (model → `music_play` tool → harness execution).
///
/// Gated behind `DONKEY_LIVE_SMOKE=1`; no-ops otherwise. To run it live:
///
///     env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       DONKEY_LIVE_SMOKE=1 DONKEY_WEB_BASE_URL=http://localhost:3000 DONKEY_DEV_AUTH_BYPASS=1 \
///       swift test --filter GeminiLiveMusicPlaybackLiveSmokeTests
@Suite
struct GeminiLiveMusicPlaybackLiveSmokeTests {
    @Test
    @MainActor
    func playsMusicThroughTheLiveController() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DONKEY_LIVE_SMOKE"] == "1" else { return }
        if environment["DONKEY_WEB_BASE_URL"]?.isEmpty != false {
            Issue.record("DONKEY_LIVE_SMOKE=1 but DONKEY_WEB_BASE_URL is not set; cannot reach a backend.")
            return
        }

        LiveSmokeMusicProbe.pauseAll()

        let controller = GeminiLiveVoiceController()
        var acted: [String] = []
        controller.onActed = { acted.append($0) }
        await controller.start()
        #expect(controller.isConnected, "Live controller did not connect (Vertex gemini-live-2.5-flash).")
        guard controller.isConnected else { await controller.stop(); return }

        let start = Date()
        await controller.sendText("play some cold play")
        let playing = await liveSmokeWaitUntil(timeout: 60) { await LiveSmokeMusicProbe.isAnyMusicPlaying() }
        let duration = Date().timeIntervalSince(start)
        await controller.stop()

        print(String(format: "[music smoke] live controller %@ in %.2fs  (acted: %@)",
                     playing ? "PLAYING" : "DID NOT PLAY", duration, acted.joined(separator: " | ")))
        #expect(playing, "Live controller did not start music within 60s. acted=\(acted)")
    }
}
