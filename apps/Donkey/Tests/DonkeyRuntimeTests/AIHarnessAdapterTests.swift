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
        #expect(selected.rollbackID == nil)
        #expect(selected.metadata["runtime"] == "nvidia-nemo")
        #expect(selected.metadata["local"] == "true")
        #expect(selected.metadata["fallbackPolicy"] == "none")
        #expect(selected.metadata["fallbackModelID"] == nil)
    }

    @Test
    func voiceTranscriptionRouteHasNoWhisperFallbackWhenParakeetFailed() throws {
        let router = AIModelRouter(registry: .defaultHybridPlanner)

        #expect(throws: AIModelRouteError.noMatchingModel) {
            _ = try router.route(
                AIModelRouteRequest(
                    jobType: .voiceTranscription,
                    privacyMode: .privacySensitive,
                    failedModelEntryIDs: ["local-voice-transcription-parakeet-tdt-0.6b-v3"],
                    requiredCapabilities: [.audioInput]
                )
            )
        }
    }

    @Test
    func localVoiceTranscriptionAdapterReturnsTranscriptForCommandParser() async {
        let adapter = LocalVoiceTranscriptionAdapter(
            runtime: FakeVoiceRuntime(
                transcript: LocalVoiceTranscript(
                    text: "play Coldplay",
                    language: "en",
                    confidence: 0.91,
                    segments: ["play Coldplay"]
                )
            ),
            now: fixedClock([10, 42])
        )
        let result = await adapter.transcribe(
            LocalVoiceTranscriptionRequest(
                audio: LocalVoiceAudioBuffer(
                    id: "audio-1",
                    durationMS: 1_200,
                    data: Data([0, 1, 2])
                ),
                sourceTraceID: "trace-voice"
            )
        )

        #expect(result.transcript?.text == "play Coldplay")
        #expect(result.trace.status == .completed)
        #expect(result.trace.role == .voiceTranscription)
        #expect(result.trace.modelID == "nvidia/parakeet-tdt-0.6b-v3")
        #expect(result.trace.validationStatus == "transcriptDecoded")
        #expect(result.trace.metadata["transcriptFeedsCommandParser"] == "true")
        #expect(result.trace.metadata["localOnly"] == "true")
    }

    @Test
    func processBackedParakeetRuntimeDecodesSidecarTranscript() async throws {
        let runtime = ProcessBackedParakeetTranscriptionRuntime(
            sidecarRunner: FakeSidecarRunner(
                result: LocalJSONSidecarResult(
                    status: .completed,
                    outputData: Data("""
                    {"text":"play Coldplay","language":"en","confidence":0.94,"segments":["play Coldplay"],"metadata":{"decoder":"fake-parakeet"}}
                    """.utf8),
                    metadata: ["sidecar.reason": "completed"]
                )
            )
        )
        let transcript = try await runtime.transcribe(
            audio: LocalVoiceAudioBuffer(
                id: "audio-sidecar",
                durationMS: 800,
                data: Data([1, 2, 3])
            ),
            model: try AIModelRouter(registry: .defaultHybridPlanner).route(
                AIModelRouteRequest(
                    jobType: .voiceTranscription,
                    requiredCapabilities: [.audioInput],
                    allowedProviders: [.localRuntime]
                )
            )
        )

        #expect(transcript.text == "play Coldplay")
        #expect(transcript.language == "en")
        #expect(transcript.metadata["decoder"] == "fake-parakeet")
    }

    @Test
    func processBackedParakeetRuntimeFailsClearlyWhenUnavailable() async throws {
        let runtime = ProcessBackedParakeetTranscriptionRuntime(
            sidecarRunner: FakeSidecarRunner(
                result: LocalJSONSidecarResult(
                    status: .unavailable,
                    metadata: ["sidecar.reason": "missingEnvironmentVariable"]
                )
            )
        )

        await #expect(throws: LocalVoiceTranscriptionRuntimeError.runtimeUnavailable("missingEnvironmentVariable")) {
            _ = try await runtime.transcribe(
                audio: LocalVoiceAudioBuffer(id: "audio-missing", durationMS: 10, data: Data()),
                model: try AIModelRouter(registry: .defaultHybridPlanner).route(
                    AIModelRouteRequest(
                        jobType: .voiceTranscription,
                        requiredCapabilities: [.audioInput],
                        allowedProviders: [.localRuntime]
                    )
                )
            )
        }
    }

    @Test
    func localJSONSidecarRunnerReportsMissingEnvAndNonzeroExit() async {
        let missing = await ProcessBackedLocalJSONSidecarRunner(environment: [:]).run(
            LocalJSONSidecarRequest(
                environmentVariableName: "DONKEY_PARAKEET_TRANSCRIBER",
                inputData: Data("{}".utf8),
                timeoutMS: 100
            )
        )
        #expect(missing.status == .unavailable)
        #expect(missing.metadata["sidecar.reason"] == "missingEnvironmentVariable")

        let failed = await ProcessBackedLocalJSONSidecarRunner(
            environment: ["DONKEY_TEST_SIDECAR": "/bin/false"]
        )
        .run(
            LocalJSONSidecarRequest(
                environmentVariableName: "DONKEY_TEST_SIDECAR",
                inputData: Data("{}".utf8),
                timeoutMS: 100
            )
        )
        #expect(failed.status == .failed)
        #expect(failed.exitCode != 0)
        #expect(failed.metadata["sidecar.reason"] == "nonZeroExit")
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

    @Test
    func semanticMemoryRetrievalUsesBudgetsAndTargetScope() async {
        let records = [
            memoryRecord(id: "weather", value: "Weather app search field accepts city names.", targetID: "weather-app"),
            memoryRecord(id: "music", value: "Music app can play Coldplay from the search field.", targetID: "music-app")
        ]
        let retriever = SemanticRunMemoryRetriever()

        let results = await retriever.retrieve(
            query: RunMemorySemanticQuery(
                text: "play music",
                targetID: "music-app",
                budget: RunMemoryRetrievalBudget(maxRecords: 1, maxPromptCharacters: 80, minRelevance: 0.1)
            ),
            records: records
        )

        #expect(results.map(\.record.id) == ["music"])
        #expect(results.first?.embeddingModelID == "local-semantic-memory-embedding-contract-v1")
    }

    @Test
    func redactorCoversRemoteBoundModelContext() {
        let result = AIHarnessRedactor().redact(
            "email david@example.com password: hunter2",
            surface: .modelContext
        )

        #expect(result.redactedText.contains("[redacted-email]"))
        #expect(result.redactedText.contains("[redacted-secret]"))
        #expect(result.redactionCount == 2)
    }

    @Test
    func modelObservabilityAggregatesLatencyValidityCostAndRecovery() {
        let report = AIModelObservabilityReportBuilder.build(from: [
            modelTrace(id: "call-1", status: .completed, validationStatus: "schemaDecoded", latencyMS: 20, metadata: ["cost.estimatedUSD": "0.01"]),
            modelTrace(id: "call-2", status: .invalidOutput, validationStatus: "invalid", latencyMS: 40, metadata: ["recovery.success": "true"])
        ])

        #expect(report.callCount == 2)
        #expect(report.statusCounts["completed"] == 1)
        #expect(report.validationStatusCounts["invalid"] == 1)
        #expect(report.acceptedCount == 1)
        #expect(report.recoverySuccessCount == 1)
        #expect(report.totalEstimatedCostUSD == 0.01)
        #expect(report.latencyMS.p95 == 20)
    }

    @Test
    func providerDecodedMemoryProposalsUseDeterministicApprover() throws {
        let proposal = RunMemoryWriteProposal(
            id: "proposal-1",
            proposedBy: .model,
            record: memoryRecord(id: "record-1", value: "Music app search works for artist names.", targetID: "music-app"),
            rationale: "provider decoded"
        )
        let data = try JSONEncoder().encode([proposal])

        let decisions = try ProviderDecodedMemoryProposalHandler.decisions(
            from: data,
            decidedAt: timestamp(20)
        )

        #expect(decisions.first?.approval.approved == true)
        #expect(decisions.first?.storedRecord?.id == "record-1")
        #expect(decisions.first?.approval.approver == "deterministic-memory-approver-v1")
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

    private func fixedClock(_ milliseconds: [UInt64]) -> @Sendable () -> RunTraceTimestamp {
        let clock = FixedTraceClock(milliseconds: milliseconds)
        return {
            clock.next()
        }
    }

    private func memoryRecord(
        id: String,
        value: String,
        targetID: String
    ) -> RunMemoryRecord {
        RunMemoryRecord(
            id: id,
            scope: .target,
            kind: .targetFact,
            targetID: targetID,
            value: value,
            createdAt: timestamp(10),
            expiresAt: timestamp(1_000),
            durable: false,
            source: RunMemorySource(traceID: "trace-\(id)", summary: "test source")
        )
    }

    private func modelTrace(
        id: String,
        status: AIModelCallStatus,
        validationStatus: String,
        latencyMS: Double,
        metadata: [String: String] = [:]
    ) -> AIModelCallTrace {
        AIModelCallTrace(
            id: id,
            role: .plannerHint,
            provider: .openAI,
            modelID: "gpt-5.2",
            promptVersion: "planner-hint-v1",
            schemaID: "planner-hint-v1",
            latencyMS: latencyMS,
            timeoutMS: 8_000,
            status: status,
            validationStatus: validationStatus,
            sourceTraceID: "trace-\(id)",
            metadata: metadata
        )
    }
}

private final class FixedTraceClock: @unchecked Sendable {
    private var milliseconds: [UInt64]
    private var index = 0

    init(milliseconds: [UInt64]) {
        self.milliseconds = milliseconds
    }

    func next() -> RunTraceTimestamp {
        let value = milliseconds[min(index, milliseconds.count - 1)]
        index += 1
        return RunTraceTimestamp(
            wallClock: Date(timeIntervalSince1970: Double(value) / 1_000),
            monotonicUptimeNanoseconds: value * 1_000_000
        )
    }
}

private struct FakeVoiceRuntime: LocalVoiceTranscriptionRuntime {
    var transcript: LocalVoiceTranscript

    func transcribe(
        audio: LocalVoiceAudioBuffer,
        model: AIModelRegistryEntry
    ) async throws -> LocalVoiceTranscript {
        transcript
    }
}

private struct FakeSidecarRunner: LocalJSONSidecarRunning {
    var result: LocalJSONSidecarResult

    func run(_ request: LocalJSONSidecarRequest) async -> LocalJSONSidecarResult {
        result
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
