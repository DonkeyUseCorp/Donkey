import CoreGraphics
import DonkeyContracts
import DonkeyRuntime
import Foundation

/// Goal-directed, per-turn vision driver: given the current window screenshot and a goal, ask the
/// hosted vision model for the SINGLE next action (click / type / key / done). The caller executes it,
/// re-screenshots, and asks again — so the plan adapts to whatever the UI becomes after each step
/// (search → results → artist page → play), which is exactly what's needed for apps whose post-click
/// UI you can't know in advance (Spotify, Slack, …).
///
/// The screenshot is compressed (downscaled + JPEG) with `ScreenshotCompression` — the same path the
/// debug UI inspection flow uses — so the model receives a small payload. The model reports click
/// coordinates in Gemini's native 0–1000 normalized space, which `screenPoint` maps to the window.
/// App-specific operating knowledge (where controls are, how to read state) is supplied via
/// `appGuidance`, sourced from a discoverable app skill — never hardcoded here.
public enum VisionActionPlannerError: Error, CustomStringConvertible {
    case missingOutputText(rawResponse: String)

    public var description: String {
        switch self {
        case let .missingOutputText(raw): return "missingOutputText raw=\(raw)"
        }
    }
}

/// Driven in production by `UserQueryCommandHandler.handleVisionAction` for non-scriptable apps, and
/// by `SpotifyVisionAgentLiveSmokeTests` for live verification.
@MainActor
public enum VisionActionPlanner {
    public struct PlannedAction: Equatable, Sendable, Codable {
        public var action: String        // "click" | "type" | "key" | "done"
        public var x: Double?
        public var y: Double?
        public var text: String?
        public var reason: String?
        /// Resolved real-screen point for `click` actions (nil for non-click / unmappable).
        public var screenPoint: CGPoint?

        private enum CodingKeys: String, CodingKey { case action, x, y, text, reason }
    }

    public static func nextAction(
        goal: String,
        app: String,
        screenshot: CapturedWindowScreenshot,
        window: WindowTargetBounds,
        history: [String] = [],
        appGuidance: String? = nil,
        backend: DonkeyBackendInferenceClient
    ) async throws -> PlannedAction {
        let compressed = ScreenshotCompression.compressedForModel(screenshot)
        let response = try await backend.createResponse(
            responseRequest(goal: goal, app: app, compressed: compressed, history: history, appGuidance: appGuidance)
        )
        guard let text = outputText(from: response), !text.isEmpty else {
            let raw = (try? JSONEncoder().encode(response)).flatMap { String(data: $0, encoding: .utf8) } ?? "<unencodable>"
            throw VisionActionPlannerError.missingOutputText(rawResponse: String(raw.prefix(2_000)))
        }
        let json = DebugUIInspectionResponseDecoder.jsonObjectSubstring(text)
        var action = try JSONDecoder().decode(PlannedAction.self, from: Data(json.utf8))
        action.screenPoint = screenPoint(action: action, window: window)
        return action
    }

    /// Gemini reports click coordinates in its native 0–1000 NORMALIZED space (x=0 left … 1000 right,
    /// y=0 top … 1000 bottom of the image), NOT raw pixels — so we map normalized → window bounds.
    /// This is independent of the compressed image size, which is why it stays correct after downscaling.
    nonisolated static let normalizedCoordinateScale = 1_000.0

    nonisolated static func screenPoint(
        action: PlannedAction,
        window: WindowTargetBounds
    ) -> CGPoint? {
        guard let x = action.x, let y = action.y else { return nil }
        let nx = min(max(x / normalizedCoordinateScale, 0), 1)
        let ny = min(max(y / normalizedCoordinateScale, 0), 1)
        return CGPoint(
            x: window.x + nx * window.width,
            y: window.y + ny * window.height
        )
    }

