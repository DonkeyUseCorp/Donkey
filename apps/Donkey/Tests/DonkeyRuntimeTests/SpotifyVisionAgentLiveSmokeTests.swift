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
        let capturer = ScreenCaptureKitWindowScreenshotCapturer()
        // App-specific operating playbook, discovered from BuiltInSkills/spotify/SKILL.md by app name
        // (no hardcoded app logic in code — add a SKILL.md to teach the agent a new app).
        let appGuidance = BuiltInLocalAppSkillPacks.appOperatingGuidance(forApp: "Spotify", bundleIdentifier: "com.spotify.client")

        NSWorkspace.shared.launchApplication("Spotify")
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        var log: [String] = []
        var history: [String] = []
        for turn in 0..<12 {
            guard let target = AccessibilityObserver.resolveTarget(appName: "Spotify", bundleIdentifier: nil) else {
                log.append("turn \(turn): no window"); break
            }
            guard let shot = try? await capturer.capture(target: target) else {
                log.append("turn \(turn): capture failed"); break
            }
            // Dump exactly what the model sees (compressed) so we can inspect it.
            let dump = ScreenshotCompression.compressedForModel(shot)
            let dumpPath = "/tmp/spotify-agent-turn\(turn).jpg"
            try? dump.data.write(to: URL(fileURLWithPath: dumpPath))
            log.append("turn \(turn): window=(\(Int(target.bounds.x)),\(Int(target.bounds.y)) \(Int(target.bounds.width))x\(Int(target.bounds.height))) model-image=\(Int(dump.pixelSize.width))x\(Int(dump.pixelSize.height)) -> \(dumpPath)")
            let action: VisionActionPlanner.PlannedAction
            do {
                action = try await VisionActionPlanner.nextAction(goal: goal, app: "Spotify", screenshot: shot, window: target.bounds, history: history, appGuidance: appGuidance, backend: backend)
            } catch {
                log.append("turn \(turn): planner error \(error)"); break
            }
            log.append("turn \(turn): \(action.action) x=\(action.x.map { String(Int($0)) } ?? "-") y=\(action.y.map { String(Int($0)) } ?? "-") text=\(action.text ?? "") :: \(action.reason ?? "")")

            // Effective action: a "click" that carries text but no point is really a "type".
            var effective = action.action
            if effective == "click", action.screenPoint == nil, let t = action.text, !t.isEmpty {
                effective = "type"
            }

            switch effective {
            case "done":
                log.append("turn \(turn): model reports DONE")
                // Verify the agent's claim against the app's real playback state.
                let state = Self.spotifyPlayerState()
                log.append("verified player state: \(state)")
                #expect(state == "playing", "Agent finished but Spotify is not playing.\n\(log.joined(separator: "\n"))")
                return
            case "click":
                if let p = action.screenPoint {
                    _ = MacPointerInput.moveAndClick(at: p)
                    history.append("clicked at (\(Int(action.x ?? 0)),\(Int(action.y ?? 0))) — \(action.reason ?? "")")
                } else {
                    history.append("attempted click but no coordinates were given — \(action.reason ?? "")")
                }
            case "type":
                if let t = action.text { MacKeyboardInput.type(t); history.append("typed \"\(t)\"") }
            case "key":
                MacKeyboardInput.pressReturn()
                history.append("pressed return")
            default:
                break
            }
            try? await Task.sleep(nanoseconds: 2_200_000_000)
        }
        // Loop ended without the model declaring done — still verify the end state.
        let state = Self.spotifyPlayerState()
        log.append("loop ended; verified player state: \(state)")
        #expect(state == "playing", "Vision agent loop ended without playing music.\n\(log.joined(separator: "\n"))")
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
