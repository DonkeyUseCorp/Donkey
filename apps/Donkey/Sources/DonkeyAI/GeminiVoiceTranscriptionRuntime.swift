import Foundation

/// Transcribes captured audio with Gemini's `generateContent`, used as the
/// automatic fallback when Apple's on-device speech path is unavailable or fails.
///
/// Auth mirrors the always-on Gemini Live session (see `GeminiLiveConnectionFactory`):
///
/// - **Developer API** (`GEMINI_API_KEY` set): post directly to
///   `generativelanguage.googleapis.com` with the key in the query string. Dev-only —
///   a client-held key.
/// - **Vertex AI** (no key): mint a short-lived OAuth token via the backend
///   (`DonkeyBackendInferenceClient.mintLiveConnection`) and post to the Vertex
///   `generateContent` endpoint with a bearer token. The long-lived credential
///   stays on the backend. This is the production path.
public struct GeminiVoiceTranscriptionRuntime: LocalVoiceTranscriptionRuntime {
    /// Turn-based transcription model. A fast flash model is plenty for short voice
    /// commands; override with `GEMINI_TRANSCRIPTION_MODEL`.
    public static let defaultModel = "gemini-2.5-flash"

    private static let prompt =
        "Transcribe this audio verbatim. Return only the transcript text with no commentary, labels, or quotation marks. If there is no speech, return an empty string."

    private let apiKey: String?
    private let model: String
    private let httpClient: any AIHTTPClient
    private let environment: [String: String]
    /// Caches the backend client and minted Vertex token across turns so the Vertex path
    /// doesn't rebuild the client and re-mint a fresh OAuth token on every transcription.
    private let vertexAuthCache = VertexAuthCache()

    public init(
        apiKey: String? = nil,
        model: String? = nil,
        httpClient: any AIHTTPClient = URLSessionAIHTTPClient(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.apiKey = GeminiGenerateContent.trimmed(apiKey ?? environment["GEMINI_API_KEY"])
        self.model = GeminiGenerateContent.trimmed(model ?? environment["GEMINI_TRANSCRIPTION_MODEL"]) ?? Self.defaultModel
        self.httpClient = httpClient
        self.environment = environment
    }

    public func transcribe(
        audio: LocalVoiceAudioBuffer,
        model entry: AIModelRegistryEntry
    ) async throws -> LocalVoiceTranscript {
        // Use the routed entry's model when it carries a usable one for this runtime; otherwise fall
        // back to `self.model` (the env override, else the constant). The metadata reports what was
        // used. `self.model` already folds env override over the constant.
        let requestModel = Self.resolvedModel(entry: entry, fallback: model)
        let request: URLRequest
        if let apiKey {
            request = try developerAPIRequest(apiKey: apiKey, model: requestModel, audio: audio)
        } else {
            request = try await vertexRequest(model: requestModel, audio: audio)
        }

        let (data, response) = try await httpClient.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GeminiVoiceTranscriptionError.requestFailed(
                status: response.statusCode,
                body: String(body.prefix(240))
            )
        }

        guard let text = GeminiGenerateContent.candidateText(data)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw LocalVoiceTranscriptionRuntimeError.emptyTranscript
        }

