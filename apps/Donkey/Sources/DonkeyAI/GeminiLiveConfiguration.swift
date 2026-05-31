import Foundation

/// Configuration for the always-on Gemini Live session.
///
/// Gemini Live is the command brain: it always receives text input; audio is an
/// optional second input controlled by `audioEnabled`. The whole feature is gated
/// by `enabled` so the existing text/transcription pipeline is unchanged when it
/// is not configured.
///
/// Authentication is always Vertex AI OAuth: the Donkey backend mints a
/// short-lived access token (and supplies the endpoint + model) via
/// `POST /api/inference/live-token/`. There is no client-held API-key path.
public struct GeminiLiveConfiguration: Equatable, Sendable {
    /// Whether the Gemini Live brain is active at all. When false, callers keep
    /// the existing intent pipeline.
    public var enabled: Bool
    /// Whether microphone audio is streamed into the session (optional input).
    public var audioEnabled: Bool

    public init(enabled: Bool, audioEnabled: Bool = false) {
        self.enabled = enabled
        self.audioEnabled = audioEnabled
    }

    /// Build from environment.
    ///
    /// - `GEMINI_LIVE_ENABLED` (bool) — the always-on Live session, **on by
    ///   default**; set to a falsey value to opt out.
    /// - `GEMINI_LIVE_AUDIO` (bool) — also stream microphone audio (optional).
    ///
    /// The model id is owned by the backend (`GEMINI_LIVE_MODEL` there); the
    /// client never selects it.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GeminiLiveConfiguration {
        GeminiLiveConfiguration(
            enabled: boolValue(environment["GEMINI_LIVE_ENABLED"], default: true),
            audioEnabled: boolValue(environment["GEMINI_LIVE_AUDIO"])
        )
    }

    private static func trimmed(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue?.isEmpty == false ? trimmedValue : nil
    }

    private static func boolValue(_ value: String?, default defaultValue: Bool = false) -> Bool {
        switch trimmed(value)?.lowercased() {
        case .none:
            return defaultValue
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return defaultValue
        }
    }
}
