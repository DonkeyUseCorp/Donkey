import Foundation

/// Builds the `GeminiLiveConnection` provider for a Live session, choosing the
/// auth path from configuration:
///
/// - **Developer API** (`GEMINI_API_KEY` set): connect directly to
///   `generativelanguage.googleapis.com` with the key in the query string, using
///   the hardcoded `GeminiLiveConfiguration.defaultModel` (an audio-output-only
///   model). No
///   backend round-trip. Dev-only — a client-held key.
/// - **Vertex AI** (no key): mint a short-lived OAuth token via the backend
///   (`DonkeyBackendInferenceClient.mintLiveConnection`); the model + endpoint
///   come from the backend. This stays the production path (no client secrets).
public enum GeminiLiveConnectionFactory {
    /// Developer-API bidi Live endpoint (v1beta).
    private static let developerAPIEndpoint =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    /// A provider that rebuilds the connection on every (re)connect so Vertex
    /// OAuth tokens stay fresh; the Developer-API key path is constant.
    public static func makeProvider(
        configuration: GeminiLiveConfiguration = .fromEnvironment()
    ) -> @Sendable () async throws -> GeminiLiveConnection {
        return {
            if let apiKey = configuration.apiKey, !apiKey.isEmpty {
                return try developerAPIConnection(
                    apiKey: apiKey, model: configuration.model, audioOutput: configuration.liveAudioOutput
                )
            }
            return try await vertexConnection()
        }
    }

    static func developerAPIConnection(apiKey: String, model: String, audioOutput: Bool) throws -> GeminiLiveConnection {
        var components = URLComponents(string: developerAPIEndpoint)
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components?.url else { throw GeminiLiveError.invalidURL }
        // The key authenticates via the query string, so there's no bearer token.
        // The default Dev-API model is audio-output only, so `audioOutput` defaults
        // true (tool calls + output transcription still flow even when TEXT is
        // rejected); use a TEXT-capable model to change that.
        return GeminiLiveConnection(url: url, bearerToken: nil, model: model, audioOutput: audioOutput)
    }

    static func vertexConnection() async throws -> GeminiLiveConnection {
        let backend = DonkeyBackendInferenceClient(
            configuration: try DonkeyBackendInferenceConfiguration.fromEnvironment()
        )
        let minted = try await backend.mintLiveConnection()
        guard let url = URL(string: minted.websocketUrl) else { throw GeminiLiveError.invalidURL }
        return GeminiLiveConnection(url: url, bearerToken: minted.token, model: minted.model, audioOutput: false)
    }
}
