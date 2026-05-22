import CoreGraphics
import DonkeyContracts
import DonkeyRuntime
import Foundation

public struct AgentVisualizationPlanResolverRequest: Equatable, Sendable {
    public var command: String
    public var runtimeCapabilities: [String]
    public var cacheSnippets: [String]
    public var sourceTraceID: String
    public var routeRequest: AIModelRouteRequest

    public init(
        command: String,
        runtimeCapabilities: [String] = [],
        cacheSnippets: [String] = [],
        sourceTraceID: String,
        routeRequest: AIModelRouteRequest = AIModelRouteRequest(
            jobType: .taskIntent,
            privacyMode: .privacySensitive,
            latencyTolerance: .interactive
        )
    ) {
        self.command = command
        self.runtimeCapabilities = runtimeCapabilities
        self.cacheSnippets = cacheSnippets
        self.sourceTraceID = sourceTraceID
        self.routeRequest = routeRequest
    }
}

public struct AgentVisualizationPlanResolverResult: Equatable, Sendable {
    public var visualizationPlan: AgentVisualizationPlan?
    public var cursorRequest: PointerCoachCursorGuideRequest?
    public var confidence: Double
    public var reason: String
    public var trace: AIModelCallTrace

    public init(
        visualizationPlan: AgentVisualizationPlan? = nil,
        cursorRequest: PointerCoachCursorGuideRequest?,
        confidence: Double,
        reason: String,
        trace: AIModelCallTrace
    ) {
        self.visualizationPlan = visualizationPlan
        self.cursorRequest = cursorRequest
        self.confidence = min(max(confidence, 0), 1)
        self.reason = reason
        self.trace = trace
    }
}

public protocol AgentVisualizationPlanResolving: Sendable {
    func resolveVisualizationPlan(
        _ request: AgentVisualizationPlanResolverRequest
    ) async -> AgentVisualizationPlanResolverResult
}

public struct ProcessBackedLocalLLMAgentVisualizationPlanResolver: AgentVisualizationPlanResolving {
    public static let schemaID = "agent_visualization_plan"

    public var router: AIModelRouter
    public var sidecarRunner: any LocalJSONSidecarRunning
    public var encoder: JSONEncoder
    public var decoder: JSONDecoder
    public var minimumConfidence: Double

    public init(
        router: AIModelRouter = AIModelRouter(registry: .defaultHybridPlanner),
        sidecarRunner: any LocalJSONSidecarRunning = ProcessBackedLocalJSONSidecarRunner(),
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder(),
        minimumConfidence: Double = 0.62
    ) {
        self.router = router
        self.sidecarRunner = sidecarRunner
        self.encoder = encoder
        self.decoder = decoder
        self.minimumConfidence = minimumConfidence
    }

