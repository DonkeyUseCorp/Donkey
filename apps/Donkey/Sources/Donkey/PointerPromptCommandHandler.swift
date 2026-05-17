import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation

struct PointerPromptCommandHandlingResult: Equatable, Sendable {
    var status: LocalAppTaskLiveRunStatus
    var summary: String
    var traceID: String
    var metadata: [String: String]
}

protocol PointerPromptCommandHandling: Sendable {
    func handleSubmittedCommand(_ command: String) async -> PointerPromptCommandHandlingResult
}

struct LocalAppPointerPromptCommandHandler: PointerPromptCommandHandling {
    var catalog: LocalAppTaskCatalog
    var localModelResolver: LocalModelTaskIntentResolver
    var liveRunner: LocalAppTaskLiveRunner

    init(
        catalog: LocalAppTaskCatalog = .defaultLocal(),
        localModelResolver: LocalModelTaskIntentResolver? = nil,
        liveRunner: LocalAppTaskLiveRunner? = nil
    ) {
        self.catalog = catalog
        self.localModelResolver = localModelResolver ?? LocalModelTaskIntentResolver(catalog: catalog)
        self.liveRunner = liveRunner ?? LocalAppTaskLiveRunner(catalog: catalog)
    }

    func handleSubmittedCommand(_ command: String) async -> PointerPromptCommandHandlingResult {
        let traceID = "pointer-prompt-\(UUID().uuidString)"
        let localModelResult = await localModelResolver.resolve(
            command: command,
            sourceTraceID: traceID
        )
        let localModelResolution = localModelResult.resolution
        let deterministicResolution = catalog.resolve(command: command)
        let shouldUseDeterministicFallback = localModelResolution.status == .unsupportedCommand
            && localModelResolution.metadata["reason"] == "localModelIntentUnavailable"
            && deterministicResolution.status != .unsupportedCommand
        let resolution = shouldUseDeterministicFallback
            ? deterministicResolution
            : localModelResolution
        let parserSource = shouldUseDeterministicFallback ? "deterministicFallback" : "localModel"

        let result = await liveRunner.run(
            command: command,
            traceID: traceID,
            resolution: resolution,
            metadata: [
                "intentParser": parserSource,
                "modelCallID": localModelResult.trace.id,
                "modelCallStatus": localModelResult.trace.status.rawValue,
                "modelValidationStatus": localModelResult.trace.validationStatus
            ]
        )

        return PointerPromptCommandHandlingResult(
            status: result.status,
            summary: summary(for: result),
            traceID: traceID,
            metadata: result.metadata
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
                return "Need \(reason)"
            }
            return "Need more detail"
        case .appUnavailable:
            return "App unavailable"
        case .unsupportedCommand:
            return "Unsupported command"
        case .failedSafe:
            return "Stopped safely"
        }
    }
}
