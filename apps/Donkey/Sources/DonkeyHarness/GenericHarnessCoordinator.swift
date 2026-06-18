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

public struct HarnessTaskState: Codable, Equatable, Sendable {
    public var id: String
    public var threadID: String
    public var goal: String
    public var status: HarnessTaskStatus
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
        threadID: String,
        goal: String,
        status: HarnessTaskStatus = .running,
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
        self.threadID = threadID
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

public struct HarnessTaskEvent: Codable, Equatable, Sendable {
    public var id: String
    public var taskID: String
    public var status: HarnessTaskStatus
    public var summary: String
    public var createdAt: Date
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        taskID: String,
        status: HarnessTaskStatus,
        summary: String,
        createdAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.taskID = taskID
        self.status = status
        self.summary = summary
        self.createdAt = createdAt
        self.metadata = metadata
    }
}

public actor HarnessTaskCoordinator {
    /// Fact key the planner reads for instructions the user added after the task started. Persistent and
    /// additive: each follow-up appends here so every later step keeps incorporating it, unlike a
    /// transient "new message" flag that would read as brand-new on every prompt.
    public static let additionalInstructionsFactKey = "additionalUserInstructions"

    private var tasksByID: [String: HarnessTaskState] = [:]
    private var eventsByTaskID: [String: [HarnessTaskEvent]] = [:]
    /// Ephemeral, in-memory only: follow-up instructions queued against a running loop, drained at the
    /// top of the next loop iteration. Deliberately not part of the persisted `HarnessTaskState` — a
    /// queued message only matters to a live loop, and the drained text is folded into the persisted
    /// world model anyway.
    private var pendingUserMessagesByID: [String: [HarnessPendingUserMessage]] = [:]
    /// Task IDs with a live runtime loop right now. The authoritative answer to "will an enqueued
    /// follow-up actually be drained?" — set in `beginRun`, cleared in `endRunUnlessPending`/`markLoopEnded`.
    /// Sampling this is what lets `enqueueUserMessage` tell a caller whether to inject or fall back to a
    /// fresh resume, instead of guessing from a status that can already be stale.
    private var runningLoopTaskIDs: Set<String> = []
    private let threadStore: (any HarnessThreadStoring)?

    public init(threadStore: (any HarnessThreadStoring)? = nil) {
        self.threadStore = threadStore
    }

    @discardableResult
    public func createTask(
        id: String = UUID().uuidString,
        threadID: String,
        goal: String,
        intent: HarnessIntentAnalysis? = nil,
        context: HarnessContextSnapshot = HarnessContextSnapshot(),
        grantedPermissions: Set<HarnessPermission> = []
    ) async -> HarnessTaskState {
        let task = HarnessTaskState(
            id: id,
            threadID: threadID,
            goal: goal,
            intent: intent,
            context: context,
            grantedPermissions: grantedPermissions
        )
        tasksByID[id] = task
        await threadStore?.upsertTaskSnapshot(task)
        await appendEvent(taskID: id, status: task.status, summary: "Task created")
        return task
    }

    /// Merge metadata onto a task without recording a lifecycle event (used to pin the resolved drive
    /// target so a later resume drives the original app rather than whatever is frontmost). Persists the
    /// snapshot but stays quiet in the thread record, since it is bookkeeping, not a step.
    public func recordMetadata(taskID: String, _ values: [String: String]) async {
        let existing: HarnessTaskState?
        if let cached = tasksByID[taskID] {
            existing = cached
        } else {
            existing = await threadStore?.taskSnapshot(id: taskID)
        }
        guard var task = existing else { return }
        task.metadata.merge(values) { _, new in new }
        task.updatedAt = Date()
        tasksByID[taskID] = task
        await threadStore?.upsertTaskSnapshot(task)
    }

    public func task(id: String) async -> HarnessTaskState? {
        if let task = tasksByID[id] {
            return task
        }
        guard let task = await threadStore?.taskSnapshot(id: id) else {
            return nil
        }
        tasksByID[id] = task
        return task
    }

    public func activeTasks() async -> [HarnessTaskState] {
        let persistedTasks = await threadStore?.activeTaskSnapshots() ?? []
        for task in persistedTasks {
            tasksByID[task.id] = task
        }
        return tasksByID.values
            .filter(Self.isActiveTask)
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func events(taskID: String) async -> [HarnessTaskEvent] {
        if let events = eventsByTaskID[taskID] {
            return events
        }
        let events = await threadStore?.taskEvents(taskID: taskID) ?? []
        eventsByTaskID[taskID] = events
        return events
    }

    public func updateIntent(
        taskID: String,
        intent: HarnessIntentAnalysis
    ) async -> HarnessTaskState? {
        await mutate(taskID: taskID, summary: "Intent updated") { task in
            task.intent = intent
            task.goal = intent.goal
        }
    }

    public func updateContext(
        taskID: String,
        context: HarnessContextSnapshot
    ) async -> HarnessTaskState? {
        await mutate(taskID: taskID, summary: "Context updated") { task in
            task.context = context
        }
    }

    public func updatePlan(
        taskID: String,
        plan: HarnessPlan
    ) async -> HarnessTaskState? {
        await mutate(taskID: taskID, summary: "Plan updated") { task in
            task.plan = plan
        }
    }

    public func updateWorldModel(
        taskID: String,
        worldModel: HarnessWorldModel
    ) async -> HarnessTaskState? {
        await mutate(taskID: taskID, summary: "World model updated") { task in
            task.worldModel = worldModel
        }
    }

    public func pause(taskID: String, reason: String = "User paused task") async -> HarnessTaskState? {
        await setStatus(taskID: taskID, status: .paused, summary: reason)
    }

    public func resume(taskID: String, reason: String = "Task resumed") async -> HarnessTaskState? {
        await mutate(taskID: taskID, status: .resuming, summary: reason) { task in
            task.pendingContinuation = nil
        }
    }

    public func startRunning(taskID: String, reason: String = "Task running") async -> HarnessTaskState? {
        await mutate(taskID: taskID, status: .running, summary: reason) { task in
            task.pendingContinuation = nil
            // A new run on a task whose previous run already ended must not inherit that run's
            // facts as current truth — observed live: a stale "10 songs added" fact convinced the
            // planner a brand-new playlist was already populated, so it skipped the add and then
            // spiraled on the (truthful) empty read. The tool history keeps the full record for
            // context; the facts re-derive from the fresh reads the completion gate already
            // requires. Gate resumes (clarify/permission) continue the SAME run — their history
            // does not end in a terminal lifecycle call — and keep their facts.
            let terminalNames: Set<String> = ["run.complete", "run.failSafe", "run.cancel"]
            if let last = task.toolHistory.last,
               terminalNames.contains(last.call.name), last.resultStatus == .succeeded {
                task.worldModel.facts = [:]
            }
        }
    }

    public func cancel(taskID: String, reason: String = "Task cancelled") async -> HarnessTaskState? {
        await mutate(taskID: taskID, status: .cancelled, summary: reason) { task in
            task.pendingContinuation = nil
        }
    }

    public func complete(taskID: String, reason: String = "Task completed") async -> HarnessTaskState? {
        await mutate(taskID: taskID, status: .completed, summary: reason) { task in
            task.pendingContinuation = nil
            // Follow-up instructions were run-scoped context for this completed run; drop them so a later
            // reuse of the task never re-presents an already-handled one-shot as a fresh demand.
            task.worldModel.facts[Self.additionalInstructionsFactKey] = nil
        }
    }

    public func failSafe(taskID: String, reason: String) async -> HarnessTaskState? {
        await mutate(taskID: taskID, status: .failedSafe, summary: reason) { task in
            task.pendingContinuation = nil
        }
    }

    /// The loop hit the runaway step ceiling without completing — distinct from a fail-safe stall. The
    /// goal still stands, so the task is left retryable: resuming it (`startRunning`) re-enters the loop.
    public func timeOut(taskID: String, reason: String = "Task hit the step ceiling") async -> HarnessTaskState? {
        await mutate(taskID: taskID, status: .timedOut, summary: reason) { task in
            task.pendingContinuation = nil
        }
    }

    public func interrupt(
        taskID: String,
        newGoal: String,
        turn: AppHarnessTurn? = nil,
        reason: String = "Task interrupted by user"
    ) async -> HarnessTaskState? {
        await mutate(taskID: taskID, status: .interrupted, summary: reason) { task in
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
    public func beginRun(taskID: String) {
        runningLoopTaskIDs.insert(taskID)
    }

    /// Unconditionally clear the running-loop mark (used when a run ends on a terminal that should not be
    /// reopened, e.g. a step-ceiling timeout).
    public func markLoopEnded(taskID: String) {
        runningLoopTaskIDs.remove(taskID)
    }

    /// Atomically decide, at the end of a loop, whether the run is truly finished. Returns true (caller
    /// stops) only when no follow-up is queued; if a follow-up slipped in after the last drain, the mark
    /// is kept and the caller loops once more to drain it. Because this is one actor call, it cannot race
    /// `enqueueUserMessage`: either the message lands first (queue non-empty → keep running) or this clears
    /// the mark first (so `enqueueUserMessage` then reports no live loop and the caller resumes instead).
    public func endRunUnlessPending(taskID: String) -> Bool {
        if pendingUserMessagesByID[taskID]?.isEmpty == false {
            return false
        }
        runningLoopTaskIDs.remove(taskID)
        return true
    }

    /// Queue a follow-up instruction onto a task. Returns whether a live loop is running that will drain
    /// it — false means the caller should resume the task instead (a fresh run drains it at its top). The
    /// deliberate opposite of `interrupt`, which clobbers the goal; this amends the work in place.
    @discardableResult
    public func enqueueUserMessage(taskID: String, text: String) async -> Bool {
        guard let task = await task(id: taskID) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return runningLoopTaskIDs.contains(taskID) }
        pendingUserMessagesByID[taskID, default: []].append(HarnessPendingUserMessage(text: trimmed))
        // Record the follow-up immediately so it survives in the thread even if the loop ends before drain.
        await appendEvent(taskID: taskID, status: task.status, summary: "Queued follow-up: \(trimmed)")
        return runningLoopTaskIDs.contains(taskID)
    }

    /// Pull and clear any queued follow-up instructions, appending them to the additive
    /// `additionalUserInstructions` fact the planner reads. Returns the drained messages (empty if none).
    @discardableResult
    public func drainUserMessages(taskID: String) async -> [HarnessPendingUserMessage] {
        guard let queued = pendingUserMessagesByID[taskID], !queued.isEmpty else { return [] }
        pendingUserMessagesByID[taskID] = nil
        let addition = queued.map(\.text).joined(separator: "\n")
        _ = await mutate(taskID: taskID, status: nil, summary: "Folded in queued follow-up") { task in
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
    public func reopenForFollowUp(taskID: String) async {
        guard let task = await task(id: taskID) else { return }
        switch task.status {
        case .completed, .failedSafe, .timedOut, .cancelled:
            _ = await mutate(taskID: taskID, status: .running, summary: "Reopened for queued follow-up") { task in
                task.pendingContinuation = nil
            }
        default:
            break
        }
    }

    /// Mark a still-runnable task as timed out (used when the loop hits the step ceiling). No-op if the
    /// task already reached a terminal/gate state.
    public func timeOutIfRunnable(taskID: String, reason: String) async {
        guard let task = await task(id: taskID), task.status.canExecuteTools else { return }
        _ = await timeOut(taskID: taskID, reason: reason)
    }

    /// Mark a still-runnable task as failed-safe (used when the planner stops or a tool call can't run). No-op
    /// if the task already reached a terminal/gate state.
    public func failSafeIfRunnable(taskID: String, reason: String) async {
        guard let task = await task(id: taskID), task.status.canExecuteTools else { return }
        _ = await failSafe(taskID: taskID, reason: reason)
    }

    public func waitForUser(
        taskID: String,
        question: String,
        pendingToolCall: HarnessToolCall? = nil,
        reason: String = "Task needs user clarification"
    ) async -> HarnessTaskState? {
        await mutate(taskID: taskID, status: .waitingForUser, summary: reason) { task in
            task.pendingContinuation = HarnessPendingContinuation(
                stage: .clarification,
                reason: reason,
                question: question,
                pendingToolCall: pendingToolCall
            )
        }
    }

    public func waitForPermission(
        taskID: String,
        missingPermissions: [HarnessPermission],
        pendingToolCall: HarnessToolCall,
        reason: String = "Task needs permission",
        metadata: [String: String] = [:]
    ) async -> HarnessTaskState? {
        await mutate(taskID: taskID, status: .waitingForPermission, summary: reason) { task in
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
        taskID: String,
        response: String
    ) async -> HarnessTaskState? {
        await mutate(taskID: taskID, status: .resuming, summary: "User response received") { task in
            task.context.memory.append(response)
            task.worldModel.facts["lastUserClarification"] = response
            task.pendingContinuation = nil
        }
    }

    public func grantPermissions(
        taskID: String,
        permissions: Set<HarnessPermission>,
        reason: String = "Permission granted"
    ) async -> HarnessTaskState? {
        await mutate(taskID: taskID, status: .resuming, summary: reason) { task in
            task.grantedPermissions.formUnion(permissions)
            task.pendingContinuation = nil
        }
    }

    public func recordToolResult(
        taskID: String,
        call: HarnessToolCall,
        result: HarnessToolResult
    ) async -> HarnessTaskState? {
        await mutate(taskID: taskID, status: nil, summary: "Tool result recorded") { task in
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
    public func annotateLastToolRecord(taskID: String, note: String) async -> HarnessTaskState? {
        await mutate(taskID: taskID, status: nil, summary: "Tool record annotated") { task in
            guard !task.toolHistory.isEmpty else { return }
            task.toolHistory[task.toolHistory.count - 1].summary += "\n\(note)"
            task.worldModel.attemptedToolCalls = task.toolHistory
        }
    }

    private func setStatus(
        taskID: String,
        status: HarnessTaskStatus,
        summary: String
    ) async -> HarnessTaskState? {
        await mutate(taskID: taskID, status: status, summary: summary) { _ in }
    }

    private func mutate(
        taskID: String,
        status: HarnessTaskStatus? = nil,
        summary: String,
        mutation: (inout HarnessTaskState) -> Void
    ) async -> HarnessTaskState? {
        let existingTask: HarnessTaskState?
        if let task = tasksByID[taskID] {
            existingTask = task
        } else {
            existingTask = await threadStore?.taskSnapshot(id: taskID)
        }
        guard var task = existingTask else { return nil }
        if let status {
            task.status = status
        }
        mutation(&task)
        task.updatedAt = Date()
        tasksByID[taskID] = task
        await threadStore?.upsertTaskSnapshot(task)
        await appendEvent(
            taskID: taskID,
            status: task.status,
            summary: summary
        )
        return task
    }

    private func appendEvent(
        taskID: String,
        status: HarnessTaskStatus,
        summary: String,
        metadata: [String: String] = [:]
    ) async {
        var events = eventsByTaskID[taskID] ?? []
        let event = HarnessTaskEvent(
            taskID: taskID,
            status: status,
            summary: summary,
            metadata: metadata
        )
        events.append(event)
        eventsByTaskID[taskID] = events
        await threadStore?.appendTaskEvent(event)
    }

    private static func isActiveTask(_ task: HarnessTaskState) -> Bool {
        [.running, .paused, .waitingForUser, .waitingForPermission, .interrupted, .resuming, .timedOut].contains(task.status)
    }
}
