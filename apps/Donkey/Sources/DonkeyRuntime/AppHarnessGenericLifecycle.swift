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
    public var conversation: HarnessConversation
    public var agent: HarnessAgentState
    public var compactedContext: HarnessCompactedConversationContext

    public init(
        conversation: HarnessConversation,
        agent: HarnessAgentState,
        compactedContext: HarnessCompactedConversationContext
    ) {
        self.conversation = conversation
        self.agent = agent
        self.compactedContext = compactedContext
    }
}

public struct AppHarnessGenericLifecycle: Sendable {
    public var conversationStore: any HarnessConversationStoring
    public var coordinator: HarnessAgentCoordinator
    public var compactor: HarnessConversationCompactor

    public init(
        conversationStore: (any HarnessConversationStoring)? = nil,
        coordinator: HarnessAgentCoordinator? = nil,
        compactor: HarnessConversationCompactor = HarnessConversationCompactor()
    ) {
        let resolvedConversationStore = conversationStore ?? FileHarnessConversationStore()
        self.conversationStore = resolvedConversationStore
        self.coordinator = coordinator ?? HarnessAgentCoordinator(conversationStore: resolvedConversationStore)
        self.compactor = compactor
    }

    public func prepareUserQueryTurn(
        request: AppHarnessTurnRequest,
        pointerTask: UserQueryConversation?,
        traceID: String,
        availableToolNames: [String],
        grantedPermissions: Set<HarnessPermission> = []
    ) async -> AppHarnessGenericLifecyclePreparedTurn {
        let conversationID = request.turn.conversationID ?? pointerTask?.id ?? traceID
        let agentID = pointerTask?.id ?? request.turn.conversationID ?? conversationID
        let title = pointerTask?.title ?? request.turn.text
        let now = Date()
        let existingConversation = await conversationStore.conversation(id: conversationID)
        let activeAgentIDs = Array(Set((existingConversation?.activeAgentIDs ?? []) + [agentID])).sorted()
        let conversation = HarnessConversation(
            id: conversationID,
            title: existingConversation?.title ?? title,
            status: .running,
            activeAgentIDs: activeAgentIDs,
            createdAt: existingConversation?.createdAt ?? now,
            updatedAt: now,
            metadata: (existingConversation?.metadata ?? [:]).merging([
                "source": "userQuery",
                "traceID": traceID
            ]) { current, _ in current }
        )
        await conversationStore.upsertConversation(conversation)
        await mirrorUserQueryEvents(
            request.recentEvents,
            conversationID: conversationID,
            agentID: agentID
        )
        await mirrorUserQueryAssets(
            request.assets,
            conversationID: conversationID,
            agentID: agentID
        )
        await appendCurrentTurnIfNeeded(
            request.turn,
            conversationID: conversationID,
            agentID: agentID
        )

        let context = HarnessContextSnapshot(
            turn: request.turn,
            conversationID: conversationID,
            memory: request.memory,
            availableToolNames: availableToolNames,
            policy: request.policy,
            metadata: [
                "traceID": traceID,
                "source": "userQuery"
            ]
        )
        let agent = await loadOrCreateAgent(
            agentID: agentID,
            conversationID: conversationID,
            goal: request.turn.text,
            context: context,
            grantedPermissions: grantedPermissions
        )
        let events = await conversationStore.events(conversationID: conversationID)
        let assets = await conversationStore.assets(conversationID: conversationID)
        let activeAgents = await coordinator.activeAgents()
            .filter { $0.conversationID == conversationID }
        let compactedContext = compactor.compact(
            conversation: conversation,
            currentTurn: request.turn,
            events: events,
            assets: assets,
            activeAgents: activeAgents
        )
        await conversationStore.appendCompactionSnapshot(
            HarnessCompactionSnapshot(
                conversationID: conversationID,
                agentIDs: compactedContext.activeAgents.map(\.id),
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
            conversation: conversation,
            agent: agent,
            compactedContext: compactedContext
        )
    }

    public func agentState(agentID: String) async -> HarnessAgentState? {
        await coordinator.agent(id: agentID)
    }

    @discardableResult
    public func pauseAgent(agentID: String, reason: String) async -> HarnessAgentState? {
        await coordinator.pause(agentID: agentID, reason: reason)
    }

    @discardableResult
    public func resumeAgent(agentID: String, reason: String) async -> HarnessAgentState? {
        await coordinator.resume(agentID: agentID, reason: reason)
    }

    @discardableResult
    public func approvePermissionGate(
        agentID: String,
        decision: HarnessGateApproval = .allow,
        reason: String
    ) async -> HarnessAgentState? {
        guard let agent = await coordinator.agent(id: agentID),
              agent.status == .waitingForPermission,
              let continuation = agent.pendingContinuation else {
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
                await ShellPermissionPolicyStore.shared.grantOnce(agentID: agentID, signature: signature)
            }
            return await coordinator.resume(agentID: agentID, reason: reason)
        }

        // System (TCC) permission gate: the user approved in the notch, so NOW trigger the macOS
        // permission request. Only on a successful grant do we resume the loop to re-run the tool.
        if continuation.metadata["gate"] == "systemPermission" {
            guard let permission = Self.systemPermission(from: continuation.metadata) else { return nil }
            let granted = await SystemPermissionCoordinator.request(permission)
            guard granted else { return nil }
            return await coordinator.resume(agentID: agentID, reason: reason)
        }

        guard !continuation.missingPermissions.isEmpty else { return nil }
        return await coordinator.grantPermissions(
            agentID: agentID,
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

    private func loadOrCreateAgent(
        agentID: String,
        conversationID: String,
        goal: String,
        context: HarnessContextSnapshot,
        grantedPermissions: Set<HarnessPermission>
    ) async -> HarnessAgentState {
        guard let existing = await coordinator.agent(id: agentID) else {
            return await coordinator.createAgent(
                id: agentID,
                conversationID: conversationID,
                goal: goal,
                context: context,
                grantedPermissions: grantedPermissions
            )
        }

        if existing.status == .waitingForUser,
           let response = context.turn?.text,
           !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = await coordinator.provideUserResponse(
                agentID: agentID,
                response: response
            )
        } else if context.turn?.isFollowUp == true {
            // A follow-up to a agent whose loop already stopped (a live loop picks the message up directly
            // and never reaches here): queue the instruction so the resumed loop folds it in, and resume.
            // The original goal is preserved — the follow-up amends the work rather than replacing it,
            // the deliberate opposite of the old interrupt-and-restart behavior.
            if let followUpText = context.turn?.text,
               !followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = await coordinator.enqueueUserMessage(agentID: agentID, text: followUpText)
            }
            _ = await coordinator.resume(
                agentID: agentID,
                reason: "User query follow-up resumed agent"
            )
        } else if !existing.status.canExecuteTools {
            _ = await coordinator.resume(
                agentID: agentID,
                reason: "User query resumed agent"
            )
        }

        return await coordinator.updateContext(
            agentID: agentID,
            context: context
        ) ?? existing
    }

