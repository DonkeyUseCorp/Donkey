import DonkeyAI
import DonkeyContracts
import DonkeyHarness
import Foundation
import Testing

@Suite
@MainActor
struct HostedHarnessStepPlannerTests {
    @Test
    func clarifyGateFiresOnFirstStepWhenUnderstandingNeedsClarification() async {
        // The HTTP client returns 500 so any model round-trip would fail the decode and yield
        // run.failSafe — proving the clarify result came from the deterministic gate, not the model.
        let planner = makePlanner(
            httpClient: FixtureHTTPClient(data: Data(), statusCode: 500),
            understanding: HarnessRequestUnderstanding(
                restatedGoal: "Delete the selected file",
                needsClarification: true,
                clarifyingQuestion: "Which file should I delete?"
            )
        )

        let call = await planner.planNextStep(for: task(goal: "delete it", toolHistory: []))

        #expect(call?.name == "user.clarify")
        #expect(call?.input["question"] == "Which file should I delete?")
    }

    @Test
    func clarifyGateDoesNotFireAfterTheFirstStep() async {
        // With history present the gate must not short-circuit; the model picks the next tool instead.
        let planner = makePlanner(
            httpClient: FixtureHTTPClient(data: cannedDecision(tool: "ax.observe"), statusCode: 200),
            understanding: HarnessRequestUnderstanding(
                restatedGoal: "Delete the selected file",
                needsClarification: true,
                clarifyingQuestion: "Which file should I delete?"
            )
        )

        let priorStep = HarnessToolCallRecord(
            call: HarnessToolCall(name: "ax.observe", input: [:]),
            resultStatus: .succeeded,
            summary: "Observed the window."
        )
        let call = await planner.planNextStep(for: task(goal: "delete it", toolHistory: [priorStep]))

        #expect(call?.name == "ax.observe")
    }

    @Test
    func promptUsesRestatedGoalAndRendersUnderstandingBlock() async {
        let httpClient = FixtureHTTPClient(data: cannedDecision(tool: "ax.observe"), statusCode: 200)
        let planner = makePlanner(
            httpClient: httpClient,
            understanding: HarnessRequestUnderstanding(
                restatedGoal: "Create a note titled Groceries",
                targetAppName: "Notes",
                parameters: ["title": "Groceries"],
                successCriteria: "a note titled Groceries exists"
            )
        )

        let call = await planner.planNextStep(for: task(goal: "raw untouched command", toolHistory: []))
        #expect(call?.name == "ax.observe")

        let body = requestBodyString(httpClient)
        #expect(body.contains("Create a note titled Groceries"))
        #expect(body.contains("WHAT THE USER WANTS"))
        #expect(body.contains("Target app: Notes"))
        #expect(body.contains("title=Groceries"))
        #expect(body.contains("a note titled Groceries exists"))
        // The restated goal replaces the raw command as the GOAL line.
        #expect(!body.contains("raw untouched command"))
    }

    @Test
    func promptFallsBackToRawGoalWhenNoUnderstanding() async {
        let httpClient = FixtureHTTPClient(data: cannedDecision(tool: "ax.observe"), statusCode: 200)
        let planner = makePlanner(httpClient: httpClient, understanding: nil)

        _ = await planner.planNextStep(for: task(goal: "open settings", toolHistory: []))

        let body = requestBodyString(httpClient)
        #expect(body.contains("open settings"))
        #expect(!body.contains("WHAT THE USER WANTS"))
    }

