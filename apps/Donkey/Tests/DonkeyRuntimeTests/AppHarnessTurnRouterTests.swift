import DonkeyContracts
import DonkeyRuntime
import Testing

@Suite
struct AppHarnessTurnRouterTests {
    @Test
    func greetingRoutesToConversationWithoutTaskExecution() {
        let result = router().route(
            request: AppHarnessTurnRequest(
                turn: AppHarnessTurn(text: "hi", source: .typedPrompt)
            ),
            traceID: "trace-chat"
        )

        #expect(result.outcome.kind == .conversation)
        #expect(result.outcome.resolution == nil)
        #expect(result.outcome.assistantResponse?.contains("local app task") == true)
    }

    @Test
    func actionableWeatherRequestRoutesThroughCatalog() {
        let result = router().route(
            request: AppHarnessTurnRequest(
                turn: AppHarnessTurn(text: "show me the weather for SF", source: .typedPrompt)
            ),
            traceID: "trace-action"
        )

        #expect(result.outcome.kind == .actionableIntent)
        #expect(result.outcome.resolution?.status == .resolved)
        #expect(result.outcome.resolution?.intent?.normalizedEntities["city"] == "San Francisco")
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
        #expect(result.outcome.kind == .actionableIntent)
        #expect(result.outcome.resolution?.status == .resolved)
        #expect(result.outcome.resolution?.intent?.normalizedEntities["city"] == "San Francisco")
    }

    @Test
    func ambiguousWeatherRequestAsksForSpecificMissingDetail() {
        let result = router().route(
            request: AppHarnessTurnRequest(
                turn: AppHarnessTurn(text: "show weather", source: .typedPrompt)
            ),
            traceID: "trace-clarify"
        )

        #expect(result.outcome.kind == .clarification)
        #expect(result.outcome.missingDetail == "city")
        #expect(result.outcome.assistantResponse == "Which city should I use?")
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
                    PointerPromptTaskEvent(
                        id: "event-1",
                        taskID: "task-1",
                        role: .user,
                        text: "older event should be excluded",
                        sequence: 0
                    ),
                    PointerPromptTaskEvent(
                        id: "event-2",
                        taskID: "task-1",
                        role: .assistant,
                        text: "contact me at helper@example.com",
                        sequence: 1
                    ),
                    PointerPromptTaskEvent(
                        id: "event-3",
                        taskID: "task-1",
                        role: .user,
                        text: String(repeating: "long ", count: 80),
                        sequence: 2
                    )
                ],
                assets: [
                    PointerPromptTaskAsset(
                        id: "asset-1",
                        taskID: "task-1",
                        source: .userUploaded,
                        displayName: "old.pdf",
                        contentType: "application/pdf",
                        urlString: "file:///tmp/old.pdf"
                    ),
                    PointerPromptTaskAsset(
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
    }

    private func router(
        limits: AppHarnessContextPacketLimits = AppHarnessContextPacketLimits()
    ) -> AppHarnessTurnRouter {
        AppHarnessTurnRouter(
            catalog: LocalAppTaskCatalog(
                taskDefinitions: BuiltInLocalAppTaskDefinitions.defaults,
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
