import CoreGraphics
import DonkeyContracts
import DonkeyRuntime
import Foundation

/// Goal-directed, per-turn vision planner over the hosted `createResponse` boundary: given the current
/// window screenshot and a goal, it asks Gemini's built-in `computer_use` tool (macOS desktop
/// environment, via the backend's `donkey_gemini_mac_desktop_interaction` tool) for the single next UI
/// action and returns it as a typed `VisionComputerAction`. The caller executes it, re-screenshots, and
/// asks again — so the plan adapts to whatever the UI becomes after each step.
///
/// The screenshot is compressed (downscaled + JPEG) with `ScreenshotCompression` — the same path the
/// debug UI inspection flow uses — so the model receives a small payload. App-specific operating
/// knowledge (where controls are, how to read state) is supplied via `appGuidance`, sourced from a
/// discoverable app skill — never hardcoded here.
///
/// Driven in production by the Live → vision escalation (via the direct-Vertex
/// `GeminiVertexVisionPlanner`) and by `SpotifyVisionAgentLiveSmokeTests` for live verification of this
/// hosted path.
@MainActor
public enum VisionActionPlanner {
    public static func nextAction(
        goal: String,
        app: String,
        screenshot: CapturedWindowScreenshot,
        window: WindowTargetBounds,
        history: [String] = [],
        appGuidance: String? = nil,
        backend: DonkeyBackendInferenceClient
    ) async throws -> VisionComputerAction {
        let compressed = ScreenshotCompression.compressedForModel(screenshot)
        let response = try await backend.createResponse(
            responseRequest(goal: goal, app: app, compressed: compressed, history: history, appGuidance: appGuidance)
        )
        return try VisionComputerResponse.firstAction(in: response)
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
        let prompt = VisionComputerUsePrompt.instructions(
            goal: goal, app: app, width: width, height: height, history: history, appGuidance: appGuidance
        )
        return RemoteInferenceResponseCreateRequest(
            donkeyProvider: "gemini",
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
            // The built-in computer-use tool answers via function calls, so no `text` JSON format.
            tools: [
                RemoteInferenceComputerUseTool(
                    type: .geminiMacDesktopInteraction,
                    metadata: ["mode": "act", "schema": "computer-use-desktop-v1"]
                ).jsonObject
            ],
            metadata: ["source": "vision-action-planner", "prompt_version": "computer-use-desktop-v1"],
            parameters: [
                "temperature": .number(0),
                // Headroom for medium thinking PLUS the small function call, so thinking can't starve it.
                "max_output_tokens": .number(3_000),
                // Gemini 3.x honors thinking_level, not the integer thinking_budget (which it ignores).
                "thinking_level": .string("medium")
            ]
        )
    }
}
