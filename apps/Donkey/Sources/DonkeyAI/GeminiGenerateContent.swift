import Foundation

/// Small shared plumbing for Gemini `generateContent` calls, reused by the Vertex
/// vision planners and the voice transcription runtime so each feature builds its
/// own request body but not the endpoint URL or response parsing.
public enum GeminiGenerateContent {
    /// Vertex AI `generateContent` endpoint for a publisher model.
    public static func vertexURL(project: String, location: String, model: String) -> URL? {
        let host = location == "global"
            ? "aiplatform.googleapis.com"
            : "\(location)-aiplatform.googleapis.com"
        return URL(
            string: "https://\(host)/v1/projects/\(project)/locations/\(location)/publishers/google/models/\(model):generateContent"
        )
    }

    /// Trim whitespace and treat empty/absent as nil — the env-reading idiom used
    /// when pulling Gemini config (API key, model) out of the environment.
    public static func trimmed(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue?.isEmpty == false ? trimmedValue : nil
    }

    /// Serialize a `generateContent` request body: a single user turn whose `parts`
    /// are supplied by the caller (text / inlineData), plus the caller's
    /// `generationConfig` (temperature, response schema, thinking level, …).
    public static func requestBody(
        parts: [[String: Any]],
        generationConfig: [String: Any]
    ) throws -> Data {
        let body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": parts
            ]],
            "generationConfig": generationConfig
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// A part carrying a base64 inline blob (image/audio) with its MIME type.
    public static func inlineDataPart(mimeType: String, base64: String) -> [String: Any] {
        ["inlineData": ["mimeType": mimeType, "data": base64]]
    }

    /// Build the Vertex `generateContent` POST request: bearer auth + JSON content
    /// type, body already serialized.
    public static func vertexRequest(url: URL, bearerToken: String, body: Data) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    /// The text of the first candidate, concatenating its content parts. Returns
    /// nil when the response has no candidate text.
    public static func candidateText(_ data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]]
        else { return nil }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }
}
