import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation
import OSLog

private enum PointerPromptLog {
    static let commands = Logger(subsystem: "com.donkey.app", category: "pointer-prompt")
}

struct PointerPromptCommandHandlingResult: Equatable, Sendable {
    var status: LocalAppTaskLiveRunStatus
    var threadStatus: PointerPromptTaskStatus
    var decision: AppHarnessDecision
    var summary: String
    var taskLabel: String?
    var traceID: String
    var metadata: [String: String]
    var documentReviewRequest: DocumentFormFillReviewRequest?
    var cursorGuideRequest: PointerCoachCursorGuideRequest?
}

struct DocumentFormFillReviewRequest: Equatable, Sendable {
    var plan: DocumentFormFillPlan
    var definition: LocalAppTaskDefinition
    var traceID: String
}

struct PointerPromptCommandContext: Equatable, Sendable {
    var task: PointerPromptNotchTask
    var recentEvents: [PointerPromptTaskEvent]
    var assets: [PointerPromptTaskAsset]
    var isFollowUp: Bool
    var turnSource: AppHarnessTurnSource = .typedPrompt
}

protocol PointerPromptCommandHandling: Sendable {
    func handleSubmittedCommand(
        _ command: String,
        context: PointerPromptCommandContext?
    ) async -> PointerPromptCommandHandlingResult
    func pauseCommand(taskID: String) async -> Bool
    func resumeCommand(taskID: String) async -> Bool
}

extension PointerPromptCommandHandling {
    func handleSubmittedCommand(_ command: String) async -> PointerPromptCommandHandlingResult {
        await handleSubmittedCommand(command, context: nil)
    }
}

struct LocalAppPointerPromptCommandHandler: PointerPromptCommandHandling {
    var catalog: LocalAppTaskCatalog
    var appHarnessRouter: AppHarnessTurnRouter
    var localModelResolver: LocalModelTaskIntentResolver
    var liveRunner: LocalAppTaskLiveRunner
    var redactor: AIHarnessRedactor
    var memoryRetriever: SemanticRunMemoryRetriever
    var coordinatorRegistry: PointerPromptRunCoordinatorRegistry
    var targetMemoryStore: TargetMemoryJSONLStore?
    var pointerCoachGuideResolver: any PointerCoachCursorGuideResolving

    init(
        catalog: LocalAppTaskCatalog = .defaultLocal(),
        localModelResolver: LocalModelTaskIntentResolver? = nil,
        liveRunner: LocalAppTaskLiveRunner? = nil,
        redactor: AIHarnessRedactor = AIHarnessRedactor(),
        memoryRetriever: SemanticRunMemoryRetriever = SemanticRunMemoryRetriever(),
        coordinatorRegistry: PointerPromptRunCoordinatorRegistry = PointerPromptRunCoordinatorRegistry(),
        targetMemoryStore: TargetMemoryJSONLStore? = try? TargetMemoryJSONLStore(),
        pointerCoachGuideResolver: any PointerCoachCursorGuideResolving = ProcessBackedLocalLLMPointerCoachCursorGuideResolver()
    ) {
        self.catalog = catalog
        self.appHarnessRouter = AppHarnessTurnRouter(catalog: catalog)
        self.coordinatorRegistry = coordinatorRegistry
        self.localModelResolver = localModelResolver ?? LocalModelTaskIntentResolver(catalog: catalog)
        self.liveRunner = liveRunner ?? LocalAppTaskLiveRunner(catalog: catalog)
        self.redactor = redactor
        self.memoryRetriever = memoryRetriever
        self.targetMemoryStore = targetMemoryStore
        self.pointerCoachGuideResolver = pointerCoachGuideResolver
    }

