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
        let width = Int(compressed.pixelSize.width.rounded())
        let height = Int(compressed.pixelSize.height.rounded())
        let prompt = VisionActionPlanner.visionPrompt(
            goal: goal, app: appName, width: width, height: height, history: history, appGuidance: appGuidance
        )
        let generationConfig: [String: Any] = [
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

        var action = try await generateAction(
            auth: auth,
            model: model,
            prompt: prompt,
            compressed: compressed,
            generationConfig: generationConfig,
            urlSession: urlSession,
            decode: VisionActionPlanner.PlannedAction.self
        )
        action.screenPoint = VisionActionPlanner.screenPoint(action: action, window: window)
        return action
    }

    /// Shared Vertex vision turn: resolve the endpoint, post the prompt + screenshot
    /// with the caller's `generationConfig` (response schema, thinking level), guard
    /// status/candidate-text, then decode the JSON substring into `Output`. The two
    /// planners differ only in their schema and decoded shape, which are passed in.
    static func generateAction<Output: Decodable>(
        auth: VertexAuth,
        model: String,
        prompt: String,
        compressed: CompressedScreenshot,
        generationConfig: [String: Any],
        urlSession: URLSession,
        decode: Output.Type
    ) async throws -> Output {
        guard let url = GeminiGenerateContent.vertexURL(
            project: auth.project,
            location: auth.location,
            model: model
        ) else { throw PlannerError.requestFailed(status: -1, body: "bad url") }

        let body = try GeminiGenerateContent.requestBody(
            parts: [
                ["text": prompt],
                GeminiGenerateContent.inlineDataPart(
                    mimeType: compressed.contentType,
                    base64: compressed.data.base64EncodedString()
                )
            ],
            generationConfig: generationConfig
        )
        let request = GeminiGenerateContent.vertexRequest(url: url, bearerToken: auth.token, body: body)

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw PlannerError.requestFailed(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let text = GeminiGenerateContent.candidateText(data), !text.isEmpty else {
            throw PlannerError.noOutputText(body: String(data: data, encoding: .utf8) ?? "")
        }
        let json = DebugUIInspectionResponseDecoder.jsonObjectSubstring(text)
        return try JSONDecoder().decode(Output.self, from: Data(json.utf8))
    }

}
