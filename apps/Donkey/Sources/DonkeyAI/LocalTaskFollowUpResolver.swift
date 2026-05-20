import DonkeyContracts
import DonkeyRuntime
import Foundation

public struct PointerPromptFollowUpCandidate: Codable, Equatable, Sendable {
    public var taskID: String
    public var title: String
    public var detail: String
    public var commandText: String
    public var status: PointerPromptTaskStatus
    public var updatedAt: Date
    public var recentEvents: [String]
    public var assetNames: [String]

    public init(
        taskID: String,
        title: String,
        detail: String,
        commandText: String,
        status: PointerPromptTaskStatus,
        updatedAt: Date,
        recentEvents: [String] = [],
        assetNames: [String] = []
    ) {
        self.taskID = taskID
        self.title = title
        self.detail = detail
        self.commandText = commandText
        self.status = status
        self.updatedAt = updatedAt
        self.recentEvents = recentEvents
        self.assetNames = assetNames
    }
}

public struct PointerPromptFollowUpResolverRequest: Equatable, Sendable {
    public var text: String
    public var candidates: [PointerPromptFollowUpCandidate]
    public var sourceTraceID: String
    public var routeRequest: AIModelRouteRequest

    public init(
        text: String,
        candidates: [PointerPromptFollowUpCandidate],
        sourceTraceID: String,
        routeRequest: AIModelRouteRequest = AIModelRouteRequest(
            jobType: .taskIntent,
            privacyMode: .privacySensitive,
            latencyTolerance: .interactive
        )
    ) {
        self.text = text
        self.candidates = candidates
        self.sourceTraceID = sourceTraceID
        self.routeRequest = routeRequest
    }
}

public struct PointerPromptFollowUpResolverResult: Equatable, Sendable {
    public var taskID: String?
    public var confidence: Double
    public var reason: String
    public var trace: AIModelCallTrace

    public init(taskID: String?, confidence: Double, reason: String, trace: AIModelCallTrace) {
        self.taskID = taskID
        self.confidence = confidence
        self.reason = reason
        self.trace = trace
    }
}

public protocol PointerPromptFollowUpResolving: Sendable {
    func resolveFollowUp(_ request: PointerPromptFollowUpResolverRequest) async -> PointerPromptFollowUpResolverResult
}

public struct ProcessBackedLocalLLMTaskFollowUpResolver: PointerPromptFollowUpResolving {
    public static let schemaID = "task_followup_resolution_v1"

    public var router: AIModelRouter
    public var sidecarRunner: any LocalJSONSidecarRunning
    public var encoder: JSONEncoder
    public var decoder: JSONDecoder

    public init(
        router: AIModelRouter = AIModelRouter(registry: .defaultHybridPlanner),
        sidecarRunner: any LocalJSONSidecarRunning = ProcessBackedLocalJSONSidecarRunner(),
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.router = router
        self.sidecarRunner = sidecarRunner
        self.encoder = encoder
        self.decoder = decoder
    }