    @Test
    func retriesOnceOnMalformedReplyThenUsesTheSecondDecision() async {
        let httpClient = SequencedHTTPClient(responses: [
            (Data(#"{"output_text":"not json at all"}"#.utf8), 200),
            (cannedDecision(tool: "ax.observe"), 200)
        ])
        let planner = makePlanner(httpClient: httpClient, understanding: nil)

        let call = await planner.planNextStep(for: task(goal: "open settings", toolHistory: []))

        #expect(call?.name == "ax.observe")
        #expect(httpClient.requests.count == 2)
        // The retry prompt names the failure so the model can correct itself.
        let retryBody = requestBodyString(httpClient, index: 1)
        #expect(retryBody.contains("could not be used"))
    }

    @Test
    func failsSafeAfterThreeFailedInferences() async {
        // Following Hermes' "retry up to 3 with feedback", the planner re-asks twice before failing
        // safe — three model round-trips total — and each retry boosts the output-token budget so a
        // reply truncated at the cap can complete on a later attempt.
        let httpClient = SequencedHTTPClient(responses: [
            (Data(), 500),
            (Data(), 500),
            (Data(), 500)
        ])
        let planner = makePlanner(httpClient: httpClient, understanding: nil)

        let call = await planner.planNextStep(for: task(goal: "open settings", toolHistory: []))

        #expect(call?.name == "run.failSafe")
        #expect(httpClient.requests.count == 3)
        // The retried requests raise max_output_tokens (2000 → 4000 → 6000) to recover truncation.
        #expect(maxOutputTokens(httpClient, index: 1) > maxOutputTokens(httpClient, index: 0))
        #expect(maxOutputTokens(httpClient, index: 2) > maxOutputTokens(httpClient, index: 1))
    }

    @Test
    func contentFilterBlockRetriesWithStrategyNoteThenFailsSafeNamingTheFilter() async {
        // The model writes protected material (e.g. a tracklist) from memory and the provider's
        // recitation filter withholds every reply: empty output_text with finishReason=RECITATION in
        // the echoed provider payload. The retry must redirect strategy (obtain the content as data)
        // rather than re-ask verbatim — the filter is deterministic on content — and the terminal
        // failSafe must name the filter so the failure is exact, not a guess.
        let blocked = Data(
            #"{"output_text":"","output":[],"provider_output":{"candidates":[{"content":{"role":"model"},"finishReason":"RECITATION"}]}}"#.utf8
        )
        let httpClient = SequencedHTTPClient(responses: [(blocked, 200), (blocked, 200), (blocked, 200)])
        let planner = makePlanner(httpClient: httpClient, understanding: nil)

        let call = await planner.planNextStep(for: task(goal: "note the album tracklist", toolHistory: []))

        #expect(call?.name == "run.failSafe")
        #expect(call?.input["reason"] == "plannerContentFiltered(RECITATION)")
        #expect(planner.lastNarration?.contains("RECITATION") == true)
        // Every thread-bound planning error names the exact finish reason.
        #expect(!planner.lastPlanningErrors.isEmpty)
        #expect(planner.lastPlanningErrors.allSatisfy { $0.contains("finishReason=RECITATION") })
        // The retry note changes strategy instead of re-asking for the same blocked reply.
        let retryBody = requestBodyString(httpClient, index: 1)
        #expect(retryBody.contains("content filter"))
        #expect(retryBody.contains("Do not write such content from memory"))
    }

    @Test
    func emptyReplyFailsSafeWithExactReason() async {
        // No content filter in play — the provider just returned nothing. The failSafe reason and
        // narration say exactly that instead of a generic plan failure.
        let empty = Data(#"{"output_text":""}"#.utf8)
        let httpClient = SequencedHTTPClient(responses: [(empty, 200), (empty, 200), (empty, 200)])
        let planner = makePlanner(httpClient: httpClient, understanding: nil)

        let call = await planner.planNextStep(for: task(goal: "open settings", toolHistory: []))

        #expect(call?.name == "run.failSafe")
        #expect(call?.input["reason"] == "plannerEmptyReply")
        #expect(planner.lastNarration?.contains("empty reply") == true)
    }

    @Test
    func unauthorizedFailsSafeOnceWithASignInPrompt() async {
        // A 401 is an expired session — retrying just 401s again. The planner must stop on the first
        // attempt (not burn the whole retry budget) and surface a clear "sign in again" message rather
        // than a generic plan failure the user has to guess at.
        let unauthorized = (Data("unauthorized".utf8), 401)
        let httpClient = SequencedHTTPClient(responses: [unauthorized, unauthorized, unauthorized])
        let planner = makePlanner(httpClient: httpClient, understanding: nil)

        let call = await planner.planNextStep(for: task(goal: "open settings", toolHistory: []))

        #expect(call?.name == "run.failSafe")
        #expect(call?.input["reason"] == "sessionSignedOut")
        #expect(planner.lastNarration?.lowercased().contains("sign in") == true)
        // Terminal on the first attempt — no wasted retries against a session that can't recover.
        #expect(httpClient.requests.count == 1)
    }

    @Test
    func insufficientCreditsFailsSafeOnceWithABuyCreditsPrompt() async {
        // A 402 is an exhausted balance — retrying just 402s again. The planner must stop on the first
        // attempt and surface a clear "buy credits" message with the billing destination, never a raw
        // `httpStatus(402, …)` dump.
        let outOfCredits = (Data(#"{"error":"insufficient_credits","balance":"0"}"#.utf8), 402)
        let httpClient = SequencedHTTPClient(responses: [outOfCredits, outOfCredits, outOfCredits])
        let planner = makePlanner(httpClient: httpClient, understanding: nil)

        let call = await planner.planNextStep(for: task(goal: "open settings", toolHistory: []))

        #expect(call?.name == "run.failSafe")
        #expect(call?.input["reason"] == "insufficientCredits")
        #expect(planner.lastNarration?.lowercased().contains("credits") == true)
        // Typed flag the notch reads to show the reload CTA (never inferred from the narration text).
        #expect(planner.lastFailureRequiresCreditReload == true)
        // User-facing: no raw status code or error type leaking into the notch.
        #expect(planner.lastNarration?.lowercased().contains("httpstatus") == false)
        // Terminal on the first attempt — no wasted retries against a balance that can't recover mid-run.
        #expect(httpClient.requests.count == 1)
    }

    @Test
    func backendHTTPFailureShowsAFriendlyNarrationAndKeepsTheRawErrorForTheThread() async {
        // A non-auth backend failure must read as a plain, friendly message to the user — never a raw
        // error dump like `httpStatus(500, …)`. The exact backend error (status code and body) is kept
        // in the recorded planning errors instead, which the thread persists for support and diagnostics.
        let serverError = (Data("server error".utf8), 500)
        let httpClient = SequencedHTTPClient(responses: [serverError, serverError, serverError])
        let planner = makePlanner(httpClient: httpClient, understanding: nil)

        let call = await planner.planNextStep(for: task(goal: "open settings", toolHistory: []))

        #expect(call?.name == "run.failSafe")
        #expect(call?.input["reason"] == "harnessPlanFailed")
        // User-facing: friendly, no raw status code or error type leaking into the notch.
        #expect(planner.lastNarration?.contains("couldn't reach the model") == true)
        #expect(planner.lastNarration?.contains("500") == false)
        #expect(planner.lastNarration?.lowercased().contains("httpstatus") == false)
        // Thread-facing: the exact backend status is still recorded for diagnostics.
        #expect(planner.lastPlanningErrors.contains { $0.contains("500") })
    }

    @Test
    func emptyToolNameNeverReadsAsCompletion() async {
        // A refusal or truncated reply decodes with no tool. That must re-ask once and then fail
        // safe — never run.complete, which would record an unverified claim as success.
        let httpClient = SequencedHTTPClient(responses: [
            (Data(#"{"output_text":"{\"tool\":\"\",\"narration\":\"cannot help\"}"}"#.utf8), 200),
            (Data(#"{"output_text":"{\"tool\":\"\",\"narration\":\"cannot help\"}"}"#.utf8), 200)
        ])
        let planner = makePlanner(httpClient: httpClient, understanding: nil)

        let call = await planner.planNextStep(for: task(goal: "open settings", toolHistory: []))

        #expect(call?.name == "run.failSafe")
        #expect(call?.input["reason"] == "plannerReturnedNoTool")
    }

    @Test
    func emptyToolNameRecoversWhenTheRetryNamesATool() async {
        let httpClient = SequencedHTTPClient(responses: [
            (Data(#"{"output_text":"{\"tool\":\"\",\"narration\":\"unsure\"}"}"#.utf8), 200),
            (cannedDecision(tool: "ax.observe"), 200)
        ])
        let planner = makePlanner(httpClient: httpClient, understanding: nil)

        let call = await planner.planNextStep(for: task(goal: "open settings", toolHistory: []))

        #expect(call?.name == "ax.observe")
        let retryBody = requestBodyString(httpClient, index: 1)
        #expect(retryBody.contains("named no tool"))
    }

    @Test
    func capturesThinkingFromResponseAndRequestsAThinkingLevel() async {
        // Thinking is enabled on the planning call via thinking_level (the param Gemini 3.x honors, not
        // the legacy integer budget), and the model's thought summary (returned separately from
        // output_text so it can't corrupt the decision JSON) is captured for the thread transcript.
        let httpClient = FixtureHTTPClient(
            data: Data(#"{"output_text":"{\"tool\":\"ax.observe\",\"narration\":\"look first\"}","reasoning_text":"The window state is unknown, so I observe before acting."}"#.utf8),
            statusCode: 200
        )
        let planner = makePlanner(httpClient: httpClient, understanding: nil)

        let call = await planner.planNextStep(for: task(goal: "open settings", toolHistory: []))

        #expect(call?.name == "ax.observe")
        #expect(planner.lastThinking == "The window state is unknown, so I observe before acting.")
        let body = requestBodyString(httpClient, index: 0)
        #expect(body.contains("thinking_level"))
        #expect(!body.contains("thinking_budget"))
    }

    @Test
    func stepNarrationKeepsFullLineForConversationSubtext() async {
        let longNarration = "I'll check the Downloads folder to see what files we have for the YouTube clip and subtitle assets before deciding the next command."
        let planner = makePlanner(
            httpClient: FixtureHTTPClient(
                data: Data(#"{"output_text":"{\"tool\":\"ax.observe\",\"narration\":\"\#(longNarration)\"}"}"#.utf8),
                statusCode: 200
            ),
            understanding: nil
        )
        let step = HarnessStepExecutionResult(
            task: task(goal: "create a subtitled clip", toolHistory: []),
            toolResult: HarnessToolResult(
                callID: "call-1",
                toolName: "ax.observe",
                status: .succeeded,
                summary: "fallback"
            )
        )

        _ = await planner.planNextStep(for: task(goal: "create a subtitled clip", toolHistory: []))
        let narration = UserQueryCommandHandler.stepNarration(for: step, planner: planner)

        #expect(narration == longNarration)
    }

    @Test
    func retriesOnceWhenChosenToolMissesAllRequiredInput() async {
        // The exact loop the user hit: the model chose shell_exec with NO command (its required input),
        // which only yields invalidInput and, repeated, fails the run. The planner must retry once with
        // a corrective note, then use the corrected call.
        let httpClient = SequencedHTTPClient(responses: [
            (Data(#"{"output_text":"{\"tool\":\"shell_exec\",\"narration\":\"verify\"}"}"#.utf8), 200),
            (Data(#"{"output_text":"{\"tool\":\"shell_exec\",\"input\":{\"command\":\"date\"},\"narration\":\"verify\"}"}"#.utf8), 200)
        ])
        let planner = HostedHarnessStepPlanner(
            backend: DonkeyBackendInferenceClient(
                configuration: DonkeyBackendInferenceConfiguration(
                    baseURL: URL(string: "https://donkey.example")!,
                    clientID: "client-1"
                ),
                httpClient: httpClient
            ),
            descriptors: [
                HarnessToolDescriptor(
                    name: "shell_exec",
                    pluginID: "core",
                    summary: "Run a single-line command.",
                    inputSchema: ["command": "The command.", "timeoutSeconds": "Budget."],
                    optionalInputKeys: ["timeoutSeconds"],
                    safetyClass: .guardedInput
                )
            ],
            appName: "Notes",
            appGuidance: nil,
            understanding: nil
        )

        let call = await planner.planNextStep(for: task(goal: "confirm what is playing", toolHistory: []))

        #expect(call?.name == "shell_exec")
        #expect(call?.input["command"] == "date")
        #expect(httpClient.requests.count == 2)
        #expect(requestBodyString(httpClient, index: 1).contains("none of its required input"))
    }

    @Test
    func failsSafeInsteadOfExecutingACallMissingAllRequiredInput() async {
        // When every planning attempt names a tool but omits all of its required input, the planner
        // must fail safe rather than execute a call it already knows is invalid — running it only
        // yields invalidInput, which tells the model nothing the retry notes didn't. Each attempt's
        // raw reply is recorded so the thread shows whether the model emitted an empty input object
        // or the field was lost in response mapping.
        let inputlessReply = (Data(#"{"output_text":"{\"tool\":\"shell_exec\",\"narration\":\"verify\"}"}"#.utf8), 200)
        let httpClient = SequencedHTTPClient(responses: [inputlessReply, inputlessReply, inputlessReply])
        let planner = HostedHarnessStepPlanner(
            backend: DonkeyBackendInferenceClient(
                configuration: DonkeyBackendInferenceConfiguration(
                    baseURL: URL(string: "https://donkey.example")!,
                    clientID: "client-1"
                ),
                httpClient: httpClient
            ),
            descriptors: [
                HarnessToolDescriptor(
                    name: "shell_exec",
                    pluginID: "core",
                    summary: "Run a single-line command.",
                    inputSchema: ["command": "The command.", "timeoutSeconds": "Budget."],
                    optionalInputKeys: ["timeoutSeconds"],
                    safetyClass: .guardedInput
                )
            ],
            appName: "Notes",
            appGuidance: nil,
            understanding: nil
        )

        let call = await planner.planNextStep(for: task(goal: "confirm what is playing", toolHistory: []))

        #expect(call?.name == "run.failSafe")
        #expect(call?.input["reason"] == "plannerOmittedRequiredInput(shell_exec)")
        #expect(httpClient.requests.count == 3)
        #expect(planner.lastPlanningErrors.count == 3)
        #expect(planner.lastPlanningErrors.allSatisfy { $0.contains("required input (command)") && $0.contains("reply:") })
        #expect(planner.lastNarration?.contains("command") == true)
    }

    @Test
    func requestsPlainJSONModeWithoutAResponseSchema() async throws {
        // Constrained decoding broke the decision's `input` object two ways live (omitted entirely
        // with an additionalProperties-only schema; junk keys from unrelated tools with the union
        // enumerated), so the planner asks for plain JSON mode and relies on the prompt's stated
        // shape plus the lenient parse and retry/failSafe machinery.
        let httpClient = FixtureHTTPClient(data: cannedDecision(tool: "ax.observe"), statusCode: 200)
        let planner = makePlanner(httpClient: httpClient, understanding: nil)

        _ = await planner.planNextStep(for: task(goal: "open settings", toolHistory: []))

        let body = try #require(
            try JSONSerialization.jsonObject(with: Data(requestBodyString(httpClient, index: 0).utf8)) as? [String: Any]
        )
        let format = try #require(((body["text"] as? [String: Any])?["format"]) as? [String: Any])
        #expect(format["type"] as? String == "json_object")
        #expect(format["schema"] == nil)
    }

    @Test
    func promptRendersElementGeometryValueAndEligibility() async {
        let httpClient = FixtureHTTPClient(data: cannedDecision(tool: "ax.observe"), statusCode: 200)
        let planner = makePlanner(httpClient: httpClient, understanding: nil)
        var state = task(goal: "open settings", toolHistory: [])
        state.worldModel.elements = [
            HarnessWorldElement(
                id: "btn1",
                label: "Send",
                role: "button",
                isActionEligible: true,
                metadata: [
                    "ax.frame.x": "100", "ax.frame.y": "200",
                    "ax.frame.width": "80", "ax.frame.height": "30",
                    "ax.value": "ready"
                ]
            ),
            HarnessWorldElement(id: "lbl1", label: "Banner", role: "staticText", isActionEligible: false)
        ]

        _ = await planner.planNextStep(for: state)

        let body = requestBodyString(httpClient, index: 0)
        #expect(body.contains("@(100,200 80x30)"))
        #expect(body.contains(#"value=\"ready\""#))
        #expect(body.contains("(not clickable)"))
    }

    @Test
    func promptCondensesEvictedHistoryInsteadOfDroppingIt() async {
        let httpClient = FixtureHTTPClient(data: cannedDecision(tool: "ax.observe"), statusCode: 200)
        let planner = makePlanner(httpClient: httpClient, understanding: nil)
        let history = (1...15).map { index in
            HarnessToolCallRecord(
                call: HarnessToolCall(name: "step\(index)", input: [:]),
                resultStatus: index == 2 ? .failed : .succeeded,
                summary: "Summary of step \(index)."
            )
        }

        _ = await planner.planNextStep(for: task(goal: "open settings", toolHistory: history))

        let body = requestBodyString(httpClient, index: 0)
        // The first three steps fall outside the detailed window but stay visible condensed.
        #expect(body.contains("Earlier steps 1-3 (condensed)"))
        #expect(body.contains("step2 → failed"))
        #expect(!body.contains("Summary of step 1."))
        #expect(body.contains("Summary of step 15."))
    }

    // MARK: - Helpers

    private func makePlanner(
        httpClient: any AIHTTPClient,
        understanding: HarnessRequestUnderstanding?
    ) -> HostedHarnessStepPlanner {
        HostedHarnessStepPlanner(
            backend: DonkeyBackendInferenceClient(
                configuration: DonkeyBackendInferenceConfiguration(
                    baseURL: URL(string: "https://donkey.example")!,
                    clientID: "client-1"
                ),
                httpClient: httpClient
            ),
            descriptors: [
                HarnessToolDescriptor(
                    name: "user.clarify",
                    pluginID: "core",
                    summary: "Ask the user a question.",
                    inputSchema: ["question": "The question to ask."],
                    safetyClass: .readOnly
                ),
                HarnessToolDescriptor(
                    name: "ax.observe",
                    pluginID: "core",
                    summary: "Read the accessibility tree.",
                    safetyClass: .readOnly
                )
            ],
            appName: "Notes",
            appGuidance: nil,
            understanding: understanding
        )
    }

    private func task(goal: String, toolHistory: [HarnessToolCallRecord]) -> HarnessAgentState {
        HarnessAgentState(conversationID: "thread-1", goal: goal, toolHistory: toolHistory)
    }

    private func cannedDecision(tool: String) -> Data {
        Data(#"{"output_text":"{\"tool\":\"\#(tool)\",\"narration\":\"step\"}"}"#.utf8)
    }

    private func requestBodyString(_ httpClient: FixtureHTTPClient, index: Int = 0) -> String {
        requestBodyString(requests: httpClient.requests, index: index)
    }

    private func requestBodyString(_ httpClient: SequencedHTTPClient, index: Int = 0) -> String {
        requestBodyString(requests: httpClient.requests, index: index)
    }

    /// Pulls the numeric `max_output_tokens` out of a captured request body, to assert the per-retry
    /// boost. Returns 0 when absent so a missing key fails the comparison loudly.
    private func maxOutputTokens(_ httpClient: SequencedHTTPClient, index: Int) -> Int {
        let body = requestBodyString(httpClient, index: index)
        guard let range = body.range(of: #""max_output_tokens"\s*:\s*"#, options: .regularExpression) else {
            return 0
        }
        let digits = body[range.upperBound...].prefix { $0.isNumber }
        return Int(digits) ?? 0
    }

    private func requestBodyString(requests: [URLRequest], index: Int) -> String {
        guard requests.indices.contains(index),
              let body = requests[index].httpBody,
              let string = String(data: body, encoding: .utf8) else {
            return ""
        }
        return string
    }
}

private final class FixtureHTTPClient: AIHTTPClient, @unchecked Sendable {
    var data: Data
    var statusCode: Int
    var requests: [URLRequest] = []

    init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (
            data,
            HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: [:])!
        )
    }
}

/// Returns each canned response once, in order, repeating the last one if called again.
private final class SequencedHTTPClient: AIHTTPClient, @unchecked Sendable {
    var responses: [(data: Data, statusCode: Int)]
    var requests: [URLRequest] = []

    init(responses: [(data: Data, statusCode: Int)]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses[min(requests.count - 1, responses.count - 1)]
        return (
            response.data,
            HTTPURLResponse(url: request.url!, statusCode: response.statusCode, httpVersion: nil, headerFields: [:])!
        )
    }
}
