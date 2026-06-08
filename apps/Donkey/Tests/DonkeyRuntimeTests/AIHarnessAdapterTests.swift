import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation
import Testing

private let defaultLocalRuntimeModelID = "qwen2.5-0.5b-instruct-q4_k_m"
// Only used in explicit local-generate planner-hint unit tests; it is not a default runtime dependency.
private let explicitLocalGenerateFixtureModelID = "qwen3:8b"

@Suite
struct AIHarnessAdapterTests {
    @Test
    func routerSelectsPlannerModelFromRegistryAndSkipsFailedEntries() throws {
        let registry = AIModelRegistry(
            entries: [
                entry(id: "failed", modelID: "backend-selected-a", evalStatus: .passing, timeoutMS: 1_000),
                entry(id: "selected", modelID: "backend-selected-b", evalStatus: .passing, timeoutMS: 2_000)
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
        #expect(selected.modelID == "backend-selected-b")
    }

    @Test
    func highRiskRouteRequiresPassingModel() throws {
        let router = AIModelRouter(
            registry: AIModelRegistry(
                entries: [
                    entry(id: "candidate", modelID: "backend-selected", evalStatus: .candidate)
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
                entry(id: "backend", provider: .donkeyBackend, modelID: AIModelRegistryEntry.backendSelectedModelID, evalStatus: .candidate),
                entry(id: "local", provider: .localRuntime, modelID: defaultLocalRuntimeModelID, evalStatus: .candidate)
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
        #expect(selected.provider == .localRuntime)
    }

    @Test
    func privacySensitiveTaskIntentRouteSelectsHostedBackendProvider() throws {
        let router = AIModelRouter(registry: .defaultHybridPlanner)

        let selected = try router.route(
            AIModelRouteRequest(
                jobType: .taskIntent,
                privacyMode: .privacySensitive
            )
        )

        #expect(selected.id == "backend-task-intent-default")
        #expect(selected.role == .taskIntent)
        #expect(selected.provider == .donkeyBackend)
        #expect(selected.modelID == AIModelRegistryEntry.backendSelectedModelID)
        #expect(selected.backendModelOverride == nil)
        #expect(selected.timeoutMS == 12_000)
    }

    @Test
    func defaultPlannerHintRouteUsesBackendProvider() throws {
        let router = AIModelRouter(registry: .defaultHybridPlanner)

        let selected = try router.route(
            AIModelRouteRequest(
                jobType: .plannerHint,
                privacyMode: .privacySensitive
            )
        )

        #expect(selected.id == "backend-planner-hint-default")
        #expect(selected.provider == .donkeyBackend)
        #expect(selected.modelID == AIModelRegistryEntry.backendSelectedModelID)
    }

    @Test
    func localModelPriorityWorkerPreemptsLowerPriorityWorkCooperatively() async throws {
        let worker = LocalModelPriorityWorker()
        let recorder = LocalModelPriorityWorkerRecorder()

        let lowPriority = Task {
            await worker.submit(kind: .plannerHint, priority: .replay) { context in
                await recorder.append("low-start")
                while !(await context.isCancelled()) {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                await recorder.append("low-cancelled")
                return "low"
            }
        }

        for _ in 0..<100 where !(await recorder.events().contains("low-start")) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(await recorder.events().contains("low-start"))

        let highPriority = Task {
            await worker.submit(kind: .taskIntent, priority: .userInteractive) {
                await recorder.append("high-run")
                return "high"
            }
        }

        let highResult = await highPriority.value
        let lowResult = await lowPriority.value
        let events = await recorder.events()
        let snapshot = await worker.snapshot()

        #expect(highResult == "high")
        #expect(lowResult == "low")
        #expect(events == ["low-start", "low-cancelled", "high-run"])
        #expect(snapshot.currentWorkID == nil)
        #expect(snapshot.queuedCount == 0)
    }

    @Test
    func voiceTranscriptionRouteHasNoDefaultLocalModel() throws {
        let router = AIModelRouter(registry: .defaultHybridPlanner)

        #expect(throws: AIModelRouteError.noMatchingModel) {
            _ = try router.route(
                AIModelRouteRequest(
                    jobType: .voiceTranscription,
                    privacyMode: .privacySensitive,
                    requiredCapabilities: [.audioInput]
                )
            )
        }
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
            router: AIModelRouter(registry: localVoiceRegistry()),
            runtime: FakeVoiceRuntime(
                transcript: LocalVoiceTranscript(
                    text: "show weather",
                    language: "en",
                    confidence: 0.91,
                    segments: ["show weather"]
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

        #expect(result.transcript?.text == "show weather")
        #expect(result.trace.status == .completed)
        #expect(result.trace.role == .voiceTranscription)
        #expect(result.trace.modelID == "nvidia/parakeet-tdt-0.6b-v3")
        #expect(result.trace.validationStatus == "transcriptDecoded")
        #expect(result.trace.metadata["transcriptFeedsCommandParser"] == "true")
        #expect(result.trace.metadata["localOnly"] == "true")
    }

    @Test
    func localVoiceTranscriptionAdapterConvertsPCMToParakeetCompatibleWAV() async {
        let runtime = RecordingVoiceRuntime(
            transcript: LocalVoiceTranscript(text: "show weather", confidence: 0.9)
        )
        let adapter = LocalVoiceTranscriptionAdapter(
            router: AIModelRouter(registry: localVoiceRegistry()),
            runtime: runtime,
            now: fixedClock([10, 20])
        )
        let result = await adapter.transcribe(
            LocalVoiceTranscriptionRequest(
                audio: LocalVoiceAudioBuffer(
                    id: "audio-pcm",
                    format: "pcm_f32le",
                    sampleRateHz: 48_000,
                    channelCount: 1,
                    durationMS: 4,
                    data: float32LittleEndianData([0, 0.25, -0.25, 0.5, -0.5, 0.1])
                ),
                sourceTraceID: "trace-voice-pcm"
            )
        )
        let prepared = await runtime.lastAudio

        #expect(result.trace.status == .completed)
        #expect(prepared?.format == "wav")
        #expect(prepared?.sampleRateHz == 16_000)
        #expect(prepared?.channelCount == 1)
        #expect(prepared?.metadata["audio.normalization.status"] == "converted")
        #expect(prepared?.data.prefix(4) == Data("RIFF".utf8))
        #expect(result.trace.metadata["audio.normalization.status"] == "converted")
        #expect(result.trace.metadata["audio.prepared.format"] == "wav")
    }

    @Test
    func processBackedParakeetRuntimeDecodesSidecarTranscript() async throws {
        let runtime = ProcessBackedParakeetTranscriptionRuntime(
            sidecarRunner: FakeSidecarRunner(
                result: LocalJSONSidecarResult(
                    status: .completed,
                    outputData: Data("""
                    {"text":"show weather","language":"en","confidence":0.94,"segments":["show weather"],"metadata":{"decoder":"fake-parakeet"}}
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
            model: try AIModelRouter(registry: localVoiceRegistry()).route(
                AIModelRouteRequest(
                    jobType: .voiceTranscription,
                    requiredCapabilities: [.audioInput],
                    allowedProviders: [.localRuntime]
                )
            )
        )

        #expect(transcript.text == "show weather")
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
                model: try AIModelRouter(registry: localVoiceRegistry()).route(
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
    func hostedFollowUpResolverLetsBackendSelectResponsesModel() async throws {
        let httpClient = FakeAIHTTPClient(
            data: Data(#"{"output_text":"{\"isFollowUp\":true,\"taskID\":\"task-1\",\"confidence\":0.82,\"reason\":\"same task\"}"}"#.utf8),
            statusCode: 200
        )
        let resolver = HostedTaskFollowUpResolver(
            configuration: DonkeyBackendInferenceConfiguration(
                baseURL: URL(string: "https://donkey.example")!,
                clientID: "client-1"
            ),
            httpClient: httpClient
        )

        let result = await resolver.resolveFollowUp(
            UserQueryFollowUpResolverRequest(
                text: "add that to it",
                candidates: [
                    UserQueryFollowUpCandidate(
                        taskID: "task-1",
                        title: "Draft note",
                        detail: "Writing a note",
                        commandText: "write a note",
                        status: .chatting,
                        updatedAt: Date(timeIntervalSince1970: 0)
                    )
                ],
                sourceTraceID: "trace-hosted-followup"
            )
        )

        #expect(result.taskID == "task-1")
        #expect(result.trace.provider == .donkeyBackend)
        #expect(result.trace.modelID == AIModelRegistryEntry.backendSelectedModelID)

        let request = try #require(httpClient.requests.first)
        #expect(request.url?.path == "/api/inference/responses/")
        let body = try #require(request.httpBodyJSONObject)
        #expect(body["model"] == nil)
        #expect(body["store"] as? Bool == false)
        #expect(body["donkeyProvider"] == nil)
    }







    @Test
    func hostedPlannerAdapterBuildsResponsesRequestWithStoreFalseAndDecodesStructuredHint() async throws {
        let httpClient = FakeAIHTTPClient(
            data: responseData(
                outputText: """
                {"id":"hint-1","goal":"avoid hazards","policyName":"planner-policy","priorities":["center lane"],"preferredActions":["wait"],"avoidActions":["tapTarget"],"confidence":0.82,"expiryMilliseconds":5000}
                """
            ),
            statusCode: 200
        )
        let adapter = HostedPlannerHintAdapter(
            router: AIModelRouter(registry: AIModelRegistry(entries: [entry(id: "planner", modelID: AIModelRegistryEntry.backendSelectedModelID)])),
            configuration: DonkeyBackendInferenceConfiguration(
                baseURL: URL(string: "https://donkey.example")!,
                clientID: "client-1"
            ),
            httpClient: httpClient
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
        #expect(request.url?.path == "/api/inference/responses/")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "x-donkey-client-id") == "client-1")
        let body = try #require(request.httpBodyJSONObject)
        #expect(body["model"] == nil)
        #expect(body["donkeyProvider"] == nil)
        #expect(body["store"] as? Bool == false)
        let text = try #require(body["text"] as? [String: Any])
        let formatContainer = try #require(text["format"] as? [String: Any])
        #expect(formatContainer["type"] as? String == "json_schema")
    }

    @Test
    func hostedPlannerAdapterIncludesSelectedSemanticMemoryInPrompt() async throws {
        let httpClient = FakeAIHTTPClient(
            data: responseData(
                outputText: """
                {"id":"hint-semantic","goal":"avoid hazards","policyName":"planner-policy","priorities":["center lane"],"preferredActions":["wait"],"avoidActions":[],"confidence":0.82,"expiryMilliseconds":5000}
                """
            ),
            statusCode: 200
        )
        let adapter = HostedPlannerHintAdapter(
            router: AIModelRouter(registry: AIModelRegistry(entries: [entry(id: "planner", modelID: AIModelRegistryEntry.backendSelectedModelID)])),
            configuration: DonkeyBackendInferenceConfiguration(
                baseURL: URL(string: "https://donkey.example")!,
                clientID: "client-1"
            ),
            httpClient: httpClient,
            memoryStore: nil
        )
        var request = adapterRequest()
        request.context.semanticMemoryResults = [
            RunMemorySemanticResult(
                record: memoryRecord(
                    id: "memory-weather",
                    value: "Weather app search accepts city names.",
                    targetID: "target-1"
                ),
                relevance: 0.91,
                embeddingModelID: "test-embedding"
            )
        ]

        _ = await adapter.generatePlannerHint(request)

        let body = try #require(httpClient.requests.first?.httpBodyJSONObject)
        let input = try #require(body["input"] as? [[String: Any]])
        let firstInput = try #require(input.first)
        let content = try #require(firstInput["content"] as? [[String: Any]])
        let prompt = try #require(content.first?["text"] as? String)
        #expect(prompt.contains("semantic_memory: memory-weather(0.91): Weather app search accepts city names."))
    }

    @Test
    func hostedPlannerAdapterPersistsProviderMemoryProposalsWithValidatedHint() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteAgentMemoryStore(baseDirectory: root, cleanupLegacyStores: false)
        let httpClient = FakeAIHTTPClient(
            data: responseData(
                outputText: providerOutput(
                    hintID: "hint-memory",
                    memoryWriteProposals: [
                        providerMemoryProposalJSON(
                            proposalID: "proposal-1",
                            recordID: "memory-1",
                            targetID: "target-1"
                        )
                    ]
                )
            ),
            statusCode: 200
        )
        let adapter = HostedPlannerHintAdapter(
            router: AIModelRouter(registry: AIModelRegistry(entries: [entry(id: "planner", modelID: AIModelRegistryEntry.backendSelectedModelID)])),
            configuration: DonkeyBackendInferenceConfiguration(
                baseURL: URL(string: "https://donkey.example")!,
                clientID: "client-1"
            ),
            httpClient: httpClient,
            memoryStore: store
        )

        let result = await adapter.generatePlannerHint(adapterRequest())
        let records = try store.records(scope: .target, kinds: [.targetFact], targetID: "target-1")

        #expect(result.hint?.id == "hint-memory")
        #expect(result.trace.status == .completed)
        #expect(result.memoryWriteDecisions.count == 1)
        #expect(result.memoryWriteDecisions.first?.approval.approved == true)
        #expect(records.map(\.id) == ["memory-1"])
        #expect(result.trace.metadata["memoryProposal.count"] == "1")
        #expect(result.trace.metadata["memoryProposal.persistedCount"] == "1")
    }

    @Test
    func hostedPlannerAdapterKeepsHintWhenMemoryProposalPayloadIsMalformed() async {
        let httpClient = FakeAIHTTPClient(
            data: responseData(
                outputText: """
                {"hint":{"id":"hint-only","goal":"recover","policyName":"planner-policy","priorities":["observe"],"preferredActions":["wait"],"avoidActions":[],"confidence":0.82,"expiryMilliseconds":5000},"memoryWriteProposals":[{}]}
                """
            ),
            statusCode: 200
        )
        let adapter = HostedPlannerHintAdapter(
            router: AIModelRouter(registry: AIModelRegistry(entries: [entry(id: "planner", modelID: AIModelRegistryEntry.backendSelectedModelID)])),
            configuration: DonkeyBackendInferenceConfiguration(
                baseURL: URL(string: "https://donkey.example")!,
                clientID: "client-1"
            ),
            httpClient: httpClient,
            memoryStore: nil
        )

        let result = await adapter.generatePlannerHint(adapterRequest())

        #expect(result.hint?.id == "hint-only")
        #expect(result.trace.status == .completed)
        #expect(result.memoryWriteDecisions.isEmpty)
        #expect(result.trace.metadata["memoryProposal.decodeStatus"] == "invalid")
    }

    @Test
    func hostedPlannerAdapterHandlesMissingCredentialsRateLimitAndInvalidOutput() async {
        let adapter = HostedPlannerHintAdapter(
            router: AIModelRouter(registry: AIModelRegistry(entries: [entry(id: "planner", modelID: AIModelRegistryEntry.backendSelectedModelID)])),
            httpClient: FakeAIHTTPClient(data: responseData(outputText: "{}"), statusCode: 200),
            environment: [:]
        )

        let missingCredentials = await adapter.generatePlannerHint(adapterRequest())
        #expect(missingCredentials.hint == nil)
        #expect(missingCredentials.trace.status == .missingCredentials)

        let rateLimited = await HostedPlannerHintAdapter(
            router: AIModelRouter(registry: AIModelRegistry(entries: [entry(id: "planner", modelID: AIModelRegistryEntry.backendSelectedModelID)])),
            configuration: DonkeyBackendInferenceConfiguration(
                baseURL: URL(string: "https://donkey.example")!,
                clientID: "client-1"
            ),
            httpClient: FakeAIHTTPClient(data: Data(), statusCode: 429),
            memoryStore: nil
        )
        .generatePlannerHint(adapterRequest())
        #expect(rateLimited.trace.status == .rateLimited)

        let invalidOutput = await HostedPlannerHintAdapter(
            router: AIModelRouter(registry: AIModelRegistry(entries: [entry(id: "planner", modelID: AIModelRegistryEntry.backendSelectedModelID)])),
            configuration: DonkeyBackendInferenceConfiguration(
                baseURL: URL(string: "https://donkey.example")!,
                clientID: "client-1"
            ),
            httpClient: FakeAIHTTPClient(data: responseData(outputText: "{}"), statusCode: 200),
            memoryStore: nil
        )
        .generatePlannerHint(adapterRequest())
        #expect(invalidOutput.trace.status == .invalidOutput)
    }

    @Test
    func localGenerateAdapterBuildsLocalGenerateRequestAndDecodesStructuredHint() async throws {
        let httpClient = FakeAIHTTPClient(
            data: localGenerateResponseData(
                response: """
                {"id":"local-hint-1","goal":"recover locally","policyName":"local-planner-policy","priorities":["observe menu"],"preferredActions":["observe"],"avoidActions":["tapTarget"],"confidence":0.74,"expiryMilliseconds":3000}
                """
            ),
            statusCode: 200
        )
        let adapter = LocalGeneratePlannerHintAdapter(
            router: AIModelRouter(
                registry: AIModelRegistry(
                    entries: [
                        entry(
                            id: "local-planner",
                            provider: .ollama,
                            modelID: explicitLocalGenerateFixtureModelID,
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
        #expect(body["model"] as? String == explicitLocalGenerateFixtureModelID)
        #expect(body["stream"] as? Bool == false)
        #expect(body["format"] as? [String: Any] != nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func providerBackedSlowPlannerFallsBackFromLocalToBackendProvider() async {
        let localAdapter = LocalGeneratePlannerHintAdapter(
            router: AIModelRouter(
                registry: AIModelRegistry(
                    entries: [
                        entry(
                            id: "local-planner",
                            provider: .ollama,
                            modelID: explicitLocalGenerateFixtureModelID,
                            endpoint: URL(string: "http://127.0.0.1:11434/api/generate")!
                        )
                    ]
                )
            ),
            httpClient: FakeAIHTTPClient(data: Data("{}".utf8), statusCode: 500)
        )
        let hostedAdapter = HostedPlannerHintAdapter(
            router: AIModelRouter(
                registry: AIModelRegistry(
                    entries: [entry(id: "backend-planner", provider: .donkeyBackend, modelID: AIModelRegistryEntry.backendSelectedModelID)]
                )
            ),
            configuration: DonkeyBackendInferenceConfiguration(
                baseURL: URL(string: "https://donkey.example")!,
                clientID: "client-1"
            ),
            httpClient: FakeAIHTTPClient(
                data: responseData(
                    outputText: """
                    {"id":"backend-hint-1","goal":"fallback backend","policyName":"backend-planner-policy","priorities":["recover"],"preferredActions":["wait"],"avoidActions":[],"confidence":0.81,"expiryMilliseconds":4000}
                    """
                ),
                statusCode: 200
            )
        )
        let planner = ProviderBackedSlowPlannerHintGenerator(
            localAdapter: localAdapter,
            hostedAdapter: hostedAdapter,
            providerOrder: [.ollama, .donkeyBackend]
        )

        let result = await planner.generatePlannerHint(snapshot: slowPlannerSnapshot())

        #expect(result.hint?.id == "backend-hint-1")
        #expect(result.metadata["ollama.status"] == "providerOutage")
        #expect(result.metadata["donkeyBackend.status"] == "completed")
        #expect(result.metadata["selectedProvider"] == "donkeyBackend")
        #expect(result.metadata["selectedModelID"] == AIModelRegistryEntry.backendSelectedModelID)
    }

    @Test
    func providerBackedSlowPlannerDefaultOrderSkipsOllama() {
        let planner = ProviderBackedSlowPlannerHintGenerator()

        #expect(planner.providerOrder == [.donkeyBackend])
    }

    @Test
    func plannerHintRequestsCompactMemoryBeforeProviderCalls() {
        let longMemory = "important prefix " + String(repeating: "planner-memory ", count: 100)
        let request = PlannerHintAdapterRequest(
            context: RunContextPackage(
                sessionID: "session-compact-planner",
                userGoal: "recover",
                targetID: "target-1",
                runtimeProfile: "dry-run",
                latestWorldState: RunWorldStateSummary(
                    stateID: "state-long",
                    summary: String(repeating: "state ", count: 200),
                    confidence: 0.4
                ),
                transcriptSummary: "",
                memorySnapshot: RunMemorySnapshot(
                    targetRecords: [
                        memoryRecord(
                            id: "memory-long",
                            value: longMemory,
                            targetID: "target-1"
                        )
                    ]
                )
            ),
            sourceTraceID: "trace-compact-planner",
            sourceStateID: "state-long",
            now: timestamp(10)
        )

        let record = request.context.memorySnapshot?.targetRecords.first
        #expect(request.context.latestWorldState?.summary.count == 600)
        #expect(record?.value.count == 600)
        #expect(record?.value.contains("important prefix") == true)
        #expect(record?.metadata["compaction.truncated"] == "true")
    }

    @Test
    func semanticMemoryRetrievalUsesBudgetsAndTargetScope() async {
        let records = [
            memoryRecord(id: "weather", value: "Weather app search field accepts city names.", targetID: "weather-app"),
            memoryRecord(id: "music", value: "Music app can play Sample Result from the search field.", targetID: "music-app")
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
        let sampleEmail = "privacy-test" + "@example.invalid"
        let sampleSecret = "example-secret"
        let result = AIHarnessRedactor().redact(
            "email \(sampleEmail) password: \(sampleSecret)",
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

    private func localVoiceRegistry() -> AIModelRegistry {
        AIModelRegistry(
            entries: [
                AIModelRegistryEntry(
                    id: "fixture-local-voice-transcription-parakeet",
                    role: .voiceTranscription,
                    provider: .localRuntime,
                    modelID: "nvidia/parakeet-tdt-0.6b-v3",
                    endpoint: URL(string: "local://nvidia/parakeet-tdt-0.6b-v3")!,
                    capabilities: [.audioInput],
                    timeoutMS: 2_000,
                    promptVersion: "voice-transcription-v1",
                    evalStatus: .candidate,
                    docsURL: URL(string: "local://test-voice-model")!
                )
            ]
        )
    }

    private func entry(
        id: String,
        role: AIModelRole = .plannerHint,
        provider: AIModelProvider = .donkeyBackend,
        modelID: String,
        endpoint: URL = URL(string: "donkey://backend/api/inference/responses")!,
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
        case .donkeyBackend:
            return URL(string: "donkey://backend/api/inference/responses")!
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

    private func hostedPlanningOutput(
        route: String = "localAppTask",
        goal: String,
        taskType: String,
        targetAppName: String,
        entitiesJSON: String = "{}",
        normalizedEntitiesJSON: String = "{}",
        confidence: Double,
        needsConfirmation: Bool = false,
        ambiguityClass: String = "safe",
        riskLevel: String = "low",
        missingInformationJSON: String = "[]",
        shouldAskBeforeActing: Bool = false,
        contextNeedsJSON: String = "[]",
        planStepsJSON: String = "[]",
        verificationCriteriaJSON: String = "[]",
        fallbacksJSON: String = "[]",
        clarificationShouldAsk: Bool = false,
        clarificationQuestionsJSON: String = "[]",
        clarificationPolicy: String = "Ask only when required information is missing.",
        metadataJSON: String = "{}"
    ) -> String {
        """
        {"structuredIntent":{"route":"\(route)","goal":"\(goal)","taskType":"\(taskType)","targetAppName":"\(targetAppName)","entities":\(entitiesJSON),"normalizedEntities":\(normalizedEntitiesJSON),"confidence":\(confidence),"needsConfirmation":\(needsConfirmation)},"ambiguityRisk":{"ambiguityClass":"\(ambiguityClass)","riskLevel":"\(riskLevel)","missingInformation":\(missingInformationJSON),"shouldAskBeforeActing":\(shouldAskBeforeActing)},"contextNeeds":\(contextNeedsJSON),"planSteps":\(planStepsJSON),"verificationCriteria":\(verificationCriteriaJSON),"fallbacks":\(fallbacksJSON),"clarificationPolicy":{"shouldAsk":\(clarificationShouldAsk),"questions":\(clarificationQuestionsJSON),"policy":"\(clarificationPolicy)"},"metadata":\(metadataJSON)}
        """
    }

    private func localGenerateResponseData(response: String) -> Data {
        let escaped = response
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return Data("{\"model\":\"\(explicitLocalGenerateFixtureModelID)\",\"response\":\"\(escaped)\",\"done\":true}".utf8)
    }

    private func providerOutput(
        hintID: String,
        memoryWriteProposals: [String]
    ) -> String {
        """
        {"hint":{"id":"\(hintID)","goal":"avoid hazards","policyName":"planner-policy","priorities":["center lane"],"preferredActions":["wait"],"avoidActions":[],"confidence":0.82,"expiryMilliseconds":5000},"memoryWriteProposals":[\(memoryWriteProposals.joined(separator: ","))]}
        """
    }

    private func providerMemoryProposalJSON(
        proposalID: String,
        recordID: String,
        targetID: String
    ) -> String {
        """
        {"id":"\(proposalID)","proposedBy":"model","record":{"id":"\(recordID)","scope":"target","kind":"targetFact","targetID":"\(targetID)","value":"Weather app search accepts city names.","createdAt":{"wallClock":0.01,"monotonicUptimeNanoseconds":10000000},"expiresAt":{"wallClock":1.0,"monotonicUptimeNanoseconds":1000000000},"durable":false,"source":{"traceID":"trace-1","summary":"provider proposal test"},"metadata":{}},"rationale":"provider decoded"}
        """
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
            provider: .donkeyBackend,
            modelID: AIModelRegistryEntry.backendSelectedModelID,
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

    private func float32LittleEndianData(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<UInt32>.size)
        for sample in samples {
            var bits = sample.bitPattern.littleEndian
            data.append(Data(bytes: &bits, count: MemoryLayout<UInt32>.size))
        }
        return data
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "DonkeyAIHarnessAdapterTests-\(UUID().uuidString)",
            isDirectory: true
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

private actor RecordingVoiceRuntime: LocalVoiceTranscriptionRuntime {
    var transcript: LocalVoiceTranscript
    private(set) var lastAudio: LocalVoiceAudioBuffer?

    init(transcript: LocalVoiceTranscript) {
        self.transcript = transcript
    }

    func transcribe(
        audio: LocalVoiceAudioBuffer,
        model: AIModelRegistryEntry
    ) async throws -> LocalVoiceTranscript {
        lastAudio = audio
        return transcript
    }
}

private struct FakeSidecarRunner: LocalJSONSidecarRunning {
    var result: LocalJSONSidecarResult

    func run(_ request: LocalJSONSidecarRequest) async -> LocalJSONSidecarResult {
        result
    }
}

private actor LocalModelPriorityWorkerRecorder {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func events() -> [String] {
        values
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

private struct HTTPStub {
    var data: Data
    var statusCode: Int
}

private final class SequencedFakeAIHTTPClient: AIHTTPClient, @unchecked Sendable {
    var responses: [HTTPStub]
    var requests: [URLRequest] = []

    init(responses: [HTTPStub]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.isEmpty
            ? HTTPStub(data: Data(), statusCode: 500)
            : responses.removeFirst()
        return (
            response.data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: response.statusCode,
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
