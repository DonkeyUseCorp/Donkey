import AppKit
@testable import Donkey
import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation
import Testing

/// Live, doubly-gated: exercises the box-based vision driver (`VertexVisionBoxDriver`,
/// the `GEMINI_VISION_BOX=1` escalation path) driving Spotify to play. Each turn it
/// draws the model's returned bounding box + click points onto the screenshot and
/// saves it to `/tmp/donkey-vision-boxes/` so the box quality can be checked by eye —
/// the assertion only confirms the driver actually ran (grounding is probabilistic).
///
/// Gated behind `DONKEY_LIVE_SMOKE=1` and `DONKEY_LIVE_INPUT=1`. Run live:
///
///     env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       DONKEY_LIVE_SMOKE=1 DONKEY_LIVE_INPUT=1 GEMINI_VISION_BOX=1 \
///       DONKEY_WEB_BASE_URL=http://localhost:3000 DONKEY_DEV_AUTH_BYPASS=1 \
///       swift test --filter GeminiLiveVisionBoxSpotifySmokeTests
@Suite
struct GeminiLiveVisionBoxSpotifySmokeTests {
    @Test
    @MainActor
    func boxVisionDriverPlaysSpotify() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DONKEY_LIVE_SMOKE"] == "1", environment["DONKEY_LIVE_INPUT"] == "1",
              let config = try? DonkeyBackendInferenceConfiguration.fromEnvironment()
        else { return }
        let goal = environment["DONKEY_GOAL"] ?? "Search for the artist Coldplay and play their most popular song."
        let visionModel = GeminiLiveConfiguration.fromEnvironment().visionModel

        let outputDir = URL(fileURLWithPath: "/tmp/donkey-vision-boxes", isDirectory: true)
        try? FileManager.default.removeItem(at: outputDir)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        NSWorkspace.shared.launchApplication("Spotify")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        LiveSmokeMusicProbe.pauseAll()

        let auth = try await GeminiVertexVisionPlanner.mintAuth(
            backend: DonkeyBackendInferenceClient(configuration: config)
        )

        let start = Date()
        var saved = 0
        let outcome = await VertexVisionBoxDriver.drive(
            appName: "Spotify",
            bundleIdentifier: "com.spotify.client",
            goal: goal,
            auth: auth,
            model: visionModel,
            verify: { LiveSmokeMusicProbe.playerState(ofApp: "Spotify") == "playing" },
            onTurn: { turn, screenshot, action in
                guard let box = action.box,
                      let png = ScreenshotAnnotation.annotatedPNG(
                          screenshot: screenshot,
                          box: box,
                          label: "\(action.action): \(action.reason ?? "")"
                      )
                else { return }
                let url = outputDir.appendingPathComponent(String(format: "turn-%02d.png", turn))
                try? png.write(to: url)
                saved += 1
            }
        )
        let total = Date().timeIntervalSince(start)

        print(String(format: "[vision-box smoke / %@] %@ in %.2fs over %d turns — %d annotated frames in %@\n  trace: %@",
                     visionModel, outcome.completed ? "PLAYING" : "DID NOT PLAY", total, outcome.turns,
                     saved, outputDir.path, outcome.history.joined(separator: " | ")))
        // Probe (vision grounding is probabilistic): require the driver actually ran.
        #expect(outcome.turns > 0, "Box vision driver never took a turn (infra failure).")
    }
}
