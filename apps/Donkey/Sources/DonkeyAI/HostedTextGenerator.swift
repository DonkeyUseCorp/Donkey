import DonkeyContracts
import DonkeyHarness
import Foundation

/// The model boundary behind the generic `llm.generate` harness tool: one prompt in, generated text
/// out. It composes, transforms, summarizes, or massages text through the same hosted inference route
/// the rest of the harness uses, so a planner can reach for the model mid-task (build a tracklist,
/// clean up a note body, rewrite a raw status into a friendly line) without any provider details
/// leaking past this adapter.
public struct HostedTextGenerator: Sendable {
    private let backend: DonkeyBackendInferenceClient
    private let maxOutputTokens: Int
    private let timeoutSeconds: TimeInterval

    public init(
        backend: DonkeyBackendInferenceClient,
        maxOutputTokens: Int = 4_000,
        timeoutSeconds: TimeInterval = 45
    ) {
        self.backend = backend
        self.maxOutputTokens = maxOutputTokens
        self.timeoutSeconds = timeoutSeconds
    }

    /// Returns the model's text for `prompt`, or nil on any failure (the tool turns nil into a typed
    /// failure the harness already handles).
    public func generate(_ prompt: String) async -> String? {
        let request = RemoteInferenceResponseCreateRequest(
            input: .array([
                .object([
                    "role": .string("user"),
                    "content": .array([
                        .object(["type": .string("input_text"), "text": .string(prompt)])
                    ])
                ])
            ]),
            store: false,
            metadata: ["source": "hosted-text-generator", "prompt_version": "llm-generate-v1"],
            parameters: [
                "temperature": .number(0.4),
                "max_output_tokens": .number(Double(maxOutputTokens)),
                // Gemini 3.x honors thinking_level, not the integer thinking_budget (which it ignores).
                "thinking_level": .string("medium")
            ]
        )
        let backend = self.backend
        guard let response = try? await AIDeadline.enforce(seconds: timeoutSeconds, {
            try await backend.createResponse(request)
        }) else {
            return nil
        }
        let text = RemoteInferenceResponseHelpers.outputText(from: response)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }
}