    private func mirrorUserQueryEvents(
        _ pointerEvents: [UserQueryConversationEvent],
        conversationID: String,
        agentID: String
    ) async {
        let existingIDs = Set(await conversationStore.events(conversationID: conversationID).map(\.id))
        for event in pointerEvents where !existingIDs.contains(event.id) {
            await conversationStore.appendEvent(
                HarnessConversationEvent(
                    id: event.id,
                    conversationID: conversationID,
                    agentID: agentID,
                    role: HarnessConversationEventRole(userQueryRole: event.role),
                    text: event.text,
                    sequence: event.sequence,
                    createdAt: event.createdAt,
                    metadata: ["source": "userQueryTaskStore"]
                )
            )
        }
    }

    private func mirrorUserQueryAssets(
        _ pointerAssets: [UserQueryConversationAsset],
        conversationID: String,
        agentID: String
    ) async {
        let existingIDs = Set(await conversationStore.assets(conversationID: conversationID).map(\.id))
        for asset in pointerAssets where !existingIDs.contains(asset.id) {
            await conversationStore.appendAsset(
                HarnessConversationAsset(
                    id: asset.id,
                    conversationID: conversationID,
                    agentID: agentID,
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
        conversationID: String,
        agentID: String
    ) async {
        let events = await conversationStore.events(conversationID: conversationID)
        let hasCurrentTurn = events.contains { event in
            event.metadata["turnID"] == turn.id
                || (event.role == .user && event.text == turn.text)
        }
        guard !hasCurrentTurn else { return }

        await conversationStore.appendEvent(
            HarnessConversationEvent(
                id: "turn-\(turn.id)",
                conversationID: conversationID,
                agentID: agentID,
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

private extension HarnessConversationEventRole {
    init(userQueryRole: UserQueryConversationEventRole) {
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
