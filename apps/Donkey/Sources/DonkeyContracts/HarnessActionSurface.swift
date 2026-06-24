import Foundation

/// Whether an actionable turn drives a macOS app's GUI, or is produced entirely through system, web, and
/// generative tools with no app at all.
///
/// Like ``HarnessTurnKind`` and ``ExecutionPreference``, this is a typed field the request-understanding
/// boundary sets — never inferred by matching the user's words. It exists because an empty
/// ``HarnessRequestUnderstanding/targetAppName`` is ambiguous on its own: it can mean "operate whatever app
/// is already in front" or "no app is involved at all" (generate an image, fetch the web, read or change a
/// setting, write a file). Deterministic code reads this enum to decide whether the run pins an app and
/// requires input permission, or runs app-less — so an artifact task is never blocked on a missing frontmost
/// window, and an app-less task is never pinned to whatever app happened to be in front.
public enum HarnessActionSurface: String, Codable, Equatable, Sendable {
    /// The work operates a macOS app through its GUI — a specific named app, or the one already in front.
    /// The run pins that app, requires input permission, and drives it with the AX/vision/pointer tools.
    case guiApp
    /// The work needs no GUI app. The planner produces it with system, web, file, and generative tools
    /// (`shell_exec`, `web.*`, `files.*`, `image.generate`) — no app to focus, no pointer to move.
    case appless
}