    func handleSubmittedCommand(
        _ command: String,
        context: PointerPromptCommandContext?
    ) async -> PointerPromptCommandHandlingResult {
        let traceID = "pointer-prompt-\(UUID().uuidString)"
        let taskID = context?.task.id ?? traceID
        logSubmittedCommand(command, traceID: traceID, taskID: taskID, context: context)
        let cursorGuideResolution = await pointerCoachGuideResolver.resolveGuide(
            PointerCoachCursorGuideResolverRequest(
                command: command,
                runtimeCapabilities: Self.runtimeCapabilities(for: catalog),
                cacheSnippets: LocalItemResolutionCache.shared.contextSnippets(for: command),
                sourceTraceID: traceID
            )
        )
        if let cursorGuideRequest = cursorGuideResolution.guideRequest {
            let result = PointerPromptCommandHandlingResult(
                status: .completed,
                threadStatus: .chatting,
                decision: AppHarnessDecision(
                    kind: .respond,
                    message: "Showing you.",
                    traceID: traceID,
                    metadata: [
                        "structuredDecision": "true",
                        "router": "pointerCoachGuide"
                    ]
                ),
                summary: "Showing you.",
                taskLabel: cursorGuideRequest.title,
                traceID: traceID,
                metadata: cursorGuideRequest.metadata.merging([
                    "appHarness.decision": AppHarnessDecisionKind.respond.rawValue,
                    "appHarness.context.traceID": traceID,
                    "cursorGuide.modelCallID": cursorGuideResolution.trace.id,
                    "cursorGuide.modelStatus": cursorGuideResolution.trace.status.rawValue,
                    "cursorGuide.validationStatus": cursorGuideResolution.trace.validationStatus,
                    "cursorGuide.confidence": Self.formatLatency(cursorGuideResolution.confidence),
                    "cursorGuide.reason": cursorGuideResolution.reason,
                    "cursorGuide.stepCount": String(cursorGuideRequest.steps.count)
                ]) { current, _ in current },
                documentReviewRequest: nil,
                cursorGuideRequest: cursorGuideRequest
            )
            logHandlingResult(result, stage: "cursorGuide", hint: "Showing an instructional cursor guide.")
            return result
        }

        let routing = appHarnessRouter.route(
            request: Self.harnessRequest(command: command, context: context),
            traceID: traceID
        )
        logRouting(command: command, traceID: traceID, taskID: taskID, routing: routing)
        switch routing.outcome.decision.kind {
        case .respond:
            let result = PointerPromptCommandHandlingResult(
                status: .completed,
                threadStatus: .chatting,
                decision: routing.outcome.decision,
                summary: routing.outcome.assistantResponse ?? "Tell me what local app task you want to work on.",
                taskLabel: nil,
                traceID: traceID,
                metadata: Self.contextPacketMetadata(routing.contextPacket, outcome: routing.outcome),
                documentReviewRequest: nil,
                cursorGuideRequest: nil
            )
            logHandlingResult(result, stage: "conversation", hint: routingHint(for: routing))
            return result
        case .askClarification:
            let result = PointerPromptCommandHandlingResult(
                status: .needsConfirmation,
                threadStatus: .waitingForClarification,
                decision: routing.outcome.decision,
                summary: routing.outcome.assistantResponse ?? "What detail should I use?",
                taskLabel: nil,
                traceID: traceID,
                metadata: Self.contextPacketMetadata(routing.contextPacket, outcome: routing.outcome),
                documentReviewRequest: nil,
                cursorGuideRequest: nil
            )
            logHandlingResult(result, stage: "routing", hint: routingHint(for: routing))
            return result
        case .noOp:
            let result = PointerPromptCommandHandlingResult(
                status: .completed,
                threadStatus: .chatting,
                decision: routing.outcome.decision,
                summary: "",
                taskLabel: nil,
                traceID: traceID,
                metadata: Self.contextPacketMetadata(routing.contextPacket, outcome: routing.outcome),
                documentReviewRequest: nil,
                cursorGuideRequest: nil
            )
            logHandlingResult(result, stage: "empty", hint: "Empty command; no action was run.")
            return result
        case .openReview, .runLocalTask:
            break
        }

        let coordinator = await coordinatorRegistry.coordinator(for: taskID)
        var taskLiveRunner = liveRunner
        taskLiveRunner.coordinator = coordinator
        let modelCommand = Self.modelCommand(
            for: command,
            context: context,
            contextPacket: routing.contextPacket
        )
        let redaction = redactor.redact(modelCommand, surface: .modelContext)
        let memoryProposalDecisions = (try? ProviderDecodedMemoryProposalHandler.decisions(
            from: Data("[]".utf8),
            decidedAt: Self.now()
        )) ?? []
        let parseStartedAt = Self.uptimeMilliseconds()
        let localModelResult = await localModelResolver.resolve(
            command: modelCommand,
            sourceTraceID: traceID
        )
        let resolution = localModelResult.resolution
        let parseLatencyMS = Self.uptimeMilliseconds() - parseStartedAt
        logModelResolution(
            command: modelCommand,
            traceID: traceID,
            resolution: resolution,
            trace: localModelResult.trace,
            latencyMS: parseLatencyMS
        )
        let semanticMemoryResults = await retrieveSemanticMemory(
            command: modelCommand,
            resolution: resolution
        )
        let modelObservability = AIModelObservabilityReportBuilder.build(from: [localModelResult.trace])
        let modelMetadata = [
            "appHarness.decision": routing.outcome.decision.kind.rawValue,
            "appHarness.context.promptCharacters": String(routing.contextPacket.promptText.count),
            "appHarness.context.redactionCount": String(routing.contextPacket.redactionCount),
            "intentParser": "localModel",
            "latency.commandParseMS": Self.formatLatency(parseLatencyMS),
            "modelCallID": localModelResult.trace.id,
            "modelCallStatus": localModelResult.trace.status.rawValue,
            "modelValidationStatus": localModelResult.trace.validationStatus,
            "modelObservability.callCount": String(modelObservability.callCount),
            "modelObservability.acceptedCount": String(modelObservability.acceptedCount),
            "modelObservability.recoverySuccessCount": String(modelObservability.recoverySuccessCount),
            "redaction.modelContext.count": String(redaction.redactionCount),
            "semanticMemory.resultCount": String(semanticMemoryResults.count),
            "semanticMemory.recordIDs": semanticMemoryResults.map(\.record.id).joined(separator: ","),
            "semanticMemory.targetID": semanticMemoryTargetID(for: resolution) ?? "",
            "memoryProposal.decisionCount": String(memoryProposalDecisions.count)
        ].merging(Self.contextMetadata(context)) { current, _ in current }

        await coordinator.recordToolEvent(
            capability: .model,
            decision: .allow,
            toolName: "local-task-intent-parser",
            summary: "Parsed local app command",
            traceID: traceID,
            metadata: [
                "modelCallID": localModelResult.trace.id,
                "modelCallStatus": localModelResult.trace.status.rawValue,
                "modelValidationStatus": localModelResult.trace.validationStatus
            ]
        )

        if Self.shouldRespondWithoutLocalTask(resolution) {
            let response = "I couldn't find a supported local action for that yet."
            let decision = AppHarnessDecision(
                kind: .respond,
                message: response,
                traceID: traceID,
                metadata: [
                    "structuredDecision": "true",
                    "router": "modelNoTaskIntent",
                    "resolution.status": resolution.status.rawValue
                ]
            )
            let handlingResult = PointerPromptCommandHandlingResult(
                status: .completed,
                threadStatus: .chatting,
                decision: decision,
                summary: response,
                taskLabel: nil,
                traceID: traceID,
                metadata: modelMetadata.merging([
                    "appHarness.decision": AppHarnessDecisionKind.respond.rawValue,
                    "router": "modelNoTaskIntent",
                    "resolution.status": resolution.status.rawValue,
                    "resolution.reason": resolution.metadata["reason"] ?? ""
                ]) { _, new in new }.merging(
                    Self.contextPacketMetadata(routing.contextPacket, outcome: routing.outcome)
                ) { current, _ in current },
                documentReviewRequest: nil,
                cursorGuideRequest: nil
            )
            await coordinatorRegistry.finish(taskID: taskID)
            logHandlingResult(
                handlingResult,
                stage: "conversation",
                hint: "No local task intent was produced; responded in the thread."
            )
            return handlingResult
        }

        let result = await taskLiveRunner.run(
            command: modelCommand,
            traceID: traceID,
            resolution: resolution,
            metadata: modelMetadata
        )

        let handlingResult = PointerPromptCommandHandlingResult(
            status: result.status,
            threadStatus: threadStatus(for: result),
            decision: routing.outcome.decision,
            summary: summary(for: result),
            taskLabel: taskLabel(for: result),
            traceID: traceID,
            metadata: result.metadata.merging(
                Self.contextPacketMetadata(routing.contextPacket, outcome: routing.outcome)
            ) { current, _ in current },
            documentReviewRequest: documentReviewRequest(
                traceID: traceID,
                result: result
            ),
            cursorGuideRequest: nil
        )
        await coordinatorRegistry.finish(taskID: taskID)
        logHandlingResult(
            handlingResult,
            stage: "localTask",
            hint: runHint(for: result)
        )
        return handlingResult
    }

