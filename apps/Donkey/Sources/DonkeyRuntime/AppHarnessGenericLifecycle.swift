import DonkeyContracts
import DonkeyHarness
import Foundation

/// How the user answered a permission/consent gate. `allow` covers a one-time
/// approval (category permission grant, or shell allow-once); `allowAlways`
/// persists a standing shell-command rule and is offered only for non-highRisk
/// commands.
public enum HarnessGateApproval: String, Sendable {
    case allow
    case allowAlways
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

    public func prepareUserQueryTurn(
        request: AppHarnessTurnRequest,
        pointerTask: UserQueryNotchTask?,
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
                "source": "userQuery",
                "traceID": traceID
            ]) { current, _ in current }
        )
        await threadStore.upsertThread(thread)
        await mirrorUserQueryEvents(
            request.recentEvents,
            threadID: threadID,
            taskID: taskID
        )
        await mirrorUserQueryAssets(
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
                "source": "userQuery"
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
                    "source": "userQuery",
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
    public func approvePermissionGate(
        taskID: String,
        decision: HarnessGateApproval = .allow,
        reason: String
    ) async -> HarnessTaskState? {
        guard let task = await coordinator.task(id: taskID),
              task.status == .waitingForPermission,
              let continuation = task.pendingContinuation else {
            return nil
        }

        // Shell-command consent: persist an always-allow rule or grant a single
        // use, then resume so the loop re-issues the command and the executor
        // finds it allowed.
        if continuation.metadata["gate"] == "shellConsent" {
            let signature = continuation.metadata["shell.signature"] ?? ""
            let tier = ShellRiskTier(rawValue: continuation.metadata["shell.tier"] ?? "") ?? .reversibleWrite
            if decision == .allowAlways, tier != .highRisk {
                await ShellPermissionPolicyStore.shared.allowAlways(signature, tier: tier)
            } else {
                await ShellPermissionPolicyStore.shared.grantOnce(taskID: taskID, signature: signature)
            }
            return await coordinator.resume(taskID: taskID, reason: reason)
        }

        // System (TCC) permission gate: the user approved in the notch, so NOW trigger the macOS
        // permission request. Only on a successful grant do we resume the loop to re-run the tool.
        if continuation.metadata["gate"] == "systemPermission" {
            guard let permission = Self.systemPermission(from: continuation.metadata) else { return nil }
            let granted = await SystemPermissionCoordinator.request(permission)
            guard granted else { return nil }
            return await coordinator.resume(taskID: taskID, reason: reason)
        }

        guard !continuation.missingPermissions.isEmpty else { return nil }
        return await coordinator.grantPermissions(
            taskID: taskID,
            permissions: Set(continuation.missingPermissions),
            reason: reason
        )
    }

    private static func systemPermission(from metadata: [String: String]) -> SystemPermission? {
        switch metadata["system.permission"] {
        case "automation":
            let target = metadata["system.target"]
            return .automation(targetBundleID: (target?.isEmpty == false) ? target : nil)
        case "screenRecording":
            return .screenRecording
        case "accessibility":
            return .accessibility
        case "microphone":
            return .microphone
        default:
            return nil
        }
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
            // A follow-up to a task whose loop already stopped (a live loop picks the message up directly
            // and never reaches here): queue the instruction so the resumed loop folds it in, and resume.
            // The original goal is preserved — the follow-up amends the work rather than replacing it,
            // the deliberate opposite of the old interrupt-and-restart behavior.
            if let followUpText = context.turn?.text,
               !followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = await coordinator.enqueueUserMessage(taskID: taskID, text: followUpText)
            }
            _ = await coordinator.resume(
                taskID: taskID,
                reason: "User query follow-up resumed task"
            )
        } else if !existing.status.canExecuteTools {
            _ = await coordinator.resume(
                taskID: taskID,
                reason: "User query resumed task"
            )
        }

        return await coordinator.updateContext(
            taskID: taskID,
            context: context
        ) ?? existing
    }

    private func mirrorUserQueryEvents(
        _ pointerEvents: [UserQueryTaskEvent],
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
                    role: HarnessThreadEventRole(userQueryRole: event.role),
                    text: event.text,
                    sequence: event.sequence,
                    createdAt: event.createdAt,
                    metadata: ["source": "userQueryTaskStore"]
                )
            )
        }
    }

    private func mirrorUserQueryAssets(
        _ pointerAssets: [UserQueryTaskAsset],
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
                        "source": "userQueryTaskStore",
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

}

private extension HarnessThreadEventRole {
    init(userQueryRole: UserQueryTaskEventRole) {
        switch userQueryRole {
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
