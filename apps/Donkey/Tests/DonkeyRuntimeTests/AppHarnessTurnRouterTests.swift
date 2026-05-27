import DonkeyContracts
import DonkeyRuntime
import Testing

@Suite
struct AppHarnessTurnRouterTests {
    @Test
    func greetingDefersToModelIntentClassifierWithoutWordScanning() {
        let result = router().route(
            request: AppHarnessTurnRequest(
                turn: AppHarnessTurn(text: "hi there", source: .typedPrompt)
            ),
            traceID: "trace-chat"
        )

        #expect(result.outcome.decision.kind == .runLocalTask)
        #expect(result.outcome.decision.traceID == "trace-chat")
        #expect(result.outcome.metadata["router"] == "modelIntent")
        #expect(result.outcome.resolution == nil)
        #expect(result.outcome.assistantResponse == nil)
    }

    @Test
    func arithmeticQuestionAlsoDefersToModelIntentRouting() {
        let result = router().route(
            request: AppHarnessTurnRequest(
                turn: AppHarnessTurn(text: "What is 2+2?", source: .typedPrompt)
            ),
            traceID: "trace-math"
        )

        #expect(result.outcome.decision.kind == .runLocalTask)
        #expect(result.outcome.metadata["router"] == "modelIntent")
        #expect(result.outcome.resolution == nil)
        #expect(result.outcome.assistantResponse == nil)
    }

    @Test
    func openMusicDefersToModelIntentRouting() {
        let result = router().route(
            request: AppHarnessTurnRequest(
                turn: AppHarnessTurn(text: "open music", source: .typedPrompt)
            ),
            traceID: "trace-open-music"
        )

        #expect(result.outcome.decision.kind == .runLocalTask)
        #expect(result.outcome.metadata["router"] == "modelIntent")
        #expect(result.outcome.resolution == nil)
    }

    @Test
    func missingAppOpenDefersToModelIntentRouting() {
        let result = router().route(
            request: AppHarnessTurnRequest(
                turn: AppHarnessTurn(text: "open Imaginary App", source: .typedPrompt)
            ),
            traceID: "trace-missing-app"
        )

        #expect(result.outcome.decision.kind == .runLocalTask)
        #expect(result.outcome.metadata["router"] == "modelIntent")
        #expect(result.outcome.resolution == nil)
    }

    @Test
    func actionableWeatherRequestDefersToModelIntentRouting() {
        let result = router().route(
            request: AppHarnessTurnRequest(
                turn: AppHarnessTurn(text: "show me the weather for SF", source: .typedPrompt)
            ),
            traceID: "trace-action"
        )

        #expect(result.outcome.decision.kind == .runLocalTask)
        #expect(result.outcome.metadata["router"] == "modelIntent")
        #expect(result.outcome.resolution == nil)
    }

    @Test
    func voiceTranscriptRoutesThroughSameHarnessPathAsTypedText() {
        let result = router().route(
            request: AppHarnessTurnRequest(
                turn: AppHarnessTurn(text: "show me the weather for SF", source: .voiceTranscript)
            ),
            traceID: "trace-voice-action"
        )

        #expect(result.contextPacket.currentTurn.source == .voiceTranscript)
        #expect(result.outcome.decision.kind == .runLocalTask)
        #expect(result.outcome.metadata["router"] == "modelIntent")
        #expect(result.outcome.resolution == nil)
    }

    @Test
    func ambiguousWeatherRequestAlsoRequiresModelIntent() {
        let result = router().route(
            request: AppHarnessTurnRequest(
                turn: AppHarnessTurn(text: "show weather", source: .typedPrompt)
            ),
            traceID: "trace-clarify"
        )

        #expect(result.outcome.decision.kind == .runLocalTask)
        #expect(result.outcome.metadata["router"] == "modelIntent")
        #expect(result.outcome.resolution == nil)
    }

