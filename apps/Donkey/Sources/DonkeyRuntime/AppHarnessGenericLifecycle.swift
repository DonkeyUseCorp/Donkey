import DonkeyContracts
import DonkeyHarness
import Foundation

public enum AppHarnessGenericLifecycleToolNames {
    public static let localAppRun = "pointer-prompt.local-app.run"
}

public struct AppHarnessGenericLifecyclePreparedTurn: Equatable, Sendable {
    public var thread: HarnessThread
    public var task: HarnessTaskState
    public var compactedContext: HarnessCompactedThreadContext

    public init(
        thread: HarnessThread,
        task: HarnessTaskState,
        compactedContext: HarnessCompactedThreadContext
    ) {
        self.thread = thread
        self.task = task
        self.compactedContext = compactedContext
    }
}

public struct AppHarnessGenericLifecycle: Sendable {
    public var threadStore: any HarnessThreadStoring
    public var coordinator: HarnessTaskCoordinator
    public var compactor: HarnessThreadCompactor

    public init(
        threadStore: any HarnessThreadStoring = InMemoryHarnessThreadStore(),
        coordinator: HarnessTaskCoordinator = HarnessTaskCoordinator(),
        compactor: HarnessThreadCompactor = HarnessThreadCompactor()
    ) {
        self.threadStore = threadStore
        self.coordinator = coordinator
        self.compactor = compactor
    }

    public func preparePointerPromptTurn(
        request: AppHarnessTurnRequest,
        pointerTask: PointerPromptNotchTask?,
        traceID: String,
        availableToolNames: [String],
        grantedPermissions: Set<HarnessPermission> = []
    ) async -> AppHarnessGenericLifecyclePreparedTurn {
        let threadID = request.turn.taskID ?? pointerTask?.id ?? traceID
        let taskID = pointerTask?.id ?? request.turn.taskID ?? threadID
        let title = pointerTask?.title ?? request.turn.text
        let now = Date()
        let existingThread = await threadStore.thread(id: threadID)
        let activeTaskIDs = Array(Set((existingThread?.activeTaskIDs ?? []) + [taskID])).sorted()
        let thread = HarnessThread(
            id: threadID,
            title: existingThread?.title ?? title,
            status: .running,
            activeTaskIDs: activeTaskIDs,
            createdAt: existingThread?.createdAt ?? now,
            updatedAt: now,
            metadata: (existingThread?.metadata ?? [:]).merging([
                "source": "pointerPrompt",
                "traceID": traceID
            ]) { current, _ in current }
        )
        await threadStore.upsertThread(thread)
        await mirrorPointerPromptEvents(
            request.recentEvents,
            threadID: threadID,
            taskID: taskID
        )
        await mirrorPointerPromptAssets(
            request.assets,
            threadID: threadID,
            taskID: taskID
        )
        await appendCurrentTurnIfNeeded(
            request.turn,
            threadID: threadID,
            taskID: taskID
        )

        let context = HarnessContextSnapshot(
            turn: request.turn,
            threadID: threadID,
            memory: request.memory,
            availableToolNames: availableToolNames,
            policy: request.policy,
            metadata: [
                "traceID": traceID,
                "source": "pointerPrompt"
            ]
        )
        let task = await loadOrCreateTask(
            taskID: taskID,
            threadID: threadID,
            goal: request.turn.text,
            context: context,
            grantedPermissions: grantedPermissions
        )
        let events = await threadStore.events(threadID: threadID)
        let assets = await threadStore.assets(threadID: threadID)
        let activeTasks = await coordinator.activeTasks()
            .filter { $0.threadID == threadID }
        let compactedContext = compactor.compact(
            thread: thread,
            currentTurn: request.turn,
            events: events,
            assets: assets,
            activeTasks: activeTasks
        )

        return AppHarnessGenericLifecyclePreparedTurn(
            thread: thread,
            task: task,
            compactedContext: compactedContext
        )
    }