    func pauseCommand(taskID: String) async -> Bool {
        await coordinatorRegistry.pause(
            taskID: taskID,
            reason: "Pointer prompt paused task"
        )
    }

    func resumeCommand(taskID: String) async -> Bool {
        await coordinatorRegistry.resume(
            taskID: taskID,
            reason: "Pointer prompt resumed task"
        )
    }

    private func logRouting(
        command: String,
        traceID: String,
        taskID: String,
        routing: AppHarnessRoutingResult
    ) {
        let decision = routing.outcome.decision.kind.rawValue
        let router = routing.outcome.metadata["router"] ?? "unknown"
        let resolution = routing.outcome.resolution?.status.rawValue ?? "none"
        let missingDetail = routing.outcome.missingDetail ?? ""
        let taskType = routing.outcome.resolution?.definition?.taskType ?? ""
        let hint = routingHint(for: routing)
        PointerPromptLog.commands.notice(
            "command routed traceID=\(traceID, privacy: .public) taskID=\(taskID, privacy: .public) decision=\(decision, privacy: .public) router=\(router, privacy: .public) resolution=\(resolution, privacy: .public) taskType=\(taskType, privacy: .public) missingDetail=\(missingDetail, privacy: .public) hint=\(hint, privacy: .public) command=\(command, privacy: .public)"
        )
    }

