import DonkeyContracts
import Foundation

public struct HarnessPendingContinuation: Codable, Equatable, Sendable {
    public var checkpointID: String
    public var stage: HarnessStage
    public var reason: String
    public var question: String?
    public var missingPermissions: [HarnessPermission]
    public var pendingToolCall: HarnessToolCall?
    public var createdAt: Date
    public var metadata: [String: String]

    public init(
        checkpointID: String = UUID().uuidString,
        stage: HarnessStage,
        reason: String,
        question: String? = nil,
        missingPermissions: [HarnessPermission] = [],
        pendingToolCall: HarnessToolCall? = nil,
        createdAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.checkpointID = checkpointID
        self.stage = stage
        self.reason = reason
        self.question = question
        self.missingPermissions = missingPermissions
        self.pendingToolCall = pendingToolCall
        self.createdAt = createdAt
        self.metadata = metadata
    }
}

/// A user instruction that arrived while the task's loop was already running. It is queued on the task
/// and drained at the top of the next loop iteration, so a live run folds in the new instruction at its
/// next step instead of being torn down and restarted. This is the deliberate opposite of `interrupt`,
/// which clobbers the goal.
public struct HarnessPendingUserMessage: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

public struct HarnessAgentState: Codable, Equatable, Sendable {
    public var id: String
    public var conversationID: String
    /// The agent that spawned this one, or nil for a conversation's root agent. A subagent is simply an
    /// agent with a non-nil parent; subagent execution is not wired yet — this only establishes the edge.
    public var parentAgentID: String?
    public var goal: String
    public var status: HarnessAgentStatus
    public var intent: HarnessIntentAnalysis?
    public var context: HarnessContextSnapshot
    public var worldModel: HarnessWorldModel
    public var plan: HarnessPlan?
    public var grantedPermissions: Set<HarnessPermission>
    public var toolHistory: [HarnessToolCallRecord]
    public var pendingContinuation: HarnessPendingContinuation?
    public var createdAt: Date
    public var updatedAt: Date
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        conversationID: String,
        parentAgentID: String? = nil,
        goal: String,
        status: HarnessAgentStatus = .running,
        intent: HarnessIntentAnalysis? = nil,
        context: HarnessContextSnapshot = HarnessContextSnapshot(),
        worldModel: HarnessWorldModel = HarnessWorldModel(),
        plan: HarnessPlan? = nil,
        grantedPermissions: Set<HarnessPermission> = [],
        toolHistory: [HarnessToolCallRecord] = [],
        pendingContinuation: HarnessPendingContinuation? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.conversationID = conversationID
        self.parentAgentID = parentAgentID
        self.goal = goal
        self.status = status
        self.intent = intent
        self.context = context
        self.worldModel = worldModel
        self.plan = plan
        self.grantedPermissions = grantedPermissions
        self.toolHistory = toolHistory
        self.pendingContinuation = pendingContinuation
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }
}

public struct HarnessAgentEvent: Codable, Equatable, Sendable {
    public var id: String
    public var agentID: String
    public var status: HarnessAgentStatus
    public var summary: String
    public var createdAt: Date
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        agentID: String,
        status: HarnessAgentStatus,
        summary: String,
        createdAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.agentID = agentID
        self.status = status
        self.summary = summary
        self.createdAt = createdAt
        self.metadata = metadata
    }
}

