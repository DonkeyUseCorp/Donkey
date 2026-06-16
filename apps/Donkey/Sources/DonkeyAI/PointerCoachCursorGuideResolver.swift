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
