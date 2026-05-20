import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation

struct PointerPromptCommandHandlingResult: Equatable, Sendable {
    var status: LocalAppTaskLiveRunStatus
    var threadStatus: PointerPromptTaskStatus
    var routeKind: AppHarnessTurnRouteKind
    var summary: String
    var taskLabel: String?
    var traceID: String
    var metadata: [String: String]
    var documentReviewRequest: DocumentFormFillReviewRequest?
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

    init(
        catalog: LocalAppTaskCatalog = .defaultLocal(),
        localModelResolver: LocalModelTaskIntentResolver? = nil,
        liveRunner: LocalAppTaskLiveRunner? = nil,
        redactor: AIHarnessRedactor = AIHarnessRedactor(),
        memoryRetriever: SemanticRunMemoryRetriever = SemanticRunMemoryRetriever(),
        coordinatorRegistry: PointerPromptRunCoordinatorRegistry = PointerPromptRunCoordinatorRegistry(),
        targetMemoryStore: TargetMemoryJSONLStore? = try? TargetMemoryJSONLStore()
    ) {
        self.catalog = catalog
        self.appHarnessRouter = AppHarnessTurnRouter(catalog: catalog)
        self.coordinatorRegistry = coordinatorRegistry
        self.localModelResolver = localModelResolver ?? LocalModelTaskIntentResolver(catalog: catalog)
        self.liveRunner = liveRunner ?? LocalAppTaskLiveRunner(catalog: catalog)
        self.redactor = redactor
        self.memoryRetriever = memoryRetriever
        self.targetMemoryStore = targetMemoryStore
    }

    func handleSubmittedCommand(
        _ command: String,
        context: PointerPromptCommandContext?
    ) async -> PointerPromptCommandHandlingResult {
        let traceID = "pointer-prompt-\(UUID().uuidString)"
        let taskID = context?.task.id ?? traceID
        let routing = appHarnessRouter.route(
            request: Self.harnessRequest(command: command, context: context),
            traceID: traceID
        )
        switch routing.outcome.kind {
        case .conversation, .assistantResponse:
            return PointerPromptCommandHandlingResult(
                status: .completed,
                threadStatus: .chatting,
                routeKind: routing.outcome.kind,
                summary: routing.outcome.assistantResponse ?? "Tell me what local app task you want to work on.",
                taskLabel: nil,
                traceID: traceID,
                metadata: Self.contextPacketMetadata(routing.contextPacket, outcome: routing.outcome),
                documentReviewRequest: nil
            )
        case .clarification:
            return PointerPromptCommandHandlingResult(
                status: .needsConfirmation,
                threadStatus: .waitingForClarification,
                routeKind: routing.outcome.kind,
                summary: routing.outcome.assistantResponse ?? "What detail should I use?",
                taskLabel: nil,
                traceID: traceID,
                metadata: Self.contextPacketMetadata(routing.contextPacket, outcome: routing.outcome),
                documentReviewRequest: nil
            )
        case .noOp:
            return PointerPromptCommandHandlingResult(
                status: .completed,
                threadStatus: .chatting,
                routeKind: routing.outcome.kind,
                summary: "",
                taskLabel: nil,
                traceID: traceID,
                metadata: Self.contextPacketMetadata(routing.contextPacket, outcome: routing.outcome),
                documentReviewRequest: nil
            )
        case .actionableIntent, .review, .execution, .failure:
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
        let semanticMemoryResults = await retrieveSemanticMemory(
            command: modelCommand,
            resolution: resolution
        )
        let modelObservability = AIModelObservabilityReportBuilder.build(from: [localModelResult.trace])

        let result = await taskLiveRunner.run(
            command: modelCommand,
            traceID: traceID,
            resolution: resolution,
            metadata: [
                "appHarness.route": routing.outcome.kind.rawValue,
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
        )
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

        let handlingResult = PointerPromptCommandHandlingResult(
            status: result.status,
            threadStatus: threadStatus(for: result),
            routeKind: routing.outcome.kind,
            summary: summary(for: result),
            taskLabel: taskLabel(for: result),
            traceID: traceID,
            metadata: result.metadata.merging(
                Self.contextPacketMetadata(routing.contextPacket, outcome: routing.outcome)
            ) { current, _ in current },
            documentReviewRequest: documentReviewRequest(
                traceID: traceID,
                result: result
            )
        )
        await coordinatorRegistry.finish(taskID: taskID)
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
            return "App unavailable"
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
        switch definition.taskType {
        case "weather_lookup":
            if let city = entities["city"], !city.isEmpty {
                return "Weather for \(city)"
            }
            return "Weather lookup"
        case "media_playback":
            if let query = entities["query"], !query.isEmpty {
                return "Play \(query)"
            }
            return "Play media"
        case "document_form_fill":
            return "Fill PDF"
        default:
            return definition.taskType
                .split(separator: "_")
                .map { word in word.prefix(1).uppercased() + word.dropFirst() }
                .joined(separator: " ")
        }
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

    private static func harnessRequest(
        command: String,
        context: PointerPromptCommandContext?
    ) -> AppHarnessTurnRequest {
        AppHarnessTurnRequest(
            turn: AppHarnessTurn(
                text: command,
                source: context?.isFollowUp == true ? .followUp : .typedPrompt,
                taskID: context?.task.id,
                isFollowUp: context?.isFollowUp ?? false
            ),
            recentEvents: context?.recentEvents ?? [],
            assets: context?.assets ?? [],
            policy: ["localInput": "guarded"]
        )
    }

    private static func contextPacketMetadata(
        _ packet: AppHarnessContextPacket,
        outcome: AppHarnessRoutingOutcome
    ) -> [String: String] {
        [
            "appHarness.route": outcome.kind.rawValue,
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
