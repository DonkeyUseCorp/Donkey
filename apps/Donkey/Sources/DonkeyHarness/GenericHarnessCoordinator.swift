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
    private var tasksByID: [String: HarnessTaskState] = [:]
    private var eventsByTaskID: [String: [HarnessTaskEvent]] = [:]

    public init() {}

    @discardableResult
    public func createTask(
        id: String = UUID().uuidString,
        threadID: String,
        goal: String,
        intent: HarnessIntentAnalysis? = nil,
        context: HarnessContextSnapshot = HarnessContextSnapshot(),
        grantedPermissions: Set<HarnessPermission> = []
    ) -> HarnessTaskState {
        let task = HarnessTaskState(
            id: id,
            threadID: threadID,
            goal: goal,
            intent: intent,
            context: context,
            grantedPermissions: grantedPermissions
        )
        tasksByID[id] = task
        appendEvent(taskID: id, status: task.status, summary: "Task created")
        return task
    }

    public func task(id: String) -> HarnessTaskState? {
        tasksByID[id]
    }

    public func activeTasks() -> [HarnessTaskState] {
        tasksByID.values
            .filter { [.running, .paused, .waitingForUser, .waitingForPermission, .interrupted, .resuming].contains($0.status) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func events(taskID: String) -> [HarnessTaskEvent] {
        eventsByTaskID[taskID] ?? []
    }

    public func updateIntent(
        taskID: String,
        intent: HarnessIntentAnalysis
    ) -> HarnessTaskState? {
        mutate(taskID: taskID, summary: "Intent updated") { task in
            task.intent = intent
            task.goal = intent.goal
        }
    }

    public func updateContext(
        taskID: String,
        context: HarnessContextSnapshot
    ) -> HarnessTaskState? {
        mutate(taskID: taskID, summary: "Context updated") { task in
            task.context = context
        }
    }

    public func updatePlan(
        taskID: String,
        plan: HarnessPlan
    ) -> HarnessTaskState? {
        mutate(taskID: taskID, summary: "Plan updated") { task in
            task.plan = plan
        }
    }

    public func updateWorldModel(
        taskID: String,
        worldModel: HarnessWorldModel
    ) -> HarnessTaskState? {
        mutate(taskID: taskID, summary: "World model updated") { task in
            task.worldModel = worldModel
        }
    }

    public func pause(taskID: String, reason: String = "User paused task") -> HarnessTaskState? {
        setStatus(taskID: taskID, status: .paused, summary: reason)
    }

    public func resume(taskID: String, reason: String = "Task resumed") -> HarnessTaskState? {
        mutate(taskID: taskID, status: .resuming, summary: reason) { task in
            task.pendingContinuation = nil
        }
    }

    public func startRunning(taskID: String, reason: String = "Task running") -> HarnessTaskState? {
        mutate(taskID: taskID, status: .running, summary: reason) { task in
            task.pendingContinuation = nil
        }
    }

    public func cancel(taskID: String, reason: String = "Task cancelled") -> HarnessTaskState? {
        mutate(taskID: taskID, status: .cancelled, summary: reason) { task in
            task.pendingContinuation = nil
        }
    }

    public func complete(taskID: String, reason: String = "Task completed") -> HarnessTaskState? {
        mutate(taskID: taskID, status: .completed, summary: reason) { task in
            task.pendingContinuation = nil
        }
    }

    public func failSafe(taskID: String, reason: String) -> HarnessTaskState? {
        mutate(taskID: taskID, status: .failedSafe, summary: reason) { task in
            task.pendingContinuation = nil
        }
    }

    public func interrupt(
        taskID: String,
        newGoal: String,
        turn: AppHarnessTurn? = nil,
        reason: String = "Task interrupted by user"
    ) -> HarnessTaskState? {
        mutate(taskID: taskID, status: .interrupted, summary: reason) { task in
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

    public func waitForUser(
        taskID: String,
        question: String,
        pendingToolCall: HarnessToolCall? = nil,
        reason: String = "Task needs user clarification"
    ) -> HarnessTaskState? {
        mutate(taskID: taskID, status: .waitingForUser, summary: reason) { task in
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
        reason: String = "Task needs permission"
    ) -> HarnessTaskState? {
        mutate(taskID: taskID, status: .waitingForPermission, summary: reason) { task in
            task.pendingContinuation = HarnessPendingContinuation(
                stage: .permissionGate,
                reason: reason,
                missingPermissions: missingPermissions,
                pendingToolCall: pendingToolCall
            )
        }
    }

    public func provideUserResponse(
        taskID: String,
        response: String
    ) -> HarnessTaskState? {
        mutate(taskID: taskID, status: .resuming, summary: "User response received") { task in
            task.context.memory.append(response)
            task.worldModel.facts["lastUserClarification"] = response
            task.pendingContinuation = nil
        }
    }

    public func grantPermissions(
        taskID: String,
        permissions: Set<HarnessPermission>
    ) -> HarnessTaskState? {
        mutate(taskID: taskID, status: .resuming, summary: "Permission granted") { task in
            task.grantedPermissions.formUnion(permissions)
            task.pendingContinuation = nil
        }
    }

    public func recordToolResult(
        taskID: String,
        call: HarnessToolCall,
        result: HarnessToolResult
    ) -> HarnessTaskState? {
        mutate(taskID: taskID, status: nil, summary: "Tool result recorded") { task in
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

    private func setStatus(
        taskID: String,
        status: HarnessTaskStatus,
        summary: String
    ) -> HarnessTaskState? {
        mutate(taskID: taskID, status: status, summary: summary) { _ in }
    }

    private func mutate(
        taskID: String,
        status: HarnessTaskStatus? = nil,
        summary: String,
        mutation: (inout HarnessTaskState) -> Void
    ) -> HarnessTaskState? {
        guard var task = tasksByID[taskID] else { return nil }
        if let status {
            task.status = status
        }
        mutation(&task)
        task.updatedAt = Date()
        tasksByID[taskID] = task
        appendEvent(
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
    ) {
        var events = eventsByTaskID[taskID] ?? []
        events.append(
            HarnessTaskEvent(
                taskID: taskID,
                status: status,
                summary: summary,
                metadata: metadata
            )
        )
        eventsByTaskID[taskID] = events
    }
}