    private static func responseRequest(
        goal: String,
        app: String,
        compressed: CompressedScreenshot,
        history: [String],
        appGuidance: String?
    ) -> RemoteInferenceResponseCreateRequest {
        let width = Int(compressed.pixelSize.width.rounded())
        let height = Int(compressed.pixelSize.height.rounded())
        let historyBlock = history.isEmpty
            ? "This is the first action; nothing has been done yet."
            : "Actions you have ALREADY performed, in order (do NOT repeat one that already worked):\n"
                + history.enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let guidanceBlock: String
        if let appGuidance, !appGuidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guidanceBlock = """

            APP-SPECIFIC OPERATING GUIDE for "\(app)" (follow this — it describes where controls are and how to read state; it never gives fixed coordinates, so always read the current screenshot for exact positions):
            \(appGuidance)
            """
        } else {
            guidanceBlock = ""
        }
        let prompt = """
        You are operating the macOS app "\(app)" by clicking and typing to accomplish a goal.
        GOAL: \(goal)
        The attached screenshot is the CURRENT state of the app window (\(width) x \(height) pixels), origin top-left.

        \(historyBlock)
        \(guidanceBlock)

        Decide the SINGLE next action that best progresses toward the goal given ONLY what is visible now.
        Each action type has a STRICT meaning — never overload one:
        - "click": move the pointer and click. Set x and y to the center of the target. NEVER put text in a click; a click has no text.
        - "type": type characters into the field that is ALREADY focused. Set "text" to the characters and set x and y to 0. Use this AFTER you have clicked a text field — do not click again, just type.
        - "key": press a single key. Set "text" to the key name (e.g. "return" to submit a search) and set x and y to 0.
        - "done": the goal is fully and verifiably satisfied in the current screenshot. Set x and y to 0.
        COORDINATES: report x and y NORMALIZED to a 0–1000 scale relative to the image — x=0 is the left edge and x=1000 the right edge; y=0 is the top edge and y=1000 the bottom edge. (Use 0 for non-click actions.)
        Look at the history and the screenshot: if you just clicked a text field, the next action should be "type", not another click. Do not get stuck repeating the same step.
        If you clicked something and the screenshot looks unchanged, your click MISSED — do not repeat the same coordinate; re-locate the target and aim at its exact visual center.
        CLICK PRECISELY: set x,y to the exact visual CENTER of the intended control, not above/below/beside it.
        Keep "reason" to one short sentence. Return ONLY the JSON object, nothing else.
        """
        return RemoteInferenceResponseCreateRequest(
            input: .array([
                .object([
                    "role": .string("user"),
                    "content": .array([
                        .object(["type": .string("input_text"), "text": .string(prompt)]),
                        .object([
                            "type": .string("input_image"),
                            "image_url": .string(compressed.base64DataURL),
                            "detail": .string("original")
                        ])
                    ])
                ])
            ]),
            store: false,
            text: [
                "format": .object([
                    "type": .string("json_schema"),
                    "name": .string("vision_action_v1"),
                    "strict": .bool(true),
                    "schema": .object([
                        "type": .string("object"),
                        "additionalProperties": .bool(false),
                        "required": .array([.string("action"), .string("x"), .string("y"), .string("reason")]),
                        "properties": .object([
                            "action": .object([
                                "type": .string("string"),
                                "enum": .array([.string("click"), .string("type"), .string("key"), .string("done")])
                            ]),
                            "x": .object(["type": .string("number")]),
                            "y": .object(["type": .string("number")]),
                            "text": .object(["type": .string("string")]),
                            "reason": .object(["type": .string("string")])
                        ])
                    ])
                ])
            ],
            metadata: ["source": "vision-action-planner", "prompt_version": "vision-action-v1"],
            parameters: [
                "temperature": .number(0),
                "max_output_tokens": .number(2_000),
                "thinking_budget": .number(0)  // disable Gemini thinking; thinking tokens otherwise starve the JSON output
            ]
        )
    }

    private static func outputText(from value: RemoteInferenceJSONValue) -> String? {
        guard let object = value.objectValue else { return nil }
        if let text = object["output_text"]?.stringValue { return text }
        return object["output"]?.arrayValue?
            .compactMap { item -> String? in
                guard let content = item.objectValue?["content"]?.arrayValue else {
                    return item.objectValue?["text"]?.stringValue
                }
                return content.compactMap { $0.objectValue?["text"]?.stringValue }.joined()
            }
            .joined(separator: "\n")
    }
}