public actor HarnessAgentCoordinator {
    /// Fact key the planner reads for instructions the user added after the task started. Persistent and
    /// additive: each follow-up appends here so every later step keeps incorporating it, unlike a
    /// transient "new message" flag that would read as brand-new on every prompt.
    public static let additionalInstructionsFactKey = "additionalUserInstructions"

    private var tasksByID: [String: HarnessAgentState] = [:]
    private var eventsByTaskID: [String: [HarnessAgentEvent]] = [:]
    /// Ephemeral, in-memory only: follow-up instructions queued against a running loop, drained at the
    /// top of the next loop iteration. Deliberately not part of the persisted `HarnessAgentState` — a
    /// queued message only matters to a live loop, and the drained text is folded into the persisted
    /// world model anyway.
    private var pendingUserMessagesByID: [String: [HarnessPendingUserMessage]] = [:]
    /// Task IDs with a live runtime loop right now. The authoritative answer to "will an enqueued
    /// follow-up actually be drained?" — set in `beginRun`, cleared in `endRunUnlessPending`/`markLoopEnded`.
    /// Sampling this is what lets `enqueueUserMessage` tell a caller whether to inject or fall back to a
    /// fresh resume, instead of guessing from a status that can already be stale.
    private var runningLoopTaskIDs: Set<String> = []
    private let conversationStore: (any HarnessConversationStoring)?

    public init(conversationStore: (any HarnessConversationStoring)? = nil) {
        self.conversationStore = conversationStore
    }

    /// Create an agent in a conversation. Pass `parentAgentID` to spawn a subagent under an existing
    /// agent; the root agent of a conversation leaves it nil. Subagent execution is not wired yet — this
    /// only establishes the parent edge so nesting can be queried and built on later.
    @discardableResult
    public func createAgent(
        id: String = UUID().uuidString,
        conversationID: String,
        parentAgentID: String? = nil,
        goal: String,
        intent: HarnessIntentAnalysis? = nil,
        context: HarnessContextSnapshot = HarnessContextSnapshot(),
        grantedPermissions: Set<HarnessPermission> = []
    ) async -> HarnessAgentState {
        let task = HarnessAgentState(
            id: id,
            conversationID: conversationID,
            parentAgentID: parentAgentID,
            goal: goal,
            intent: intent,
            context: context,
            grantedPermissions: grantedPermissions
        )
        tasksByID[id] = task
        await conversationStore?.upsertAgentSnapshot(task)
        await appendEvent(agentID: id, status: task.status, summary: "Task created")
        return task
    }

    /// Merge metadata onto a task without recording a lifecycle event (used to pin the resolved drive
    /// target so a later resume drives the original app rather than whatever is frontmost). Persists the
    /// snapshot but stays quiet in the thread record, since it is bookkeeping, not a step.
    public func recordMetadata(agentID: String, _ values: [String: String]) async {
        let existing: HarnessAgentState?
        if let cached = tasksByID[agentID] {
            existing = cached
        } else {
            existing = await conversationStore?.agentSnapshot(id: agentID)
        }
        guard var task = existing else { return }
        task.metadata.merge(values) { _, new in new }
        task.updatedAt = Date()
        tasksByID[agentID] = task
        await conversationStore?.upsertAgentSnapshot(task)
    }

    public func agent(id: String) async -> HarnessAgentState? {
        if let task = tasksByID[id] {
            return task
        }
        guard let task = await conversationStore?.agentSnapshot(id: id) else {
            return nil
        }
        tasksByID[id] = task
        return task
    }

    public func activeAgents() async -> [HarnessAgentState] {
        let persistedTasks = await conversationStore?.activeAgentSnapshots() ?? []
        for task in persistedTasks {
            tasksByID[task.id] = task
        }
        return tasksByID.values
            .filter(Self.isActiveTask)
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Subagents spawned by `parentAgentID`, found by scanning the parent's conversation. Children are
    /// derived by query rather than cached on the parent, so the two ends can never drift out of sync.
    public func childAgents(of parentAgentID: String) async -> [HarnessAgentState] {
        guard let parent = await agent(id: parentAgentID) else { return [] }
        let siblings = await conversationStore?.agentSnapshots(conversationID: parent.conversationID) ?? []
        return siblings
            .filter { $0.parentAgentID == parentAgentID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// The root agents of a conversation — those with no parent. Each top-level run is a root agent;
    /// subagents hang beneath one of these.
    public func rootAgents(conversationID: String) async -> [HarnessAgentState] {
        let agents = await conversationStore?.agentSnapshots(conversationID: conversationID) ?? []
        return agents
            .filter { $0.parentAgentID == nil }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func events(agentID: String) async -> [HarnessAgentEvent] {
        if let events = eventsByTaskID[agentID] {
            return events
        }
        let events = await conversationStore?.agentEvents(agentID: agentID) ?? []
        eventsByTaskID[agentID] = events
        return events
    }

    public func updateIntent(
        agentID: String,
        intent: HarnessIntentAnalysis
    ) async -> HarnessAgentState? {
        await mutate(agentID: agentID, summary: "Intent updated") { task in
            task.intent = intent
            task.goal = intent.goal
        }
    }

    public func updateContext(
        agentID: String,
        context: HarnessContextSnapshot
    ) async -> HarnessAgentState? {
        await mutate(agentID: agentID, summary: "Context updated") { task in
            task.context = context
        }
    }

    public func updatePlan(
        agentID: String,
        plan: HarnessPlan
    ) async -> HarnessAgentState? {
        await mutate(agentID: agentID, summary: "Plan updated") { task in
            task.plan = plan
        }
    }

    public func updateWorldModel(
        agentID: String,
        worldModel: HarnessWorldModel
    ) async -> HarnessAgentState? {
        await mutate(agentID: agentID, summary: "World model updated") { task in
            task.worldModel = worldModel
        }
    }

    public func pause(agentID: String, reason: String = "User paused task") async -> HarnessAgentState? {
        await setStatus(agentID: agentID, status: .paused, summary: reason)
    }

    public func resume(agentID: String, reason: String = "Task resumed") async -> HarnessAgentState? {
        await mutate(agentID: agentID, status: .resuming, summary: reason) { task in
            task.pendingContinuation = nil
        }
    }

    public func startRunning(agentID: String, reason: String = "Task running") async -> HarnessAgentState? {
        await mutate(agentID: agentID, status: .running, summary: reason) { task in
            task.pendingContinuation = nil
            // A new run on a task whose previous run already ended must not inherit that run's
            // facts as current truth — observed live: a stale "10 songs added" fact convinced the
            // planner a brand-new playlist was already populated, so it skipped the add and then
            // spiraled on the (truthful) empty read. The tool history keeps the full record for
            // context; the facts re-derive from the fresh reads the completion gate already
            // requires. Gate resumes (clarify/permission) continue the SAME run — their history
            // does not end in a terminal call — and keep their facts.
            if let last = task.toolHistory.last,
               BuiltInHarnessToolCatalog.terminalToolNames.contains(last.call.name), last.resultStatus == .succeeded {
                task.worldModel.facts = [:]
            }
        }
    }

    public func cancel(agentID: String, reason: String = "Task cancelled") async -> HarnessAgentState? {
        await mutate(agentID: agentID, status: .cancelled, summary: reason) { task in
            task.pendingContinuation = nil
        }
    }

    public func complete(agentID: String, reason: String = "Task completed") async -> HarnessAgentState? {
        await mutate(agentID: agentID, status: .completed, summary: reason) { task in
            task.pendingContinuation = nil
            // Follow-up instructions were run-scoped context for this completed run; drop them so a later
            // reuse of the task never re-presents an already-handled one-shot as a fresh demand.
            task.worldModel.facts[Self.additionalInstructionsFactKey] = nil
        }
    }

    public func failSafe(agentID: String, reason: String) async -> HarnessAgentState? {
        await mutate(agentID: agentID, status: .failedSafe, summary: reason) { task in
            task.pendingContinuation = nil
        }
    }

    /// The loop hit the runaway step ceiling without completing — distinct from a fail-safe stall. The
    /// goal still stands, so the task is left retryable: resuming it (`startRunning`) re-enters the loop.
    public func timeOut(agentID: String, reason: String = "Task hit the step ceiling") async -> HarnessAgentState? {
        await mutate(agentID: agentID, status: .timedOut, summary: reason) { task in
            task.pendingContinuation = nil
        }
    }

    public func interrupt(
        agentID: String,
        newGoal: String,
        turn: AppHarnessTurn? = nil,
        reason: String = "Task interrupted by user"
    ) async -> HarnessAgentState? {
        await mutate(agentID: agentID, status: .interrupted, summary: reason) { task in
            task.goal = newGoal
            if let turn {
                task.context.turn = turn
            }
            task.plan = nil
            task.pendingContinuation = HarnessPendingContinuation(
                stage: .planning,
                reason: "courseChanged",
                metadata: ["newGoal": newGoal]
            )
        }
    }

    /// Mark that a runtime loop has started for this task. Paired with `endRunUnlessPending` /
    /// `markLoopEnded`. While a loop is marked running, an enqueued follow-up is guaranteed to be drained
    /// by it (the loop drains every iteration and, on exit, atomically checks for late arrivals).
    public func beginRun(agentID: String) {
        runningLoopTaskIDs.insert(agentID)
    }

    /// Unconditionally clear the running-loop mark (used when a run ends on a terminal that should not be
    /// reopened, e.g. a step-ceiling timeout).
    public func markLoopEnded(agentID: String) {
        runningLoopTaskIDs.remove(agentID)
    }

    /// Atomically decide, at the end of a loop, whether the run is truly finished. Returns true (caller
    /// stops) only when no follow-up is queued; if a follow-up slipped in after the last drain, the mark
    /// is kept and the caller loops once more to drain it. Because this is one actor call, it cannot race
    /// `enqueueUserMessage`: either the message lands first (queue non-empty → keep running) or this clears
    /// the mark first (so `enqueueUserMessage` then reports no live loop and the caller resumes instead).
    public func endRunUnlessPending(agentID: String) -> Bool {
        if pendingUserMessagesByID[agentID]?.isEmpty == false {
            return false
        }
        runningLoopTaskIDs.remove(agentID)
        return true
    }

    /// Queue a follow-up instruction onto a task. Returns whether a live loop is running that will drain
    /// it — false means the caller should resume the task instead (a fresh run drains it at its top). The
    /// deliberate opposite of `interrupt`, which clobbers the goal; this amends the work in place.
    @discardableResult
    public func enqueueUserMessage(agentID: String, text: String) async -> Bool {
        guard let task = await agent(id: agentID) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return runningLoopTaskIDs.contains(agentID) }
        pendingUserMessagesByID[agentID, default: []].append(HarnessPendingUserMessage(text: trimmed))
        // Record the follow-up immediately so it survives in the thread even if the loop ends before drain.
        await appendEvent(agentID: agentID, status: task.status, summary: "Queued follow-up: \(trimmed)")
        return runningLoopTaskIDs.contains(agentID)
    }

    /// Pull and clear any queued follow-up instructions, appending them to the additive
    /// `additionalUserInstructions` fact the planner reads. Returns the drained messages (empty if none).
    @discardableResult
    public func drainUserMessages(agentID: String) async -> [HarnessPendingUserMessage] {
        guard let queued = pendingUserMessagesByID[agentID], !queued.isEmpty else { return [] }
        pendingUserMessagesByID[agentID] = nil
        let addition = queued.map(\.text).joined(separator: "\n")
        _ = await mutate(agentID: agentID, status: nil, summary: "Folded in queued follow-up") { task in
            let existing = task.worldModel.facts[Self.additionalInstructionsFactKey]
            let combined = [existing, addition]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            task.worldModel.facts[Self.additionalInstructionsFactKey] = combined
        }
        return queued
    }

    /// Re-open a task whose loop reached a non-gate terminal (completed/failedSafe/timedOut/cancelled) so a
    /// freshly-drained follow-up gets acted on. Unlike `startRunning`, it preserves the world model facts
    /// (including the just-folded instruction). Gates and already-runnable tasks are left untouched.
    public func reopenForFollowUp(agentID: String) async {
        guard let task = await agent(id: agentID) else { return }
        switch task.status {
        case .completed, .failedSafe, .timedOut, .cancelled:
            _ = await mutate(agentID: agentID, status: .running, summary: "Reopened for queued follow-up") { task in
                task.pendingContinuation = nil
            }
        default:
            break
        }
    }

    /// Mark a still-runnable task as timed out (used when the loop hits the step ceiling). No-op if the
    /// task already reached a terminal/gate state.
    public func timeOutIfRunnable(agentID: String, reason: String) async {
        guard let task = await agent(id: agentID), task.status.canExecuteTools else { return }
        _ = await timeOut(agentID: agentID, reason: reason)
    }

    /// Mark a still-runnable task as failed-safe (used when the planner stops or a tool call can't run). No-op
    /// if the task already reached a terminal/gate state.
    public func failSafeIfRunnable(agentID: String, reason: String) async {
        guard let task = await agent(id: agentID), task.status.canExecuteTools else { return }
        _ = await failSafe(agentID: agentID, reason: reason)
    }

    public func waitForUser(
        agentID: String,
        question: String,
        pendingToolCall: HarnessToolCall? = nil,
        reason: String = "Task needs user clarification"
    ) async -> HarnessAgentState? {
        await mutate(agentID: agentID, status: .waitingForUser, summary: reason) { task in
            task.pendingContinuation = HarnessPendingContinuation(
                stage: .clarification,
                reason: reason,
                question: question,
                pendingToolCall: pendingToolCall
            )
        }
    }

    public func waitForPermission(
        agentID: String,
        missingPermissions: [HarnessPermission],
        pendingToolCall: HarnessToolCall,
        reason: String = "Task needs permission",
        metadata: [String: String] = [:]
    ) async -> HarnessAgentState? {
        await mutate(agentID: agentID, status: .waitingForPermission, summary: reason) { task in
            task.pendingContinuation = HarnessPendingContinuation(
                stage: .permissionGate,
                reason: reason,
                missingPermissions: missingPermissions,
                pendingToolCall: pendingToolCall,
                metadata: metadata
            )
        }
    }

    public func provideUserResponse(
        agentID: String,
        response: String
    ) async -> HarnessAgentState? {
        await mutate(agentID: agentID, status: .resuming, summary: "User response received") { task in
            task.context.memory.append(response)
            task.worldModel.facts["lastUserClarification"] = response
            task.pendingContinuation = nil
        }
    }

    public func grantPermissions(
        agentID: String,
        permissions: Set<HarnessPermission>,
        reason: String = "Permission granted"
    ) async -> HarnessAgentState? {
        await mutate(agentID: agentID, status: .resuming, summary: reason) { task in
            task.grantedPermissions.formUnion(permissions)
            task.pendingContinuation = nil
        }
    }

    public func recordToolResult(
        agentID: String,
        call: HarnessToolCall,
        result: HarnessToolResult
    ) async -> HarnessAgentState? {
        await mutate(agentID: agentID, status: nil, summary: "Tool result recorded") { task in
            task.toolHistory.append(
                HarnessToolCallRecord(
                    call: call,
                    resultStatus: result.status,
                    summary: result.summary,
                    recordedAt: result.completedAt
                )
            )
            task.worldModel = task.worldModel.merging(result: result)
            task.worldModel.attemptedToolCalls = task.toolHistory
        }
    }

    /// Appends a note to the most recent tool record's summary. The runtime uses this to warn the
    /// planner — in the history it reads every step — that it just repeated a call without learning
    /// anything, one step before the stall guard would end the run.
    public func annotateLastToolRecord(agentID: String, note: String) async -> HarnessAgentState? {
        await mutate(agentID: agentID, status: nil, summary: "Tool record annotated") { task in
            guard !task.toolHistory.isEmpty else { return }
            task.toolHistory[task.toolHistory.count - 1].summary += "\n\(note)"
            task.worldModel.attemptedToolCalls = task.toolHistory
        }
    }

    private func setStatus(
        agentID: String,
        status: HarnessAgentStatus,
        summary: String
    ) async -> HarnessAgentState? {
        await mutate(agentID: agentID, status: status, summary: summary) { _ in }
    }

    private func mutate(
        agentID: String,
        status: HarnessAgentStatus? = nil,
        summary: String,
        mutation: (inout HarnessAgentState) -> Void
    ) async -> HarnessAgentState? {
        let existingTask: HarnessAgentState?
        if let task = tasksByID[agentID] {
            existingTask = task
        } else {
            existingTask = await conversationStore?.agentSnapshot(id: agentID)
        }
        guard var task = existingTask else { return nil }
        if let status {
            task.status = status
        }
        mutation(&task)
        task.updatedAt = Date()
        tasksByID[agentID] = task
        await conversationStore?.upsertAgentSnapshot(task)
        await appendEvent(
            agentID: agentID,
            status: task.status,
            summary: summary
        )
        return task
    }

    private func appendEvent(
        agentID: String,
        status: HarnessAgentStatus,
        summary: String,
        metadata: [String: String] = [:]
    ) async {
        var events = eventsByTaskID[agentID] ?? []
        let event = HarnessAgentEvent(
            agentID: agentID,
            status: status,
            summary: summary,
            metadata: metadata
        )
        events.append(event)
        eventsByTaskID[agentID] = events
        await conversationStore?.appendAgentEvent(event)
    }

    private static func isActiveTask(_ task: HarnessAgentState) -> Bool {
        [.running, .paused, .waitingForUser, .waitingForPermission, .interrupted, .resuming, .timedOut].contains(task.status)
    }
}
