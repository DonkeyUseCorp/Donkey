import DonkeyContracts
import Foundation

public actor RunCoordinator {
    private let sessionQueue: LatestRunSessionQueue
    private let eventStore: InMemoryRunEventStore
    private let reflexTraceStore: InMemoryReflexTraceStore
    private let contextAssembler: RunContextAssembler
    private var currentSession: RunSession?
    private var lifecycleState: RunLifecycleState = .idle
    private var requiresInputRelease = false
    private var activeTraceID: String?
    private var pauseContinuations: [CheckedContinuation<Void, Never>] = []

    public init(
        sessionQueue: LatestRunSessionQueue = LatestRunSessionQueue(),
        eventStore: InMemoryRunEventStore = InMemoryRunEventStore(),
        reflexTraceStore: InMemoryReflexTraceStore = InMemoryReflexTraceStore(),
        contextAssembler: RunContextAssembler = RunContextAssembler()
    ) {
        self.sessionQueue = sessionQueue
        self.eventStore = eventStore
        self.reflexTraceStore = reflexTraceStore
        self.contextAssembler = contextAssembler
    }

    public func submit(_ session: RunSession) async {
        await sessionQueue.submit(session)
    }

    public func setTraceID(_ traceID: String?) {
        activeTraceID = traceID
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
        let continuations = pauseContinuations
        pauseContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    public func waitIfPaused() async {
        guard lifecycleState == .paused else { return }

        await withCheckedContinuation { continuation in
            pauseContinuations.append(continuation)
        }
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
        let event = await recordToolEvent(
            capability: capability,
            toolName: toolName
        )
        guard case .tool(let payload) = event.payload else {
            return .deny(reason: "\(capability.rawValue) tool event was not recorded")
        }

        return payload.decision
    }

    @discardableResult
    public func recordToolEvent(
        capability: ToolCallCapability,
        decision explicitDecision: ToolCallDecision? = nil,
        toolName: String? = nil,
        summary: String? = nil,
        traceID: String? = nil,
        metadata: [String: String] = [:]
    ) async -> RunEvent {
        let decision = explicitDecision ?? activePolicy().decision(for: capability)
        let event = RunEvent(
            stream: .tool,
            summary: summary ?? "\(capability.rawValue) tool call \(decision.summaryFragment)",
            payload: .tool(
                ToolRunEvent(
                    capability: capability,
                    decision: decision,
                    toolName: toolName
                )
            ),
            traceID: traceID ?? activeTraceID,
            metadata: metadata
        )

        return await eventStore.append(event)
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
                traceID: traceID ?? activeTraceID
            )
        )
    }

    @discardableResult
    public func appendReflexTrace(
        _ record: ReflexTraceRecord,
        sampled: Bool = true
    ) async -> RunEvent {
        await reflexTraceStore.append(record)

        return await eventStore.append(
            RunEvent(
                stream: .reflex,
                summary: "Reflex trace recorded",
                payload: .reflex(
                    ReflexRunEvent(
                        frameID: record.frameID,
                        stateID: record.stateID,
                        actionID: record.actionID,
                        latency: record.latencyBreakdown,
                        sampled: sampled
                    )
                ),
                traceID: record.traceID,
                metadata: reflexMetadata(for: record)
            )
        )
    }

    public func buildContext(
        latestWorldState: RunWorldStateSummary? = nil,
        transcriptSummary: String = "",
        activeHints: [RunPlannerHint] = [],
        recentFailures: [RunFailureSummary] = [],
        memorySnapshot: RunMemorySnapshot? = nil,
        semanticMemoryResults: [RunMemorySemanticResult] = []
    ) -> RunContextPackage? {
        guard let currentSession else { return nil }

        return contextAssembler.build(
            session: currentSession,
            latestWorldState: latestWorldState,
            transcriptSummary: transcriptSummary,
            activeHints: activeHints,
            recentFailures: recentFailures,
            memorySnapshot: memorySnapshot,
            semanticMemoryResults: semanticMemoryResults
        )
    }

    public func snapshot() async -> RuntimeStatusSnapshot {
        let latestEvent = await eventStore.latestEvent()
        let eventCount = await eventStore.count()

        return RuntimeStatusSnapshot(
            isReady: lifecycleState == .running,
            summary: summary(for: lifecycleState),
            lifecycleState: lifecycleState,
            latestEventSummary: latestEvent?.summary,
            eventCount: eventCount,
            requiresInputRelease: requiresInputRelease
        )
    }

    public func events() async -> [RunEvent] {
        await eventStore.allEvents()
    }

    public func reflexTraces() async -> [ReflexTraceRecord] {
        await reflexTraceStore.allRecords()
    }

    public func latestReflexTrace() async -> ReflexTraceRecord? {
        await reflexTraceStore.latestRecord()
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
            traceID: activeTraceID,
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

    private func reflexMetadata(for record: ReflexTraceRecord) -> [String: String] {
        var metadata = record.metadata

        metadata["reflex.frameID"] = record.frameID
        metadata["reflex.stateID"] = record.stateID
        metadata["reflex.actionID"] = record.actionID
        metadata["reflex.controllerPolicy"] = record.controllerPolicy
        metadata["reflex.plannerHintID"] = record.plannerHintID
        metadata["reflex.machineProfile"] = record.machineProfile
        metadata["reflex.buildID"] = record.buildID

        if let confidence = record.confidence {
            metadata["reflex.confidence"] = String(confidence)
        }

        metadata.merge(record.latencyBreakdown.metadata) { current, _ in current }

        return metadata
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

private extension ReflexLatencyBreakdown {
    var metadata: [String: String] {
        var values: [String: String] = [:]

        values["latency.captureMS"] = captureMS.map { String($0) }
        values["latency.preprocessMS"] = preprocessMS.map { String($0) }
        values["latency.modelInferenceMS"] = modelInferenceMS.map { String($0) }
        values["latency.perceptionMS"] = perceptionMS.map { String($0) }
        values["latency.stateUpdateMS"] = stateUpdateMS.map { String($0) }
        values["latency.decisionMS"] = decisionMS.map { String($0) }
        values["latency.actionProjectionMS"] = actionProjectionMS.map { String($0) }
        values["latency.inputMS"] = inputMS.map { String($0) }
        values["latency.softwareLoopMS"] = softwareLoopMS.map { String($0) }
        values["latency.frameAgeMS"] = frameAgeMS.map { String($0) }
        values["latency.stateAgeMS"] = stateAgeMS.map { String($0) }

        return values
    }
}
