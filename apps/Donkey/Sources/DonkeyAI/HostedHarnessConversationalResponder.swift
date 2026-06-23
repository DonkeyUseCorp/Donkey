import DonkeyContracts
import Foundation

/// The conversational arm of the two-tier turn split. When the request-understanding boundary types a
/// turn `.converse` (a greeting, a thanks, a question answerable in words), the caller routes here
/// instead of into the action loop.
///
/// The defining property is what this boundary CANNOT do: it is handed no tool registry, no world
/// model, and no executor, so it can only produce text. A greeting that was misread can at worst yield
/// a slightly-off reply — never a shell command, an app action, or a permission prompt. That safety is
/// structural, which is the whole point of separating the responder from the action planner.
@MainActor
public final class HostedHarnessConversationalResponder {
    private let generator: HostedTextGenerator
    /// Optional turn-trace sink. The single responder call is recorded with its clipped prompt, clipped
    /// reply, and span, so a conversational turn is as traceable in the thread as a planned one.
    private let trace: (any HarnessTurnTracing)?

    public init(backend: DonkeyBackendInferenceClient, trace: (any HarnessTurnTracing)? = nil) {
        // A conversational reply is short and wants to feel instant; a tight cap keeps it snappy.
        self.generator = HostedTextGenerator(backend: backend, maxOutputTokens: 800, timeoutSeconds: 30)
        self.trace = trace
    }

    /// Streams a conversational reply for `command`, delivering each delta to `onDelta` as it arrives
    /// and returning the full text. `conversationContext` is the bounded rolling view of the thread so
    /// far (nil on a fresh turn). Returns nil only on a transport/empty failure, so the caller can fall
    /// back to a plain greeting rather than showing nothing.
    public func respond(
        command: String,
        frontmostAppName: String,
        conversationContext: String?,
        onDelta: @escaping @MainActor @Sendable (String) -> Void
    ) async -> String? {
        let prompt = DonkeyPrompts.conversationalResponse(
            command: command,
            frontmostAppName: frontmostAppName,
            conversationContext: conversationContext
        )
        let startedAt = RunTraceTimestamp.now()
        // Prefer the streamed reply so it types into the chin live; if streaming is unavailable or fails
        // (transport, empty), fall back to a single non-streaming generation so a real question still gets
        // a real answer instead of a canned greeting.
        var reply = await generator.generateStreaming(prompt, onDelta: onDelta)
        if reply?.isEmpty != false {
            reply = await generator.generate(prompt)
        }
        trace?.recordModelCall(TraceModelCall(
            kind: .conversationalReply,
            prompt: prompt,
            response: reply ?? "<no output text>",
            finishReason: nil,
            status: (reply?.isEmpty == false) ? .ok : .empty,
            startedAt: startedAt,
            endedAt: .now()
        ))
        return reply
    }
}
