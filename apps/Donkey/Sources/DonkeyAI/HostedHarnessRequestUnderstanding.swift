import DonkeyContracts
import Foundation

/// A focused, one-shot "understand the request" boundary that runs ONCE before the harness loop.
///
/// It does not plan or pick tools. It turns the raw user command into a small typed understanding the
/// loop can act on: a restated goal, the app to operate, the key parameters, observable success
/// criteria, and a clarify gate. The per-step `HostedHarnessStepPlanner` still chooses every tool —
/// this only sharpens what "the goal" means and which app to drive, so the planner stops re-deriving
/// intent from a raw string on every step.
public struct HarnessRequestUnderstanding: Sendable, Equatable {
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
    /// Structured parameters extracted from the request (e.g. title, recipient, query).
    public var parameters: [String: String]
    /// What, observable on screen, would mean the goal is done.
    public var successCriteria: String?
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

    public init(
        turnKind: HarnessTurnKind = .act,
        restatedGoal: String,
        targetAppName: String? = nil,
        parameters: [String: String] = [:],
        successCriteria: String? = nil,
        needsClarification: Bool = false,
        clarifyingQuestion: String? = nil,
        executionPreference: ExecutionPreference = .background,
        relevantSkillIDs: [String] = []
    ) {
        self.turnKind = turnKind
        self.restatedGoal = restatedGoal
        self.targetAppName = targetAppName
        self.parameters = parameters
        self.successCriteria = successCriteria
        self.needsClarification = needsClarification
        self.clarifyingQuestion = clarifyingQuestion
        self.executionPreference = executionPreference
        self.relevantSkillIDs = relevantSkillIDs
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
    public func understand(
        command: String,
        frontmostAppName: String,
        skillCatalog: String? = nil
    ) async -> HarnessRequestUnderstanding? {
        let prompt = DonkeyPrompts.requestUnderstanding(
            command: command,
            frontmostAppName: frontmostAppName,
            skillCatalog: skillCatalog
        )
        let startedAt = RunTraceTimestamp.now()
        do {
            let response = try await backend.createResponse(
                responseRequest(command: command, frontmostAppName: frontmostAppName, skillCatalog: skillCatalog)
            )
            let endedAt = RunTraceTimestamp.now()
            guard let text = RemoteInferenceResponseHelpers.outputText(from: response), !text.isEmpty else {
                recordCall(prompt: prompt, response: "<no output text>",
                           finishReason: RemoteInferenceResponseHelpers.providerFinishReason(from: response),
                           status: .empty, startedAt: startedAt, endedAt: endedAt)
                return nil
            }
            recordCall(prompt: prompt, response: text,
                       finishReason: RemoteInferenceResponseHelpers.providerFinishReason(from: response),
                       status: .ok, startedAt: startedAt, endedAt: endedAt)
            let json = DebugUIInspectionResponseDecoder.jsonObjectSubstring(text)
            let wire = try JSONDecoder().decode(UnderstandingWire.self, from: Data(json.utf8))
            let restated = wire.restatedGoal?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let restated, !restated.isEmpty else { return nil }
            return HarnessRequestUnderstanding(
                turnKind: wire.turnKind.flatMap { HarnessTurnKind(rawValue: $0) } ?? .act,
                restatedGoal: restated,
                targetAppName: wire.targetAppName.flatMap { $0.isEmpty ? nil : $0 },
                parameters: wire.parameters ?? [:],
                successCriteria: wire.successCriteria.flatMap { $0.isEmpty ? nil : $0 },
                needsClarification: wire.needsClarification ?? false,
                clarifyingQuestion: wire.clarifyingQuestion.flatMap { $0.isEmpty ? nil : $0 },
                executionPreference: wire.executionPreference
                    .flatMap { ExecutionPreference(rawValue: $0) } ?? .background,
                relevantSkillIDs: (wire.relevantSkillIDs ?? [])
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        } catch {
            recordCall(prompt: prompt, response: String(String(describing: error).prefix(500)),
                       finishReason: nil, status: .failed, startedAt: startedAt, endedAt: .now())
            return nil
        }
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
        var parameters: [String: String]?
        var successCriteria: String?
        var needsClarification: Bool?
        var clarifyingQuestion: String?
        var executionPreference: String?
        var relevantSkillIDs: [String]?

        private enum CodingKeys: String, CodingKey {
            case turnKind, restatedGoal, targetAppName, parameters, successCriteria, needsClarification, clarifyingQuestion
            case executionPreference, relevantSkillIDs
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            turnKind = try container.decodeIfPresent(String.self, forKey: .turnKind)
            restatedGoal = try container.decodeIfPresent(String.self, forKey: .restatedGoal)
            targetAppName = try container.decodeIfPresent(String.self, forKey: .targetAppName)
            successCriteria = try container.decodeIfPresent(String.self, forKey: .successCriteria)
            clarifyingQuestion = try container.decodeIfPresent(String.self, forKey: .clarifyingQuestion)
            needsClarification = try container.decodeIfPresent(Bool.self, forKey: .needsClarification)
            executionPreference = try container.decodeIfPresent(String.self, forKey: .executionPreference)
            relevantSkillIDs = try container.decodeIfPresent([String].self, forKey: .relevantSkillIDs)
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
        skillCatalog: String?
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
                                skillCatalog: skillCatalog
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
                            "parameters": .object([
                                "type": .string("object"),
                                "additionalProperties": .object(["type": .string("string")])
                            ]),
                            "successCriteria": .object(["type": .string("string")]),
                            "needsClarification": .object(["type": .string("boolean")]),
                            "clarifyingQuestion": .object(["type": .string("string")]),
                            "executionPreference": .object([
                                "type": .string("string"),
                                "enum": .array([.string("foreground"), .string("background")])
                            ]),
                            "relevantSkillIDs": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")])
                            ])
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