    @discardableResult
    public func planLocalTaskRun(
        taskID: String,
        resolution: LocalAppTaskCatalogResolution,
        fallbackGoal: String,
        traceID: String
    ) async -> HarnessTaskState? {
        let intent = Self.intentAnalysis(
            for: resolution,
            fallbackGoal: fallbackGoal
        )
        _ = await coordinator.updateIntent(taskID: taskID, intent: intent)
        let plan = HarnessPlan(
            goal: intent.goal,
            steps: [
                HarnessPlanStep(
                    id: "run-local-app-task",
                    summary: "Run the resolved local app task through the generic harness executor.",
                    toolCall: HarnessToolCall(
                        id: "local-app-run-\(traceID)",
                        name: AppHarnessGenericLifecycleToolNames.localAppRun,
                        input: [
                            "resolutionStatus": resolution.status.rawValue,
                            "taskType": resolution.intent?.taskType ?? resolution.definition?.taskType ?? "",
                            "targetApp": resolution.intent?.targetApp.appName
                                ?? resolution.definition?.targetApp.appName
                                ?? resolution.availability?.target.appName
                                ?? ""
                        ],
                        metadata: [
                            "adapter": "pointerPrompt",
                            "traceID": traceID
                        ]
                    ),
                    expectedObservation: "Local app task reaches a terminal or waiting state."
                ),
                HarnessPlanStep(
                    id: "verify-local-app-task",
                    summary: "Verify the local app task result.",
                    toolCall: HarnessToolCall(
                        id: "local-app-verify-\(traceID)",
                        name: "state.verify",
                        input: ["criteria": "Use the local app task result status and verification metadata."],
                        metadata: [
                            "adapter": "pointerPrompt",
                            "traceID": traceID
                        ]
                    ),
                    expectedObservation: "Verification records success criteria or evidence."
                )
            ],
            successCriteria: ["Resolved local app result is completed or handed to a user gate."],
            fallbackPolicy: ["If execution needs review or missing detail, stop at the user gate."],
            clarificationPolicy: ["Ask a specific follow-up question when the resolved task is incomplete."],
            confidence: intent.confidence,
            metadata: [
                "planner": "genericHarnessPointerPromptBridge",
                "traceID": traceID,
                "resolution.status": resolution.status.rawValue
            ]
        )
        _ = await coordinator.updatePlan(taskID: taskID, plan: plan)
        return await coordinator.startRunning(
            taskID: taskID,
            reason: "Pointer prompt task planned through generic harness"
        )
    }

    @discardableResult
    public func planRecovery(
        taskID: String,
        reason: String,
        traceID: String
    ) async -> HarnessTaskState? {
        guard let task = await coordinator.task(id: taskID) else { return nil }

        let plan = HarnessPlan(
            goal: task.goal,
            steps: [
                HarnessPlanStep(
                    id: "recover-local-app-task",
                    summary: "Recover from an unsuccessful pointer-prompt local app task.",
                    toolCall: HarnessToolCall(
                        id: "local-app-recover-\(traceID)",
                        name: "run.recover",
                        input: ["reason": reason],
                        metadata: [
                            "adapter": "pointerPrompt",
                            "traceID": traceID
                        ]
                    ),
                    expectedObservation: "Recovery records a safe fallback or updated task evidence."
                )
            ],
            successCriteria: ["Recovery stops safely or prepares a future continuation."],
            fallbackPolicy: ["If recovery cannot proceed, leave the task failed safe."],
            clarificationPolicy: ["Ask only if a specific missing user detail would let the task continue."],
            confidence: task.intent?.confidence ?? 0,
            metadata: [
                "planner": "genericHarnessPointerPromptRecovery",
                "traceID": traceID,
                "recovery.reason": reason
            ]
        )
        _ = await coordinator.updatePlan(taskID: taskID, plan: plan)
        return await coordinator.startRunning(
            taskID: taskID,
            reason: "Pointer prompt recovery planned through generic harness"
        )
    }

    public func taskState(taskID: String) async -> HarnessTaskState? {
        await coordinator.task(id: taskID)
    }

    @discardableResult
    public func pauseTask(taskID: String, reason: String) async -> HarnessTaskState? {
        await coordinator.pause(taskID: taskID, reason: reason)
    }

    @discardableResult
    public func resumeTask(taskID: String, reason: String) async -> HarnessTaskState? {
        await coordinator.resume(taskID: taskID, reason: reason)
    }

    public static func localTaskRunDescriptor() -> HarnessToolDescriptor {
        HarnessToolDescriptor(
            name: AppHarnessGenericLifecycleToolNames.localAppRun,
            pluginID: "pointer-prompt.migration",
            summary: "Execute a resolved pointer-prompt local app task as one generic harness step.",
            inputSchema: [
                "resolutionStatus": "Resolved, waiting, unsupported, or unavailable local app task status.",
                "taskType": "Resolved local app task type.",
                "targetApp": "Resolved local app target name."
            ],
            outputSchema: ["status": "Local app task terminal status and metadata."],
            requiredPermissions: [],
            safetyClass: .guardedInput,
            requiredContext: ["structured intent", "local app task resolution", "generic harness task"],
            verificationHints: ["Run state.verify after this step records its terminal evidence."],
            metadata: [
                "migrationBridge": "true",
                "legacyBackend": "LocalAppTaskLiveRunner"
            ]
        )
    }

