import DonkeyContracts
@testable import DonkeyRuntime
import Testing

@Suite
struct RunCoordinatorTests {
    @Test
    func coordinatorLifecycleEmitsOrderedEvents() async {
        let coordinator = RunCoordinator()

        let ticket = await coordinator.start(
            RunSession(
                id: "session-1",
                userGoal: "tap when ready",
                targetID: "target-1"
            )
        )
        #expect(ticket?.session.id == "session-1")

        await coordinator.pause(reason: "operator paused")
        await coordinator.resume(reason: "operator resumed")
        await coordinator.complete(reason: "done")

        let events = await coordinator.events()
        #expect(events.map(\.sequence) == [1, 2, 3, 4, 5, 6])
        #expect(lifecycleStates(in: events) == [
            .starting,
            .running,
            .paused,
            .running,
            .stopping,
            .completed
        ])

        let snapshot = await coordinator.snapshot()
        #expect(snapshot.lifecycleState == .completed)
        #expect(snapshot.eventCount == 6)
        #expect(snapshot.latestEventSummary == "Run completed")
    }

    @Test
    func abortEmitsTerminalLifecycleEventAndRequestsInputRelease() async {
        let coordinator = RunCoordinator()

        _ = await coordinator.start(
            RunSession(
                id: "session-abort",
                userGoal: "run until stopped",
                targetID: "target-1"
            )
        )
        await coordinator.abort(reason: "stop requested")

        let events = await coordinator.events()
        #expect(lifecycleStates(in: events).last == .aborted)
        #expect(events.last?.requiresInputRelease == true)

        let snapshot = await coordinator.snapshot()
        #expect(snapshot.lifecycleState == .aborted)
        #expect(snapshot.requiresInputRelease == true)
    }

    @Test
    func timeoutDoesNotCreateInputActionAndRequestsInputRelease() async {
        let coordinator = RunCoordinator()

        _ = await coordinator.start(
            RunSession(
                id: "session-timeout",
                userGoal: "run with deadline",
                targetID: "target-1"
            )
        )
        await coordinator.timeout(reason: "deadline exceeded")

        let events = await coordinator.events()
        #expect(lifecycleStates(in: events).last == .timedOut)
        #expect(events.last?.requiresInputRelease == true)
        #expect(!events.contains { event in
            guard case .tool(let payload) = event.payload else { return false }
            return payload.capability == .input
        })
    }

    @Test
    func waitIfPausedBlocksUntilResume() async {
        let coordinator = RunCoordinator()

        _ = await coordinator.start(
            RunSession(
                id: "session-paused-gate",
                userGoal: "wait while paused",
                targetID: "target-1"
            )
        )
        await coordinator.pause(reason: "operator paused")

        let gate = Task {
            await coordinator.waitIfPaused()
            return true
        }
        let completedBeforeResume = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await gate.value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 50_000_000)
                return false
            }
            let firstResult = await group.next() ?? false
            group.cancelAll()
            return firstResult
        }
        #expect(completedBeforeResume == false)

        await coordinator.resume(reason: "operator resumed")
        #expect(await gate.value == true)
    }

    @Test
    func latestSessionQueueDropsStaleSessions() async {
        let queue = LatestRunSessionQueue()
        await queue.submit(
            RunSession(id: "stale", userGoal: "old goal", targetID: "target-1")
        )
        await queue.submit(
            RunSession(id: "latest", userGoal: "new goal", targetID: "target-1")
        )

        let ticket = await queue.nextLatest()

        #expect(ticket?.session.id == "latest")
        #expect(ticket?.droppedBeforeStartCount == 1)
        #expect(await queue.nextLatest() == nil)
    }

    @Test
    func permissionPolicyDeniesInputByDefault() async {
        let coordinator = RunCoordinator()

        _ = await coordinator.start(
            RunSession(
                id: "session-policy",
                userGoal: "try input",
                targetID: "target-1"
            )
        )

        let decision = await coordinator.recordToolCall(
            capability: .input,
            toolName: "synthetic-input"
        )

        #expect(!decision.isAllowed)

        let events = await coordinator.events()
        #expect(events.last?.stream == .tool)
        guard case .tool(let payload) = events.last?.payload else {
            Issue.record("Expected a tool event")
            return
        }
        #expect(payload.capability == .input)
        #expect(!payload.decision.isAllowed)
    }

    @Test
    func eventStorePreservesAppendOrderAcrossStreams() async {
        let store = InMemoryRunEventStore()

        await store.append(
            RunEvent(
                stream: .assistant,
                summary: "assistant",
                payload: .assistant(AssistantRunEvent(message: "thinking"))
            )
        )
        await store.append(
            RunEvent(
                stream: .tool,
                summary: "tool",
                payload: .tool(
                    ToolRunEvent(
                        capability: .capture,
                        decision: .allow
                    )
                )
            )
        )
        await store.append(
            RunEvent(
                stream: .lifecycle,
                summary: "lifecycle",
                payload: .lifecycle(LifecycleRunEvent(state: .running))
            )
        )
        await store.append(
            RunEvent(
                stream: .reflex,
                summary: "reflex",
                payload: .reflex(ReflexRunEvent(frameID: "frame-1"))
            )
        )

        let events = await store.allEvents()
        #expect(events.map(\.sequence) == [1, 2, 3, 4])
        #expect(events.map(\.stream) == [.assistant, .tool, .lifecycle, .reflex])
    }

    @Test
    func contextAssemblerBoundsTranscriptAndPreservesCurrentContext() {
        let assembler = RunContextAssembler(maxTranscriptCharacters: 10)
        let session = RunSession(
            id: "session-context",
            userGoal: "avoid hazards",
            targetID: "subway-surfers",
            runtimeProfile: "iphone-mirroring"
        )
        let worldState = RunWorldStateSummary(
            stateID: "state-1",
            summary: "player in center lane",
            confidence: 0.9
        )
        let context = assembler.build(
            session: session,
            latestWorldState: worldState,
            transcriptSummary: "0123456789abcdef",
            activeHints: [
                RunPlannerHint(id: "hint-1", summary: "prefer center", isValid: true),
                RunPlannerHint(id: "hint-2", summary: "expired", isValid: false)
            ],
            recentFailures: [
                RunFailureSummary(traceID: "trace-1", summary: "missed left hazard")
            ]
        )

        #expect(context.sessionID == "session-context")
        #expect(context.userGoal == "avoid hazards")
        #expect(context.targetID == "subway-surfers")
        #expect(context.runtimeProfile == "iphone-mirroring")
        #expect(context.latestWorldState == worldState)
        #expect(context.transcriptSummary == "6789abcdef")
        #expect(context.droppedTranscriptCharacterCount == 6)
        #expect(context.activeHints.map(\.id) == ["hint-1"])
        #expect(context.recentFailures.map(\.traceID) == ["trace-1"])
    }

    private func lifecycleStates(in events: [RunEvent]) -> [RunLifecycleState] {
        events.compactMap { event in
            guard case .lifecycle(let payload) = event.payload else { return nil }
            return payload.state
        }
    }
}
