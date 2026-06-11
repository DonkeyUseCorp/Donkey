import CoreGraphics
import DonkeyContracts
import DonkeyRuntime
import Foundation

/// Box-based sibling of `GeminiVertexVisionPlanner`. Instead of a single click
/// point, it asks the turn-based Vertex vision model to return the target control
/// as a 2D bounding box (`box = [ymin, xmin, ymax, xmax]` in Gemini's 0–1000
/// normalized space). `VertexVisionBoxGeometry` turns that box into an ordered list
/// of click points (center first, then nearby fallbacks), so a slightly-loose box
/// still lands on the control within a single turn.
///
/// Auth (token + project + location) is reused from `GeminiVertexVisionPlanner`
/// (`VertexAuth` / `mintAuth`); only the schema, prompt, and decoded shape differ.
public enum GeminiVertexVisionBoxPlanner {
    /// A single planned action with the target expressed as a bounding box.
    public struct VisionBoxAction: Equatable, Sendable, Codable {
        public var action: String        // "click" | "type" | "key" | "done"
        public var box: [Double]?        // [ymin, xmin, ymax, xmax] normalized 0–1000, click only
        public var text: String?
        public var reason: String?
        /// Resolved real-screen click points (box center first), filled in post-decode.
        public var screenPoints: [CGPoint]?

        private enum CodingKeys: String, CodingKey { case action, box, text, reason }
    }

    public static func nextBoxAction(
        auth: GeminiVertexVisionPlanner.VertexAuth,
        model: String,
        goal: String,
        appName: String,
        history: [String],
        appGuidance: String? = nil,
        compressed: CompressedScreenshot,
        window: WindowTargetBounds,
        urlSession: URLSession = .shared
    ) async throws -> VisionBoxAction {
        let host = auth.location == "global" ? "aiplatform.googleapis.com" : "\(auth.location)-aiplatform.googleapis.com"
        let endpoint = "https://\(host)/v1/projects/\(auth.project)/locations/\(auth.location)/publishers/google/models/\(model):generateContent"
        guard let url = URL(string: endpoint) else {
            throw GeminiVertexVisionPlanner.PlannerError.requestFailed(status: -1, body: "bad url")
        }

        let width = Int(compressed.pixelSize.width.rounded())
        let height = Int(compressed.pixelSize.height.rounded())
        let body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [
                    ["text": prompt(goal: goal, app: appName, width: width, height: height, history: history, appGuidance: appGuidance)],
                    ["inlineData": ["mimeType": compressed.contentType, "data": compressed.data.base64EncodedString()]]
                ]
            ]],
            "generationConfig": [
                "temperature": 0,
                "responseMimeType": "application/json",
                // gemini-3.5-flash takes thinking_level (the integer thinkingBudget is ignored on 3.x).
                // No maxOutputTokens is set, so the large default leaves ample room for medium thinking
                // plus the small box JSON. Vertex takes the proto enum name (uppercase).
                "thinkingConfig": ["thinkingLevel": "MEDIUM"],
                "responseSchema": [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["click", "type", "key", "done"]],
                        "box": ["type": "array", "items": ["type": "number"]],
                        "text": ["type": "string"],
                        "reason": ["type": "string"]
                    ],
                    "required": ["action", "reason"]
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
            throw GeminiVertexVisionPlanner.PlannerError.requestFailed(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let text = outputText(data), !text.isEmpty else {
            throw GeminiVertexVisionPlanner.PlannerError.noOutputText(body: String(data: data, encoding: .utf8) ?? "")
        }
        let json = DebugUIInspectionResponseDecoder.jsonObjectSubstring(text)
        var action = try JSONDecoder().decode(VisionBoxAction.self, from: Data(json.utf8))
        if action.action == "click", let box = action.box {
            let points = VisionBoxGeometry.screenPoints(box, window: window)
            action.screenPoints = points.isEmpty ? nil : points
        }
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

    private static func prompt(goal: String, app: String, width: Int, height: Int, history: [String], appGuidance: String?) -> String {
        let historyBlock = history.isEmpty
            ? "This is the first action; nothing has been done yet."
            : "Actions ALREADY performed, in order (do NOT repeat one that already worked):\n"
                + history.suffix(8).enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let guidanceBlock: String
        if let appGuidance, !appGuidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guidanceBlock = """


            APP-SPECIFIC OPERATING GUIDE for "\(app)" (follow this — it describes where controls are and how to read state; it never gives fixed coordinates, so always read the current screenshot for exact positions):
            \(appGuidance)
            """
        } else {
            guidanceBlock = ""
        }
        return """
        You are operating the macOS app "\(app)" by clicking and typing to accomplish a goal.
        GOAL: \(goal)
        The attached screenshot is the CURRENT state of the app window (\(width) x \(height) pixels), origin top-left.

        \(historyBlock)\(guidanceBlock)

        Decide the SINGLE next action that best progresses toward the goal given ONLY what is visible now.
        - "click": move the pointer and click a control. Set "box" to a TIGHT 2D bounding box around the ONE
          target control (a button, row, field, or icon). A click has no text.
        - "type": type into the ALREADY-focused field. Set "text"; omit "box". Use this after clicking a text field.
        - "key": press one key. Set "text" to the key name (e.g. "return"); omit "box".
        - "done": the goal is fully and verifiably satisfied in the current screenshot. Omit "box".
        BOX FORMAT: "box" is [ymin, xmin, ymax, xmax], each value NORMALIZED to 0–1000 relative to the image
        (x=0 left … 1000 right; y=0 top … 1000 bottom). We click the box CENTER first and then a few points just
        inside it, so the box must bound exactly one control as tightly as possible — too large and we click the
        wrong thing.
        If you clicked and the screenshot looks unchanged, the click MISSED — re-locate the target and return a
        tighter, correctly-placed box; don't repeat the same one.
        Keep "reason" to one short sentence.
        """
    }
}
