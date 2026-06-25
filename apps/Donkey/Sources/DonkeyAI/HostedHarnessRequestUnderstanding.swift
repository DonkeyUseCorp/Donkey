import DonkeyContracts
import Foundation

/// A focused, one-shot "understand the request" boundary that runs ONCE before the harness loop.
///
/// It does not plan or pick tools. It turns the raw user command into a small typed understanding the
/// loop can act on: a restated goal, the app to operate, the key parameters, observable success
/// criteria, and a clarify gate. The per-step `HostedHarnessStepPlanner` still chooses every tool —
/// this only sharpens what "the goal" means and which app to drive, so the planner stops re-deriving
/// intent from a raw string on every step.
public struct HarnessRequestUnderstanding: Sendable, Equatable, Codable {
    /// What this turn fundamentally is: a conversation, an action on the Mac, or a clarifying question.
    /// Decided here, before any action machinery exists, and the single fact the caller routes on —
    /// only `.act` ever reaches the action planner. A `.converse` turn is answered by a responder that
    /// holds no action tools, so a misclassified greeting can never run a command.
    public var turnKind: HarnessTurnKind
    /// The user's request restated. For `.act`/`.clarify` it is one concrete imperative goal; for
    /// `.converse` it is a short restatement of what the user said, never an invented task.
    public var restatedGoal: String
    /// The macOS app the request needs to operate through its GUI. Left nil/empty for pure
    /// conversation, for whatever app is already frontmost, and for tasks an expert would do with
    /// system tools (finding files, launching/quitting apps, reading or changing settings/state) —
    /// those have no GUI target and the planner drives them with shell_exec.
    public var targetAppName: String?
    /// Whether this turn drives a GUI app or is produced app-less through system/web/generative tools.
    /// Disambiguates an empty `targetAppName` — "operate the front app" vs "no app at all" — so the caller
    /// can run an artifact/system task (generate an image, fetch the web, change a setting) without pinning
    /// it to a window or demanding one be frontmost. Set by the model; defaults to `.guiApp`.
    public var actionSurface: HarnessActionSurface
    /// Structured parameters extracted from the request (e.g. title, recipient, query).
    public var parameters: [String: String]
    /// What, observable on screen, would mean the goal is done.
    public var successCriteria: String?
    /// A short ordered plan for an `.act` turn — the few real steps to the deliverable, named up front so
    /// the planner works toward the point instead of re-deriving the shape each step and circling the easy
    /// parts. Each step is one imperative phrase; the hard/decisive ones (a mapping, a computation) are
    /// flagged in the text. Empty for `.converse`/`.clarify` and for trivial one-step tasks. Advisory, not
    /// harness-tracked: the planner still chooses each tool and the done-gate enforces real progress.
    public var plan: [String]
    /// True only when the request is genuinely ambiguous or missing critical detail and cannot be
    /// safely resolved with reasonable defaults.
    public var needsClarification: Bool
    /// The question to ask when `needsClarification` is true.
    public var clarifyingQuestion: String?
    /// Whether the turn's work should run in the background (the agent acts without stealing the
    /// cursor or raising the app) or in the foreground (the user is meant to watch). Set by this
    /// boundary from the request's intent — never matched from raw text. Defaults to background.
    public var executionPreference: ExecutionPreference
    /// Ids the model picked from the skill catalog whose playbook this task should follow (0, 1, or a
    /// few). The harness preloads each one's full guide into the planner — the capability-skill analogue
    /// of `targetAppName` driving the app skill's preload — so a task in a skill's domain gets that
    /// skill's instructions from step one. Empty when no skill applies. Selected by the model against a
    /// typed catalog, never matched from raw text.
    public var relevantSkillIDs: [String]
    /// For a `.converse` turn, the actual reply to show the user — produced in this same boundary so a
    /// greeting or simple question is answered in one round trip instead of a second responder call. It is
    /// context-free (this boundary sees only the current turn), so the caller uses it directly only on a
    /// fresh turn and still routes a multi-turn follow-up through the context-aware responder. Empty/nil for
    /// `.act` and `.clarify`.
    public var conversationReply: String?

