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

    // MARK: - Helpers

    private func makePlanner(
        httpClient: FixtureHTTPClient,
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

    private func task(goal: String, toolHistory: [HarnessToolCallRecord]) -> HarnessTaskState {
        HarnessTaskState(threadID: "thread-1", goal: goal, toolHistory: toolHistory)
    }

    private func cannedDecision(tool: String) -> Data {
        Data(#"{"output_text":"{\"tool\":\"\#(tool)\",\"reason\":\"step\"}"}"#.utf8)
    }

    private func requestBodyString(_ httpClient: FixtureHTTPClient) -> String {
        guard let body = httpClient.requests.first?.httpBody,
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
