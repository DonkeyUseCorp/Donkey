import AppKit
import Foundation

/// Shared helpers for the live Gemini smoke tests. The session orchestration and
/// vision driver now live in production (`GeminiLiveVoiceController`,
/// `VertexVisionDriver`); these are just test utilities.

/// Poll `condition` until it's true or `timeout` seconds elapse.
@discardableResult
func liveSmokeWaitUntil(timeout seconds: Double, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    return await condition()
}

/// Reads/controls real music-app playback via Automation (NSAppleScript),
/// independent of the model's claims — so the smoke tests verify music is ACTUALLY
/// playing (and the RIGHT artist), not just that the model said so.
enum LiveSmokeMusicProbe {
    /// True if Spotify or Apple Music reports it is currently playing.
    @MainActor static func isAnyMusicPlaying() -> Bool {
        playerState(ofApp: "Spotify") == "playing" || playerState(ofApp: "Music") == "playing"
    }

    /// Pause both music apps if they are running (no-op if not).
    @MainActor static func pauseAll() {
        runIfRunning(app: "Spotify", command: "pause")
        runIfRunning(app: "Music", command: "pause")
    }

    /// The currently-playing Spotify track's artist, or "" if not playing / not
    /// running. Used to verify the RIGHT music is playing — Spotify auto-resumes a
    /// random track on launch, so "is anything playing" is not enough.
    @MainActor static func spotifyPlayingArtist() -> String {
        let source = """
        tell application "System Events"
            if not (exists process "Spotify") then return ""
        end tell
        tell application "Spotify"
            if player state is playing then return (artist of current track) as text
        end tell
        return ""
        """
        return runScript(source) ?? ""
    }

    /// `"playing"`, `"notplaying"`, `"notrunning"`, or `"unknown"`. Uses System
    /// Events to check the process first so it never launches a stopped app.
    @MainActor static func playerState(ofApp app: String) -> String {
        let source = """
        tell application "System Events"
            if not (exists process "\(app)") then return "notrunning"
        end tell
        tell application "\(app)"
            if player state is playing then
                return "playing"
            else
                return "notplaying"
            end if
        end tell
        """
        return runScript(source) ?? "unknown"
    }

    @MainActor private static func runIfRunning(app: String, command: String) {
        let source = """
        tell application "System Events"
            if not (exists process "\(app)") then return
        end tell
        tell application "\(app)" to \(command)
        """
        _ = runScript(source)
    }

    @MainActor private static func runScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let output = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return output.stringValue
    }
}
