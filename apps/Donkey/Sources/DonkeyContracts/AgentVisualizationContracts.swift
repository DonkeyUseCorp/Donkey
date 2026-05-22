import CoreGraphics
import Foundation

public enum AgentVisualizationExecutionMode: String, Codable, Equatable, Sendable {
    case live
    case visualOnly
}

public enum AgentVisualizationStepKind: String, Codable, Equatable, Sendable {
    case plan
    case observe
    case navigate
    case moveToTarget
    case focusControl
    case enterText
    case submit
    case verify
    case explain
    case recover
}

public enum AgentVisualizationGroundingSource: String, Codable, Equatable, Sendable {
    case modelPlan
    case dryRun
    case accessibility
    case windowMetadata
    case localUIUnderstanding
    case yoloSegmentation
    case actionTrace
    case fallback
}

public enum AgentVisualizationVerificationStatus: String, Codable, Equatable, Sendable {
    case unverified
    case verified
    case needsReview
    case blocked
    case failed
}

public struct AgentVisualizationStepTarget: Codable, Equatable, Sendable {
    public var point: HotLoopPoint?
    public var bounds: HotLoopRect?
    public var description: String
    public var controlID: String?
    public var source: AgentVisualizationGroundingSource
    public var confidence: Double
    public var metadata: [String: String]

    public init(
        point: HotLoopPoint? = nil,
        bounds: HotLoopRect? = nil,
        description: String = "",
        controlID: String? = nil,
        source: AgentVisualizationGroundingSource,
        confidence: Double,
        metadata: [String: String] = [:]
    ) {
        self.point = point
        self.bounds = bounds
        self.description = description
        self.controlID = controlID
        self.source = source
        self.confidence = min(max(confidence, 0), 1)
        self.metadata = metadata
    }
}

public struct AgentVisualizationStep: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: AgentVisualizationStepKind
    public var label: String
    public var target: AgentVisualizationStepTarget?
    public var travelDuration: TimeInterval
    public var holdDuration: TimeInterval
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        kind: AgentVisualizationStepKind,
        label: String,
        target: AgentVisualizationStepTarget? = nil,
        travelDuration: TimeInterval = 0.9,
        holdDuration: TimeInterval = 1.8,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.target = target
        self.travelDuration = max(0.1, travelDuration)
        self.holdDuration = max(0.4, holdDuration)
        self.metadata = metadata
    }
}

public struct AgentVisualizationVerificationReport: Codable, Equatable, Sendable {
    public var status: AgentVisualizationVerificationStatus
    public var summary: String
    public var confidence: Double
    public var evidenceCount: Int
    public var metadata: [String: String]

    public init(
        status: AgentVisualizationVerificationStatus = .unverified,
        summary: String = "",
        confidence: Double = 0,
        evidenceCount: Int = 0,
        metadata: [String: String] = [:]
    ) {
        self.status = status
        self.summary = summary
        self.confidence = min(max(confidence, 0), 1)
        self.evidenceCount = max(0, evidenceCount)
        self.metadata = metadata
    }
}

public struct AgentVisualizationPlan: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var executionMode: AgentVisualizationExecutionMode
    public var sourceTraceID: String
    public var steps: [AgentVisualizationStep]
    public var verification: AgentVisualizationVerificationReport
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        title: String,
        executionMode: AgentVisualizationExecutionMode,
        sourceTraceID: String,
        steps: [AgentVisualizationStep],
        verification: AgentVisualizationVerificationReport = AgentVisualizationVerificationReport(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.executionMode = executionMode
        self.sourceTraceID = sourceTraceID
        self.steps = steps
        self.verification = verification
        self.metadata = metadata
    }

    public var usesRealPointer: Bool {
        metadata["realPointerMoved"] == "true"
    }

    public func cursorOverlayRequest() -> PointerCoachCursorGuideRequest? {
        let cursorSteps = steps.prefix(8).enumerated().map { index, step in
            PointerCoachCursorGuideStep(
                id: step.id,
                label: step.label,
                target: cursorPoint(for: step, index: index),
                travelDuration: step.travelDuration,
                holdDuration: step.holdDuration
            )
        }
        guard !cursorSteps.isEmpty else { return nil }

        return PointerCoachCursorGuideRequest(
            id: id,
            title: title,
            steps: cursorSteps,
            metadata: metadata.merging([
                "agentVisualization.planID": id,
                "agentVisualization.executionMode": executionMode.rawValue,
                "agentVisualization.sourceTraceID": sourceTraceID,
                "agentVisualization.stepCount": String(steps.count),
                "agentVisualization.verificationStatus": verification.status.rawValue,
                "realPointerMoved": "false"
            ]) { current, _ in current }
        )
    }

    private func cursorPoint(for step: AgentVisualizationStep, index: Int) -> CGPoint {
        if let point = step.target?.point,
           point.space == .normalizedTarget {
            return CGPoint(
                x: min(max(point.x, 0.04), 0.96),
                y: min(max(point.y, 0.06), 0.94)
            )
        }

        if let bounds = step.target?.bounds,
           bounds.space == .normalizedTarget {
            return CGPoint(
                x: min(max(bounds.origin.x + bounds.size.width / 2, 0.04), 0.96),
                y: min(max(bounds.origin.y + bounds.size.height / 2, 0.06), 0.94)
            )
        }

        return Self.fallbackPoint(index: index)
    }

    private static func fallbackPoint(index: Int) -> CGPoint {
        let lane = Double(index % 4)
        let row = Double(index / 4)
        return CGPoint(
            x: min(0.82, 0.28 + lane * 0.16),
            y: min(0.86, 0.20 + row * 0.18)
        )
    }
}
