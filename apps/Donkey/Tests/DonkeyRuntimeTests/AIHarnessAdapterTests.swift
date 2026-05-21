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

        #expect(selected.id == "local-runtime-task-intent-qwen3")
        #expect(selected.role == .taskIntent)
        #expect(selected.provider == .localRuntime)
        #expect(selected.modelID == "qwen3:8b")
        #expect(selected.timeoutMS == 20_000)
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
    func localVoiceTranscriptionAdapterConvertsPCMToParakeetCompatibleWAV() async {
        let runtime = RecordingVoiceRuntime(
            transcript: LocalVoiceTranscript(text: "show weather", confidence: 0.9)
        )
        let adapter = LocalVoiceTranscriptionAdapter(
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
                {"taskType":"weather_lookup","targetAppName":"Weather","entities":{"city":"SF"},"normalizedEntities":{"city":"San Francisco"},"confidence":0.93,"needsConfirmation":false,"actionPlan":{"tools":[],"inputEntity":"","controlID":"","focusKey":"","verification":"commandAttempted"},"metadata":{"source":"test"}}
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
                taskDefinitions: BuiltInLocalAppTaskDefinitions.benchmarkFixtures,
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
        #expect(body["keep_alive"] as? String == "10m")
        let options = try #require(body["options"] as? [String: Any])
        #expect(options["num_predict"] as? Int == 512)
        #expect(options["num_ctx"] as? Int == 2048)
        #expect((body["prompt"] as? String)?.contains("Use only the provided task definitions") == true)
        #expect((body["prompt"] as? String)?.contains("choose by capability and target app") == true)
        #expect((body["prompt"] as? String)?.contains("Do not include reasoning") == true)
        #expect((body["prompt"] as? String)?.contains("For website navigation") == true)
        #expect((body["prompt"] as? String)?.contains("ui.newDocument") == true)
        #expect((body["prompt"] as? String)?.contains("action, destination or target app/item") == true)
        #expect((body["prompt"] as? String)?.contains("metadata.responseMode=conversation") == true)
        #expect((body["prompt"] as? String)?.contains("triggers=") == false)
        #expect((body["prompt"] as? String)?.contains("metadata=") == false)
    }

    @Test
    func ollamaTaskIntentAdapterUsesInstalledLocalModelWhenConfiguredModelIsMissing() async throws {
        let httpClient = SequencedFakeAIHTTPClient(
            responses: [
                HTTPStub(
                    data: Data(#"{"error":"model 'qwen3:8b' not found"}"#.utf8),
                    statusCode: 404
                ),
                HTTPStub(
                    data: Data(#"{"models":[{"name":"kimi-k2.5:cloud","size":0},{"name":"llama3:latest","size":4700000000}]}"#.utf8),
                    statusCode: 200
                ),
                HTTPStub(
                    data: ollamaResponseData(
                        response: """
                        {"taskType":"local_app_interaction","targetAppName":"Music","entities":{"appName":"Music","goal":"play media","query":"justin bieber"},"normalizedEntities":{"appName":"Music","goal":"play media","query":"Justin Bieber"},"confidence":0.91,"needsConfirmation":false,"actionPlan":{"tools":["app.openOrFocus","app.observe","ui.focusSearch","ui.setText","ui.pressReturn","app.verifyCommand"],"inputEntity":"query","controlID":"search","focusKey":"Command+F","verification":"commandAttempted"},"metadata":{}}
                        """
                    ),
                    statusCode: 200
                )
            ]
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
                command: "play some justin bieber",
                taskDefinitions: LocalAppTaskDefinitionLoader.runtimeSeedDefinitions,
                contextSnippets: ["Music application com.apple.Music"],
                sourceTraceID: "trace-ollama-model-fallback"
            )
        )

        #expect(result.intent?.taskType == "local_app_interaction")
        #expect(result.intent?.targetApp.appName == "Music")
        #expect(result.intent?.normalizedEntities["query"] == "Justin Bieber")
        #expect(result.trace.status == .completed)
        #expect(result.trace.modelID == "llama3:latest")
        #expect(result.trace.metadata["modelFallback.originalModelID"] == "qwen3:8b")
        #expect(result.trace.metadata["modelFallback.selectedModelID"] == "llama3:latest")
        #expect(httpClient.requests.map { $0.url?.path } == ["/api/generate", "/api/tags", "/api/generate"])
        let fallbackRequest = try #require(httpClient.requests.last)
        let fallbackBody = try #require(fallbackRequest.httpBodyJSONObject)
        #expect(fallbackBody["model"] as? String == "llama3:latest")
    }

    @Test
    func processBackedLocalLLMTaskIntentAdapterDecodesValidatedIntent() async throws {
        let adapter = ProcessBackedLocalLLMTaskIntentAdapter(
            router: AIModelRouter(registry: .defaultHybridPlanner),
            sidecarRunner: FakeSidecarRunner(
                result: LocalJSONSidecarResult(
                    status: .completed,
                    outputData: Data("""
                    {"outputText":"{\\"taskType\\":\\"media_playback\\",\\"targetAppName\\":\\"Music\\",\\"entities\\":{\\"query\\":\\"cold play\\"},\\"normalizedEntities\\":{\\"query\\":\\"Cold Play\\"},\\"confidence\\":0.91,\\"needsConfirmation\\":false,\\"actionPlan\\":{\\"tools\\":[],\\"inputEntity\\":\\"\\",\\"controlID\\":\\"\\",\\"focusKey\\":\\"\\",\\"verification\\":\\"commandAttempted\\"},\\"metadata\\":{\\"source\\":\\"test\\"}}","metadata":{"local.provider":"ollama-sidecar"}}
                    """.utf8),
                    latencyMS: 14,
                    metadata: ["sidecar.role": "taskIntent"]
                )
            )
        )

        let result = await adapter.parseTaskIntent(
            TaskIntentAdapterRequest(
                command: "play cold play",
                taskDefinitions: BuiltInLocalAppTaskDefinitions.benchmarkFixtures,
                sourceTraceID: "trace-local-llm"
            )
        )

        #expect(result.intent?.taskType == "media_playback")
        #expect(result.intent?.targetApp.appName == "Music")
        #expect(result.intent?.normalizedEntities["query"] == "Cold Play")
        #expect(result.intent?.metadata["parser"] == "local-llm-sidecar-v1")
        #expect(result.trace.provider == .localRuntime)
        #expect(result.trace.status == .completed)
        #expect(result.trace.metadata["local.provider"] == "ollama-sidecar")
    }

    @Test
    func processBackedLocalLLMTaskIntentAdapterDecodesGenericPlannedInteraction() async throws {
        let adapter = ProcessBackedLocalLLMTaskIntentAdapter(
            router: AIModelRouter(registry: .defaultHybridPlanner),
            sidecarRunner: FakeSidecarRunner(
                result: LocalJSONSidecarResult(
                    status: .completed,
                    outputData: Data("""
                    {"outputText":"{\\"taskType\\":\\"local_app_interaction\\",\\"targetAppName\\":\\"Music\\",\\"entities\\":{\\"appName\\":\\"Music\\",\\"goal\\":\\"play media\\",\\"query\\":\\"justin bieber\\"},\\"normalizedEntities\\":{\\"appName\\":\\"Music\\",\\"goal\\":\\"play media\\",\\"query\\":\\"Justin Bieber\\"},\\"confidence\\":0.91,\\"needsConfirmation\\":false,\\"actionPlan\\":{\\"tools\\":[\\"app.openOrFocus\\",\\"app.observe\\",\\"ui.focusSearch\\",\\"ui.setText\\",\\"ui.pressReturn\\",\\"ui.pressReturn\\",\\"app.verifyCommand\\"],\\"inputEntity\\":\\"query\\",\\"controlID\\":\\"search\\",\\"focusKey\\":\\"Command+F\\",\\"verification\\":\\"commandAttempted\\"},\\"metadata\\":{}}","metadata":{"local.provider":"ollama-sidecar"}}
                    """.utf8),
                    latencyMS: 14,
                    metadata: ["sidecar.role": "taskIntent"]
                )
            )
        )

        let result = await adapter.parseTaskIntent(
            TaskIntentAdapterRequest(
                command: "play some justin bieber",
                taskDefinitions: LocalAppTaskDefinitionLoader.runtimeSeedDefinitions,
                contextSnippets: ["Music application com.apple.Music"],
                sourceTraceID: "trace-local-app-plan"
            )
        )

        #expect(result.intent?.taskType == "local_app_interaction")
        #expect(result.intent?.targetApp.appName == "Music")
        #expect(result.intent?.normalizedEntities["query"] == "Justin Bieber")
        #expect(result.intent?.actionPlan?.tools.contains(.setText) == true)
        #expect(result.intent?.actionPlan?.inputEntity == "query")
        #expect(result.trace.status == .completed)
    }

    @Test
    func processBackedLocalLLMTaskIntentAdapterDecodesWrappedStructuredOutput() async throws {
        let adapter = ProcessBackedLocalLLMTaskIntentAdapter(
            router: AIModelRouter(registry: .defaultHybridPlanner),
            sidecarRunner: FakeSidecarRunner(
                result: LocalJSONSidecarResult(
                    status: .completed,
                    outputData: try localLLMSidecarOutputData(
                        outputText: """
                        <think>I should choose the generic app interaction.</think>
                        ```json
                        {"taskType":"local_app_interaction","targetAppName":"Music","entities":{"appName":"Music","goal":"play media","query":"justin bieber"},"normalizedEntities":{"appName":"Music","goal":"play media","query":"Justin Bieber"},"confidence":0.91,"needsConfirmation":false,"actionPlan":{"tools":["app.openOrFocus","app.observe","ui.focusSearch","ui.setText","ui.pressReturn","app.verifyCommand"],"inputEntity":"query","controlID":"search","focusKey":"Command+F","verification":"commandAttempted"},"metadata":{}}
                        ```
                        """,
                        metadata: ["local.provider": "ollama-sidecar"]
                    ),
                    latencyMS: 14,
                    metadata: ["sidecar.role": "taskIntent"]
                )
            )
        )

        let result = await adapter.parseTaskIntent(
            TaskIntentAdapterRequest(
                command: "play some justin bieber",
                taskDefinitions: LocalAppTaskDefinitionLoader.runtimeSeedDefinitions,
                contextSnippets: ["Music application com.apple.Music"],
                sourceTraceID: "trace-wrapped-local-app-plan"
            )
        )

        #expect(result.intent?.taskType == "local_app_interaction")
        #expect(result.intent?.targetApp.appName == "Music")
        #expect(result.intent?.normalizedEntities["query"] == "Justin Bieber")
        #expect(result.trace.status == .completed)
    }

    @Test
    func processBackedLocalLLMTaskIntentAdapterMapsEmptySidecarFailureToProviderOutage() async throws {
        let adapter = ProcessBackedLocalLLMTaskIntentAdapter(
            router: AIModelRouter(registry: .defaultHybridPlanner),
            sidecarRunner: FakeSidecarRunner(
                result: LocalJSONSidecarResult(
                    status: .completed,
                    outputData: try localLLMSidecarOutputData(
                        outputText: "",
                        metadata: [
                            "reason": "localLLMGenerationFailed",
                            "detail": "ollama HTTP 404: model 'qwen3:8b' not found"
                        ]
                    ),
                    latencyMS: 14,
                    metadata: ["sidecar.role": "taskIntent"]
                )
            )
        )

        let result = await adapter.parseTaskIntent(
            TaskIntentAdapterRequest(
                command: "play some justin bieber",
                taskDefinitions: LocalAppTaskDefinitionLoader.runtimeSeedDefinitions,
                sourceTraceID: "trace-empty-sidecar"
            )
        )

        #expect(result.intent == nil)
        #expect(result.trace.status == .providerOutage)
        #expect(result.trace.validationStatus == "notValidated")
        #expect(result.trace.metadata["reason"] == "localLLMGenerationFailed")
        #expect(result.trace.metadata["modelOutput.empty"] == "true")
        #expect(result.trace.metadata["detail"]?.contains("qwen3:8b") == true)
    }

    @Test
    func processBackedLocalLLMTaskIntentAdapterRepairsIncompleteModelPlannedInteraction() async throws {
        let adapter = ProcessBackedLocalLLMTaskIntentAdapter(
            router: AIModelRouter(registry: .defaultHybridPlanner),
            sidecarRunner: FakeSidecarRunner(
                result: LocalJSONSidecarResult(
                    status: .completed,
                    outputData: try localLLMSidecarOutputData(
                        outputText: """
                        {"taskType":"local_app_interaction","targetAppName":"com.apple.Music","entities":{"appName":"Music","goal":"play some justin bieber"},"normalizedEntities":{"query":"Justin Bieber"},"confidence":1.0,"needsConfirmation":false,"actionPlan":{"tools":["app.openOrFocus","ui.focusSearch"],"inputEntity":"query","controlID":"","focusKey":"","verification":"commandAttempted"},"metadata":{}}
                        """,
                        metadata: [
                            "local.provider": "ollama-sidecar",
                            "modelFallback.selectedModelID": "llama3:latest"
                        ]
                    ),
                    latencyMS: 14,
                    metadata: ["sidecar.role": "taskIntent"]
                )
            )
        )

        let result = await adapter.parseTaskIntent(
            TaskIntentAdapterRequest(
                command: "play some justin bieber",
                taskDefinitions: LocalAppTaskDefinitionLoader.runtimeSeedDefinitions,
                contextSnippets: ["Music application com.apple.Music"],
                sourceTraceID: "trace-repaired-local-app-plan"
            )
        )

        #expect(result.intent?.taskType == "local_app_interaction")
        #expect(result.intent?.normalizedEntities["appName"] == "Music")
        #expect(result.intent?.normalizedEntities["query"] == "Justin Bieber")
        #expect(result.intent?.metadata["modelPlan.repaired"] == "true")
        #expect(result.intent?.actionPlan?.tools.contains(.setText) == true)
        #expect(result.intent?.actionPlan?.tools.contains(.pressReturn) == true)
        #expect(result.intent?.actionPlan?.controlID == "search")
        #expect(result.intent?.actionPlan?.focusKey == "Command+F")
        #expect(result.trace.status == .completed)
    }

    @Test
    func processBackedLocalLLMTaskIntentAdapterDecodesRepresentativeAppCommands() async throws {
        let examples: [(command: String, outputText: String, appName: String, requiredTools: [LocalAppActionPlanTool], queryContains: String)] = [
            (
                command: "go to cnn.com",
                outputText: """
                {"taskType":"local_app_interaction","targetAppName":"Safari","entities":{"appName":"Safari","goal":"open website","query":"https://cnn.com"},"normalizedEntities":{"appName":"Safari","goal":"open website","query":"https://cnn.com"},"confidence":0.94,"needsConfirmation":false,"actionPlan":{"tools":["app.openOrFocus","app.observe","ui.focusAddressBar","ui.setText","ui.pressReturn","app.verifyCommand"],"inputEntity":"query","controlID":"addressBar","focusKey":"Command+L","verification":"commandAttempted"},"metadata":{}}
                """,
                appName: "Safari",
                requiredTools: [.focusAddressBar, .setText, .pressReturn],
                queryContains: "cnn.com"
            ),
            (
                command: "write poem in notes",
                outputText: """
                {"taskType":"local_app_interaction","targetAppName":"Notes","entities":{"appName":"Notes","goal":"write a poem","query":"Morning light spills softly across the page,\\nA quiet thought wakes up and learns to sing."},"normalizedEntities":{"appName":"Notes","goal":"write a poem","query":"Morning light spills softly across the page,\\nA quiet thought wakes up and learns to sing."},"confidence":0.9,"needsConfirmation":false,"actionPlan":{"tools":["app.openOrFocus","app.observe","ui.newDocument","ui.setText","app.verifyCommand"],"inputEntity":"query","controlID":"editor","focusKey":"","verification":"commandAttempted"},"metadata":{}}
                """,
                appName: "Notes",
                requiredTools: [.newDocument, .setText],
                queryContains: "Morning light"
            ),
            (
                command: "create a table in numbers with the marketcap of the 10 largest companies in s&p",
                outputText: """
                {"taskType":"local_app_interaction","targetAppName":"Numbers","entities":{"appName":"Numbers","goal":"create spreadsheet table","query":"Company\\tMarket Cap\\nLargest S&P 500 companies\\tNeeds current market-cap data"},"normalizedEntities":{"appName":"Numbers","goal":"create spreadsheet table","query":"Company\\tMarket Cap\\nLargest S&P 500 companies\\tNeeds current market-cap data"},"confidence":0.86,"needsConfirmation":false,"actionPlan":{"tools":["app.openOrFocus","app.observe","ui.newDocument","ui.setText","app.verifyCommand"],"inputEntity":"query","controlID":"editor","focusKey":"","verification":"commandAttempted"},"metadata":{}}
                """,
                appName: "Numbers",
                requiredTools: [.newDocument, .setText],
                queryContains: "Market Cap"
            )
        ]

        for example in examples {
            let adapter = ProcessBackedLocalLLMTaskIntentAdapter(
                router: AIModelRouter(registry: .defaultHybridPlanner),
                sidecarRunner: FakeSidecarRunner(
                    result: LocalJSONSidecarResult(
                        status: .completed,
                        outputData: try localLLMSidecarOutputData(
                            outputText: example.outputText,
                            metadata: ["local.provider": "ollama-sidecar"]
                        ),
                        latencyMS: 14,
                        metadata: ["sidecar.role": "taskIntent"]
                    )
                )
            )

            let result = await adapter.parseTaskIntent(
                TaskIntentAdapterRequest(
                    command: example.command,
                    taskDefinitions: LocalAppTaskDefinitionLoader.runtimeSeedDefinitions,
                    contextSnippets: [
                        "Safari application com.apple.Safari",
                        "Notes application com.apple.Notes",
                        "Numbers application com.apple.iWork.Numbers"
                    ],
                    sourceTraceID: "trace-\(slug(example.appName))"
                )
            )

            let intent = try #require(result.intent)
            let actionPlan = try #require(intent.actionPlan)
            #expect(intent.taskType == "local_app_interaction")
            #expect(intent.normalizedEntities["appName"] == example.appName)
            #expect(intent.normalizedEntities["query"]?.contains(example.queryContains) == true)
            for tool in example.requiredTools {
                #expect(actionPlan.tools.contains(tool), "Expected \(example.command) to include \(tool.rawValue)")
            }
            #expect(result.trace.status == .completed)
        }
    }

    @Test
    func localModelTaskIntentResolverValidatesAgainstCatalogAvailability() async {
        let httpClient = FakeAIHTTPClient(
            data: ollamaResponseData(
                response: """
                {"taskType":"weather_lookup","targetAppName":"Weather","entities":{"city":"SF"},"normalizedEntities":{"city":"San Francisco"},"confidence":0.93,"needsConfirmation":false,"actionPlan":{"tools":[],"inputEntity":"","controlID":"","focusKey":"","verification":"commandAttempted"},"metadata":{}}
                """
            ),
            statusCode: 200
        )
        let resolver = LocalModelTaskIntentResolver(
            catalog: LocalAppTaskCatalog(
                taskDefinitions: BuiltInLocalAppTaskDefinitions.benchmarkFixtures,
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
    func localModelTaskIntentResolverResolvesDynamicLocalItemLookup() async {
        let httpClient = FakeAIHTTPClient(
            data: ollamaResponseData(
                response: """
                {"taskType":"app_open","targetAppName":"Figma","entities":{"appName":"figma"},"normalizedEntities":{"appName":"Figma"},"confidence":0.94,"needsConfirmation":false,"actionPlan":{"tools":[],"inputEntity":"","controlID":"","focusKey":"","verification":"commandAttempted"},"metadata":{}}
                """
            ),
            statusCode: 200
        )
        let resolver = LocalModelTaskIntentResolver(
            catalog: LocalAppTaskCatalog(
                taskDefinitions: BuiltInLocalAppTaskDefinitions.benchmarkFixtures,
                availabilityProvider: StaticLocalAppAvailabilityProvider(
                    installedBundleIdentifiers: ["com.figma.Desktop"],
                    installedApplicationNames: ["Figma": "com.figma.Desktop"]
                )
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
            command: "open figma",
            sourceTraceID: "trace-resolve-local-item"
        )

        #expect(result.resolution.status == .resolved)
        #expect(result.resolution.definition?.taskType == "app_open")
        #expect(result.resolution.intent?.targetApp.appName == "Figma")
        #expect(result.resolution.intent?.normalizedEntities["appName"] == "Figma")
        #expect(result.resolution.metadata["lookupProvider"] == "static")
    }

    @Test
    func localModelTaskIntentResolverDoesNotParseCommandTextWhenRuntimeUnavailable() async {
        let resolver = LocalModelTaskIntentResolver(
            catalog: LocalAppTaskCatalog(
                taskDefinitions: BuiltInLocalAppTaskDefinitions.benchmarkFixtures,
                availabilityProvider: StaticLocalAppAvailabilityProvider(installedBundleIdentifiers: ["com.apple.weather"])
            ),
            adapter: UnavailableTaskIntentAdapter()
        )

        let result = await resolver.resolve(
            command: "show me the weather for SF",
            sourceTraceID: "trace-resolve-fallback"
        )

        #expect(result.resolution.status == .needsConfirmation)
        #expect(result.resolution.intent == nil)
        #expect(result.resolution.metadata["reason"] == "localModelIntentUnavailable")
        #expect(result.resolution.metadata["modelCallStatus"] == "providerOutage")
        #expect(result.trace.validationStatus == "notValidated")
        #expect(result.trace.metadata["fallback.reason"] == nil)
    }

    @Test
    func localModelTaskIntentResolverAsksForDetailsInsteadOfUnsupportedWhenRuntimeUnavailable() async {
        let resolver = LocalModelTaskIntentResolver(
            catalog: LocalAppTaskCatalog(
                taskDefinitions: BuiltInLocalAppTaskDefinitions.benchmarkFixtures,
                availabilityProvider: StaticLocalAppAvailabilityProvider(installedBundleIdentifiers: ["com.apple.weather"])
            ),
            adapter: UnavailableTaskIntentAdapter()
        )

        let result = await resolver.resolve(
            command: "do the thing with that value",
            sourceTraceID: "trace-resolve-clarify"
        )

        #expect(result.resolution.status == .needsConfirmation)
        #expect(result.resolution.metadata["reason"] == "localModelIntentUnavailable")
        #expect(result.resolution.metadata["modelCallStatus"] == "providerOutage")
    }

    @Test
    func localModelTaskIntentResolverAcceptsClosestLowConfidenceClassification() async {
        let httpClient = FakeAIHTTPClient(
            data: ollamaResponseData(
                response: """
                {"taskType":"weather_lookup","targetAppName":"Weather","entities":{},"normalizedEntities":{},"confidence":0.2,"needsConfirmation":false,"actionPlan":{"tools":[],"inputEntity":"","controlID":"","focusKey":"","verification":"commandAttempted"},"metadata":{}}
                """
            ),
            statusCode: 200
        )
        let resolver = LocalModelTaskIntentResolver(
            catalog: LocalAppTaskCatalog(
                taskDefinitions: BuiltInLocalAppTaskDefinitions.benchmarkFixtures,
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
            command: "banana",
            sourceTraceID: "trace-low-confidence"
        )

        #expect(result.resolution.status == .needsConfirmation)
        #expect(result.resolution.intent?.taskType == "weather_lookup")
        #expect(result.resolution.metadata["reason"] == "city")
    }

    @Test
    func localModelTaskIntentResolverPreservesConversationResponseForMalformedTask() async {
        let httpClient = FakeAIHTTPClient(
            data: ollamaResponseData(
                response: """
                {"taskType":"local_app_interaction","targetAppName":"Notes","entities":{"appName":"Notes","goal":"unclear writing request"},"normalizedEntities":{"appName":"Notes","goal":"unclear writing request"},"confidence":0.2,"needsConfirmation":false,"actionPlan":{"tools":[],"inputEntity":"query","controlID":"","focusKey":"","verification":"commandAttempted"},"metadata":{"responseMode":"conversation","assistantResponse":"I can help with that, but I need a clearer thing to write before opening Notes."}}
                """
            ),
            statusCode: 200
        )
        let resolver = LocalModelTaskIntentResolver(
            catalog: LocalAppTaskCatalog(
                taskDefinitions: LocalAppTaskDefinitionLoader.runtimeSeedDefinitions,
                availabilityProvider: StaticLocalAppAvailabilityProvider(installedBundleIdentifiers: ["com.apple.Notes"])
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
            command: "write a people in notes",
            sourceTraceID: "trace-malformed-writing"
        )

        #expect(result.resolution.status == .needsConfirmation)
        #expect(result.resolution.metadata["reason"] == "lowConfidenceIntent")
        #expect(result.resolution.metadata["responseMode"] == "conversation")
        #expect(result.resolution.metadata["assistantResponse"]?.contains("clearer thing to write") == true)
    }

    @Test
    func taskIntentDecoderRoutesShortUnquotedDocumentPayloadToConversation() async throws {
        let adapter = ProcessBackedLocalLLMTaskIntentAdapter(
            router: AIModelRouter(registry: .defaultHybridPlanner),
            sidecarRunner: FakeSidecarRunner(
                result: LocalJSONSidecarResult(
                    status: .completed,
                    outputData: try localLLMSidecarOutputData(
                        outputText: """
                        {"taskType":"local_app_interaction","targetAppName":"Notes","entities":{"appName":"Notes","goal":"write requested text","query":"a people"},"normalizedEntities":{"appName":"Notes","goal":"write requested text","query":"a people"},"confidence":0.9,"needsConfirmation":false,"actionPlan":{"tools":["app.openOrFocus","ui.newDocument","ui.setText"],"inputEntity":"query","controlID":"editor","focusKey":"","verification":"commandAttempted"},"metadata":{}}
                        """,
                        metadata: ["local.provider": "ollama-sidecar"]
                    ),
                    latencyMS: 14,
                    metadata: ["sidecar.role": "taskIntent"]
                )
            )
        )

        let result = await adapter.parseTaskIntent(
            TaskIntentAdapterRequest(
                command: "write a people in notes",
                taskDefinitions: LocalAppTaskDefinitionLoader.runtimeSeedDefinitions,
                contextSnippets: ["Notes application com.apple.Notes"],
                sourceTraceID: "trace-short-document-payload"
            )
        )

        #expect(result.intent?.confidence == 0.2)
        #expect(result.intent?.actionPlan == nil)
        #expect(result.intent?.metadata["responseMode"] == "conversation")
        #expect(result.intent?.metadata["notActionableReason"] == "insufficientDocumentPayload")
        #expect(result.intent?.metadata["assistantResponse"]?.contains("clearer thing to write") == true)
    }

    @Test
    func taskIntentDecoderKeepsShortQuotedDocumentPayloadActionable() async throws {
        let adapter = ProcessBackedLocalLLMTaskIntentAdapter(
            router: AIModelRouter(registry: .defaultHybridPlanner),
            sidecarRunner: FakeSidecarRunner(
                result: LocalJSONSidecarResult(
                    status: .completed,
                    outputData: try localLLMSidecarOutputData(
                        outputText: """
                        {"taskType":"local_app_interaction","targetAppName":"Notes","entities":{"appName":"Notes","goal":"write requested text","query":"hello"},"normalizedEntities":{"appName":"Notes","goal":"write requested text","query":"hello"},"confidence":0.9,"needsConfirmation":false,"actionPlan":{"tools":["app.openOrFocus","ui.newDocument","ui.setText"],"inputEntity":"query","controlID":"editor","focusKey":"","verification":"commandAttempted"},"metadata":{}}
                        """,
                        metadata: ["local.provider": "ollama-sidecar"]
                    ),
                    latencyMS: 14,
                    metadata: ["sidecar.role": "taskIntent"]
                )
            )
        )

        let result = await adapter.parseTaskIntent(
            TaskIntentAdapterRequest(
                command: "write \"hello\" in notes",
                taskDefinitions: LocalAppTaskDefinitionLoader.runtimeSeedDefinitions,
                contextSnippets: ["Notes application com.apple.Notes"],
                sourceTraceID: "trace-quoted-document-payload"
            )
        )

        #expect(result.intent?.confidence == 0.9)
        #expect(result.intent?.actionPlan?.tools.contains(.setText) == true)
        #expect(result.intent?.metadata["responseMode"] == nil)
    }

    @Test
    func taskIntentDecoderRoutesCopiedPromptPlaceholderToConversation() async throws {
        let adapter = ProcessBackedLocalLLMTaskIntentAdapter(
            router: AIModelRouter(registry: .defaultHybridPlanner),
            sidecarRunner: FakeSidecarRunner(
                result: LocalJSONSidecarResult(
                    status: .completed,
                    outputData: try localLLMSidecarOutputData(
                        outputText: """
                        {"taskType":"local_app_interaction","targetAppName":"Notes","entities":{"appName":"Notes","goal":"write requested text","query":"A complete piece of text generated for the user writing request."},"normalizedEntities":{"appName":"Notes","goal":"write requested text","query":"A complete piece of text generated for the user writing request."},"confidence":0.9,"needsConfirmation":false,"actionPlan":{"tools":["app.openOrFocus","ui.newDocument","ui.setText"],"inputEntity":"query","controlID":"editor","focusKey":"","verification":"commandAttempted"},"metadata":{}}
                        """,
                        metadata: ["local.provider": "ollama-sidecar"]
                    ),
                    latencyMS: 14,
                    metadata: ["sidecar.role": "taskIntent"]
                )
            )
        )

        let result = await adapter.parseTaskIntent(
            TaskIntentAdapterRequest(
                command: "write a people in notes",
                taskDefinitions: LocalAppTaskDefinitionLoader.runtimeSeedDefinitions,
                contextSnippets: ["Notes application com.apple.Notes"],
                sourceTraceID: "trace-placeholder-document-payload"
            )
        )

        #expect(result.intent?.confidence == 0.2)
        #expect(result.intent?.actionPlan == nil)
        #expect(result.intent?.metadata["responseMode"] == "conversation")
        #expect(result.intent?.metadata["notActionableReason"] == "promptPlaceholderPayload")
    }

    @Test
    func taskIntentDecoderRoutesEmptyTextInputPlanToConversation() async throws {
        let adapter = ProcessBackedLocalLLMTaskIntentAdapter(
            router: AIModelRouter(registry: .defaultHybridPlanner),
            sidecarRunner: FakeSidecarRunner(
                result: LocalJSONSidecarResult(
                    status: .completed,
                    outputData: try localLLMSidecarOutputData(
                        outputText: """
                        {"taskType":"local_app_interaction","targetAppName":"Notes","entities":{"appName":"Notes","goal":"write requested text","query":""},"normalizedEntities":{"appName":"Notes","goal":"write requested text","query":""},"confidence":0.9,"needsConfirmation":false,"actionPlan":{"tools":["app.openOrFocus","ui.newDocument","ui.setText"],"inputEntity":"query","controlID":"editor","focusKey":"","verification":"commandAttempted"},"metadata":{}}
                        """,
                        metadata: ["local.provider": "ollama-sidecar"]
                    ),
                    latencyMS: 14,
                    metadata: ["sidecar.role": "taskIntent"]
                )
            )
        )

        let result = await adapter.parseTaskIntent(
            TaskIntentAdapterRequest(
                command: "write poem in notes",
                taskDefinitions: LocalAppTaskDefinitionLoader.runtimeSeedDefinitions,
                contextSnippets: ["Notes application com.apple.Notes"],
                sourceTraceID: "trace-empty-document-payload"
            )
        )

        #expect(result.intent?.confidence == 0.2)
        #expect(result.intent?.actionPlan == nil)
        #expect(result.intent?.metadata["responseMode"] == "conversation")
        #expect(result.intent?.metadata["notActionableReason"] == "missingTextPayload")
    }

    @Test
    func taskIntentDecoderRepairsSentenceSpreadsheetPayloadIntoTableText() async throws {
        let adapter = ProcessBackedLocalLLMTaskIntentAdapter(
            router: AIModelRouter(registry: .defaultHybridPlanner),
            sidecarRunner: FakeSidecarRunner(
                result: LocalJSONSidecarResult(
                    status: .completed,
                    outputData: try localLLMSidecarOutputData(
                        outputText: """
                        {"taskType":"local_app_interaction","targetAppName":"Numbers","entities":{"appName":"Numbers","goal":"create requested table","query":"Market capital of the 10 largest companies in S&P"},"normalizedEntities":{"appName":"Numbers","goal":"create requested table","query":"Market capital of the 10 largest companies in S&P"},"confidence":0.9,"needsConfirmation":false,"actionPlan":{"tools":["app.openOrFocus","app.observe","ui.newDocument","ui.setText"],"inputEntity":"query","controlID":"editor","focusKey":"","verification":"commandAttempted"},"metadata":{}}
                        """,
                        metadata: ["local.provider": "ollama-sidecar"]
                    ),
                    latencyMS: 14,
                    metadata: ["sidecar.role": "taskIntent"]
                )
            )
        )

        let result = await adapter.parseTaskIntent(
            TaskIntentAdapterRequest(
                command: "create a table in numbers with the marketcap of the 10 largest companies in s&p",
                taskDefinitions: LocalAppTaskDefinitionLoader.runtimeSeedDefinitions,
                contextSnippets: ["Numbers application com.apple.iWork.Numbers"],
                sourceTraceID: "trace-repaired-table-payload"
            )
        )

        #expect(result.intent?.actionPlan?.tools.contains(.setText) == true)
        #expect(result.intent?.metadata["modelPlan.repairedTableText"] == "true")
        #expect(result.intent?.normalizedEntities["query"]?.contains("Request\tStatus") == true)
        #expect(result.intent?.normalizedEntities["query"]?.contains("Market capital") == true)
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
    func openAIAdapterIncludesSelectedSemanticMemoryInPrompt() async throws {
        let httpClient = FakeAIHTTPClient(
            data: responseData(
                outputText: """
                {"id":"hint-semantic","goal":"avoid hazards","policyName":"planner-policy","priorities":["center lane"],"preferredActions":["wait"],"avoidActions":[],"confidence":0.82,"expiryMilliseconds":5000}
                """
            ),
            statusCode: 200
        )
        let adapter = OpenAIPlannerHintAdapter(
            router: AIModelRouter(registry: AIModelRegistry(entries: [entry(id: "planner", modelID: "gpt-5.2")])),
            httpClient: httpClient,
            environment: ["OPENAI_API_KEY": "test-key"],
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
    func openAIAdapterPersistsProviderMemoryProposalsWithValidatedHint() async throws {
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
        let adapter = OpenAIPlannerHintAdapter(
            router: AIModelRouter(registry: AIModelRegistry(entries: [entry(id: "planner", modelID: "gpt-5.2")])),
            httpClient: httpClient,
            environment: ["OPENAI_API_KEY": "test-key"],
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
    func openAIAdapterKeepsHintWhenMemoryProposalPayloadIsMalformed() async {
        let httpClient = FakeAIHTTPClient(
            data: responseData(
                outputText: """
                {"hint":{"id":"hint-only","goal":"recover","policyName":"planner-policy","priorities":["observe"],"preferredActions":["wait"],"avoidActions":[],"confidence":0.82,"expiryMilliseconds":5000},"memoryWriteProposals":[{}]}
                """
            ),
            statusCode: 200
        )
        let adapter = OpenAIPlannerHintAdapter(
            router: AIModelRouter(registry: AIModelRegistry(entries: [entry(id: "planner", modelID: "gpt-5.2")])),
            httpClient: httpClient,
            environment: ["OPENAI_API_KEY": "test-key"],
            memoryStore: nil
        )

        let result = await adapter.generatePlannerHint(adapterRequest())

        #expect(result.hint?.id == "hint-only")
        #expect(result.trace.status == .completed)
        #expect(result.memoryWriteDecisions.isEmpty)
        #expect(result.trace.metadata["memoryProposal.decodeStatus"] == "invalid")
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

private func localLLMSidecarOutputData(
    outputText: String,
    metadata: [String: String]
) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "outputText": outputText,
            "metadata": metadata
        ]
    )
}

private func slug(_ value: String) -> String {
    LocalAppTaskIntentParser.normalizedPhrase(value)
        .split(separator: " ")
        .joined(separator: "-")
}

private struct UnavailableTaskIntentAdapter: TaskIntentParsingAdapter {
    func parseTaskIntent(_ request: TaskIntentAdapterRequest) async -> TaskIntentAdapterResult {
        TaskIntentAdapterResult(
            intent: nil,
            trace: AIModelCallTrace(
                id: "model-call-unavailable",
                role: .taskIntent,
                provider: .localRuntime,
                modelID: "qwen3:8b",
                promptVersion: "task-intent-v1",
                schemaID: "task_intent_v1",
                latencyMS: nil,
                timeoutMS: 4_000,
                status: .providerOutage,
                validationStatus: "notValidated",
                sourceTraceID: request.sourceTraceID,
                metadata: ["reason": "runtimeUnavailable"]
            )
        )
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
