import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation
import Testing

@Suite
struct AgentVisualizationPlanResolverTests {
    @Test
    func localLLMResolverBuildsPlanFromStructuredModelOutput() async throws {
        let sidecar = RecordingAgentVisualizationSidecarRunner(
            result: LocalJSONSidecarResult(
                status: .completed,
                outputData: sidecarResponseData(outputText: """
                {
                  "shouldVisualize": true,
                  "title": "Show Export Controls",
                  "goal": "export the design",
                  "targetApp": "Design App",
                  "confidence": 0.91,
                  "reason": "The user asked for visual instruction inside an app.",
                  "steps": [
                    {"label": "Open the export menu", "x": 0.82, "y": 0.18, "travelDuration": 0.4, "holdDuration": 0.8},
                    {"label": "Choose the file type", "x": 0.72, "y": 0.36}
                  ],
                  "metadata": {"modelDecision": "coach"}
                }
                """)
            )
        )
        let resolver = ProcessBackedLocalLLMAgentVisualizationPlanResolver(
            router: AIModelRouter(registry: registry()),
            sidecarRunner: sidecar
        )

        let result = await resolver.resolveVisualizationPlan(
            AgentVisualizationPlanResolverRequest(
                command: "please demonstrate the export flow",
                runtimeCapabilities: ["app_open: open local item"],
                cacheSnippets: ["local_resolution_cache: name=\"Design App\" kind=application"],
                sourceTraceID: "trace-visualization"
            )
        )

        let cursorRequest = try #require(result.cursorRequest)
        let visualizationPlan = try #require(result.visualizationPlan)
        #expect(result.confidence == 0.91)
        #expect(result.trace.validationStatus == "visualizationDecoded")
        #expect(visualizationPlan.executionMode == .visualOnly)
        #expect(visualizationPlan.usesRealPointer == false)
        #expect(visualizationPlan.metadata["source"] == "local-llm-agent-visualization")
        #expect(visualizationPlan.steps.map(\.label) == ["Open the export menu", "Choose the file type"])
        #expect(cursorRequest.title == "Show Export Controls")
        #expect(cursorRequest.metadata["source"] == "local-llm-agent-visualization")
        #expect(cursorRequest.metadata["modelDecision"] == "coach")
        #expect(cursorRequest.steps.map(\.label) == ["Open the export menu", "Choose the file type"])
        #expect(cursorRequest.steps.first?.target.x == 0.82)

        let requests = await sidecar.requests()
        let request = try #require(requests.first)
        #expect(request.environmentVariableName == "DONKEY_LOCAL_LLM_RUNNER")
        #expect(request.metadata["sidecar.role"] == "agentVisualizationPlan")
        let input = try JSONDecoder().decode(AgentVisualizationSidecarInputProbe.self, from: request.inputData)
        #expect(input.command == "please demonstrate the export flow")
        #expect(input.runtimeCapabilities == ["app_open: open local item"])
        #expect(input.cacheSnippets == ["local_resolution_cache: name=\"Design App\" kind=application"])
        #expect(input.metadata["schemaID"] == ProcessBackedLocalLLMAgentVisualizationPlanResolver.schemaID)
    }

    @Test
    func localLLMResolverDoesNotCreatePlanWhenModelSaysNo() async throws {
        let sidecar = RecordingAgentVisualizationSidecarRunner(
            result: LocalJSONSidecarResult(
                status: .completed,
                outputData: sidecarResponseData(outputText: """
                {
                  "shouldVisualize": false,
                  "title": null,
                  "goal": null,
                  "targetApp": null,
                  "confidence": 0.88,
                  "reason": "This is an actionable app command, not a visual-only visualization request.",
                  "steps": []
                }
                """)
            )
        )
        let resolver = ProcessBackedLocalLLMAgentVisualizationPlanResolver(
            router: AIModelRouter(registry: registry()),
            sidecarRunner: sidecar
        )

        let result = await resolver.resolveVisualizationPlan(
            AgentVisualizationPlanResolverRequest(
                command: "show me the weather for SF",
                sourceTraceID: "trace-no-visualization"
            )
        )

        #expect(result.cursorRequest == nil)
        #expect(result.visualizationPlan == nil)
        #expect(result.confidence == 0.88)
        #expect(result.trace.validationStatus == "notVisualization")
    }

    private func registry() -> AIModelRegistry {
        AIModelRegistry(
            entries: [
                AIModelRegistryEntry(
                    id: "local-visualization-test",
                    role: .taskIntent,
                    provider: .localRuntime,
                    modelID: "local-visualization-model",
                    endpoint: URL(string: "local://visualization")!,
                    capabilities: [.textInput, .structuredOutputs],
                    timeoutMS: 1_000,
                    promptVersion: "agent-visualization-test",
                    evalStatus: .candidate,
                    docsURL: URL(string: "https://example.test/model")!
                )
            ]
        )
    }

    private func sidecarResponseData(outputText: String) -> Data {
        (try? JSONEncoder().encode(AgentVisualizationSidecarResponseProbe(
            outputText: outputText,
            metadata: ["sidecar": "test"]
        ))) ?? Data()
    }
}

private actor RecordingAgentVisualizationSidecarRunner: LocalJSONSidecarRunning {
    private let result: LocalJSONSidecarResult
    private var recordedRequests: [LocalJSONSidecarRequest] = []

    init(result: LocalJSONSidecarResult) {
        self.result = result
    }

    func run(_ request: LocalJSONSidecarRequest) async -> LocalJSONSidecarResult {
        recordedRequests.append(request)
        return result
    }

    func requests() -> [LocalJSONSidecarRequest] {
        recordedRequests
    }
}

private struct AgentVisualizationSidecarInputProbe: Decodable {
    var command: String
    var runtimeCapabilities: [String]
    var cacheSnippets: [String]
    var metadata: [String: String]
}

private struct AgentVisualizationSidecarResponseProbe: Encodable {
    var outputText: String
    var metadata: [String: String]
}