    private func logSubmittedCommand(
        _ command: String,
        traceID: String,
        taskID: String,
        context: PointerPromptCommandContext?
    ) {
        let source = context?.turnSource.rawValue ?? AppHarnessTurnSource.typedPrompt.rawValue
        let isFollowUp = context?.isFollowUp ?? false
        PointerPromptLog.commands.notice(
            "command submitted traceID=\(traceID, privacy: .public) taskID=\(taskID, privacy: .public) source=\(source, privacy: .public) followUp=\(String(isFollowUp), privacy: .public) command=\(command, privacy: .public)"
        )
    }

    private func logModelResolution(
        command: String,
        traceID: String,
        resolution: LocalAppTaskCatalogResolution,
        trace: AIModelCallTrace,
        latencyMS: Double
    ) {
        let taskType = resolution.definition?.taskType ?? resolution.intent?.taskType ?? ""
        let reason = resolution.metadata["reason"] ?? ""
        let latency = Self.formatLatency(latencyMS)
        PointerPromptLog.commands.notice(
            "intent resolved traceID=\(traceID, privacy: .public) resolution=\(resolution.status.rawValue, privacy: .public) taskType=\(taskType, privacy: .public) reason=\(reason, privacy: .public) modelStatus=\(trace.status.rawValue, privacy: .public) validation=\(trace.validationStatus, privacy: .public) latencyMS=\(latency, privacy: .public) command=\(command, privacy: .public)"
        )
    }

    private func logHandlingResult(
        _ result: PointerPromptCommandHandlingResult,
        stage: String,
        hint: String
    ) {
        let taskLabel = result.taskLabel ?? ""
        PointerPromptLog.commands.notice(
            "command finished traceID=\(result.traceID, privacy: .public) stage=\(stage, privacy: .public) status=\(result.status.rawValue, privacy: .public) threadStatus=\(result.threadStatus.rawValue, privacy: .public) summary=\(result.summary, privacy: .public) taskLabel=\(taskLabel, privacy: .public) hint=\(hint, privacy: .public)"
        )
    }

    private func routingHint(for routing: AppHarnessRoutingResult) -> String {
        let router = routing.outcome.metadata["router"] ?? ""
        switch router {
        case "simpleArithmetic":
            return "Answered a simple arithmetic question locally; no app workflow was run."
        case "followUpActionContext":
            return "Follow-up turn is being treated as an action for the existing task."
        case "modelIntent":
            return "Using local model intent classification with cache-backed local lookup."
        default:
            return "Router path \(router.isEmpty ? "unknown" : router)."
        }
    }

