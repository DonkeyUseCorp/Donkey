import Foundation

/// Configuration for the always-on Gemini Live session.
///
/// Gemini Live is the command brain: it always receives text input; audio is an
/// optional second input controlled by `audioEnabled`. The whole feature is gated
/// by `enabled` so the existing text/transcription pipeline is unchanged when it
/// is not configured.
///
/// Two auth paths (see `GeminiLiveConnectionFactory`): production is keyless
/// Vertex AI OAuth, where the Donkey backend mints a short-lived access token
/// (and supplies the endpoint + model) via `POST /api/inference/live-token/`. A
/// dev-only path connects directly to the Developer API when `GEMINI_API_KEY` is
/// set.
public struct GeminiLiveConfiguration: Equatable, Sendable {
    /// Whether the Gemini Live brain is active at all. When false, callers keep
    /// the existing intent pipeline.
    public var enabled: Bool
    /// Whether microphone audio is streamed into the session (optional input).
    public var audioEnabled: Bool
    /// Gemini Developer API key (`GEMINI_API_KEY`). When set, the client connects
    /// directly to the Developer API (`generativelanguage.googleapis.com`) with
    /// this key instead of minting a Vertex token via the backend. Dev-only — a
    /// client-held key; prod uses the keyless Vertex path.
    public var apiKey: String?
    /// Live model id for the Developer-API path (`GEMINI_LIVE_MODEL`). The Vertex
    /// path ignores this (its model comes from the backend mint response).
    public var model: String
    /// Model used for the per-turn vision driver (`GEMINI_VISION_MODEL`). This is a
    /// turn-based `generateContent` model (not Live/bidi) — a stronger model for
    /// the screenshot-grounding task than the fast realtime command model.
    public var visionModel: String
    /// Opt into the box-based vision driver (`GEMINI_VISION_BOX`): the planner
    /// returns a 2D bounding box and the driver clicks the box center plus nearby
    /// points in one turn. Off by default, leaving the single-point driver in place.
    public var visionBoxEnabled: Bool
    /// Whether the Developer-API Live session requests AUDIO response modality
    /// (`GEMINI_LIVE_AUDIO_OUTPUT`). The default Dev-API model is audio-output only,
    /// so this defaults true; set falsey when pointing `GEMINI_LIVE_MODEL` at a
    /// TEXT-capable Live model. Ignored on the Vertex path (always TEXT).
    public var liveAudioOutput: Bool

    /// Default Developer-API Live (command) model — the realtime, tool-calling
    /// brain. `gemini-2.5-flash-native-audio-preview-09-2025` is the 2.5 Live model
    /// available on the Developer API; it is audio-output only (see
    /// `GeminiLiveConnection.audioOutput`).
    public static let defaultModel = "gemini-2.5-flash-native-audio-preview-09-2025"
    /// Default vision model — stronger, turn-based, used only when a task needs the
    /// screen.
    public static let defaultVisionModel = "gemini-3.5-flash"

    public init(
        enabled: Bool,
        audioEnabled: Bool = false,
        apiKey: String? = nil,
        model: String = GeminiLiveConfiguration.defaultModel,
        visionModel: String = GeminiLiveConfiguration.defaultVisionModel,
        visionBoxEnabled: Bool = false,
        liveAudioOutput: Bool = true
    ) {
        self.enabled = enabled
        self.audioEnabled = audioEnabled
        self.apiKey = apiKey
        self.model = model
        self.visionModel = visionModel
        self.visionBoxEnabled = visionBoxEnabled
        self.liveAudioOutput = liveAudioOutput
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
            audioEnabled: boolValue(environment["GEMINI_LIVE_AUDIO"]),
            apiKey: trimmed(environment["GEMINI_API_KEY"]),
            model: trimmed(environment["GEMINI_LIVE_MODEL"]) ?? defaultModel,
            visionModel: trimmed(environment["GEMINI_VISION_MODEL"]) ?? defaultVisionModel,
            visionBoxEnabled: boolValue(environment["GEMINI_VISION_BOX"]),
            liveAudioOutput: boolValue(environment["GEMINI_LIVE_AUDIO_OUTPUT"], default: true)
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
