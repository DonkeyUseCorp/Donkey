import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation

struct PointerPromptCommandHandlingResult: Equatable, Sendable {
    var status: LocalAppTaskLiveRunStatus
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

protocol PointerPromptCommandHandling: Sendable {
    func handleSubmittedCommand(_ command: String) async -> PointerPromptCommandHandlingResult
}

struct LocalAppPointerPromptCommandHandler: PointerPromptCommandHandling {
    var catalog: LocalAppTaskCatalog
    var localModelResolver: LocalModelTaskIntentResolver
    var liveRunner: LocalAppTaskLiveRunner
    var redactor: AIHarnessRedactor
    var memoryRetriever: SemanticRunMemoryRetriever
    var coordinator: RunCoordinator
    var targetMemoryStore: TargetMemoryJSONLStore?

    init(
        catalog: LocalAppTaskCatalog = .defaultLocal(),
        localModelResolver: LocalModelTaskIntentResolver? = nil,
        liveRunner: LocalAppTaskLiveRunner? = nil,
        redactor: AIHarnessRedactor = AIHarnessRedactor(),
        memoryRetriever: SemanticRunMemoryRetriever = SemanticRunMemoryRetriever(),
        coordinator: RunCoordinator = RunCoordinator(),
        targetMemoryStore: TargetMemoryJSONLStore? = try? TargetMemoryJSONLStore()
    ) {
        self.catalog = catalog
        self.coordinator = coordinator
        self.localModelResolver = localModelResolver ?? LocalModelTaskIntentResolver(catalog: catalog)
        self.liveRunner = liveRunner ?? LocalAppTaskLiveRunner(catalog: catalog, coordinator: coordinator)
        self.redactor = redactor
        self.memoryRetriever = memoryRetriever
        self.targetMemoryStore = targetMemoryStore
    }

    func handleSubmittedCommand(_ command: String) async -> PointerPromptCommandHandlingResult {
        let traceID = "pointer-prompt-\(UUID().uuidString)"
        let redaction = redactor.redact(command, surface: .modelContext)
        let memoryProposalDecisions = (try? ProviderDecodedMemoryProposalHandler.decisions(
            from: Data("[]".utf8),
            decidedAt: Self.now()
        )) ?? []
        let parseStartedAt = Self.uptimeMilliseconds()
        let localModelResult = await localModelResolver.resolve(
            command: command,
            sourceTraceID: traceID
        )
        let resolution = localModelResult.resolution
        let parseLatencyMS = Self.uptimeMilliseconds() - parseStartedAt
        let semanticMemoryResults = await retrieveSemanticMemory(
            command: command,
            resolution: resolution
        )
        let modelObservability = AIModelObservabilityReportBuilder.build(from: [localModelResult.trace])

        let result = await liveRunner.run(
            command: command,
            traceID: traceID,
            resolution: resolution,
            metadata: [
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
            ]
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

        return PointerPromptCommandHandlingResult(
            status: result.status,
            summary: summary(for: result),
            taskLabel: taskLabel(for: result),
            traceID: traceID,
            metadata: result.metadata,
            documentReviewRequest: documentReviewRequest(
                traceID: traceID,
                result: result
            )
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
}
