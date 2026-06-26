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
    /// Agents whose workspace-root creation has already been attempted this session. When the directory
    /// can't be created (read-only home, no permission, disk full) the baseDir fact never gets set, so the
    /// fast path can't short-circuit; this guard stops `ensureWorkspaceRoot` from re-reading the
    /// conversation and re-issuing the failing `createDirectory` syscall on every planning step.
    private var workspaceRootAttempted: Set<String> = []
    /// Cache of small working-directory text files already read for the `workspace.files` fact, keyed by
    /// absolute path. Invalidated when the file's modification time changes, so a step that rewrites a file
    /// re-reads it but an unchanged file is not re-read every planning step.
    private var fileContentCache: [String: (mtime: Date, content: String)] = [:]
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
        reason: String = "Task needs user clarification",
        metadata: [String: String] = [:]
    ) async -> HarnessAgentState? {
        await mutate(agentID: agentID, status: .waitingForUser, summary: reason) { task in
            task.pendingContinuation = HarnessPendingContinuation(
                stage: .clarification,
                reason: reason,
                question: question,
                pendingToolCall: pendingToolCall,
                metadata: metadata
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
        let updated = await mutate(agentID: agentID, status: nil, summary: "Tool result recorded") { task in
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
        // Capture any deliverable this step produced into the conversation workspace. Keys ONLY off
        // typed result fields (status, toolName, metadata file paths) — never user text — so the
        // planner gains durable memory of what it has created and where, surviving compaction.
        if result.status == .succeeded {
            let produced = Self.producedFilePaths(from: result)
            if !produced.isEmpty {
                await recordWorkspaceDeliverables(
                    conversationID: updated?.conversationID,
                    kind: result.toolName,
                    files: produced,
                    at: result.completedAt
                )
            }
        }
        return updated
    }

    /// Pull the absolute on-disk path(s) a tool result reported, from its typed metadata only. Reads the
    /// canonical `filePath`/`path` keys plus the newline-joined `paths` (image generation), drops anything
    /// under the temporary directory (intermediate scratch from `llm.generate`/`web.fetch toFile`, which is
    /// assembled into a real deliverable later), and de-duplicates. No natural-language matching.
    static func producedFilePaths(from result: HarnessToolResult) -> [(path: String, byteCount: Int?)] {
        var raws: [String] = []
        if let single = result.metadata["filePath"] ?? result.metadata["path"], !single.isEmpty {
            raws.append(single)
        }
        if let multi = result.metadata["paths"] {
            raws.append(contentsOf: multi.split(separator: "\n").map(String.init))
        }
        let byteCount = result.metadata["bytes"].flatMap { Int($0) }
        let tempPrefix = FileManager.default.temporaryDirectory.standardizedFileURL.path
        var seen = Set<String>()
        var out: [(String, Int?)] = []
        for raw in raws {
            let std = ConversationWorkspace.standardize(raw)
            guard !std.isEmpty, !std.hasPrefix(tempPrefix), !seen.contains(std) else { continue }
            seen.insert(std)
            out.append((std, byteCount))
        }
        return out
    }

    // MARK: - Conversation workspace

    /// The conversation's durable workspace record (files produced, chosen base, promoted folder), or nil
    /// if nothing has been produced yet. Stored in `HarnessConversation.metadata` so it spans every root
    /// agent in the conversation.
    public func conversationWorkspace(conversationID: String) async -> ConversationWorkspace? {
        guard let convo = await conversationStore?.conversation(id: conversationID) else { return nil }
        return ConversationWorkspace.decode(convo.metadata[ConversationWorkspace.metadataKey])
    }

    /// Whether this conversation has recorded at least one produced deliverable — a real output file a tool
    /// wrote (an image, a `files.write`, a shell command's `-o` output), not the agent's scratch reads. The
    /// runtime uses this to refuse to upgrade a planner give-up into "complete" on a run that only scouted:
    /// reading the form and dumping pages to files is not producing the filled PDF.
    public func producedAnyDeliverable(agentID: String) async -> Bool {
        let conversationID: String?
        if let cached = tasksByID[agentID] {
            conversationID = cached.conversationID
        } else {
            conversationID = await conversationStore?.agentSnapshot(id: agentID)?.conversationID
        }
        guard let conversationID,
              let workspace = await conversationWorkspace(conversationID: conversationID) else { return false }
        return !workspace.deliverables.isEmpty
    }

    /// Record produced deliverables onto the conversation workspace, creating the conversation record if
    /// this is the first one. Loads → updates → persists the canonical copy in conversation metadata.
    public func recordWorkspaceDeliverables(
        conversationID: String?,
        kind: String,
        files: [(path: String, byteCount: Int?)],
        at date: Date
    ) async {
        guard let conversationID, let store = conversationStore, !files.isEmpty else { return }
        var convo = await store.conversation(id: conversationID)
            ?? HarnessConversation(id: conversationID, title: "")
        var workspace = ConversationWorkspace.decode(convo.metadata[ConversationWorkspace.metadataKey])
            ?? ConversationWorkspace()
        for file in files {
            workspace.record(path: file.path, kind: kind, byteCount: file.byteCount, at: date)
        }
        convo.metadata[ConversationWorkspace.metadataKey] = workspace.encodedJSON()
        convo.updatedAt = date
        await store.upsertConversation(convo)
    }

    /// Record the files the user attached onto the conversation workspace, so the planner sees them — with
    /// their paths — every step and can read or act on them. The input mirror of `recordWorkspaceDeliverables`:
    /// same load → update → persist of the canonical copy in conversation metadata. Persists across resumes
    /// and across root agents in the conversation.
    public func recordWorkspaceAttachments(
        conversationID: String?,
        attachments: [(path: String, displayName: String, contentType: String, byteCount: Int?)],
        at date: Date
    ) async {
        guard let conversationID, let store = conversationStore, !attachments.isEmpty else { return }
        var convo = await store.conversation(id: conversationID)
            ?? HarnessConversation(id: conversationID, title: "")
        var workspace = ConversationWorkspace.decode(convo.metadata[ConversationWorkspace.metadataKey])
            ?? ConversationWorkspace()
        for attachment in attachments {
            workspace.recordAttachment(
                path: attachment.path,
                displayName: attachment.displayName,
                contentType: attachment.contentType,
                byteCount: attachment.byteCount,
                at: date
            )
        }
        convo.metadata[ConversationWorkspace.metadataKey] = workspace.encodedJSON()
        convo.updatedAt = date
        await store.upsertConversation(convo)
    }

    /// Ensure the conversation has a dedicated working directory on disk before the planner takes its first
    /// action. Created once per conversation as `<output-location>/<goal-slug>-<short-id>/` (Downloads by
    /// default; user-configurable) and stored as the workspace `root`, it becomes the shell's working
    /// directory and the base relative paths resolve
    /// against — so a task's intermediate and output files (a `fields.json` dump, a filled PDF) land in one
    /// owned folder instead of loose in the user's home root. Idempotent and cheap: once the working
    /// directory is seeded its path is the `workspace.baseDir` fact, so later iterations return immediately.
    public func ensureWorkspaceRoot(agentID: String) async {
        // Fast path: once seeded, the working directory's path is the baseDir fact — skip all store I/O.
        if let cached = tasksByID[agentID],
           let base = cached.worldModel.facts[ConversationWorkspace.baseDirFactKey], !base.isEmpty {
            return
        }
        // Already tried (and failed) to create the directory this session — don't re-read the store and
        // re-issue the failing syscall every step; the run falls back to home for its lifetime.
        if workspaceRootAttempted.contains(agentID) { return }
        guard let store = conversationStore else { return }
        let existing: HarnessAgentState?
        if let cached = tasksByID[agentID] {
            existing = cached
        } else {
            existing = await store.agentSnapshot(id: agentID)
        }
        guard let task = existing else { return }
        let conversationID = task.conversationID
        var convo = await store.conversation(id: conversationID)
            ?? HarnessConversation(id: conversationID, title: "")
        var workspace = ConversationWorkspace.decode(convo.metadata[ConversationWorkspace.metadataKey])
            ?? ConversationWorkspace()
        if let root = workspace.root, !root.isEmpty, FileManager.default.fileExists(atPath: root) {
            return
        }
        var suggestedFolderName: String? = nil
        if let jsonStr = task.metadata["harness.understandingJSON"],
           let jsonData = jsonStr.data(using: .utf8) {
            struct MiniUnderstanding: Decodable {
                var suggestedFolderName: String?
            }
            if let mini = try? JSONDecoder().decode(MiniUnderstanding.self, from: jsonData) {
                suggestedFolderName = mini.suggestedFolderName
            }
        }
        let path = ConversationWorkspace.defaultRootPath(
            goal: task.goal,
            conversationID: conversationID,
            suggestedFolderName: suggestedFolderName
        )
        // Mark attempted before the syscall so a failure isn't retried every step (see the guard above).
        workspaceRootAttempted.insert(agentID)
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            // Could not create the working directory; leave root unset so callers fall back to home.
            return
        }
        workspace.root = path
        convo.metadata[ConversationWorkspace.metadataKey] = workspace.encodedJSON()
        convo.updatedAt = Date()
        await store.upsertConversation(convo)
    }

    /// Project the conversation workspace into the agent's world model facts so the planner sees, every
    /// step, what it has produced and where (and executors get the machine-readable resolve directory).
    /// Quiet: persists the snapshot without a lifecycle event, since this is per-step bookkeeping, not a
    /// step. A no-op when the conversation has produced nothing yet, so converse turns stay clean.
    public func refreshWorkspaceFact(agentID: String) async {
        let existing: HarnessAgentState?
        if let cached = tasksByID[agentID] {
            existing = cached
        } else {
            existing = await conversationStore?.agentSnapshot(id: agentID)
        }
        guard var task = existing,
              let workspace = await conversationWorkspace(conversationID: task.conversationID) else { return }
        let newSummary = workspace.plannerSummary()
        let newBase = workspace.currentBaseDirectory.flatMap { $0.isEmpty ? nil : $0 }
        // Per-step bookkeeping runs every planning iteration. Persisting re-serializes the WHOLE
        // conversation store to disk, so skip it when neither workspace fact actually changed — otherwise a
        // long run does one redundant full-store write per step, growing with conversation size.
        guard task.worldModel.facts[ConversationWorkspace.summaryFactKey] != newSummary
            || task.worldModel.facts[ConversationWorkspace.baseDirFactKey] != newBase else { return }
        task.worldModel.facts[ConversationWorkspace.summaryFactKey] = newSummary
        task.worldModel.facts[ConversationWorkspace.baseDirFactKey] = newBase
        task.updatedAt = Date()
        tasksByID[agentID] = task
        await conversationStore?.upsertAgentSnapshot(task)
    }

    /// Inline the contents of the small text files in the working directory into the `workspace.files` fact
    /// the planner reads every step. This is the context-retention fix for the re-read loop: a small input
    /// (a data file the agent copied in, a map it wrote) kept falling out of the rolling window, so the
    /// planner re-`cat`/`python`-read it again and again — varying the command each time, which slipped past
    /// the identical-repeat guard — and burned its whole budget without ever producing output. Holding the
    /// content as a fact means it is always in front of the model, so re-reading is pointless.
    ///
    /// Bounded by construction: only regular UTF-8 text files (binaries like PDFs/images are skipped by a
    /// NUL-byte sniff, never an extension list), only the few most-recently-changed, each clipped, and a
    /// small total cap — so a large dump (`fields.json`) or a binary never bloats the prompt. mtime-cached,
    /// so an unchanged file is not re-read each step.
    public func refreshFileContentsFact(agentID: String) async {
        let existing: HarnessAgentState?
        if let cached = tasksByID[agentID] {
            existing = cached
        } else {
            existing = await conversationStore?.agentSnapshot(id: agentID)
        }
        guard var task = existing else { return }
        let base = task.worldModel.facts[ConversationWorkspace.baseDirFactKey].flatMap { $0.isEmpty ? nil : $0 }
        let block = base.flatMap { Self.knownFileContentsBlock(workingDirectory: $0, cache: &fileContentCache) }
        let key = ConversationWorkspace.fileContentsFactKey
        guard task.worldModel.facts[key] != block else { return }
        if let block {
            task.worldModel.facts[key] = block
        } else {
            task.worldModel.facts.removeValue(forKey: key)
        }
        task.updatedAt = Date()
        tasksByID[agentID] = task
        await conversationStore?.upsertAgentSnapshot(task)
    }

    /// Build the `workspace.files` value: a few of the working directory's small text files, each labeled
    /// and clipped. Returns nil when there is nothing worth showing. mtime-cached via the passed cache.
    /// Static and cache-as-parameter so it is unit-testable against a temp directory without the actor.
    static func knownFileContentsBlock(
        workingDirectory: String,
        cache: inout [String: (mtime: Date, content: String)]
    ) -> String? {
        let maxRawBytes = 16_384      // skip anything bigger than this on disk (a field dump, a parsed layout)
        let perFileCap = 2_000        // chars per file in the fact
        let totalCap = 4_000          // chars across all files in the fact
        let maxFiles = 6
        let dir = URL(fileURLWithPath: (workingDirectory as NSString).expandingTildeInPath, isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys
        ) else { return nil }

        let candidates: [(url: URL, mtime: Date, size: Int)] = entries.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let mtime = values.contentModificationDate,
                  let size = values.fileSize, size > 0, size <= maxRawBytes else { return nil }
            return (url, mtime, size)
        }
        // Smallest first, not newest first. The point of this fact is to stop the planner re-reading its
        // small INPUTS (a data file copied in, a map it wrote). Those are small; the big files in the
        // directory are the agent's own scratch dumps (a form view, a field-list JSON) it can re-derive on
        // demand. Newest-first let a fresh 3 KB dump evict the 1 KB data file and the planner re-read the
        // data every step — exactly the loop this fact exists to kill.
        .sorted { $0.size < $1.size }

        var parts: [String] = []
        var total = 0
        for candidate in candidates {
            if parts.count >= maxFiles || total >= totalCap { break }
            let path = candidate.url.path
            let content: String
            if let cached = cache[path], cached.mtime == candidate.mtime {
                content = cached.content
            } else if let data = try? Data(contentsOf: candidate.url), let text = FileUnderstandingEngine.decodeText(data) {
                content = text
                cache[path] = (candidate.mtime, text)
            } else {
                continue  // binary or unreadable — skip
            }
            // Clip to the smaller of the per-file cap and the budget LEFT in the total cap, so appending this
            // file can't push the fact past totalCap (the loop-top check only gates entry, not the add).
            let budget = min(perFileCap, totalCap - total)
            let clipped = content.count > budget
                ? String(content.prefix(budget)) + "\n… [clipped]"
                : content
            parts.append("• \(candidate.url.lastPathComponent) (\(candidate.size) bytes):\n\(clipped)")
            total += clipped.count
        }
        guard !parts.isEmpty else { return nil }
        return "Contents of the small files in your working directory — READ THEM HERE, do not re-open them "
            + "with cat/python/pdf.parse:\n" + parts.joined(separator: "\n\n")
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