    public func resolveFollowUp(
        _ request: PointerPromptFollowUpResolverRequest
    ) async -> PointerPromptFollowUpResolverResult {
        let entry: AIModelRegistryEntry
        do {
            entry = try router.route(request.routeRequest.limitingProviders([.localRuntime]))
        } catch {
            return result(
                entry: nil,
                request: request,
                status: .invalidOutput,
                validationStatus: "routingFailed",
                latencyMS: nil,
                metadata: ["error": String(describing: error)]
            )
        }

        let input = LocalLLMTaskFollowUpSidecarRequest(
            command: request.text,
            candidates: request.candidates,
            sourceTraceID: request.sourceTraceID,
            modelID: entry.modelID,
            metadata: [
                "schemaID": Self.schemaID,
                "promptVersion": entry.promptVersion
            ]
        )
        let sidecarResult = await sidecarRunner.run(
            LocalJSONSidecarRequest(
                environmentVariableName: "DONKEY_LOCAL_LLM_RUNNER",
                inputData: (try? encoder.encode(input)) ?? Data(),
                timeoutMS: entry.timeoutMS,
                metadata: [
                    "sidecar.role": "taskFollowUpResolution",
                    "modelID": entry.modelID
                ]
            )
        )

        guard sidecarResult.status == .completed else {
            return result(
                entry: entry,
                request: request,
                status: sidecarResult.status == .timedOut ? .timeout : .providerOutage,
                validationStatus: "notValidated",
                latencyMS: sidecarResult.latencyMS,
                metadata: sidecarResult.metadata.merging([
                    "sidecar.stderr": sidecarResult.stderrText
                ]) { current, _ in current }
            )
        }

        do {
            let response = try decoder.decode(LocalLLMTaskFollowUpSidecarResponse.self, from: sidecarResult.outputData)
            let decisionData = Data(response.outputText.utf8)
            let decision = try decoder.decode(LocalLLMTaskFollowUpDecision.self, from: decisionData)
            let validCandidateIDs = Set(request.candidates.map(\.taskID))
            let taskID = decision.isFollowUp && validCandidateIDs.contains(decision.taskID) ? decision.taskID : nil
            return PointerPromptFollowUpResolverResult(
                taskID: taskID,
                confidence: min(max(decision.confidence, 0), 1),
                reason: decision.reason,
                trace: trace(
                    entry: entry,
                    request: request,
                    status: .completed,
                    validationStatus: taskID == nil ? "newTask" : "matchedTask",
                    latencyMS: sidecarResult.latencyMS,
                    metadata: sidecarResult.metadata.merging(response.metadata) { current, _ in current }
                )
            )
        } catch {
            return result(
                entry: entry,
                request: request,
                status: .invalidOutput,
                validationStatus: "invalid",
                latencyMS: sidecarResult.latencyMS,
                metadata: sidecarResult.metadata.merging([
                    "error": String(describing: error)
                ]) { current, _ in current }
            )
        }
    }

    private func result(
        entry: AIModelRegistryEntry?,
        request: PointerPromptFollowUpResolverRequest,
        status: AIModelCallStatus,
        validationStatus: String,
        latencyMS: Double?,
        metadata: [String: String] = [:]
    ) -> PointerPromptFollowUpResolverResult {
        PointerPromptFollowUpResolverResult(
            taskID: nil,
            confidence: 0,
            reason: metadata["error"] ?? metadata["reason"] ?? "",
            trace: trace(
                entry: entry,
                request: request,
                status: status,
                validationStatus: validationStatus,
                latencyMS: latencyMS,
                metadata: metadata
            )
        )
    }

    private func trace(
        entry: AIModelRegistryEntry?,
        request: PointerPromptFollowUpResolverRequest,
        status: AIModelCallStatus,
        validationStatus: String,
        latencyMS: Double?,
        metadata: [String: String] = [:]
    ) -> AIModelCallTrace {
        AIModelCallTrace(
            id: "model-call-\(request.sourceTraceID)",
            role: entry?.role ?? .taskIntent,
            provider: entry?.provider ?? .localRuntime,
            modelID: entry?.modelID ?? "unrouted",
            promptVersion: entry?.promptVersion ?? "unrouted",
            schemaID: Self.schemaID,
            latencyMS: latencyMS,
            timeoutMS: entry?.timeoutMS ?? 0,
            status: status,
            validationStatus: validationStatus,
            sourceTraceID: request.sourceTraceID,
            metadata: metadata
        )
    }
}

private struct LocalLLMTaskFollowUpSidecarRequest: Codable, Equatable, Sendable {
    var command: String
    var candidates: [PointerPromptFollowUpCandidate]
    var sourceTraceID: String
    var modelID: String
    var metadata: [String: String]
}

private struct LocalLLMTaskFollowUpSidecarResponse: Codable, Equatable, Sendable {
    var outputText: String
    var metadata: [String: String]
}

private struct LocalLLMTaskFollowUpDecision: Codable, Equatable, Sendable {
    var isFollowUp: Bool
    var taskID: String
    var confidence: Double
    var reason: String
}
