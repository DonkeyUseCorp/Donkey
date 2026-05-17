import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation
import Testing

@Suite
struct AIHarnessAdapterTests {
    @Test
    func routerSelectsPlannerModelFromRegistryAndSkipsFailedEntries() throws {
        let registry = AIModelRegistry(
            entries: [
                entry(id: "failed", modelID: "gpt-5-mini", evalStatus: .passing, timeoutMS: 1_000),
                entry(id: "selected", modelID: "gpt-5.2", evalStatus: .passing, timeoutMS: 2_000)
            ]
        )
        let router = AIModelRouter(registry: registry)

        let selected = try router.route(
            AIModelRouteRequest(
                jobType: .plannerHint,
                failedModelEntryIDs: ["failed"]
            )
        )

        #expect(selected.id == "selected")
        #expect(selected.modelID == "gpt-5.2")
    }

    @Test
    func highRiskRouteRequiresPassingModel() throws {
        let router = AIModelRouter(
            registry: AIModelRegistry(
                entries: [
                    entry(id: "candidate", modelID: "gpt-5.2", evalStatus: .candidate)
                ]
            )
        )

        #expect(throws: AIModelRouteError.noMatchingModel) {
            _ = try router.route(
                AIModelRouteRequest(
                    jobType: .plannerHint,
                    risk: .high
                )
            )
        }
    }

    @Test
    func privacySensitivePlannerRoutePrefersLocalProviderWhenAvailable() throws {
        let registry = AIModelRegistry(
            entries: [
                entry(id: "online", provider: .openAI, modelID: "gpt-5.2", evalStatus: .candidate),
                entry(id: "local", provider: .ollama, modelID: "qwen3:8b", evalStatus: .candidate)
            ]
        )
        let router = AIModelRouter(registry: registry)

        let selected = try router.route(
            AIModelRouteRequest(
                jobType: .plannerHint,
                privacyMode: .privacySensitive
            )
        )

        #expect(selected.id == "local")
        #expect(selected.provider == .ollama)
    }

    @Test
    func privacySensitiveTaskIntentRouteSelectsLocalProvider() throws {
        let router = AIModelRouter(registry: .defaultHybridPlanner)

        let selected = try router.route(
            AIModelRouteRequest(
                jobType: .taskIntent,
                privacyMode: .privacySensitive
            )
        )

        #expect(selected.id == "ollama-task-intent-local")
        #expect(selected.role == .taskIntent)
        #expect(selected.provider == .ollama)
    }

    @Test
    func voiceTranscriptionRouteSelectsLocalParakeetModel() throws {
        let router = AIModelRouter(registry: .defaultHybridPlanner)

        let selected = try router.route(
            AIModelRouteRequest(
                jobType: .voiceTranscription,
                privacyMode: .privacySensitive,
                requiredCapabilities: [.audioInput]
            )
        )

        #expect(selected.id == "local-voice-transcription-parakeet-tdt-0.6b-v3")
        #expect(selected.role == .voiceTranscription)
        #expect(selected.provider == .localRuntime)
        #expect(selected.modelID == "nvidia/parakeet-tdt-0.6b-v3")
        #expect(selected.endpoint.absoluteString == "local://nvidia/parakeet-tdt-0.6b-v3")
        #expect(selected.docsURL.absoluteString == "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3")
        #expect(selected.capabilities == [.audioInput])
        #expect(selected.rollbackID == "local-voice-transcription-whisper-large-v3-turbo")
        #expect(selected.metadata["runtime"] == "nvidia-nemo")
        #expect(selected.metadata["local"] == "true")
        #expect(selected.metadata["fallbackModelID"] == "openai/whisper-large-v3-turbo")
    }

    @Test
    func voiceTranscriptionRouteFallsBackToWhisperWhenParakeetFailed() throws {
        let router = AIModelRouter(registry: .defaultHybridPlanner)

        let selected = try router.route(
            AIModelRouteRequest(
                jobType: .voiceTranscription,
                privacyMode: .privacySensitive,
                failedModelEntryIDs: ["local-voice-transcription-parakeet-tdt-0.6b-v3"],
                requiredCapabilities: [.audioInput]
            )
        )

        #expect(selected.id == "local-voice-transcription-whisper-large-v3-turbo")
        #expect(selected.provider == .localRuntime)
        #expect(selected.modelID == "openai/whisper-large-v3-turbo")
    }

    @Test
    func ollamaTaskIntentAdapterBuildsLocalRequestAndDecodesValidatedIntent() async throws {
        let httpClient = FakeAIHTTPClient(
            data: ollamaResponseData(
                response: """
                {"taskType":"weather_lookup","targetAppName":"Weather","entities":{"city":"SF"},"normalizedEntities":{"city":"San Francisco"},"confidence":0.93,"needsConfirmation":false,"metadata":{"source":"test"}}
                """
            ),
            statusCode: 200
        )
        let adapter = OllamaTaskIntentAdapter(
            router: AIModelRouter(
                registry: AIModelRegistry(
                    entries: [
                        entry(
                            id: "local-intent",
                            role: .taskIntent,
                            provider: .ollama,
                            modelID: "qwen3:8b",
                            endpoint: URL(string: "http://127.0.0.1:11434/api/generate")!,
                            promptVersion: "task-intent-v1"
                        )
                    ]
                )
            ),
            httpClient: httpClient
        )

        let result = await adapter.parseTaskIntent(
            TaskIntentAdapterRequest(
                command: "show me the weather for SF",
                taskDefinitions: BuiltInLocalAppTaskDefinitions.defaults,
                sourceTraceID: "trace-intent"
            )
        )

        #expect(result.intent?.taskType == "weather_lookup")
        #expect(result.intent?.targetApp.appName == "Weather")
        #expect(result.intent?.normalizedEntities["city"] == "San Francisco")
        #expect(result.intent?.parserSource == .localModel)
        #expect(result.intent?.sourceModelCallID == "model-call-trace-intent")
        #expect(result.trace.status == .completed)
        #expect(result.trace.role == .taskIntent)
        #expect(result.trace.provider == .ollama)

        let request = try #require(httpClient.requests.first)
        #expect(request.url?.absoluteString == "http://127.0.0.1:11434/api/generate")
        let body = try #require(request.httpBodyJSONObject)
        #expect(body["model"] as? String == "qwen3:8b")
        #expect(body["stream"] as? Bool == false)
        #expect(body["format"] as? [String: Any] != nil)
        #expect((body["prompt"] as? String)?.contains("Use only the provided task definitions") == true)
    }

    @Test
    func localModelTaskIntentResolverValidatesAgainstCatalogAvailability() async {
        let httpClient = FakeAIHTTPClient(
            data: ollamaResponseData(
                response: """
                {"taskType":"weather_lookup","targetAppName":"Weather","entities":{"city":"SF"},"normalizedEntities":{"city":"San Francisco"},"confidence":0.93,"needsConfirmation":false,"metadata":{}}
                """
            ),
            statusCode: 200
        )
        let resolver = LocalModelTaskIntentResolver(
            catalog: LocalAppTaskCatalog(
                taskDefinitions: BuiltInLocalAppTaskDefinitions.defaults,
                availabilityProvider: StaticLocalAppAvailabilityProvider(installedBundleIdentifiers: ["com.apple.weather"])
            ),
            adapter: OllamaTaskIntentAdapter(
                router: AIModelRouter(
                    registry: AIModelRegistry(
                        entries: [
                            entry(
                                id: "local-intent",
                                role: .taskIntent,
                                provider: .ollama,
                                modelID: "qwen3:8b",
                                endpoint: URL(string: "http://127.0.0.1:11434/api/generate")!,
                                promptVersion: "task-intent-v1"
                            )
                        ]
                    )
                ),
                httpClient: httpClient
            )
        )

        let result = await resolver.resolve(
            command: "show me the weather for SF",
            sourceTraceID: "trace-resolve-intent"
        )

        #expect(result.resolution.status == .resolved)
        #expect(result.resolution.intent?.parserSource == .localModel)
        #expect(result.resolution.availability?.isInstalled == true)
        #expect(result.trace.status == .completed)
    }

    @Test
    func openAIAdapterBuildsResponsesRequestWithStoreFalseAndDecodesStructuredHint() async throws {
        let httpClient = FakeAIHTTPClient(
            data: responseData(
                outputText: """
                {"id":"hint-1","goal":"avoid hazards","policyName":"planner-policy","priorities":["center lane"],"preferredActions":["wait"],"avoidActions":["tapTarget"],"confidence":0.82,"expiryMilliseconds":5000}
                """
            ),
            statusCode: 200
        )
        let adapter = OpenAIPlannerHintAdapter(
            router: AIModelRouter(registry: AIModelRegistry(entries: [entry(id: "planner", modelID: "gpt-5.2")])),
            httpClient: httpClient,
            environment: ["OPENAI_API_KEY": "test-key"]
        )

        let result = await adapter.generatePlannerHint(adapterRequest())

        #expect(result.hint?.id == "hint-1")
        #expect(result.hint?.preferredActions == [.wait])
        #expect(result.hint?.avoidActions == [.tapTarget])
        #expect(result.hint?.sourceTraceID == "trace-1")
        #expect(result.trace.status == .completed)
        #expect(result.trace.validationStatus == "schemaDecoded")
        #expect(result.trace.metadata["privacy.store"] == "false")

        let request = try #require(httpClient.requests.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let body = try #require(request.httpBodyJSONObject)
        #expect(body["model"] as? String == "gpt-5.2")
        #expect(body["store"] as? Bool == false)
        let text = try #require(body["text"] as? [String: Any])
        let formatContainer = try #require(text["format"] as? [String: Any])
        #expect(formatContainer["type"] as? String == "json_schema")
    }

    @Test
    func openAIAdapterHandlesMissingCredentialsRateLimitAndInvalidOutput() async {
        let adapter = OpenAIPlannerHintAdapter(
            router: AIModelRouter(registry: AIModelRegistry(entries: [entry(id: "planner", modelID: "gpt-5.2")])),
            httpClient: FakeAIHTTPClient(data: responseData(outputText: "{}"), statusCode: 200),
            environment: [:]
        )

        let missingCredentials = await adapter.generatePlannerHint(adapterRequest())
        #expect(missingCredentials.hint == nil)
        #expect(missingCredentials.trace.status == .missingCredentials)

        let rateLimited = await OpenAIPlannerHintAdapter(
            router: AIModelRouter(registry: AIModelRegistry(entries: [entry(id: "planner", modelID: "gpt-5.2")])),
            httpClient: FakeAIHTTPClient(data: Data(), statusCode: 429),
            environment: ["OPENAI_API_KEY": "test-key"]
        )
        .generatePlannerHint(adapterRequest())
        #expect(rateLimited.trace.status == .rateLimited)

        let invalidOutput = await OpenAIPlannerHintAdapter(
            router: AIModelRouter(registry: AIModelRegistry(entries: [entry(id: "planner", modelID: "gpt-5.2")])),
            httpClient: FakeAIHTTPClient(data: responseData(outputText: "{}"), statusCode: 200),
            environment: ["OPENAI_API_KEY": "test-key"]
        )
        .generatePlannerHint(adapterRequest())
        #expect(invalidOutput.trace.status == .invalidOutput)
    }

    @Test
    func ollamaAdapterBuildsLocalGenerateRequestAndDecodesStructuredHint() async throws {
        let httpClient = FakeAIHTTPClient(
            data: ollamaResponseData(
                response: """
                {"id":"local-hint-1","goal":"recover locally","policyName":"local-planner-policy","priorities":["observe menu"],"preferredActions":["observe"],"avoidActions":["tapTarget"],"confidence":0.74,"expiryMilliseconds":3000}
                """
            ),
            statusCode: 200
        )
        let adapter = OllamaPlannerHintAdapter(
            router: AIModelRouter(
                registry: AIModelRegistry(
                    entries: [
                        entry(
                            id: "local-planner",
                            provider: .ollama,
                            modelID: "qwen3:8b",
                            endpoint: URL(string: "http://127.0.0.1:11434/api/generate")!
                        )
                    ]
                )
            ),
            httpClient: httpClient
        )

        let result = await adapter.generatePlannerHint(adapterRequest())

        #expect(result.hint?.id == "local-hint-1")
        #expect(result.hint?.preferredActions == [.observe])
        #expect(result.trace.status == .completed)
        #expect(result.trace.provider == .ollama)
        #expect(result.trace.metadata["local.provider"] == "ollama")

        let request = try #require(httpClient.requests.first)
        #expect(request.url?.absoluteString == "http://127.0.0.1:11434/api/generate")
        let body = try #require(request.httpBodyJSONObject)
        #expect(body["model"] as? String == "qwen3:8b")
        #expect(body["stream"] as? Bool == false)
        #expect(body["format"] as? [String: Any] != nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func providerBackedSlowPlannerFallsBackFromLocalToOnlineProvider() async {
        let localAdapter = OllamaPlannerHintAdapter(
            router: AIModelRouter(
                registry: AIModelRegistry(
                    entries: [
                        entry(
                            id: "local-planner",
                            provider: .ollama,
                            modelID: "qwen3:8b",
                            endpoint: URL(string: "http://127.0.0.1:11434/api/generate")!
                        )
                    ]
                )
            ),
            httpClient: FakeAIHTTPClient(data: Data("{}".utf8), statusCode: 500)
        )
        let onlineAdapter = OpenAIPlannerHintAdapter(
            router: AIModelRouter(
                registry: AIModelRegistry(
                    entries: [entry(id: "online-planner", provider: .openAI, modelID: "gpt-5.2")]
                )
            ),
            httpClient: FakeAIHTTPClient(
                data: responseData(
                    outputText: """
                    {"id":"online-hint-1","goal":"fallback online","policyName":"online-planner-policy","priorities":["recover"],"preferredActions":["wait"],"avoidActions":[],"confidence":0.81,"expiryMilliseconds":4000}
                    """
                ),
                statusCode: 200
            ),
            environment: ["OPENAI_API_KEY": "test-key"]
        )
        let planner = ProviderBackedSlowPlannerHintGenerator(
            localAdapter: localAdapter,
            onlineAdapter: onlineAdapter,
            providerOrder: [.ollama, .openAI]
        )

        let result = await planner.generatePlannerHint(snapshot: slowPlannerSnapshot())

        #expect(result.hint?.id == "online-hint-1")
        #expect(result.metadata["ollama.status"] == "providerOutage")
        #expect(result.metadata["openAI.status"] == "completed")
        #expect(result.metadata["selectedProvider"] == "openAI")
        #expect(result.metadata["selectedModelID"] == "gpt-5.2")
    }

    private func adapterRequest() -> PlannerHintAdapterRequest {
        PlannerHintAdapterRequest(
            context: RunContextPackage(
                sessionID: "session-1",
                userGoal: "avoid hazards",
                targetID: "target-1",
                runtimeProfile: "dry-run",
                latestWorldState: RunWorldStateSummary(
                    stateID: "state-1",
                    summary: "player centered",
                    confidence: 0.9
                ),
                transcriptSummary: ""
            ),
            sourceTraceID: "trace-1",
            sourceFrameID: "frame-1",
            sourceStateID: "state-1",
            now: timestamp(10)
        )
    }

    private func entry(
        id: String,
        role: AIModelRole = .plannerHint,
        provider: AIModelProvider = .openAI,
        modelID: String,
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
        evalStatus: AIModelEvalStatus = .candidate,
        timeoutMS: Int = 8_000,
        promptVersion: String = "planner-hint-v1"
    ) -> AIModelRegistryEntry {
        AIModelRegistryEntry(
            id: id,
            role: role,
            provider: provider,
            modelID: modelID,
            endpoint: endpoint,
            capabilities: [.textInput, .structuredOutputs],
            timeoutMS: timeoutMS,
            promptVersion: promptVersion,
            evalStatus: evalStatus,
            docsURL: docsURL(for: provider)
        )
    }

    private func docsURL(for provider: AIModelProvider) -> URL {
        switch provider {
        case .openAI:
            return URL(string: "https://platform.openai.com/docs/api-reference/responses/create")!
        case .ollama:
            return URL(string: "https://docs.ollama.com/api")!
        case .localRuntime:
            return URL(string: "local://test-model")!
        }
    }

    private func responseData(outputText: String) -> Data {
        let escaped = outputText
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return Data("{\"id\":\"resp-1\",\"output_text\":\"\(escaped)\"}".utf8)
    }

    private func ollamaResponseData(response: String) -> Data {
        let escaped = response
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return Data("{\"model\":\"qwen3:8b\",\"response\":\"\(escaped)\",\"done\":true}".utf8)
    }

    private func slowPlannerSnapshot() -> SlowPlannerSnapshot {
        let observedAt = timestamp(10)
        let context = RunContextPackage(
            sessionID: "session-1",
            userGoal: "avoid hazards",
            targetID: "target-1",
            runtimeProfile: "dry-run",
            latestWorldState: RunWorldStateSummary(
                stateID: "state-1",
                summary: "player centered",
                confidence: 0.9
            ),
            transcriptSummary: ""
        )
        let worldState = HotLoopWorldState(
            id: "state-1",
            traceID: "trace-1",
            frameID: "frame-1",
            targetID: "target-1",
            observedAt: observedAt,
            signalSummaries: [],
            actionAffordances: [],
            confidence: 0.9
        )
        let action = HotLoopControllerAction(
            id: "action-1",
            traceID: "trace-1",
            frameID: "frame-1",
            stateID: "state-1",
            kind: .wait,
            target: nil,
            policyName: "test-policy",
            confidence: 0.9,
            rationale: "test"
        )
        return SlowPlannerSnapshot(
            id: "snapshot-1",
            triggerReasons: [.sceneChanged],
            context: context,
            latestWorldState: worldState,
            latestAction: action,
            traceSummaries: []
        )
    }

    private func timestamp(_ milliseconds: UInt64) -> RunTraceTimestamp {
        RunTraceTimestamp(
            wallClock: Date(timeIntervalSince1970: Double(milliseconds) / 1_000),
            monotonicUptimeNanoseconds: milliseconds * 1_000_000
        )
    }
}

private final class FakeAIHTTPClient: AIHTTPClient, @unchecked Sendable {
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
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }
}

private extension URLRequest {
    var httpBodyJSONObject: [String: Any]? {
        guard let httpBody,
              let object = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any]
        else {
            return nil
        }
        return object
    }
}
