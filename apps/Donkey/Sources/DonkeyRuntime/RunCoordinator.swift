import DonkeyContracts
import Foundation

public actor RunCoordinator {
    private let sessionQueue: LatestRunSessionQueue
    private let eventStore: InMemoryRunEventStore
    private let contextAssembler: RunContextAssembler
    private var currentSession: RunSession?
    private var lifecycleState: RunLifecycleState = .idle
    private var requiresInputRelease = false

    public init(
        sessionQueue: LatestRunSessionQueue = LatestRunSessionQueue(),
        eventStore: InMemoryRunEventStore = InMemoryRunEventStore(),
        contextAssembler: RunContextAssembler = RunContextAssembler()
    ) {
        self.sessionQueue = sessionQueue
        self.eventStore = eventStore
        self.contextAssembler = contextAssembler
    }

    public func submit(_ session: RunSession) async {
        await sessionQueue.submit(session)
    }

    @discardableResult
    public func startNext() async -> RunSessionTicket? {
        guard let ticket = await sessionQueue.nextLatest() else { return nil }

        currentSession = ticket.session
        await transition(to: .starting, reason: "Run session accepted")
        await transition(to: .running, reason: "Run session started")

        if ticket.droppedBeforeStartCount > 0 {
            await appendAssistantEvent(
                summary: "Dropped \(ticket.droppedBeforeStartCount) stale run session(s)",
                message: "Latest-session queue kept the newest run request."
            )
        }

        return ticket
    }

    @discardableResult
    public func start(_ session: RunSession) async -> RunSessionTicket? {
        await submit(session)
        return await startNext()
    }

    public func pause(reason: String? = nil) async {
        await transition(to: .paused, reason: reason ?? "Run paused")
    }

    public func resume(reason: String? = nil) async {
        await transition(to: .running, reason: reason ?? "Run resumed")
    }

    public func complete(reason: String? = nil) async {
        await transition(to: .stopping, reason: "Run stopping before completion")
        await transition(to: .completed, reason: reason ?? "Run completed")
    }

    public func abort(reason: String? = nil) async {
        requiresInputRelease = true
        await transition(
            to: .aborted,
            reason: reason ?? "Run aborted",
            requiresInputRelease: true
        )
    }

    public func timeout(reason: String? = nil) async {
        requiresInputRelease = true
        await transition(
            to: .timedOut,
            reason: reason ?? "Run timed out",
            requiresInputRelease: true
        )
    }

    public func fail(reason: String? = nil) async {
        await transition(to: .failed, reason: reason ?? "Run failed")
    }

    @discardableResult
    public func recordToolCall(
        capability: ToolCallCapability,
        toolName: String? = nil
    ) async -> ToolCallDecision {
        let decision = activePolicy().decision(for: capability)
        let event = RunEvent(
            stream: .tool,
            summary: "\(capability.rawValue) tool call \(decision.summaryFragment)",
            payload: .tool(
                ToolRunEvent(
                    capability: capability,
                    decision: decision,
                    toolName: toolName
                )
            )
        )
        await eventStore.append(event)
        return decision
    }

    public func appendReflexSample(
        frameID: String? = nil,
        stateID: String? = nil,
        actionID: String? = nil,
        traceID: String? = nil
    ) async {
        await eventStore.append(
            RunEvent(
                stream: .reflex,
                summary: "Reflex sample recorded",
                payload: .reflex(
                    ReflexRunEvent(
                        frameID: frameID,
                        stateID: stateID,
                        actionID: actionID
                    )
                ),
                traceID: traceID
            )
        )
    }

    public func buildContext(
        latestWorldState: RunWorldStateSummary? = nil,
        transcriptSummary: String = "",
        activeHints: [RunPlannerHint] = [],
        recentFailures: [RunFailureSummary] = []
    ) -> RunContextPackage? {
        guard let currentSession else { return nil }

        return contextAssembler.build(
            session: currentSession,
            latestWorldState: latestWorldState,
            transcriptSummary: transcriptSummary,
            activeHints: activeHints,
            recentFailures: recentFailures
        )
    }

    public func snapshot() async -> RuntimeStatusSnapshot {
        let latestEvent = await eventStore.latestEvent()
        let eventCount = await eventStore.count()

        return RuntimeStatusSnapshot(
            isReady: lifecycleState == .running,
            summary: summary(for: lifecycleState),
            sourcePlan: "plans/20-off-the-shelf-run-loop.md",
            lifecycleState: lifecycleState,
            latestEventSummary: latestEvent?.summary,
            eventCount: eventCount,
            requiresInputRelease: requiresInputRelease
        )
    }

    public func events() async -> [RunEvent] {
        await eventStore.allEvents()
    }

    private func transition(
        to state: RunLifecycleState,
        reason: String?,
        requiresInputRelease: Bool = false
    ) async {
        lifecycleState = state

        let event = RunEvent(
            stream: .lifecycle,
            summary: summary(for: state),
            payload: .lifecycle(
                LifecycleRunEvent(
                    state: state,
                    reason: reason
                )
            ),
            requiresInputRelease: requiresInputRelease
        )

        await eventStore.append(event)
    }

    private func appendAssistantEvent(summary: String, message: String) async {
        await eventStore.append(
            RunEvent(
                stream: .assistant,
                summary: summary,
                payload: .assistant(AssistantRunEvent(message: message))
            )
        )
    }

    private func activePolicy() -> ToolCallPolicy {
        currentSession?.permissionPolicy ?? .default
    }

    private func summary(for state: RunLifecycleState) -> String {
        switch state {
        case .idle:
            return "Run coordinator idle"
        case .starting:
            return "Run starting"
        case .running:
            return "Run running"
        case .paused:
            return "Run paused"
        case .stopping:
            return "Run stopping"
        case .completed:
            return "Run completed"
        case .aborted:
            return "Run aborted"
        case .timedOut:
            return "Run timed out"
        case .failed:
            return "Run failed"
        }
    }
}

private extension ToolCallDecision {
    var summaryFragment: String {
        switch self {
        case .allow:
            return "allowed"
        case .deny:
            return "denied"
        case .ask:
            return "requires approval"
        }
    }
}
