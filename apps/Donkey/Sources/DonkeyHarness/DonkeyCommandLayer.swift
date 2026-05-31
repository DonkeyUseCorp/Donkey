import Foundation

/// The Donkey Command Layer: fast, deterministic, native commands the model can
/// call directly without screenshots or Accessibility. Descriptors live here in
/// the (Foundation-only) harness module; the native side effects are injected as
/// a `commandExecutor` closure on `HarnessBuiltInToolServices`, with the concrete
/// implementation in `DonkeyRuntime`.
public enum DonkeyCommandLayer {
    public static let pluginID = "donkey.command"

    /// Single source of truth for the command names shared between the descriptors
    /// here and the runtime backend that executes them.
    public enum Command: String, CaseIterable, Sendable {
        case shellExec = "shell_exec"
        case appsList = "apps.list"
        case musicPlay = "music.play"
    }

    public static var descriptors: [HarnessToolDescriptor] {
        [
            // Primary, general-purpose tool — listed first so the model reaches
            // for it by default.
            HarnessToolDescriptor(
                name: Command.shellExec.rawValue,
                pluginID: pluginID,
                summary: "Run a safe, single-line shell command on the user's Mac and return its output. General-purpose: open/activate or quit apps (e.g. `open -a Spotify`), drive apps and the system — including via `osascript -e '…'` — and read state (e.g. `date`, `pmset -g batt`). Avoid destructive, privileged (`sudo`), raw-disk, network-download, or pipe-to-shell commands.",
                inputSchema: ["command": "A safe, single-line shell command, e.g. `open -a Notes`, `osascript -e 'tell application \"Spotify\" to play'`, or `date`."],
                outputSchema: [
                    "stdout": "Captured standard output (trimmed).",
                    "exitCode": "Process exit code."
                ],
                requiredPermissions: [.appControl, .input],
                safetyClass: .guardedInput,
                verificationHints: ["the command exits with code 0"]
            ),
            HarnessToolDescriptor(
                name: Command.appsList.rawValue,
                pluginID: pluginID,
                summary: "List installed and currently-running applications (display names + bundle ids). Call this to discover exact app names before opening, quitting, or scripting an app instead of guessing.",
                inputSchema: ["filter": "Case-insensitive substring to narrow the results."],
                optionalInputKeys: ["filter"],
                outputSchema: [
                    "installed": "Comma-separated installed app names.",
                    "running": "Comma-separated running app names."
                ],
                requiredPermissions: [.appLookup],
                safetyClass: .readOnly
            ),
            HarnessToolDescriptor(
                name: Command.musicPlay.rawValue,
                pluginID: pluginID,
                summary: "Search for and play media in a music app (Spotify or Apple Music) without screenshots.",
                inputSchema: [
                    "query": "Track, artist, album, or playlist to search and play.",
                    "app": "Music app: Spotify or Music. Defaults to the user's available music app."
                ],
                optionalInputKeys: ["app"],
                outputSchema: ["status": "Playback status reported by the music app."],
                requiredPermissions: [.appControl, .input],
                safetyClass: .guardedInput,
                verificationHints: ["the music app reports that playback started"]
            )
        ]
    }
}