    public init(
        turnKind: HarnessTurnKind = .act,
        restatedGoal: String,
        targetAppName: String? = nil,
        actionSurface: HarnessActionSurface = .guiApp,
        parameters: [String: String] = [:],
        successCriteria: String? = nil,
        plan: [String] = [],
        needsClarification: Bool = false,
        clarifyingQuestion: String? = nil,
        executionPreference: ExecutionPreference = .background,
        relevantSkillIDs: [String] = [],
        conversationReply: String? = nil
    ) {
        self.turnKind = turnKind
        self.restatedGoal = restatedGoal
        self.targetAppName = targetAppName
        self.actionSurface = actionSurface
        self.parameters = parameters
        self.successCriteria = successCriteria
        self.plan = plan
        self.needsClarification = needsClarification
        self.clarifyingQuestion = clarifyingQuestion
        self.executionPreference = executionPreference
        self.relevantSkillIDs = relevantSkillIDs
        self.conversationReply = conversationReply
    }

    /// Serialize to a compact JSON string for persistence (e.g. the root agent's metadata), so a later
    /// continuation of the SAME turn — a permission-gate approval or an unattended auto-resume — can reuse
    /// the original understanding instead of recomputing it. Returns nil only if encoding fails.
    public func encodedJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decode a persisted understanding produced by `encodedJSON()`. Returns nil for a nil/empty/garbled
    /// value, so a missing or stale record falls back to recomputing rather than crashing.
    public static func decode(_ json: String?) -> HarnessRequestUnderstanding? {
        guard let json, !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HarnessRequestUnderstanding.self, from: data)
    }
}

/// Makes the single hosted call that produces a `HarnessRequestUnderstanding`. Mirrors the request /
/// decode shape of `HostedHarnessStepPlanner` (one `createResponse`, a JSON-schema response, scalar
/// coercion on decode) so both boundaries stay consistent.
@MainActor
public final class HostedHarnessRequestUnderstanding {
    private let backend: DonkeyBackendInferenceClient
    /// Optional turn-trace sink. The one understanding call is recorded here with its clipped prompt,
    /// clipped reply, and span, so even the pre-loop "what does this request mean?" decision is traceable
    /// in the thread. nil means tracing is off.
    private let trace: (any HarnessTurnTracing)?

    public init(backend: DonkeyBackendInferenceClient, trace: (any HarnessTurnTracing)? = nil) {
        self.backend = backend
        self.trace = trace
    }

    /// Returns the parsed understanding, or `nil` on any provider/decode failure so the caller can
    /// degrade to driving the raw command directly rather than dead-ending.
    ///
    /// A transient empty/truncated/undecodable reply is re-asked up to `maxAttempts` times — this is the
    /// turn's single routing decision, and a one-off empty reply must not silently downgrade it to the
    /// raw-command fallback (observed: the same prompt returning nil on one run and a clean classification
    /// on the next). A signed-out session or spent balance is terminal — retrying re-issues the same doomed
    /// call — so those stop immediately.
    public func understand(
        command: String,
        frontmostAppName: String,
        skillCatalog: String? = nil,
        attachments: [HarnessAttachmentInfo] = []
    ) async -> HarnessRequestUnderstanding? {
        let prompt = DonkeyPrompts.requestUnderstanding(
            command: command,
            frontmostAppName: frontmostAppName,
            skillCatalog: skillCatalog,
            attachments: attachments
        )
        for _ in 0..<Self.maxAttempts {
            let startedAt = RunTraceTimestamp.now()
            do {
                let response = try await backend.createResponse(
                    responseRequest(
                        command: command,
                        frontmostAppName: frontmostAppName,
                        skillCatalog: skillCatalog,
                        attachments: attachments
                    )
                )
                let endedAt = RunTraceTimestamp.now()
                let finishReason = RemoteInferenceResponseHelpers.providerFinishReason(from: response)
                guard let text = RemoteInferenceResponseHelpers.outputText(from: response), !text.isEmpty else {
                    recordCall(prompt: prompt, response: "<no output text>",
                               finishReason: finishReason, status: .empty, startedAt: startedAt, endedAt: endedAt)
                    continue
                }
                recordCall(prompt: prompt, response: text,
                           finishReason: finishReason, status: .ok, startedAt: startedAt, endedAt: endedAt)
                if let parsed = Self.decodeUnderstanding(from: text) {
                    return parsed
                }
                // Decoded to nothing usable (unparseable JSON / empty goal): re-ask rather than dead-end.
            } catch {
                recordCall(prompt: prompt, response: String(String(describing: error).prefix(500)),
                           finishReason: nil, status: .failed, startedAt: startedAt, endedAt: .now())
                if Self.isTerminalFailure(error) { break }
            }
        }
        return nil
    }