    private func runHint(for result: LocalAppTaskLiveRunResult) -> String {
        if let reason = result.metadata["reason"], !reason.isEmpty {
            return "Run reason: \(reason)."
        }
        if let automationBackend = result.metadata["automation.backend"],
           !automationBackend.isEmpty {
            let automationAction = result.metadata["automation.action"] ?? ""
            return "Automation \(automationBackend) \(automationAction) finished with status \(result.status.rawValue)."
        }
        if let verificationStatus = result.metadata["verification.status"],
           let verificationSummary = result.metadata["verification.summary"] {
            return "Verification \(verificationStatus): \(verificationSummary)."
        }
        return "Local app workflow finished with status \(result.status.rawValue)."
    }

    private static func shouldRespondWithoutLocalTask(_ resolution: LocalAppTaskCatalogResolution) -> Bool {
        resolution.intent == nil
            && resolution.status == .needsConfirmation
            && resolution.metadata["reason"] == "localModelIntentUnavailable"
    }

    private func retrieveSemanticMemory(
        command: String,
        resolution: LocalAppTaskCatalogResolution
    ) async -> [RunMemorySemanticResult] {
        guard let targetMemoryStore,
              let targetID = semanticMemoryTargetID(for: resolution),
              let records = try? await targetMemoryStore.records(targetID: targetID),
              !records.isEmpty
        else {
            return []
        }

        return await memoryRetriever.retrieve(
            query: RunMemorySemanticQuery(
                text: command,
                targetID: targetID,
                scope: .target,
                budget: RunMemoryRetrievalBudget(maxRecords: 3, maxPromptCharacters: 800)
            ),
            records: records
        )
    }

    private func semanticMemoryTargetID(
        for resolution: LocalAppTaskCatalogResolution
    ) -> String? {
        guard let definition = resolution.definition else { return nil }
        return LocalAppTaskAdapter(definition: definition).targetID
    }

    private func documentReviewRequest(
        traceID: String,
        result: LocalAppTaskLiveRunResult
    ) -> DocumentFormFillReviewRequest? {
        guard result.status == .needsUserReview,
              let plan = result.documentFormFillPlan,
              let definition = result.resolution.definition
        else {
            return nil
        }

        return DocumentFormFillReviewRequest(
            plan: plan,
            definition: definition,
            traceID: traceID
        )
    }

    private func summary(for result: LocalAppTaskLiveRunResult) -> String {
        switch result.status {
        case .completed:
            return "Done"
        case .needsUserReview:
            if let proposalCount = result.documentFormFillPlan?.proposals.count,
               proposalCount > 0 {
                return "Review \(proposalCount) fields"
            }
            return "Needs review"
        case .needsConfirmation:
            if let reason = result.resolution.metadata["reason"] {
                guard reason != "localModelIntentUnavailable",
                      reason != "needsConfirmation"
                else {
                    return "Need more detail"
                }
                return "Need \(reason)"
            }
            return "Need more detail"
        case .appUnavailable:
            if let appName = result.resolution.metadata["targetApp"] ?? result.resolution.availability?.target.appName {
                return "\(appName) not found"
            }
            return "App not found"
        case .unsupportedCommand:
            return "Need more detail"
        case .failedSafe:
            return "Stopped safely"
        }
    }

    private func threadStatus(for result: LocalAppTaskLiveRunResult) -> PointerPromptTaskStatus {
        switch result.status {
        case .completed:
            return .completed
        case .needsUserReview:
            return .waitingForReview
        case .needsConfirmation, .unsupportedCommand:
            return .waitingForClarification
        case .appUnavailable, .failedSafe:
            return .failed
        }
    }

    private func taskLabel(for result: LocalAppTaskLiveRunResult) -> String? {
        guard result.status == .completed || result.status == .needsUserReview,
              let definition = result.resolution.definition
        else {
            return nil
        }

        let entities = result.resolution.intent?.normalizedEntities ?? [:]
        if let template = definition.metadata["taskLabelTemplate"],
           let label = Self.renderTemplate(template, entities: entities),
           !label.isEmpty {
            return label
        }

        return Self.displayTitle(for: definition)
    }

    private static func displayTitle(for definition: LocalAppTaskDefinition) -> String {
        if let displayTitle = definition.metadata["displayTitle"], !displayTitle.isEmpty {
            return displayTitle
                .split(separator: " ")
                .map { word in word.prefix(1).uppercased() + word.dropFirst() }
                .joined(separator: " ")
        }

        return definition.taskType
            .split(separator: "_")
            .map { word in word.prefix(1).uppercased() + word.dropFirst() }
            .joined(separator: " ")
    }