    @Test
    func followUpTurnKeepsRecentThreadContextBoundedAndRedacted() {
        let limits = AppHarnessContextPacketLimits(
            maxRecentEvents: 2,
            maxAssets: 1,
            maxEventTextCharacters: 64,
            maxAssetNameCharacters: 32,
            maxPromptCharacters: 420
        )
        let result = router(limits: limits).route(
            request: AppHarnessTurnRequest(
                turn: AppHarnessTurn(
                    text: "use token=secret123 and david@example.com",
                    source: .followUp,
                    taskID: "task-1",
                    isFollowUp: true
                ),
                recentEvents: [
                    UserQueryTaskEvent(
                        id: "event-1",
                        taskID: "task-1",
                        role: .user,
                        text: "older event should be excluded",
                        sequence: 0
                    ),
                    UserQueryTaskEvent(
                        id: "event-2",
                        taskID: "task-1",
                        role: .assistant,
                        text: "contact me at helper@example.com",
                        sequence: 1
                    ),
                    UserQueryTaskEvent(
                        id: "event-3",
                        taskID: "task-1",
                        role: .user,
                        text: String(repeating: "long ", count: 80),
                        sequence: 2
                    )
                ],
                assets: [
                    UserQueryTaskAsset(
                        id: "asset-1",
                        taskID: "task-1",
                        source: .userUploaded,
                        displayName: "old.pdf",
                        contentType: "application/pdf",
                        urlString: "file:///tmp/old.pdf"
                    ),
                    UserQueryTaskAsset(
                        id: "asset-2",
                        taskID: "task-1",
                        source: .userUploaded,
                        displayName: "current-document-with-a-very-long-name.pdf",
                        contentType: "application/pdf",
                        urlString: "file:///tmp/current.pdf"
                    )
                ]
            ),
            traceID: "trace-context"
        )

        #expect(result.contextPacket.recentEvents.count == 2)
        #expect(result.contextPacket.assets.count == 1)
        #expect(result.contextPacket.promptText.count <= 423)
        #expect(!result.contextPacket.promptText.contains("david@example.com"))
        #expect(!result.contextPacket.promptText.contains("helper@example.com"))
        #expect(!result.contextPacket.promptText.contains("secret123"))
        #expect(result.contextPacket.promptText.contains("[redacted-email]"))
        #expect(result.contextPacket.promptText.contains("[redacted-secret]"))
        #expect(result.contextPacket.redactionCount == 3)
        #expect(result.contextPacket.compactionRecords.contains {
            $0.itemKind == .recentEvent && $0.originalCount == 3 && $0.includedCount == 2
        })
    }

    @Test
    func contextCompactionDoesNotInferTransientCorrectionsFromText() {
        let limits = AppHarnessContextPacketLimits(
            maxRecentEvents: 2,
            maxAssets: 0,
            maxPromptCharacters: 600
        )
        let result = router(limits: limits).route(
            request: AppHarnessTurnRequest(
                turn: AppHarnessTurn(text: "thanks", source: .typedPrompt),
                recentEvents: [
                    UserQueryTaskEvent(
                        id: "event-1",
                        taskID: "task-1",
                        role: .assistant,
                        text: "Retry nudge: invalid output, try again.",
                        sequence: 1
                    ),
                    UserQueryTaskEvent(
                        id: "event-2",
                        taskID: "task-1",
                        role: .user,
                        text: "show me the weather for SF",
                        sequence: 2
                    ),
                    UserQueryTaskEvent(
                        id: "event-3",
                        taskID: "task-1",
                        role: .assistant,
                        text: "Opening Weather for San Francisco.",
                        sequence: 3
                    )
                ]
            ),
            traceID: "trace-typed-compaction"
        )

        #expect(result.contextPacket.recentEvents.map(\.sequence) == [2, 3])
        #expect(result.contextPacket.metadata["events.droppedTransientCorrectionCount"] == "0")
        #expect(result.contextPacket.compactionRecords.contains {
            $0.itemKind == .transientCorrection && $0.droppedCount == 0
        })
    }

    private func router(
        limits: AppHarnessContextPacketLimits = AppHarnessContextPacketLimits()
    ) -> AppHarnessTurnRouter {
        AppHarnessTurnRouter(
            catalog: LocalAppTaskCatalog(
                taskDefinitions: BuiltInLocalAppTaskDefinitions.testFixtures,
                availabilityProvider: StaticLocalAppAvailabilityProvider(
                    installedBundleIdentifiers: [
                        "com.apple.weather",
                        "com.apple.Music",
                        "com.adobe.Reader"
                    ]
                )
            ),
            contextBuilder: AppHarnessContextPacketBuilder(limits: limits)
        )
    }
}