    /// Max understanding samples before giving up and letting the caller degrade to the raw command. The
    /// first is the normal call; the rest cover a transient empty/undecodable reply.
    private static let maxAttempts = 3

    /// Whether a failure can never recover by retrying (expired session, spent balance) — the same doomed
    /// call would just repeat. Matched on the typed client error, never on text.
    private static func isTerminalFailure(_ error: Error) -> Bool {
        switch error {
        case DonkeyBackendInferenceClientError.authenticationRequired:
            return true
        default:
            return DonkeyCreditExhaustion.isExhausted(error)
        }
    }

    /// Streaming counterpart of `understand`: the SAME typed understanding, but produced by a streaming call
    /// so a `.converse` turn's `conversationReply` types into the UI live — and in ONE round trip. Each delta
    /// is fed to a field extractor that forwards only the decoded `conversationReply` characters to
    /// `onReplyDelta`; the rest of the JSON (the typed decision) streams past untouched and is parsed once the
    /// stream completes. For an `.act`/`.clarify` turn nothing is forwarded (the field stays empty), so this
    /// is safe to use for any fresh turn. Returns nil on any failure, exactly like `understand`.
    public func understandStreaming(
        command: String,
        frontmostAppName: String,
        skillCatalog: String? = nil,
        attachments: [HarnessAttachmentInfo] = [],
        onReplyDelta: @escaping @MainActor @Sendable (String) -> Void
    ) async -> HarnessRequestUnderstanding? {
        let prompt = DonkeyPrompts.requestUnderstanding(
            command: command,
            frontmostAppName: frontmostAppName,
            skillCatalog: skillCatalog,
            attachments: attachments
        )
        let startedAt = RunTraceTimestamp.now()
        let streamer = ReplyFieldStreamer()
        let request = RemoteInferenceChatCompletionRequest(
            messages: [RemoteInferenceChatMessage(role: "user", content: .string(prompt))],
            stream: true,
            metadata: ["source": "hosted-harness-request-understanding", "prompt_version": "harness-request-understanding-v1-stream"],
            parameters: [
                "temperature": .number(0),
                "max_output_tokens": .number(2_500),
                "thinking_level": .string("medium"),
                "response_format": .object(["type": .string("json_object")])
            ]
        )
        let backend = self.backend
        do {
            let text = try await backend.streamChat(request) { delta in
                let reply = streamer.ingest(delta)
                if !reply.isEmpty { onReplyDelta(reply) }
            }
            let endedAt = RunTraceTimestamp.now()
            guard !text.isEmpty else {
                recordCall(prompt: prompt, response: "<no output text>", finishReason: nil,
                           status: .empty, startedAt: startedAt, endedAt: endedAt)
                return nil
            }
            recordCall(prompt: prompt, response: text, finishReason: nil,
                       status: .ok, startedAt: startedAt, endedAt: endedAt)
            return Self.decodeUnderstanding(from: text)
        } catch {
            recordCall(prompt: prompt, response: String(String(describing: error).prefix(500)),
                       finishReason: nil, status: .failed, startedAt: startedAt, endedAt: .now())
            return nil
        }
    }