    private static func renderTemplate(
        _ template: String,
        entities: [String: String]
    ) -> String? {
        var rendered = template
        for (name, value) in entities {
            rendered = rendered.replacingOccurrences(of: "{\(name)}", with: value)
        }
        guard !rendered.contains("{") else { return nil }
        return rendered.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func uptimeMilliseconds() -> Double {
        ProcessInfo.processInfo.systemUptime * 1_000
    }

    private static func formatLatency(_ milliseconds: Double) -> String {
        String(format: "%.3f", max(0, milliseconds))
    }

    private static func now() -> RunTraceTimestamp {
        RunTraceTimestamp(
            wallClock: Date(),
            monotonicUptimeNanoseconds: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        )
    }

    private static func modelCommand(
        for command: String,
        context: PointerPromptCommandContext?,
        contextPacket: AppHarnessContextPacket
    ) -> String {
        guard let context, context.isFollowUp else {
            return contextPacket.currentTurn.text
        }

        return [
            "Existing task title: \(context.task.title)",
            "Existing task original request: \(context.task.commandText)",
            "Existing task status: \(context.task.status.rawValue)",
            contextPacket.promptText
        ]
        .compactMap(\.self)
        .joined(separator: "\n\n")
    }

    private static func runtimeCapabilities(for catalog: LocalAppTaskCatalog) -> [String] {
        catalog.taskDefinitions
            .map { definition in
                let title = displayTitle(for: definition)
                let entities = definition.entityRules.map(\.name).joined(separator: ",")
                return "\(definition.taskType): \(title) app=\(definition.targetApp.appName) entities=\(entities)"
            }
            .sorted()
    }

    private static func harnessRequest(
        command: String,
        context: PointerPromptCommandContext?
    ) -> AppHarnessTurnRequest {
        AppHarnessTurnRequest(
            turn: AppHarnessTurn(
                text: command,
                source: context?.isFollowUp == true ? .followUp : context?.turnSource ?? .typedPrompt,
                taskID: context?.task.id,
                isFollowUp: context?.isFollowUp ?? false
            ),
            recentEvents: context?.recentEvents ?? [],
            assets: context?.assets ?? [],
            memory: LocalItemResolutionCache.shared.contextSnippets(for: command),
            policy: ["localInput": "guarded"]
        )
    }

    private static func contextPacketMetadata(
        _ packet: AppHarnessContextPacket,
        outcome: AppHarnessRoutingOutcome
    ) -> [String: String] {
        [
            "appHarness.decision": outcome.decision.kind.rawValue,
            "appHarness.decision.traceID": outcome.decision.traceID,
            "appHarness.missingDetail": outcome.missingDetail ?? "",
            "appHarness.context.traceID": packet.traceID,
            "appHarness.context.eventCount": String(packet.recentEvents.count),
            "appHarness.context.assetCount": String(packet.assets.count),
            "appHarness.context.promptCharacters": String(packet.promptText.count),
            "appHarness.context.redactionCount": String(packet.redactionCount)
        ]
    }

    private static func contextMetadata(_ context: PointerPromptCommandContext?) -> [String: String] {
        guard let context else { return [:] }

        return [
            "taskContext.taskID": context.task.id,
            "taskContext.isFollowUp": String(context.isFollowUp),
            "taskContext.eventCount": String(context.recentEvents.count),
            "taskContext.assetCount": String(context.assets.count)
        ]
    }
}

actor PointerPromptRunCoordinatorRegistry {
    private var coordinators: [String: RunCoordinator] = [:]

    func coordinator(for taskID: String) -> RunCoordinator {
        if let coordinator = coordinators[taskID] {
            return coordinator
        }

        let coordinator = RunCoordinator()
        coordinators[taskID] = coordinator
        return coordinator
    }

    func pause(taskID: String, reason: String) async -> Bool {
        guard let coordinator = coordinators[taskID] else { return false }

        await coordinator.pause(reason: reason)
        return true
    }

    func resume(taskID: String, reason: String) async -> Bool {
        guard let coordinator = coordinators[taskID] else { return false }

        await coordinator.resume(reason: reason)
        return true
    }

    func finish(taskID: String) {
        coordinators[taskID] = nil
    }
}
