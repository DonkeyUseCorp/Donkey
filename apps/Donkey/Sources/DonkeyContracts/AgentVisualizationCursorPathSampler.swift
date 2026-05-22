import CoreGraphics
import Foundation

public enum AgentVisualizationCursorPathPhase: String, Codable, Equatable, Sendable {
    case idle
    case travel
    case hold
    case complete
}

public struct AgentVisualizationCursorPathSample: Equatable, Sendable {
    public var position: CGPoint
    public var angle: Double
    public var visibleLabel: String
    public var isHolding: Bool
    public var phase: AgentVisualizationCursorPathPhase
    public var stepIndex: Int?
    public var stepID: String?
    public var elapsedInPhase: TimeInterval
    public var linearProgress: Double
    public var easedProgress: Double
    public var haloScale: Double
    public var haloOpacity: Double
    public var labelOpacity: Double

    public init(
        position: CGPoint,
        angle: Double,
        visibleLabel: String,
        isHolding: Bool,
        phase: AgentVisualizationCursorPathPhase,
        stepIndex: Int? = nil,
        stepID: String? = nil,
        elapsedInPhase: TimeInterval = 0,
        linearProgress: Double = 0,
        easedProgress: Double = 0,
        haloScale: Double = 1,
        haloOpacity: Double = 0.35,
        labelOpacity: Double = 0
    ) {
        self.position = position
        self.angle = angle
        self.visibleLabel = visibleLabel
        self.isHolding = isHolding
        self.phase = phase
        self.stepIndex = stepIndex
        self.stepID = stepID
        self.elapsedInPhase = elapsedInPhase
        self.linearProgress = min(max(linearProgress, 0), 1)
        self.easedProgress = min(max(easedProgress, 0), 1)
        self.haloScale = haloScale
        self.haloOpacity = haloOpacity
        self.labelOpacity = labelOpacity
    }
}

public enum AgentVisualizationCursorPathSampler {
    public static func sample(
        request: PointerCoachCursorGuideRequest,
        elapsed: TimeInterval,
        screenSize: CGSize
    ) -> AgentVisualizationCursorPathSample {
        guard !request.steps.isEmpty else {
            return AgentVisualizationCursorPathSample(
                position: point(request.origin, in: screenSize),
                angle: 0,
                visibleLabel: "",
                isHolding: false,
                phase: .idle
            )
        }

        var remaining = elapsed
        var origin = point(request.origin, in: screenSize)
        for (index, step) in request.steps.enumerated() {
            let target = point(step.target, in: screenSize)
            if remaining <= step.travelDuration {
                let linearProgress = min(max(remaining / step.travelDuration, 0), 1)
                let easedProgress = eased(linearProgress)
                return AgentVisualizationCursorPathSample(
                    position: curvedPoint(from: origin, to: target, progress: easedProgress),
                    angle: angle(from: origin, to: target),
                    visibleLabel: "",
                    isHolding: false,
                    phase: .travel,
                    stepIndex: index,
                    stepID: step.id,
                    elapsedInPhase: max(0, remaining),
                    linearProgress: linearProgress,
                    easedProgress: easedProgress
                )
            }

            remaining -= step.travelDuration
            if remaining <= step.holdDuration {
                let typeProgress = min(1, remaining / min(step.holdDuration, max(0.6, Double(step.label.count) * 0.035)))
                let wobble = sin(remaining * 8) * 1.8
                return AgentVisualizationCursorPathSample(
                    position: CGPoint(x: target.x + wobble, y: target.y),
                    angle: angle(from: origin, to: target),
                    visibleLabel: typedText(step.label, progress: typeProgress),
                    isHolding: true,
                    phase: .hold,
                    stepIndex: index,
                    stepID: step.id,
                    elapsedInPhase: max(0, remaining),
                    linearProgress: typeProgress,
                    easedProgress: typeProgress,
                    haloScale: 1 + 0.14 * sin(remaining * 3.2),
                    haloOpacity: 0.24 + 0.18 * cos(remaining * 3.2),
                    labelOpacity: min(1, remaining / 0.18)
                )
            }

            remaining -= step.holdDuration
            origin = target
        }

        let finalStep = request.steps[request.steps.count - 1]
        return AgentVisualizationCursorPathSample(
            position: point(finalStep.target, in: screenSize),
            angle: 0,
            visibleLabel: finalStep.label,
            isHolding: true,
            phase: .complete,
            stepIndex: request.steps.count - 1,
            stepID: finalStep.id,
            elapsedInPhase: max(0, remaining),
            linearProgress: 1,
            easedProgress: 1,
            labelOpacity: 1
        )
    }

    public static func point(_ normalizedPoint: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(normalizedPoint.x, 0.04), 0.96) * max(1, size.width),
            y: min(max(normalizedPoint.y, 0.06), 0.94) * max(1, size.height)
        )
    }

    public static func curvedPoint(
        from origin: CGPoint,
        to target: CGPoint,
        progress: Double
    ) -> CGPoint {
        let dx = target.x - origin.x
        let dy = target.y - origin.y
        let length = max(1, hypot(dx, dy))
        let curve = min(80, length * 0.35)
        let control = CGPoint(
            x: (origin.x + target.x) / 2 + (-dy / length) * curve,
            y: (origin.y + target.y) / 2 + (dx / length) * curve
        )
        let t = CGFloat(min(max(progress, 0), 1))
        let inv = 1 - t
        return CGPoint(
            x: inv * inv * origin.x + 2 * inv * t * control.x + t * t * target.x,
            y: inv * inv * origin.y + 2 * inv * t * control.y + t * t * target.y
        )
    }

    public static func angle(from origin: CGPoint, to target: CGPoint) -> Double {
        atan2(target.y - origin.y, target.x - origin.x) * 180 / .pi
    }

    public static func eased(_ progress: Double) -> Double {
        let t = min(max(progress, 0), 1)
        return 1 - pow(1 - t, 3)
    }

    private static func typedText(_ text: String, progress: Double) -> String {
        guard progress < 1 else { return text }

        let count = max(1, Int(Double(text.count) * progress))
        let endIndex = text.index(text.startIndex, offsetBy: min(count, text.count))
        return String(text[..<endIndex])
    }
}
