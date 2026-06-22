import Foundation

/// Whether a turn's work should run in the background (the agent acts without taking over the user's
/// cursor or raising the target app) or in the foreground (the user is meant to watch it happen).
///
/// This is a typed field set once by the request-understanding boundary — never inferred by matching
/// raw user text. Deterministic code reads only this enum, never the original phrasing. Background is
/// the default operating mode; foreground is chosen only when the point of the turn is for the user to
/// see the result on screen (pulling something up, "show me", "how do I…", a walkthrough).
public enum ExecutionPreference: String, Codable, Equatable, Sendable {
    case foreground
    case background
}
