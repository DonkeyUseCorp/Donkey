import Foundation

public enum AgentPathStepKind: String, Codable, Equatable, Sendable {
    case plan
    case navigateApp
    case observe
    case targetControl
    case act
    case verify
    case recover
}

public enum AgentPathStepStatus: String, Codable, Equatable, Sendable {
    case planned
    case observed
    case executed
    case verified
    case blocked
    case skipped
}

public struct AgentPathStep: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var phaseID: String
    public var kind: AgentPathStepKind
    public var label: String
    public var targetApp: String?
    public var bundleIdentifier: String?
    public var windowID: String?
    public var point: HotLoopPoint?
    public var bounds: HotLoopRect?
    public var controlID: String?
    public var source: AgentVisualizationGroundingSource
    public var status: AgentPathStepStatus
    public var travelDuration: TimeInterval
    public var holdDuration: TimeInterval
    public var preRotateDuration: TimeInterval
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        phaseID: String = "",
        kind: AgentPathStepKind,
        label: String,
        targetApp: String? = nil,
        bundleIdentifier: String? = nil,
        windowID: String? = nil,
        point: HotLoopPoint? = nil,
        bounds: HotLoopRect? = nil,
        controlID: String? = nil,
        source: AgentVisualizationGroundingSource,
        status: AgentPathStepStatus = .planned,
        travelDuration: TimeInterval = 0.9,
        holdDuration: TimeInterval = 1.2,
        preRotateDuration: TimeInterval = 0.12,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.phaseID = phaseID
        self.kind = kind
        self.label = label
        self.targetApp = targetApp
        self.bundleIdentifier = bundleIdentifier
        self.windowID = windowID
        self.point = point
        self.bounds = bounds
        self.controlID = controlID
        self.source = source
        self.status = status
        self.travelDuration = max(0.1, travelDuration)
        self.holdDuration = max(0.4, holdDuration)
        self.preRotateDuration = min(max(preRotateDuration, 0), 0.6)
        self.metadata = metadata
    }

    public var hasGroundedTarget: Bool {
        if let point, point.space == .normalizedTarget { return true }
        if let bounds, bounds.space == .normalizedTarget, bounds.hasPositiveArea { return true }
        return false
    }
}

public struct AgentPathTrace: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var agentID: String
    public var title: String
    public var sourceTraceID: String
    public var steps: [AgentPathStep]
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        agentID: String,
        title: String,
        sourceTraceID: String,
        steps: [AgentPathStep],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.agentID = agentID
        self.title = title
        self.sourceTraceID = sourceTraceID
        self.steps = steps
        self.metadata = metadata
    }

    public var groundedSteps: [AgentPathStep] {
        steps.filter(\.hasGroundedTarget)
    }

    public func visualizationPlan() -> AgentVisualizationPlan? {
        let visualSteps = groundedSteps.map { step in
            AgentVisualizationStep(
                id: step.id,
                kind: step.visualizationKind,
                label: step.label,
                target: AgentVisualizationStepTarget(
                    point: step.point,
                    bounds: step.bounds,
                    description: step.label,
                    controlID: step.controlID,
                    source: step.source,
                    confidence: step.visualizationConfidence,
                    metadata: step.visualizationMetadata
                ),
                travelDuration: step.travelDuration,
                holdDuration: step.holdDuration,
                metadata: step.visualizationMetadata
            )
        }
        guard !visualSteps.isEmpty else { return nil }

        return AgentVisualizationPlan(
            id: "agent-path-\(id)",
            title: title,
            executionMode: .live,
            sourceTraceID: sourceTraceID,
            steps: visualSteps,
            verification: AgentVisualizationVerificationReport(
                status: steps.contains { $0.status == .blocked } ? .blocked : .unverified,
                summary: "Agent path trace contains \(visualSteps.count) grounded step(s).",
                confidence: visualSteps.isEmpty ? 0 : 0.9,
                evidenceCount: visualSteps.count,
                metadata: [
                    "agentPath.traceID": id,
                    "agentPath.stepCount": String(steps.count),
                    "agentPath.groundedStepCount": String(visualSteps.count)
                ]
            ),
            metadata: metadata.merging([
                "source": "agent-path-trace",
                "agentPath.traceID": id,
                "agentPath.agentID": agentID,
                "agentPath.stepCount": String(steps.count),
                "agentPath.groundedStepCount": String(visualSteps.count),
                "realPointerMoved": "false",
                "cursorGuideEligible": "true"
            ]) { current, _ in current }
        )
    }
}

private extension AgentPathStep {
    var visualizationKind: AgentVisualizationStepKind {
        switch kind {
        case .plan:
            return .plan
        case .navigateApp:
            return .navigate
        case .observe:
            return .observe
        case .targetControl:
            return .focusControl
        case .act:
            return .moveToTarget
        case .verify:
            return .verify
        case .recover:
            return .recover
        }
    }

    var visualizationConfidence: Double {
        switch status {
        case .verified, .executed:
            return 0.95
        case .observed:
            return 0.9
        case .planned:
            return 0.78
        case .skipped:
            return 0.35
        case .blocked:
            return 0.2
        }
    }

    var visualizationMetadata: [String: String] {
        var values = metadata.merging([
            "agentPath.phaseID": phaseID,
            "agentPath.kind": kind.rawValue,
            "agentPath.status": status.rawValue,
            "agentPath.source": source.rawValue,
            "targetApp": targetApp ?? "",
            "bundleIdentifier": bundleIdentifier ?? "",
            "windowID": windowID ?? "",
            "realPointerMoved": "false",
            "preRotateDuration": String(preRotateDuration)
        ]) { current, _ in current }
        if let controlID {
            values["controlID"] = controlID
        }
        return values
    }
}
