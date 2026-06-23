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
    /// Compact catalog of every installed app skill (id, description, covered apps, validated scripts),
    /// so the planner can route to an authoritative playbook even when no GUI app is the drive target —
    /// e.g. playing music or saving a note by script. nil when no skills are installed.
    private let skillCatalog: String?
    /// Durable operating lessons recalled from past runs whose goal resembled this one, pre-formatted as a
    /// bounded bullet block and rendered into every step's prompt. Computed once at run start (the goal
    /// doesn't change mid-run), so it's a constant here. nil when nothing relevant was learned before.
    private let recalledLessons: String?
    private let uptimeMS: @Sendable () -> Double
    /// Optional turn-trace sink. Every planning call — the first sample, each retry, and the failure
    /// shapes (empty reply, content filter, transport error) — is recorded here with its clipped prompt,
    /// clipped reply, finish reason, attempt index, and span, so the whole decision path is traceable in
    /// the thread. nil means tracing is off and the hot path is untouched.
    private let trace: (any HarnessTurnTracing)?
    /// Live snapshot of every window on screen (all apps/displays), rendered into the prompt each step
    /// so the planner knows what else exists in the world and can target a window that isn't in front.
    private let openWindows: @Sendable () -> [MacWindowTargetCandidate]
    /// Best-effort compressed screenshot data URL attached to every step's request as an image so a
    /// multimodal planner always SEES the screen, not just read AX/vision text. Returns nil only when
    /// capture fails — the step then proceeds text-only, never breaking on a missing image.
    private let captureScreenshot: @Sendable () async -> String?

    /// Uptime (ms) at which the planner first chose an *action* tool (something that changes app
    /// state, i.e. not a read-only observation). The route turns this into the "time to first action"
    /// telemetry; nil until the first action is planned.
    public private(set) var firstActionUptimeMS: Double?
    /// The most recent step's warm, first-person narration line, surfaced live to the user and saved to
    /// the conversation record as the run's account of what it is doing.
    public private(set) var lastNarration: String?
    /// The model's full thought summary for the most recent step, when thinking is enabled. Persisted
    /// to the thread transcript (not fed back into the per-step prompt, so context stays bounded).
    public private(set) var lastThinking: String?
    /// Planning failures hit while choosing the most recent step (unusable replies, retries, the
    /// reason a step fell back to run.failSafe). Cleared at the start of each planNextStep; the route
    /// writes them into the thread transcript so a failed step is diagnosable from the thread alone.
    public private(set) var lastPlanningErrors: [String] = []
    /// True when the most recent step failed safe because the backend reported the balance is spent
    /// (HTTP 402). The user-query layer reads this typed flag to flag the task for a reload CTA in the
    /// notch, instead of inferring the credit state from the narration text.
    public private(set) var lastFailureRequiresCreditReload = false

    /// Names of the registered read-only tools (observe/verify/respond/lifecycle), derived from each
    /// descriptor's safety class. A tool counts as an "action" for first-action timing exactly when it
    /// is NOT read-only, so this stays in sync with the tools instead of a hand-maintained name list.
    private let readOnlyToolNames: Set<String>

    /// Per-tool required input keys (every declared input minus the optional ones). Used to catch a
    /// malformed decision that names a tool but omits all of its required input — emitting that only
    /// yields `invalidInput`, and repeated it fails the run (a real failure mode: an empty `shell_exec`
    /// looping until failSafe). The planner retries with a corrective note, then fails safe instead
    /// of ever executing a call it already knows is invalid.
    private let requiredInputKeys: [String: Set<String>]

    public init(
        backend: DonkeyBackendInferenceClient,
        descriptors: [HarnessToolDescriptor],
        appName: String,
        appGuidance: String?,
        understanding: HarnessRequestUnderstanding? = nil,
        skillCatalog: String? = nil,
        recalledLessons: String? = nil,
        trace: (any HarnessTurnTracing)? = nil,
        openWindows: @escaping @Sendable () -> [MacWindowTargetCandidate] = { [] },
        captureScreenshot: @escaping @Sendable () async -> String? = { nil },
        uptimeMS: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime * 1_000 }
    ) {
        self.backend = backend
        self.descriptors = descriptors
        self.appName = appName
        self.appGuidance = appGuidance
        self.understanding = understanding
        self.skillCatalog = skillCatalog
        self.recalledLessons = recalledLessons
        self.trace = trace
        self.openWindows = openWindows
        self.captureScreenshot = captureScreenshot
        self.uptimeMS = uptimeMS
        self.readOnlyToolNames = Set(descriptors.filter { $0.safetyClass == .readOnly }.map(\.name))
        self.requiredInputKeys = Dictionary(
            descriptors.map { ($0.name, Set($0.inputSchema.keys).subtracting($0.optionalInputKeys)) },
            uniquingKeysWith: { current, _ in current }
        )
    }

    public func planNextStep(for task: HarnessAgentState, rollingContext: String?) async -> HarnessToolCall? {
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
        // One bad model sample must not kill the run. Following the Hermes agent's recovery model, a
        // malformed, empty, or under-specified decision is fed back to the model and re-asked up to
        // `maxPlanAttempts` times — and each retry boosts the output-token budget, so a reply truncated
        // at the cap can complete on the next try. Only after the budget is spent do we fail safe. An
        // empty tool name never reads as completion (a refusal/truncation would otherwise record as
        // success); the runtime's stall guard remains the final backstop for genuine loops.
        var retryNote: String?
        var lastFailure: Error?
        lastPlanningErrors = []
        lastFailureRequiresCreditReload = false
        let lastAttempt = Self.maxPlanAttempts - 1
        for attempt in 0...lastAttempt {
            let decision: Decision
            do {
                decision = try await decide(task: task, rollingContext: rollingContext, retryNote: retryNote, attempt: attempt)
            } catch {
                lastFailure = error
                lastPlanningErrors.append(
                    "planning attempt \(attempt + 1)/\(Self.maxPlanAttempts) failed: \(String(describing: error).prefix(300))"
                )
                // An expired session or an exhausted balance never recovers by retrying — every attempt
                // hits the same 401/402 instantly. Stop now and fail safe with a clear, actionable
                // message rather than burning the whole retry budget.
                if Self.isAuthenticationError(error) || DonkeyCreditExhaustion.isExhausted(error) { break }
                guard attempt < lastAttempt else { break }
                retryNote = Self.retryNote(after: error)
                continue
            }
            lastNarration = decision.narration.flatMap { $0.isEmpty ? nil : $0 } ?? lastNarration
            lastThinking = decision.thinking.flatMap { $0.isEmpty ? nil : $0 }
            guard let toolName = decision.tool.flatMap({ $0.isEmpty ? nil : $0 }) else {
                lastPlanningErrors.append(
                    "planning attempt \(attempt + 1)/\(Self.maxPlanAttempts): reply named no tool"
                )
                guard attempt < lastAttempt else {
                    return HarnessToolCall(name: "run.failSafe", input: ["reason": "plannerReturnedNoTool"])
                }
                retryNote = "Your previous reply named no tool. Pick exactly one tool from AVAILABLE TOOLS; "
                    + "choose run.complete only when the goal is already confirmed by observed evidence."
                continue
            }
            // Catch a malformed decision that names a tool but supplies none of its required input.
            // Re-ask with a corrective note; once the retry budget is spent, fail safe instead of
            // executing a call we already know is invalid — the run-side invalidInput result tells the
            // model nothing the retry notes didn't, and each wasted step costs a full planning
            // inference. The raw reply prefix is recorded so the thread shows whether the model
            // emitted an empty input object or the field was lost in response mapping.
            let providedInput = decision.input ?? [:]
            if let required = requiredInputKeys[toolName], !required.isEmpty,
               Set(providedInput.keys).isDisjoint(with: required) {
                let keys = required.sorted().joined(separator: ", ")
                lastPlanningErrors.append(
                    "planning attempt \(attempt + 1)/\(Self.maxPlanAttempts): chose \(toolName) without its "
                        + "required input (\(keys)) — reply: \(String(decision.raw.prefix(300)))"
                )
                guard attempt < lastAttempt else {
                    lastNarration = "The model chose \(toolName) without any of its required input (\(keys)) "
                        + "on all \(Self.maxPlanAttempts) planning attempts, so I stopped instead of "
                        + "executing an invalid call."
                    return HarnessToolCall(name: "run.failSafe", input: ["reason": "plannerOmittedRequiredInput(\(toolName))"])
                }
                retryNote = "Your previous reply chose \(toolName) but included none of its required input "
                    + "(\(keys)). Re-issue \(toolName) with that input filled in, or choose a different tool."
                continue
            }
            if !readOnlyToolNames.contains(toolName), firstActionUptimeMS == nil {
                firstActionUptimeMS = uptimeMS()
            }
            return HarnessToolCall(name: toolName, input: providedInput)
        }
        return failSafeCall(after: lastFailure)
    }

    /// The corrective note fed back on the next attempt. A content-filter block gets a
    /// strategy-changing note — the filter is deterministic on the content, so re-asking for the same
    /// reply verbatim just re-trips it; the model must obtain the content as data instead of writing
    /// it from memory. Everything else gets the generic format re-ask.
    private static func retryNote(after error: Error) -> String {
        if case let PlanningError.blockedByContentFilter(finishReason, _) = error {
            return "The model provider's content filter blocked your previous reply before any of it "
                + "reached the harness (finish reason: \(finishReason)). That usually means the reply "
                + "wrote memorized material (a tracklist, lyrics, article text) verbatim. Do not write "
                + "such content from memory. Obtain it as data instead — web.search/web.fetch for "
                + "current facts, llm.generate with toFile=true for long content — then use the "
                + "returned file in later steps."
        }
        return "Your previous reply could not be used (\(String(describing: error).prefix(200))). "
            + "Reply with exactly ONE JSON object naming one tool from AVAILABLE TOOLS, with every "
            + "required input field filled. For a tool that needs no input, use an empty object: {}."
    }

    /// Terminal fail-safe once the planning budget is spent. The `reason` carries the exact failure for
    /// the thread — a provider content block with its finish reason, an empty reply, an HTTP/auth error,
    /// a timeout. The user-facing narration stays plain and friendly: a signed-out session, a content
    /// block, and an empty reply each get a specific, actionable line, and any other error gets a calm
    /// "couldn't reach the model" message rather than a raw error dump. The technical detail the user
    /// doesn't need is preserved in the thread's recorded planning errors, not the notch.
    private func failSafeCall(after error: Error?) -> HarnessToolCall {
        if let error, Self.isAuthenticationError(error) {
            lastNarration = "Your session is signed out, so I couldn't reach the model. Sign in again "
                + "and re-run this."
            return HarnessToolCall(name: "run.failSafe", input: ["reason": "sessionSignedOut"])
        }
        if let error, DonkeyCreditExhaustion.isExhausted(error) {
            lastNarration = DonkeyCreditExhaustion.userMessage()
            lastFailureRequiresCreditReload = true
            return HarnessToolCall(name: "run.failSafe", input: ["reason": "insufficientCredits"])
        }
        switch error as? PlanningError {
        case let .blockedByContentFilter(finishReason, _):
            lastNarration = "The model provider's content filter blocked every planning reply "
                + "(finish reason: \(finishReason)) — usually from reproducing protected material like "
                + "a tracklist or lyrics from memory instead of fetching it."
            return HarnessToolCall(name: "run.failSafe", input: ["reason": "plannerContentFiltered(\(finishReason))"])
        case let .missingOutputText(finishReason, _):
            let detail = finishReason.map { " (provider finish reason: \($0))" } ?? ""
            lastNarration = "The model returned an empty reply on all \(Self.maxPlanAttempts) "
                + "planning attempts\(detail), so I stopped."
            return HarnessToolCall(name: "run.failSafe", input: ["reason": "plannerEmptyReply"])
        case nil:
            if error != nil {
                // The user sees a plain, friendly account; the exact error (HTTP status, body, type) is
                // already written to the thread via the planner's recorded planning errors, so support and
                // a later self-correcting pass keep the technical detail without putting it in the notch.
                lastNarration = "I couldn't reach the model to plan this, so I stopped. Please try again in "
                    + "a moment — if it keeps happening, check your connection."
            }
            return HarnessToolCall(name: "run.failSafe", input: ["reason": "harnessPlanFailed"])
        }
    }

    /// Whether a planning failure is an expired/absent session (a backend 401, or the client's own
    /// pre-flight refusal while signed out). These are terminal for the step — retrying re-issues the
    /// same doomed call — so the planner stops instead of spending its retry budget. A 401 reaches us
    /// two ways: the typed `.authenticationRequired` from the normal request path, and a raw
    /// `.httpStatus(401, …)` when the failure surfaces through a streaming error event, which never
    /// runs through the status-to-auth mapping. Both mean the same signed-out state.
    private static func isAuthenticationError(_ error: Error) -> Bool {
        switch error {
        case DonkeyBackendInferenceClientError.authenticationRequired:
            return true
        case DonkeyBackendInferenceClientError.httpStatus(401, _):
            return true
        default:
            return false
        }
    }

    /// Max planning samples per step before failing safe. The first is the normal call; the rest are
    /// feedback-driven retries (malformed JSON, empty tool, missing required input, or a reply truncated
    /// at the token cap). Mirrors the Hermes agent's "retry up to 3 with feedback" recovery.
    private static let maxPlanAttempts = 3

    // MARK: - Model call

    private struct Decision: Sendable {
        var tool: String?
        var input: [String: String]?
        var narration: String?
        /// The model's full thought summary for this step (thinking enabled), persisted to the thread.
        /// Separate from `narration`, which is the warm one-line account of the step shown live and saved
        /// to the conversation record.
        var thinking: String?
        /// The reply's decision JSON as received, kept for failure diagnostics (e.g. proving whether
        /// a missing tool input was omitted by the model or lost in response mapping).
        var raw: String
    }

    private struct DecisionWire: Decodable {
        var tool: String?
        var input: [String: String]?
        var narration: String?

        private enum CodingKeys: String, CodingKey { case tool, input, narration }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tool = try container.decodeIfPresent(String.self, forKey: .tool)
            narration = try container.decodeIfPresent(String.self, forKey: .narration)
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
        /// The reply carried no output text. `finishReason` is the provider's reported finish reason
        /// when one was present (e.g. MAX_TOKENS), kept as its own field so the exact cause survives
        /// even when the clipped raw JSON would cut it off.
        case missingOutputText(finishReason: String?, raw: String)
        /// The provider's content filter withheld the reply (RECITATION, SAFETY, …) — the model wrote
        /// something, the provider blocked it, and no text reached the harness. Distinct from
        /// `missingOutputText` because retrying the same prompt verbatim re-trips the filter: the
        /// retry must change strategy, and the failure must surface as a content block, not a
        /// transport mystery.
        case blockedByContentFilter(finishReason: String, raw: String)
        public var description: String {
            switch self {
            case let .missingOutputText(finishReason, raw):
                let detail = finishReason.map { "finishReason=\($0) " } ?? ""
                return "missingOutputText \(detail)raw=\(raw)"
            case let .blockedByContentFilter(finishReason, raw):
                return "providerContentFilterBlocked finishReason=\(finishReason) raw=\(raw)"
            }
        }
    }

    /// Provider finish reasons that mean a content filter withheld the generated reply. Matching is on
    /// this typed provider enum field, never on user text. The set is provider-specific wire
    /// vocabulary, which is exactly what an adapter is allowed to know.
    private static let contentFilterFinishReasons: Set<String> = [
        "RECITATION", "SAFETY", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "IMAGE_SAFETY"
    ]

    /// Deadline for one planning inference. Past it the step throws and the
    /// caller fails safe instead of stalling the whole run on a hung provider.
    private static let stepTimeoutSeconds: TimeInterval = 45

    /// Thinking level for each planning step. The planner runs on a Gemini 3.x model, which takes a
    /// `thinking_level` (minimal | low | medium | high), NOT the legacy integer `thinking_budget` —
    /// that knob is silently ignored on these models. `medium` is the model's own default and gives the
    /// strongest everyday decision quality on the one call that decides everything (which tool, what
    /// input, act-vs-verify-vs-complete); we set it explicitly so the choice is intentional rather than
    /// an accident of an ignored parameter. The reasoning summary is persisted to the thread; it is
    /// never fed back into the prompt, so context stays bounded.
    private static let plannerThinkingLevel = "medium"

    /// Base output-token budget for a planning reply, and the ceiling a boosted retry may reach. Sized
    /// with headroom for both the thinking and the tool-call JSON. Each retry raises the budget
    /// (`base * (attempt + 1)`, capped) so a reply truncated at the cap can complete — the Hermes
    /// agent's truncation-recovery boost.
    private static let baseMaxOutputTokens = 3_000
    private static let maxOutputTokensCap = 8_000

    private func decide(task: HarnessAgentState, rollingContext: String?, retryNote: String?, attempt: Int) async throws -> Decision {
        let prompt = DonkeyPrompts.harnessStep(
            task: task,
            descriptors: descriptors,
            appName: appName,
            appGuidance: appGuidance,
            understanding: understanding,
            skillCatalog: skillCatalog,
            lessons: recalledLessons,
            rollingContext: rollingContext,
            retryNote: retryNote,
            openWindows: openWindows()
        )
        let imageDataURL = await captureScreenshot()
        let request = responseRequest(prompt: prompt, attempt: attempt, imageDataURL: imageDataURL)
        let backend = self.backend
        let startedAt = RunTraceTimestamp.now()
        let response: RemoteInferenceJSONValue
        do {
            response = try await AIDeadline.enforce(seconds: Self.stepTimeoutSeconds) {
                try await backend.createResponse(request)
            }
        } catch {
            recordPlannerCall(
                prompt: prompt,
                response: String(String(describing: error).prefix(500)),
                finishReason: nil,
                attempt: attempt,
                status: .failed,
                startedAt: startedAt,
                endedAt: .now()
            )
            throw error
        }
        let endedAt = RunTraceTimestamp.now()
        guard let text = RemoteInferenceResponseHelpers.outputText(from: response), !text.isEmpty else {
            let raw = (try? JSONEncoder().encode(response)).flatMap { String(data: $0, encoding: .utf8) } ?? "<unencodable>"
            let finishReason = RemoteInferenceResponseHelpers.providerFinishReason(from: response)
            if let finishReason, Self.contentFilterFinishReasons.contains(finishReason) {
                recordPlannerCall(
                    prompt: prompt, response: String(raw.prefix(500)), finishReason: finishReason,
                    attempt: attempt, status: .filtered, startedAt: startedAt, endedAt: endedAt
                )
                throw PlanningError.blockedByContentFilter(finishReason: finishReason, raw: String(raw.prefix(500)))
            }
            recordPlannerCall(
                prompt: prompt, response: String(raw.prefix(2_000)), finishReason: finishReason,
                attempt: attempt, status: .empty, startedAt: startedAt, endedAt: endedAt
            )
            throw PlanningError.missingOutputText(finishReason: finishReason, raw: String(raw.prefix(2_000)))
        }
        recordPlannerCall(
            prompt: prompt,
            response: text,
            finishReason: RemoteInferenceResponseHelpers.providerFinishReason(from: response),
            attempt: attempt,
            status: .ok,
            startedAt: startedAt,
            endedAt: endedAt
        )
        let json = DebugUIInspectionResponseDecoder.jsonObjectSubstring(text)
        let wire = try JSONDecoder().decode(DecisionWire.self, from: Data(json.utf8))
        return Decision(
            tool: wire.tool,
            input: wire.input,
            narration: wire.narration,
            thinking: RemoteInferenceResponseHelpers.reasoningText(from: response),
            raw: json
        )
    }

    /// Record one planning call into the turn trace. `attempt` is the 0-based loop index; the trace
    /// shows it 1-based so the first sample reads as attempt 1.
    private func recordPlannerCall(
        prompt: String,
        response: String,
        finishReason: String?,
        attempt: Int,
        status: TraceModelCallStatus,
        startedAt: RunTraceTimestamp,
        endedAt: RunTraceTimestamp
    ) {
        trace?.recordModelCall(TraceModelCall(
            kind: .plannerStep,
            prompt: prompt,
            response: response,
            finishReason: finishReason,
            attempt: attempt + 1,
            status: status,
            startedAt: startedAt,
            endedAt: endedAt
        ))
    }

    private func responseRequest(prompt: String, attempt: Int, imageDataURL: String? = nil) -> RemoteInferenceResponseCreateRequest {
        let maxOutputTokens = min(Self.baseMaxOutputTokens * (attempt + 1), Self.maxOutputTokensCap)
        // Text part always; the compressed screenshot is appended as an image part when available so a
        // multimodal model sees the screen. Both server adapters accept `input_image` + `image_url`.
        var content: [RemoteInferenceJSONValue] = [
            .object([
                "type": .string("input_text"),
                "text": .string(prompt)
            ])
        ]
        if let imageDataURL, !imageDataURL.isEmpty {
            content.append(.object([
                "type": .string("input_image"),
                "image_url": .string(imageDataURL)
            ]))
        }
        return RemoteInferenceResponseCreateRequest(
            input: .array([
                .object([
                    "role": .string("user"),
                    "content": .array(content)
                ])
            ]),
            store: false,
            // Plain JSON mode, deliberately WITHOUT a response schema. Constrained decoding broke
            // the decision's `input` object two ways live: with `input` described only by
            // `additionalProperties` the decoder omitted the whole object once context grew, and
            // with the union of tool input keys enumerated it emitted junk keys from unrelated
            // tools while dropping the intended ones — both while the thinking clearly named the
            // right call. The prompt states the exact reply shape, the parse is lenient, and the
            // retry/failSafe machinery catches the rare malformed reply, which a schema cannot
            // guarantee anyway.
            text: [
                "format": .object([
                    "type": .string("json_object")
                ])
            ],
            metadata: ["source": "hosted-harness-step-planner", "prompt_version": "harness-step-v1"],
            parameters: [
                "temperature": .number(0),
                "max_output_tokens": .number(Double(maxOutputTokens)),
                "thinking_level": .string(Self.plannerThinkingLevel)
            ]
        )
    }

}