    private func loadOrCreateTask(
        taskID: String,
        threadID: String,
        goal: String,
        context: HarnessContextSnapshot,
        grantedPermissions: Set<HarnessPermission>
    ) async -> HarnessTaskState {
        guard let existing = await coordinator.task(id: taskID) else {
            return await coordinator.createTask(
                id: taskID,
                threadID: threadID,
                goal: goal,
                context: context,
                grantedPermissions: grantedPermissions
            )
        }

        if existing.status == .waitingForUser,
           let response = context.turn?.text,
           !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = await coordinator.provideUserResponse(
                taskID: taskID,
                response: response
            )
        } else if context.turn?.isFollowUp == true {
            _ = await coordinator.interrupt(
                taskID: taskID,
                newGoal: goal,
                turn: context.turn,
                reason: "Pointer prompt follow-up changed course"
            )
            _ = await coordinator.resume(
                taskID: taskID,
                reason: "Pointer prompt follow-up resumed task"
            )
        } else if !existing.status.canExecuteTools {
            _ = await coordinator.resume(
                taskID: taskID,
                reason: "Pointer prompt resumed task"
            )
        }

        return await coordinator.updateContext(
            taskID: taskID,
            context: context
        ) ?? existing
    }

    private func mirrorPointerPromptEvents(
        _ pointerEvents: [PointerPromptTaskEvent],
        threadID: String,
        taskID: String
    ) async {
        let existingIDs = Set(await threadStore.events(threadID: threadID).map(\.id))
        for event in pointerEvents where !existingIDs.contains(event.id) {
            await threadStore.appendEvent(
                HarnessThreadEvent(
                    id: event.id,
                    threadID: threadID,
                    taskID: taskID,
                    role: HarnessThreadEventRole(pointerPromptRole: event.role),
                    text: event.text,
                    sequence: event.sequence,
                    createdAt: event.createdAt,
                    metadata: ["source": "pointerPromptTaskStore"]
                )
            )
        }
    }

    private func mirrorPointerPromptAssets(
        _ pointerAssets: [PointerPromptTaskAsset],
        threadID: String,
        taskID: String
    ) async {
        let existingIDs = Set(await threadStore.assets(threadID: threadID).map(\.id))
        for asset in pointerAssets where !existingIDs.contains(asset.id) {
            await threadStore.appendAsset(
                HarnessThreadAsset(
                    id: asset.id,
                    threadID: threadID,
                    taskID: taskID,
                    eventID: asset.eventID,
                    displayName: asset.displayName,
                    contentType: asset.contentType,
                    urlString: asset.urlString,
                    byteCount: asset.byteCount,
                    createdAt: asset.createdAt,
                    metadata: [
                        "source": "pointerPromptTaskStore",
                        "assetSource": asset.source.rawValue
                    ]
                )
            )
        }
    }

    private func appendCurrentTurnIfNeeded(
        _ turn: AppHarnessTurn,
        threadID: String,
        taskID: String
    ) async {
        let events = await threadStore.events(threadID: threadID)
        let hasCurrentTurn = events.contains { event in
            event.metadata["turnID"] == turn.id
                || (event.role == .user && event.text == turn.text)
        }
        guard !hasCurrentTurn else { return }

        await threadStore.appendEvent(
            HarnessThreadEvent(
                id: "turn-\(turn.id)",
                threadID: threadID,
                taskID: taskID,
                role: .user,
                text: turn.text,
                sequence: (events.map(\.sequence).max() ?? -1) + 1,
                createdAt: turn.createdAt,
                metadata: [
                    "source": "genericHarnessTurn",
                    "turnID": turn.id
                ]
            )
        )
    }

    private static func intentAnalysis(
        for resolution: LocalAppTaskCatalogResolution,
        fallbackGoal: String
    ) -> HarnessIntentAnalysis {
        let taskType = resolution.intent?.taskType ?? resolution.definition?.taskType
        let targetApp = resolution.intent?.targetApp.appName
            ?? resolution.definition?.targetApp.appName
            ?? resolution.availability?.target.appName
        let goalParts = [
            taskType,
            targetApp.map { "in \($0)" }
        ].compactMap { $0 }
        let goal = goalParts.isEmpty ? fallbackGoal : goalParts.joined(separator: " ")
        let missingInformation: [String]
        if resolution.status == .needsConfirmation {
            missingInformation = [resolution.metadata["reason"] ?? "more detail"]
        } else {
            missingInformation = []
        }
        return HarnessIntentAnalysis(
            goal: goal,
            entities: resolution.intent?.normalizedEntities ?? resolution.intent?.entities ?? [:],
            ambiguityClass: resolution.status == .needsConfirmation ? .recoverable : .safe,
            riskLevel: .medium,
            missingInformation: missingInformation,
            shouldAskBeforeActing: resolution.status == .needsConfirmation,
            confidence: resolution.intent?.confidence ?? 0,
            metadata: [
                "resolution.status": resolution.status.rawValue,
                "taskType": taskType ?? "",
                "targetApp": targetApp ?? "",
                "intentID": resolution.intent?.intentID ?? ""
            ].merging(resolution.metadata) { current, _ in current }
        )
    }
}

private extension HarnessThreadEventRole {
    init(pointerPromptRole: PointerPromptTaskEventRole) {
        switch pointerPromptRole {
        case .user:
            self = .user
        case .assistant:
            self = .assistant
        case .system:
            self = .system
        case .tool:
            self = .tool
        }
    }
}
