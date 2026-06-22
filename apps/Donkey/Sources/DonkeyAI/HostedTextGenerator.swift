import DonkeyContracts
import DonkeyHarness
import Foundation
import UniformTypeIdentifiers

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

    /// Streams the model's reply to `prompt`, delivering each text delta to `onDelta` as it arrives
    /// and returning the full text. Used to stream the assistant's final answer into the notch chin and
    /// the open task row token-by-token. Returns nil on any failure (empty stream, transport, timeout),
    /// so the caller falls back to the already-drafted answer rather than showing nothing.
    public func generateStreaming(
        _ prompt: String,
        onDelta: @escaping @MainActor @Sendable (String) -> Void
    ) async -> String? {
        let request = RemoteInferenceChatCompletionRequest(
            messages: [
                RemoteInferenceChatMessage(role: "user", content: .string(prompt))
            ],
            stream: true,
            metadata: ["source": "hosted-text-generator", "prompt_version": "answer-stream-v1"],
            parameters: [
                "temperature": .number(0.4),
                "max_output_tokens": .number(Double(maxOutputTokens))
            ]
        )
        let backend = self.backend
        guard let text = try? await AIDeadline.enforce(seconds: timeoutSeconds, {
            try await backend.streamChat(request, onDelta: onDelta)
        }) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Runs `prompt` against a local media file (audio or video) — the multimodal arm of
    /// `llm.generate`. The file is read and sent inline (base64) alongside the prompt, so the prompt
    /// decides the output (transcribe to SRT, translate, summarize, answer a question). `mimeType` is
    /// inferred from the extension when nil and must resolve to audio/* or video/*. The provider
    /// chooses a model that handles audio/video — no model id leaks past this adapter.
    ///
    /// Inline base64 bounds the file size, so the call rejects oversized files (chunk them) and reads
    /// off the cooperative executor so a large file never stalls the caller. A transcript cut off at
    /// the model's token ceiling is surfaced as `.truncated`, not as a complete result.
    public func generate(
        _ prompt: String,
        attachmentPath: URL,
        mimeType: String? = nil
    ) async -> HarnessMediaGenerationOutcome {
        guard let resolvedMIME = (mimeType?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? Self.inferredMIMEType(for: attachmentPath))?.lowercased() else {
            return .unsupportedType("unknown")
        }
        let partType: String
        if resolvedMIME.hasPrefix("video/") {
            partType = "input_video"
        } else if resolvedMIME.hasPrefix("audio/") {
            partType = "input_audio"
        } else {
            return .unsupportedType(resolvedMIME)
        }
        // Reject an oversized file up front (with a chunk-it signal) rather than reading the whole
        // thing just to overrun the request-body limit at the network. The body base64-encodes the
        // bytes (~+33%), so compare the PROJECTED base64 size — `size * 4 / 3`, rounded up — against
        // the wire limit, not the raw byte count. Report the raw size and the raw-equivalent limit
        // (the largest raw file that fits under the base64 cap) so the numbers stay sensible.
        if let size = Self.fileByteSize(attachmentPath) {
            let base64Size = (size + 2) / 3 * 4
            if base64Size > Self.maxInlineMediaBytes {
                let rawEquivalentLimit = Self.maxInlineMediaBytes / 4 * 3
                return .tooLarge(bytes: size, limit: rawEquivalentLimit)
            }
        }
        // Read + base64-encode off the cooperative executor (the media arm is wired onto the always-on
        // Live session path), and memory-map so the raw bytes aren't held resident alongside the
        // base64 string.
        let fileURL = attachmentPath
        let base64: String
        do {
            base64 = try await Task.detached(priority: .utility) {
                try Data(contentsOf: fileURL, options: .mappedIfSafe).base64EncodedString()
            }.value
        } catch {
            return .unreadableFile
        }
        // Transcription output (an SRT/VTT transcript) runs much longer than a one-line text massage,
        // and audio/video decoding takes longer than a text turn, so widen both ceilings here.
        let mediaMaxOutputTokens = max(maxOutputTokens, 8_000)
        let mediaTimeoutSeconds = max(timeoutSeconds, 180)
        let request = RemoteInferenceResponseCreateRequest(
            input: .array([
                .object([
                    "role": .string("user"),
                    "content": .array([
                        .object(["type": .string("input_text"), "text": .string(prompt)]),
                        .object([
                            "type": .string(partType),
                            "dataBase64": .string(base64),
                            "mimeType": .string(resolvedMIME)
                        ])
                    ])
                ])
            ]),
            store: false,
            metadata: ["source": "hosted-text-generator", "prompt_version": "llm-generate-media-v1"],
            parameters: [
                // Low temperature keeps a transcript faithful to the audio rather than creative.
                "temperature": .number(0.2),
                "max_output_tokens": .number(Double(mediaMaxOutputTokens)),
                "thinking_level": .string("low")
            ]
        )
        let backend = self.backend
        let response: RemoteInferenceJSONValue
        do {
            // A timeout or a thrown error is a retryable failure, NOT an empty model output. Catch it
            // so the caller can re-chunk / retry rather than treat it as "model returned no text".
            response = try await AIDeadline.enforce(seconds: mediaTimeoutSeconds, {
                try await backend.createResponse(request)
            })
        } catch {
            return .timedOut(reason: String(describing: error))
        }
        // A transcript cut off at the token ceiling comes back non-empty but incomplete; surface it as
        // truncated so the caller re-chunks instead of writing a silently-partial subtitle file.
        if let finishReason = RemoteInferenceResponseHelpers.providerFinishReason(from: response),
           finishReason.uppercased().contains("MAX_TOKENS") {
            return .truncated
        }
        let text = RemoteInferenceResponseHelpers.outputText(from: response)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return .empty }
        return .text(text)
    }

    /// The wire/body limit: the maximum size of the base64-encoded inline media in the request body.
    /// A raw file passes only when its base64 projection (`bytes * 4 / 3`) stays under this.
    private static let maxInlineMediaBytes = 14 * 1024 * 1024

    private static func inferredMIMEType(for url: URL) -> String? {
        UTType(filenameExtension: url.pathExtension.lowercased())?.preferredMIMEType
    }

    private static func fileByteSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
