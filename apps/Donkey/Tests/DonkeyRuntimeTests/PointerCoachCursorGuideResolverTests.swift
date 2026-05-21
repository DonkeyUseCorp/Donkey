import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation
import Testing

@Suite
struct PointerCoachCursorGuideResolverTests {
    @Test
    func localLLMResolverBuildsGuideFromStructuredModelOutput() async throws {
        let sidecar = RecordingPointerCoachSidecarRunner(
            result: LocalJSONSidecarResult(
                status: .completed,
                outputData: sidecarResponseData(outputText: """
                {
                  "shouldShowGuide": true,
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
        let resolver = ProcessBackedLocalLLMPointerCoachCursorGuideResolver(
            router: AIModelRouter(registry: registry()),
            sidecarRunner: sidecar
        )

        let result = await resolver.resolveGuide(
            PointerCoachCursorGuideResolverRequest(
                command: "please demonstrate the export flow",
                runtimeCapabilities: ["app_open: open local item"],
                cacheSnippets: ["local_resolution_cache: name=\"Design App\" kind=application"],
                sourceTraceID: "trace-guide"
            )
        )

        let guide = try #require(result.guideRequest)
        #expect(result.confidence == 0.91)
        #expect(result.trace.validationStatus == "guideDecoded")
        #expect(guide.title == "Show Export Controls")
        #expect(guide.metadata["source"] == "local-llm-pointer-coach")
        #expect(guide.metadata["modelDecision"] == "coach")
        #expect(guide.steps.map(\.label) == ["Open the export menu", "Choose the file type"])
        #expect(guide.steps.first?.target.x == 0.82)

        let requests = await sidecar.requests()
        let request = try #require(requests.first)
        #expect(request.environmentVariableName == "DONKEY_LOCAL_LLM_RUNNER")
        #expect(request.metadata["sidecar.role"] == "pointerCoachCursorGuide")
        let input = try JSONDecoder().decode(PointerCoachSidecarInputProbe.self, from: request.inputData)
        #expect(input.command == "please demonstrate the export flow")
        #expect(input.runtimeCapabilities == ["app_open: open local item"])
        #expect(input.cacheSnippets == ["local_resolution_cache: name=\"Design App\" kind=application"])
        #expect(input.metadata["schemaID"] == ProcessBackedLocalLLMPointerCoachCursorGuideResolver.schemaID)
    }

    @Test
    func localLLMResolverDoesNotCreateGuideWhenModelSaysNo() async throws {
        let sidecar = RecordingPointerCoachSidecarRunner(
            result: LocalJSONSidecarResult(
                status: .completed,
                outputData: sidecarResponseData(outputText: """
                {
                  "shouldShowGuide": false,
                  "title": null,
                  "goal": null,
                  "targetApp": null,
                  "confidence": 0.88,
                  "reason": "This is an actionable app command, not a visual coaching request.",
                  "steps": []
                }
                """)
            )
        )
        let resolver = ProcessBackedLocalLLMPointerCoachCursorGuideResolver(
            router: AIModelRouter(registry: registry()),
            sidecarRunner: sidecar
        )

        let result = await resolver.resolveGuide(
            PointerCoachCursorGuideResolverRequest(
                command: "show me the weather for SF",
                sourceTraceID: "trace-no-guide"
            )
        )

        #expect(result.guideRequest == nil)
        #expect(result.confidence == 0.88)
        #expect(result.trace.validationStatus == "notGuide")
    }

    private func registry() -> AIModelRegistry {
        AIModelRegistry(
            entries: [
                AIModelRegistryEntry(
                    id: "local-guide-test",
                    role: .taskIntent,
                    provider: .localRuntime,
                    modelID: "local-guide-model",
                    endpoint: URL(string: "local://guide")!,
                    capabilities: [.textInput, .structuredOutputs],
                    timeoutMS: 1_000,
                    promptVersion: "pointer-coach-test",
                    evalStatus: .candidate,
                    docsURL: URL(string: "https://example.test/model")!
                )
            ]
        )
    }

    private func sidecarResponseData(outputText: String) -> Data {
        (try? JSONEncoder().encode(PointerCoachSidecarResponseProbe(
            outputText: outputText,
            metadata: ["sidecar": "test"]
        ))) ?? Data()
    }
}

private actor RecordingPointerCoachSidecarRunner: LocalJSONSidecarRunning {
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

private struct PointerCoachSidecarInputProbe: Decodable {
    var command: String
    var runtimeCapabilities: [String]
    var cacheSnippets: [String]
    var metadata: [String: String]
}

private struct PointerCoachSidecarResponseProbe: Encodable {
    var outputText: String
    var metadata: [String: String]
}
