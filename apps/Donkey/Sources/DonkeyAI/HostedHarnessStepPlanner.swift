import DonkeyContracts
import DonkeyHarness
import Foundation

/// The general model boundary that plans the harness loop one step at a time. The harness calls
/// `planNextStep(for:)` after every observation; this makes one inference over the task's current
/// world model (the evidence the last tool produced) plus the catalog of available tools, and returns
/// the next tool call to run — or `run.complete` when the goal is met.
///
/// It is tool-agnostic: it does not know about vision or Accessibility specifically. It is handed the
/// descriptors of whatever tools are registered (AX see/act, vision see/act, keyboard/text, scripts,
/// lifecycle, conversation) and lets the model choose among them. That is the whole point of the
/// harness — the model picks how to SEE (AX vs. vision) and how to ACT (AX, vision, scripts) per step.
@MainActor
public final class HostedHarnessStepPlanner: HarnessNextStepPlanning {
    private let backend: DonkeyBackendInferenceClient
    private let descriptors: [HarnessToolDescriptor]
    private let appName: String
    private let appGuidance: String?
    /// One-shot understanding parsed before the loop: the restated goal, target app, parameters, and a
    /// clarify gate. nil when the upfront understanding call was skipped or failed, in which case the
    /// planner falls back to the raw task goal.
    private let understanding: HarnessRequestUnderstanding?
    /// One-line summary of which command-line tools are installed on this Mac (and versions), so the
    /// planner only reaches for tools that exist. Empty when the probe was skipped or found nothing.
    private let environmentSummary: String?
    private let uptimeMS: @Sendable () -> Double

    /// Uptime (ms) at which the planner first chose an *action* tool (something that changes app
    /// state, i.e. not a read-only observation). The route turns this into the "time to first action"
    /// telemetry; nil until the first action is planned.
    public private(set) var firstActionUptimeMS: Double?
    /// Most recent one-line rationale, surfaced to the user as the run's narration.
    public private(set) var lastNarration: String?

    /// Names of the registered read-only tools (observe/verify/respond/lifecycle), derived from each
    /// descriptor's safety class. A tool counts as an "action" for first-action timing exactly when it
    /// is NOT read-only, so this stays in sync with the tools instead of a hand-maintained name list.
    private let readOnlyToolNames: Set<String>

