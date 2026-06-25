import AppKit
import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation
import Testing

/// Live, doubly-gated: drive Spotify to play music via a per-turn vision loop (screenshot → ask the
/// hosted model for the next click/type → execute → re-screenshot → repeat). Adapts to whatever the
/// UI becomes after each step. Verify Spotify state afterward with `osascript`.
@Suite
struct SpotifyVisionAgentLiveSmokeTests {
    @Test
    @MainActor
    func playsViaVisionAgentLoop() async {
        let env = ProcessInfo.processInfo.environment
        guard env["DONKEY_LIVE_SMOKE"] == "1", env["DONKEY_LIVE_INPUT"] == "1",
              let config = try? DonkeyBackendInferenceConfiguration.fromEnvironment()
        else { return }

        let goal = env["DONKEY_GOAL"] ?? "Search for the artist Coldplay and play their most popular song."
        let backend = DonkeyBackendInferenceClient(configuration: config, httpClient: URLSessionAIHTTPClient())
        // App-specific operating playbook, discovered from BuiltInSkills/spotify/SKILL.md by app name
        // (no hardcoded app logic in code — add a SKILL.md to teach the agent a new app).
        let appGuidance = BuiltInLocalAppSkillPacks.appOperatingGuidance(forApp: "Spotify", bundleIdentifier: "com.spotify.client")

        NSWorkspace.shared.launchApplication("Spotify")
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // Drive via the SAME shared loop production uses, so this smoke test validates the real path.
        var log: [String] = []
        let outcome = await VisionActionDriver.drive(
            appName: "Spotify",
            bundleIdentifier: "com.spotify.client",
            goal: goal,
            appGuidance: appGuidance,
            backend: backend,
            settleNanoseconds: 2_200_000_000,
            onTurn: { info in
                // Dump exactly what the model saw (compressed) so we can inspect it.
                let dump = ScreenshotCompression.compressedForModel(info.screenshot)
                try? dump.data.write(to: URL(fileURLWithPath: "/tmp/spotify-agent-turn\(info.turn).jpg"))
                log.append("turn \(info.turn): \(info.action.summary)")
            }
        )
        log.append("driver outcome: completed=\(outcome.completed) turns=\(outcome.turns) reason=\(outcome.reason)")

        // Verify the agent's claim against the app's REAL playback state (independent of vision).
        let state = Self.spotifyPlayerState()
        log.append("verified player state: \(state)")
        #expect(state == "playing", "Vision agent finished but Spotify is not playing.\n\(log.joined(separator: "\n"))")
    }

    /// Reads Spotify's real playback state via Automation (NSAppleScript), independent of vision,
    /// so the smoke test verifies music is ACTUALLY playing rather than trusting the model's claim.
    @MainActor
    private static func spotifyPlayerState() -> String {
        let source = "tell application \"Spotify\"\nif player state is playing then\nreturn \"playing\"\nelse\nreturn \"notplaying\"\nend if\nend tell"
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return "unknown" }
        let output = script.executeAndReturnError(&error)
        if let error { return "error(\(error["NSAppleScriptErrorBriefMessage"] ?? "?"))" }
        return output.stringValue ?? "unknown"
    }
}