    public func resolveVisualizationPlan(
        _ request: AgentVisualizationPlanResolverRequest
    ) async -> AgentVisualizationPlanResolverResult {
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

        let input = LocalLLMAgentVisualizationPlanSidecarRequest(
            command: request.command,
            runtimeCapabilities: request.runtimeCapabilities,
            cacheSnippets: request.cacheSnippets,
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
                    "sidecar.role": "agentVisualizationPlan",
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
            let response = try decoder.decode(
                LocalLLMAgentVisualizationPlanSidecarResponse.self,
                from: sidecarResult.outputData
            )
            let decision = try decoder.decode(
                AgentVisualizationPlanDecision.self,
                from: Data(response.outputText.utf8)
            )
            let confidence = min(max(decision.confidence, 0), 1)
            let visualizationPlan = Self.visualizationPlan(
                from: decision,
                confidence: confidence,
                minimumConfidence: minimumConfidence,
                sourceTraceID: request.sourceTraceID
            )
            let cursorRequest = visualizationPlan?.cursorOverlayRequest()
            return AgentVisualizationPlanResolverResult(
                visualizationPlan: visualizationPlan,
                cursorRequest: cursorRequest,
                confidence: confidence,
                reason: decision.reason,
                trace: trace(
                    entry: entry,
                    request: request,
                    status: .completed,
                    validationStatus: visualizationPlan == nil ? "notVisualization" : "visualizationDecoded",
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

    private static func visualizationPlan(
        from decision: AgentVisualizationPlanDecision,
        confidence: Double,
        minimumConfidence: Double,
        sourceTraceID: String
    ) -> AgentVisualizationPlan? {
        guard decision.shouldVisualize,
              confidence >= minimumConfidence,
              !decision.steps.isEmpty
        else {
            return nil
        }

        let title = nonEmpty(decision.title)
            ?? nonEmpty(decision.goal).map { "Show \($0)" }
            ?? "Show me"
        let steps = decision.steps.prefix(8).enumerated().compactMap { index, step -> AgentVisualizationStep? in
            guard let label = nonEmpty(step.label) else { return nil }
            return AgentVisualizationStep(
                id: "visual-step-\(index + 1)",
                kind: .explain,
                label: label,
                target: AgentVisualizationStepTarget(
                    point: HotLoopPoint(
                        x: min(max(step.x, 0.04), 0.96),
                        y: min(max(step.y, 0.06), 0.94),
                        space: .normalizedTarget
                    ),
                    description: label,
                    source: .modelPlan,
                    confidence: confidence,
                    metadata: [
                        "targetApp": decision.targetApp ?? "",
                        "visualOnly": "true"
                    ]
                ),
                travelDuration: step.travelDuration ?? 0.9,
                holdDuration: step.holdDuration ?? 1.8,
                metadata: [
                    "targetApp": decision.targetApp ?? "",
                    "model.stepIndex": String(index)
                ]
            )
        }
        guard !steps.isEmpty else { return nil }

        return AgentVisualizationPlan(
            title: title,
            executionMode: .visualOnly,
            sourceTraceID: sourceTraceID,
            steps: steps,
            verification: AgentVisualizationVerificationReport(
                status: .unverified,
                summary: decision.reason,
                confidence: confidence,
                evidenceCount: steps.count,
                metadata: [
                    "modelDecision": "visualOnly",
                    "targetApp": decision.targetApp ?? ""
                ]
            ),
            metadata: (decision.metadata ?? [:]).merging([
                "agentVisualization": "overlay-cursor",
                "goal": decision.goal ?? "",
                "targetApp": decision.targetApp ?? "",
                "source": "local-llm-agent-visualization",
                "realPointerMoved": "false",
                "visualOnly": "true"
            ]) { current, _ in current }
        )
    }

    private func result(
        entry: AIModelRegistryEntry?,
        request: AgentVisualizationPlanResolverRequest,
        status: AIModelCallStatus,
        validationStatus: String,
        latencyMS: Double?,
        metadata: [String: String] = [:]
    ) -> AgentVisualizationPlanResolverResult {
        AgentVisualizationPlanResolverResult(
            visualizationPlan: nil,
            cursorRequest: nil,
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
        request: AgentVisualizationPlanResolverRequest,
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

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}

private struct LocalLLMAgentVisualizationPlanSidecarRequest: Codable, Equatable, Sendable {
    var command: String
    var runtimeCapabilities: [String]
    var cacheSnippets: [String]
    var sourceTraceID: String
    var modelID: String
    var metadata: [String: String]
}

private struct LocalLLMAgentVisualizationPlanSidecarResponse: Codable, Equatable, Sendable {
    var outputText: String
    var metadata: [String: String]
}

private struct AgentVisualizationPlanDecision: Codable, Equatable, Sendable {
    var shouldVisualize: Bool
    var title: String?
    var goal: String?
    var targetApp: String?
    var confidence: Double
    var reason: String
    var steps: [AgentVisualizationPlanStepDecision]
    var metadata: [String: String]?
}

private struct AgentVisualizationPlanStepDecision: Codable, Equatable, Sendable {
    var label: String
    var x: Double
    var y: Double
    var travelDuration: TimeInterval?
    var holdDuration: TimeInterval?
}
