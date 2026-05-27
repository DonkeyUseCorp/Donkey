import DonkeyContracts
import DonkeyHarness
import Foundation

public enum AppHarnessGenericLifecycleToolNames {
    public static let localAppTools: [String] = LocalAppActionPlanTool.allCases.map(\.rawValue)
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
        threadStore: (any HarnessThreadStoring)? = nil,
        coordinator: HarnessTaskCoordinator? = nil,
        compactor: HarnessThreadCompactor = HarnessThreadCompactor()
    ) {
        let resolvedThreadStore = threadStore ?? FileHarnessThreadStore()
        self.threadStore = resolvedThreadStore
        self.coordinator = coordinator ?? HarnessTaskCoordinator(threadStore: resolvedThreadStore)
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
        await threadStore.appendCompactionSnapshot(
            HarnessCompactionSnapshot(
                threadID: threadID,
                taskIDs: compactedContext.activeTasks.map(\.id),
                eventIDs: compactedContext.events.map(\.id),
                assetIDs: compactedContext.assets.map(\.id),
                promptCharacterCount: compactedContext.promptText.count,
                records: compactedContext.compactionRecords,
                metadata: compactedContext.metadata.merging([
                    "source": "pointerPrompt",
                    "traceID": traceID
                ]) { current, _ in current }
            )
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
        let plannedStepMetadata = resolution.intent?.metadata ?? [:]
        let modelPlanSteps = Self.modelPlanningSteps(
            from: plannedStepMetadata,
            traceID: traceID
        )
        let plan = HarnessPlan(
            goal: intent.goal,
            steps: modelPlanSteps,
            successCriteria: Self.stringArrayMetadata(
                plannedStepMetadata["genericHarness.verificationCriteriaJSON"],
                fallback: ["Resolved local app result is completed or handed to a user gate."]
            ),
            fallbackPolicy: Self.stringArrayMetadata(
                plannedStepMetadata["genericHarness.fallbacksJSON"],
                fallback: ["If execution needs review or missing detail, stop at the user gate."]
            ),
            clarificationPolicy: Self.clarificationPolicy(from: plannedStepMetadata),
            confidence: intent.confidence,
            metadata: [
                "planner": "genericHarnessLocalAppPlan",
                "traceID": traceID,
                "resolution.status": resolution.status.rawValue,
                "modelPlan.stepCount": String(modelPlanSteps.count),
                "modelPlan.schemaVersion": plannedStepMetadata["genericHarness.schemaVersion"] ?? ""
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

    @discardableResult
    public func approvePermissionGate(taskID: String, reason: String) async -> HarnessTaskState? {
        guard let task = await coordinator.task(id: taskID),
              task.status == .waitingForPermission,
              let continuation = task.pendingContinuation,
              !continuation.missingPermissions.isEmpty else {
            return nil
        }

        return await coordinator.grantPermissions(
            taskID: taskID,
            permissions: Set(continuation.missingPermissions),
            reason: reason
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
        let metadata = resolution.intent?.metadata ?? [:]
        let modelGoal = metadata["genericHarness.intent.goal"]
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let missingInformation: [String]
        if resolution.status == .needsConfirmation {
            missingInformation = Self.stringArrayMetadata(
                metadata["genericHarness.missingInformationJSON"],
                fallback: [resolution.metadata["reason"] ?? "more detail"]
            )
        } else {
            missingInformation = Self.stringArrayMetadata(
                metadata["genericHarness.missingInformationJSON"],
                fallback: []
            )
        }
        return HarnessIntentAnalysis(
            goal: modelGoal ?? goal,
            entities: resolution.intent?.normalizedEntities ?? resolution.intent?.entities ?? [:],
            ambiguityClass: HarnessAmbiguityClass(
                rawValue: metadata["genericHarness.ambiguity.class"] ?? ""
            ) ?? (resolution.status == .needsConfirmation ? .recoverable : .safe),
            riskLevel: HarnessRiskLevel(
                rawValue: metadata["genericHarness.risk.level"] ?? ""
            ) ?? .medium,
            missingInformation: missingInformation,
            shouldAskBeforeActing: metadata["genericHarness.shouldAskBeforeActing"] == "true"
                || resolution.status == .needsConfirmation,
            confidence: resolution.intent?.confidence ?? 0,
            metadata: [
                "resolution.status": resolution.status.rawValue,
                "taskType": taskType ?? "",
                "targetApp": targetApp ?? "",
                "intentID": resolution.intent?.intentID ?? ""
            ].merging(resolution.metadata) { current, _ in current }
        )
    }

    private static func modelPlanningSteps(
        from metadata: [String: String],
        traceID: String
    ) -> [HarnessPlanStep] {
        guard let text = metadata["genericHarness.planStepsJSON"],
              let data = text.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
        else {
            return []
        }

        return values.enumerated().map { index, value in
            let id = nonEmpty(value["id"]) ?? "model-plan-step-\(index + 1)"
            let toolName = nonEmpty(value["toolName"])
            let toolCall = toolName.flatMap { toolName -> HarnessToolCall? in
                guard LocalAppActionPlanTool(rawValue: toolName) != nil else { return nil }
                return HarnessToolCall(
                    id: "local-app-step-\(traceID)-\(index + 1)",
                    name: toolName,
                    input: [
                        "inputEntity": value["inputEntity"] ?? "",
                        "controlID": value["controlID"] ?? "",
                        "focusKey": value["focusKey"] ?? "",
                        "expectedObservation": value["expectedObservation"] ?? "",
                        "modelStepID": id,
                        "modelStepIndex": String(index)
                    ],
                    metadata: [
                        "adapter": "pointerPrompt",
                        "traceID": traceID,
                        "source": "hostedGenericHarnessPlanning"
                    ]
                )
            }
            return HarnessPlanStep(
                id: "model-\(id)",
                summary: nonEmpty(value["summary"]) ?? "Model-planned harness step",
                toolCall: toolCall,
                expectedObservation: nonEmpty(value["expectedObservation"]),
                metadata: [
                    "source": "hostedGenericHarnessPlanning",
                    "toolName": toolName ?? "",
                    "inputEntity": value["inputEntity"] ?? "",
                    "controlID": value["controlID"] ?? "",
                    "focusKey": value["focusKey"] ?? ""
                ]
            )
        }
    }

    private static func clarificationPolicy(from metadata: [String: String]) -> [String] {
        var policy = stringArrayMetadata(
            metadata["genericHarness.clarification.questionsJSON"],
            fallback: []
        )
        if let text = nonEmpty(metadata["genericHarness.clarification.policy"]) {
            policy.append(text)
        }
        return policy.isEmpty
            ? ["Ask a specific follow-up question when the resolved task is incomplete."]
            : policy
    }

    private static func stringArrayMetadata(
        _ text: String?,
        fallback: [String]
    ) -> [String] {
        guard let text,
              let data = text.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String]
        else {
            return fallback
        }
        let cleaned = values.compactMap(nonEmpty)
        return cleaned.isEmpty ? fallback : cleaned
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
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
