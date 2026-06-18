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
        let request: URLRequest
        if let apiKey {
            request = try developerAPIRequest(apiKey: apiKey, audio: audio)
        } else {
            request = try await vertexRequest(audio: audio)
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
                "transcript.model": model
            ]
        )
    }

    private func developerAPIRequest(apiKey: String, audio: LocalVoiceAudioBuffer) throws -> URLRequest {
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

    private func vertexRequest(audio: LocalVoiceAudioBuffer) async throws -> URLRequest {
        let configuration = try DonkeyBackendInferenceConfiguration.fromEnvironment(environment)
        let backend = DonkeyBackendInferenceClient(configuration: configuration, httpClient: httpClient)
        let auth = try await GeminiVertexVisionPlanner.mintAuth(backend: backend)

        guard let url = GeminiGenerateContent.vertexURL(
            project: auth.project,
            location: auth.location,
            model: model
        ) else { throw GeminiVoiceTranscriptionError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.requestBody(audio: audio)
        return request
    }

    private static func requestBody(audio: LocalVoiceAudioBuffer) throws -> Data {
        let body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [
                    ["text": prompt],
                    ["inlineData": [
                        "mimeType": mimeType(for: audio.format),
                        "data": audio.data.base64EncodedString()
                    ]]
                ]
            ]],
            "generationConfig": ["temperature": 0]
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private static func mimeType(for format: String) -> String {
        switch format.lowercased() {
        case "flac": return "audio/flac"
        case "mp3": return "audio/mp3"
        case "aac": return "audio/aac"
        case "ogg": return "audio/ogg"
        case "aiff": return "audio/aiff"
        default: return "audio/wav"
        }
    }
}

public enum GeminiVoiceTranscriptionError: Error, Equatable, Sendable {
    case invalidURL
    case requestFailed(status: Int, body: String)
}
