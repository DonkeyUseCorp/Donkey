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