    public init(
        backend: DonkeyBackendInferenceClient,
        descriptors: [HarnessToolDescriptor],
        appName: String,
        appGuidance: String?,
        understanding: HarnessRequestUnderstanding? = nil,
        environmentSummary: String? = nil,
        uptimeMS: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime * 1_000 }
    ) {
        self.backend = backend
        self.descriptors = descriptors
        self.appName = appName
        self.appGuidance = appGuidance
        self.understanding = understanding
        self.environmentSummary = environmentSummary
        self.uptimeMS = uptimeMS
        self.readOnlyToolNames = Set(descriptors.filter { $0.safetyClass == .readOnly }.map(\.name))
    }

    public func planNextStep(for task: HarnessTaskState) async -> HarnessToolCall? {
        // When the upfront understanding flagged the request as ambiguous, ask before doing anything.
        // Gated on a typed field (not raw text) and only on the first step, so a user answer resumes
        // into the normal planning loop. Reuses the harness's existing user.clarify waiting gate.
        if task.toolHistory.isEmpty,
           let understanding,
           understanding.needsClarification,
           let question = understanding.clarifyingQuestion,
           !question.isEmpty,
           descriptors.contains(where: { $0.name == "user.clarify" }) {
            return HarnessToolCall(name: "user.clarify", input: ["question": question])
        }
        let decision: Decision
        do {
            decision = try await decide(task: task)
        } catch {
            return HarnessToolCall(name: "run.failSafe", input: ["reason": "harnessPlanFailed"])
        }
        lastNarration = decision.reason.flatMap { $0.isEmpty ? nil : $0 } ?? lastNarration
        guard let toolName = decision.tool.flatMap({ $0.isEmpty ? nil : $0 }) else {
            return HarnessToolCall(name: "run.complete", input: ["reason": decision.reason ?? "Goal satisfied."])
        }
        if !readOnlyToolNames.contains(toolName), firstActionUptimeMS == nil {
            firstActionUptimeMS = uptimeMS()
        }
        return HarnessToolCall(name: toolName, input: decision.input ?? [:])
    }

    // MARK: - Model call

    private struct Decision: Sendable {
        var tool: String?
        var input: [String: String]?
        var reason: String?
    }

    private struct DecisionWire: Decodable {
        var tool: String?
        var input: [String: String]?
        var reason: String?

        private enum CodingKeys: String, CodingKey { case tool, input, reason }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tool = try container.decodeIfPresent(String.self, forKey: .tool)
            reason = try container.decodeIfPresent(String.self, forKey: .reason)
            // The response schema is non-strict, so the model can emit a numeric or boolean input value
            // (e.g. {"elementID": 3}). Coerce scalars to strings instead of failing the whole turn.
            input = try container.decodeIfPresent([String: ScalarString].self, forKey: .input)?
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
                    debugDescription: "Tool input value is not a JSON scalar"
                )
            }
        }
    }

    public enum PlanningError: Error, CustomStringConvertible {
        case missingOutputText(String)
        public var description: String {
            switch self {
            case let .missingOutputText(raw): return "missingOutputText raw=\(raw)"
            }
        }
    }

    /// Deadline for one planning inference. Past it the step throws and the
    /// caller fails safe instead of stalling the whole run on a hung provider.
    private static let stepTimeoutSeconds: TimeInterval = 45

    private func decide(task: HarnessTaskState) async throws -> Decision {
        let request = responseRequest(task: task)
        let backend = self.backend
        let response = try await AIDeadline.enforce(seconds: Self.stepTimeoutSeconds) {
            try await backend.createResponse(request)
        }
        guard let text = RemoteInferenceResponseHelpers.outputText(from: response), !text.isEmpty else {
            let raw = (try? JSONEncoder().encode(response)).flatMap { String(data: $0, encoding: .utf8) } ?? "<unencodable>"
            throw PlanningError.missingOutputText(String(raw.prefix(2_000)))
        }
        let json = DebugUIInspectionResponseDecoder.jsonObjectSubstring(text)
        let wire = try JSONDecoder().decode(DecisionWire.self, from: Data(json.utf8))
        return Decision(tool: wire.tool, input: wire.input, reason: wire.reason)
    }

    private func responseRequest(task: HarnessTaskState) -> RemoteInferenceResponseCreateRequest {
        let toolNames = descriptors.map(\.name)
        return RemoteInferenceResponseCreateRequest(
            input: .array([
                .object([
                    "role": .string("user"),
                    "content": .array([
                        .object([
                            "type": .string("input_text"),
                            "text": .string(DonkeyPrompts.harnessStep(
                                task: task,
                                descriptors: descriptors,
                                appName: appName,
                                appGuidance: appGuidance,
                                understanding: understanding,
                                environmentSummary: environmentSummary
                            ))
                        ])
                    ])
                ])
            ]),
            store: false,
            text: [
                "format": .object([
                    "type": .string("json_schema"),
                    "name": .string("harness_step_v1"),
                    "strict": .bool(false),
                    "schema": .object([
                        "type": .string("object"),
                        "additionalProperties": .bool(false),
                        "required": .array([.string("tool"), .string("reason")]),
                        "properties": .object([
                            "tool": .object([
                                "type": .string("string"),
                                "enum": .array(toolNames.map(RemoteInferenceJSONValue.string))
                            ]),
                            "input": .object([
                                "type": .string("object"),
                                "additionalProperties": .object(["type": .string("string")])
                            ]),
                            "reason": .object(["type": .string("string")])
                        ])
                    ])
                ])
            ],
            metadata: ["source": "hosted-harness-step-planner", "prompt_version": "harness-step-v1"],
            parameters: [
                "temperature": .number(0),
                "max_output_tokens": .number(2_000),
                "thinking_budget": .number(0)
            ]
        )
    }

}
