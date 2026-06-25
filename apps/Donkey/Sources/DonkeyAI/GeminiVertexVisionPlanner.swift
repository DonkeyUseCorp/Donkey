import CoreGraphics
import DonkeyContracts
import DonkeyRuntime
import Foundation

/// Per-turn vision planner backed by `gemini-3.5-flash`'s built-in `computer_use`
/// tool in the `ENVIRONMENT_DESKTOP` environment, separate from the realtime Live
/// command model. Given the current window screenshot + goal it returns the single
/// next UI action as a typed `VisionComputerAction` parsed from the model's native
/// function call (coordinates in Gemini's 0–1000 normalized space; the executor maps
/// them onto the window). No function call means the model considers the goal done.
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
        public var description: String {
            switch self {
            case .missingProjectOrLocation: return "mint response lacked project/location"
            case let .requestFailed(status, body): return "vertex generateContent \(status): \(body.prefix(200))"
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
    ) async throws -> VisionComputerAction {
        let width = Int(compressed.pixelSize.width.rounded())
        let height = Int(compressed.pixelSize.height.rounded())
        let prompt = VisionComputerUsePrompt.instructions(
            goal: goal, app: appName, width: width, height: height, history: history, appGuidance: appGuidance
        )
        // No responseSchema/responseMimeType: with the built-in computer-use tool the model answers
        // via function calls, not structured JSON. gemini-3.5-flash takes thinking_level (uppercase
        // proto enum on Vertex); the integer thinkingBudget is ignored on 3.x.
        let generationConfig: [String: Any] = [
            "temperature": 0,
            "thinkingConfig": ["thinkingLevel": "MEDIUM"]
        ]
        let tools: [[String: Any]] = [
            ["computerUse": [
                "environment": "ENVIRONMENT_DESKTOP",
                // Exclude the browser-navigation functions the desktop never uses, matching the
                // backend hosted path so the two transports offer the model the same action set.
                "excludedPredefinedFunctions": VisionComputerDesktopTool.excludedPredefinedFunctions
            ]]
        ]

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
            generationConfig: generationConfig,
            tools: tools
        )
        let request = GeminiGenerateContent.vertexRequest(url: url, bearerToken: auth.token, body: body)

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw PlannerError.requestFailed(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }

        let value = (try? JSONDecoder().decode(RemoteInferenceJSONValue.self, from: data)) ?? .null
        return try VisionComputerResponse.firstAction(in: value)
    }
}