    /// Decode the model's text (tolerant of surrounding prose via `jsonObjectSubstring`) into the typed
    /// understanding. Shared by the structured and streaming paths so both yield the same shape. Returns nil
    /// when the JSON is unparseable or carries no restated goal.
    private static func decodeUnderstanding(from text: String) -> HarnessRequestUnderstanding? {
        let json = DebugUIInspectionResponseDecoder.jsonObjectSubstring(text)
        guard let wire = try? JSONDecoder().decode(UnderstandingWire.self, from: Data(json.utf8)) else {
            return nil
        }
        let restated = wire.restatedGoal?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let restated, !restated.isEmpty else { return nil }
        return HarnessRequestUnderstanding(
            turnKind: wire.turnKind.flatMap { HarnessTurnKind(rawValue: $0) } ?? .act,
            restatedGoal: restated,
            targetAppName: wire.targetAppName.flatMap { $0.isEmpty ? nil : $0 },
            actionSurface: wire.actionSurface.flatMap { HarnessActionSurface(rawValue: $0) } ?? .guiApp,
            parameters: wire.parameters ?? [:],
            successCriteria: wire.successCriteria.flatMap { $0.isEmpty ? nil : $0 },
            plan: (wire.plan ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            needsClarification: wire.needsClarification ?? false,
            clarifyingQuestion: wire.clarifyingQuestion.flatMap { $0.isEmpty ? nil : $0 },
            executionPreference: wire.executionPreference
                .flatMap { ExecutionPreference(rawValue: $0) } ?? .background,
            relevantSkillIDs: (wire.relevantSkillIDs ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            conversationReply: wire.conversationReply
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private func recordCall(
        prompt: String,
        response: String,
        finishReason: String?,
        status: TraceModelCallStatus,
        startedAt: RunTraceTimestamp,
        endedAt: RunTraceTimestamp
    ) {
        trace?.recordModelCall(TraceModelCall(
            kind: .understanding,
            prompt: prompt,
            response: response,
            finishReason: finishReason,
            status: status,
            startedAt: startedAt,
            endedAt: endedAt
        ))
    }

    // MARK: - Wire

    private struct UnderstandingWire: Decodable {
        var turnKind: String?
        var restatedGoal: String?
        var targetAppName: String?
        var actionSurface: String?
        var parameters: [String: String]?
        var successCriteria: String?
        var plan: [String]?
        var needsClarification: Bool?
        var clarifyingQuestion: String?
        var executionPreference: String?
        var relevantSkillIDs: [String]?
        var conversationReply: String?

        private enum CodingKeys: String, CodingKey {
            case turnKind, restatedGoal, targetAppName, actionSurface, parameters, successCriteria, plan, needsClarification, clarifyingQuestion
            case executionPreference, relevantSkillIDs, conversationReply
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            turnKind = try container.decodeIfPresent(String.self, forKey: .turnKind)
            restatedGoal = try container.decodeIfPresent(String.self, forKey: .restatedGoal)
            targetAppName = try container.decodeIfPresent(String.self, forKey: .targetAppName)
            actionSurface = try container.decodeIfPresent(String.self, forKey: .actionSurface)
            successCriteria = try container.decodeIfPresent(String.self, forKey: .successCriteria)
            plan = try container.decodeIfPresent([String].self, forKey: .plan)
            clarifyingQuestion = try container.decodeIfPresent(String.self, forKey: .clarifyingQuestion)
            needsClarification = try container.decodeIfPresent(Bool.self, forKey: .needsClarification)
            executionPreference = try container.decodeIfPresent(String.self, forKey: .executionPreference)
            relevantSkillIDs = try container.decodeIfPresent([String].self, forKey: .relevantSkillIDs)
            conversationReply = try container.decodeIfPresent(String.self, forKey: .conversationReply)
            // The schema is non-strict, so a parameter value may arrive as a number or boolean. Coerce
            // scalars to strings instead of failing the whole decode.
            parameters = try container.decodeIfPresent([String: ScalarString].self, forKey: .parameters)?
                .mapValues(\.value)
        }
    }

    /// A JSON scalar (string, number, boolean, or null) decoded into its string form.
    private struct ScalarString: Decodable {
        let value: String

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                value = string
            } else if let bool = try? container.decode(Bool.self) {
                value = String(bool)
            } else if let int = try? container.decode(Int.self) {
                value = String(int)
            } else if let double = try? container.decode(Double.self) {
                value = String(double)
            } else if container.decodeNil() {
                value = ""
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Parameter value is not a JSON scalar"
                )
            }
        }
    }

    private func responseRequest(
        command: String,
        frontmostAppName: String,
        skillCatalog: String?,
        attachments: [HarnessAttachmentInfo] = []
    ) -> RemoteInferenceResponseCreateRequest {
        RemoteInferenceResponseCreateRequest(
            input: .array([
                .object([
                    "role": .string("user"),
                    "content": .array([
                        .object([
                            "type": .string("input_text"),
                            "text": .string(DonkeyPrompts.requestUnderstanding(
                                command: command,
                                frontmostAppName: frontmostAppName,
                                skillCatalog: skillCatalog,
                                attachments: attachments
                            ))
                        ])
                    ])
                ])
            ]),
            store: false,
            text: [
                "format": .object([
                    "type": .string("json_schema"),
                    "name": .string("harness_request_understanding_v1"),
                    "strict": .bool(false),
                    "schema": .object([
                        "type": .string("object"),
                        "additionalProperties": .bool(false),
                        "required": .array([.string("turnKind"), .string("restatedGoal"), .string("needsClarification"), .string("relevantSkillIDs")]),
                        "properties": .object([
                            "turnKind": .object([
                                "type": .string("string"),
                                "enum": .array([.string("converse"), .string("act"), .string("clarify")])
                            ]),
                            "restatedGoal": .object(["type": .string("string")]),
                            "targetAppName": .object(["type": .string("string")]),
                            "actionSurface": .object([
                                "type": .string("string"),
                                "enum": .array([.string("guiApp"), .string("appless")])
                            ]),
                            "parameters": .object([
                                "type": .string("object"),
                                "additionalProperties": .object(["type": .string("string")])
                            ]),
                            "successCriteria": .object(["type": .string("string")]),
                            "plan": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")])
                            ]),
                            "needsClarification": .object(["type": .string("boolean")]),
                            "clarifyingQuestion": .object(["type": .string("string")]),
                            "executionPreference": .object([
                                "type": .string("string"),
                                "enum": .array([.string("foreground"), .string("background")])
                            ]),
                            "relevantSkillIDs": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")])
                            ]),
                            "conversationReply": .object(["type": .string("string")])
                        ])
                    ])
                ])
            ],
            metadata: ["source": "hosted-harness-request-understanding", "prompt_version": "harness-request-understanding-v1"],
            parameters: [
                "temperature": .number(0),
                // Headroom for medium thinking PLUS the JSON understanding; tight caps starve the output.
                "max_output_tokens": .number(2_500),
                // Gemini 3.x honors thinking_level, not the integer thinking_budget (which it ignores).
                "thinking_level": .string("medium")
            ]
        )
    }

}

/// Accumulates streamed deltas and extracts the `conversationReply` field live. A reference type so the
/// `@MainActor @Sendable` stream callback can mutate it; only ever touched on the main actor, hence
/// `@unchecked Sendable`.
private final class ReplyFieldStreamer: @unchecked Sendable {
    private var buffer = ""
    private var field = StreamingJSONStringField(key: "conversationReply")

    /// Append a delta and return the newly-decoded reply characters (empty until the field appears).
    func ingest(_ delta: String) -> String {
        buffer += delta
        return field.consume(buffer)
    }
}
