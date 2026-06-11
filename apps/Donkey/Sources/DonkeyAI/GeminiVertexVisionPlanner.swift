import CoreGraphics
import DonkeyContracts
import DonkeyRuntime
import Foundation

/// Per-turn vision planner backed by a strong turn-based Vertex model
/// (default `gemini-3.5-flash`), separate from the realtime Live command model
/// (`gemini-live-2.5-flash`). Given the current window screenshot + goal it returns
/// the single next UI action (click / type / key / done) with click coordinates in
/// Gemini's 0–1000 normalized space, mapped to the window via
/// `VisionActionPlanner.screenPoint`.
///
/// It calls Vertex `generateContent` directly with a Bearer token minted by the
/// backend (`DonkeyBackendInferenceClient.mintLiveConnection` returns the token +
/// project + location), so the long-lived service-account credential stays on the
/// backend. Reuse one minted token across a session's turns.
public enum GeminiVertexVisionPlanner {
    public struct VertexAuth: Sendable {
        public var token: String
        public var project: String
        public var location: String
        public init(token: String, project: String, location: String) {
            self.token = token
            self.project = project
            self.location = location
        }
    }

    public enum PlannerError: Error, CustomStringConvertible {
        case missingProjectOrLocation
        case requestFailed(status: Int, body: String)
        case noOutputText(body: String)
        public var description: String {
            switch self {
            case .missingProjectOrLocation: return "mint response lacked project/location"
            case let .requestFailed(status, body): return "vertex generateContent \(status): \(body.prefix(200))"
            case let .noOutputText(body): return "no output text: \(body.prefix(200))"
            }
        }
    }

    /// Mint a Vertex auth bundle (token + project + location) from the backend.
    public static func mintAuth(backend: DonkeyBackendInferenceClient) async throws -> VertexAuth {
        let minted = try await backend.mintLiveConnection()
        guard let project = minted.project, let location = minted.location else {
            throw PlannerError.missingProjectOrLocation
        }
        return VertexAuth(token: minted.token, project: project, location: location)
    }

    public static func nextAction(
        auth: VertexAuth,
        model: String,
        goal: String,
        appName: String,
        history: [String],
        appGuidance: String? = nil,
        compressed: CompressedScreenshot,
        window: WindowTargetBounds,
        urlSession: URLSession = .shared
    ) async throws -> VisionActionPlanner.PlannedAction {
        let host = auth.location == "global" ? "aiplatform.googleapis.com" : "\(auth.location)-aiplatform.googleapis.com"
        let endpoint = "https://\(host)/v1/projects/\(auth.project)/locations/\(auth.location)/publishers/google/models/\(model):generateContent"
        guard let url = URL(string: endpoint) else { throw PlannerError.requestFailed(status: -1, body: "bad url") }

        let width = Int(compressed.pixelSize.width.rounded())
        let height = Int(compressed.pixelSize.height.rounded())
        let prompt = VisionActionPlanner.visionPrompt(
            goal: goal, app: appName, width: width, height: height, history: history, appGuidance: appGuidance
        )
        let body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [
                    ["text": prompt],
                    ["inlineData": ["mimeType": compressed.contentType, "data": compressed.data.base64EncodedString()]]
                ]
            ]],
            "generationConfig": [
                "temperature": 0,
                "responseMimeType": "application/json",
                // gemini-3.5-flash takes thinking_level (the integer thinkingBudget is ignored on 3.x).
                // No maxOutputTokens is set, so the large default leaves ample room for medium thinking
                // plus the small action JSON. Vertex takes the proto enum name (uppercase).
                "thinkingConfig": ["thinkingLevel": "MEDIUM"],
                "responseSchema": [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["click", "type", "key", "done"]],
                        "x": ["type": "number"],
                        "y": ["type": "number"],
                        "text": ["type": "string"],
                        "reason": ["type": "string"]
                    ],
                    "required": ["action", "x", "y", "reason"]
                ]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw PlannerError.requestFailed(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let text = outputText(data), !text.isEmpty else {
            throw PlannerError.noOutputText(body: String(data: data, encoding: .utf8) ?? "")
        }
        let json = DebugUIInspectionResponseDecoder.jsonObjectSubstring(text)
        var action = try JSONDecoder().decode(VisionActionPlanner.PlannedAction.self, from: Data(json.utf8))
        action.screenPoint = VisionActionPlanner.screenPoint(action: action, window: window)
        return action
    }

    private static func outputText(_ data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]]
        else { return nil }
        return parts.compactMap { $0["text"] as? String }.joined()
    }
}