        return LocalVoiceTranscript(
            text: text,
            confidence: 1,
            metadata: [
                "transcript.backend": "gemini",
                "transcript.model": requestModel
            ]
        )
    }

    /// Resolves the request model. Prefers the routed entry's model when it carries a concrete one for
    /// this runtime (not the backend-selected sentinel and not the on-device placeholder the registry
    /// uses for the Apple entry), otherwise the supplied fallback (env override, else the constant).
    static func resolvedModel(entry: AIModelRegistryEntry, fallback: String) -> String {
        let entryModel = GeminiGenerateContent.trimmed(entry.modelID)
        guard let entryModel,
              entryModel != AIModelRegistryEntry.backendSelectedModelID,
              entry.provider != .localRuntime
        else {
            return fallback
        }
        return entryModel
    }

    private func developerAPIRequest(apiKey: String, model: String, audio: LocalVoiceAudioBuffer) throws -> URLRequest {
        var components = URLComponents(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        )
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components?.url else { throw GeminiVoiceTranscriptionError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.requestBody(audio: audio)
        return request
    }

    private func vertexRequest(model: String, audio: LocalVoiceAudioBuffer) async throws -> URLRequest {
        // Reuse the cached backend client and minted Vertex token; the token is only re-minted
        // when it's missing or has expired, not on every transcription.
        let auth = try await vertexAuthCache.auth(environment: environment, httpClient: httpClient)

        guard let url = GeminiGenerateContent.vertexURL(
            project: auth.project,
            location: auth.location,
            model: model
        ) else { throw GeminiVoiceTranscriptionError.invalidURL }

        return GeminiGenerateContent.vertexRequest(
            url: url,
            bearerToken: auth.token,
            body: try Self.requestBody(audio: audio)
        )
    }

    private static func requestBody(audio: LocalVoiceAudioBuffer) throws -> Data {
        try GeminiGenerateContent.requestBody(
            parts: [
                ["text": prompt],
                GeminiGenerateContent.inlineDataPart(
                    mimeType: mimeType(for: audio.format),
                    base64: audio.data.base64EncodedString()
                )
            ],
            generationConfig: ["temperature": 0]
        )
    }

    private static func mimeType(for format: String) -> String {
        switch format.lowercased() {
        // The normalizer emits WAV PCM16, so wav/pcm must stay audio/wav.
        case "wav", "pcm", "pcm_f32le", "pcm_s16le": return "audio/wav"
        case "flac": return "audio/flac"
        case "mp3", "mpeg": return "audio/mpeg"
        case "m4a", "mp4": return "audio/mp4"
        case "webm": return "audio/webm"
        case "opus": return "audio/ogg"
        case "aac": return "audio/aac"
        case "ogg": return "audio/ogg"
        case "aiff": return "audio/aiff"
        // Don't silently claim WAV for an unknown format — a generic octet-stream surfaces the
        // mismatch instead of mislabeling the bytes.
        default: return "application/octet-stream"
        }
    }
}

public enum GeminiVoiceTranscriptionError: Error, Equatable, Sendable {
    case invalidURL
    case requestFailed(status: Int, body: String)
}

/// Caches the backend client (built once from the environment) and the minted Vertex auth
/// bundle (token + project + location) so the transcription runtime doesn't rebuild the client
/// and mint a fresh OAuth token on every turn. The token is re-minted only when it's absent or
/// within `expiryMargin` of its reported expiry.
private actor VertexAuthCache {
    private var client: DonkeyBackendInferenceClient?
    private var cached: (auth: GeminiVertexVisionPlanner.VertexAuth, expiresAt: Date)?
    /// Re-mint a little before the token actually expires so an in-flight request doesn't race it.
    private static let expiryMargin: TimeInterval = 60
    /// When the mint response reports no expiry, cap how long the token is reused so a token can
    /// never be cached indefinitely (which would 401 after its real, unknown expiry).
    private static let defaultTTL: TimeInterval = 30 * 60

    func auth(
        environment: [String: String],
        httpClient: any AIHTTPClient
    ) async throws -> GeminiVertexVisionPlanner.VertexAuth {
        if let cached, !Self.isExpired(cached.expiresAt) {
            return cached.auth
        }

        let backend = try client ?? makeClient(environment: environment, httpClient: httpClient)
        client = backend
        let minted = try await backend.mintLiveConnection()
        guard let project = minted.project, let location = minted.location else {
            throw GeminiVertexVisionPlanner.PlannerError.missingProjectOrLocation
        }
        let auth = GeminiVertexVisionPlanner.VertexAuth(
            token: minted.token,
            project: project,
            location: location
        )
        // Fall back to a bounded default TTL when the mint reports no parseable expiry, so the token
        // is never cached forever.
        cached = (auth, Self.parseExpiry(minted.expiresAt) ?? Date().addingTimeInterval(Self.defaultTTL))
        return auth
    }

    private func makeClient(
        environment: [String: String],
        httpClient: any AIHTTPClient
    ) throws -> DonkeyBackendInferenceClient {
        let configuration = try DonkeyBackendInferenceConfiguration.fromEnvironment(environment)
        return DonkeyBackendInferenceClient(configuration: configuration, httpClient: httpClient)
    }

    private static func isExpired(_ expiresAt: Date) -> Bool {
        return Date().addingTimeInterval(expiryMargin) >= expiresAt
    }

    private static func parseExpiry(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = ISO8601DateFormatter().date(from: value) {
            return date
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }
}
