import Foundation

public enum HotLoopCoordinateSpace: String, Codable, Equatable, Sendable {
    case screen
    case window
    case crop
    case normalizedTarget
}

public struct HotLoopPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var space: HotLoopCoordinateSpace

    public init(x: Double, y: Double, space: HotLoopCoordinateSpace) {
        self.x = x
        self.y = y
        self.space = space
    }
}

public struct HotLoopSize: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var space: HotLoopCoordinateSpace

    public init(width: Double, height: Double, space: HotLoopCoordinateSpace) {
        self.width = width
        self.height = height
        self.space = space
    }

    public var hasPositiveArea: Bool {
        width > 0 && height > 0
    }
}

public struct HotLoopRect: Codable, Equatable, Sendable {
    public var origin: HotLoopPoint
    public var size: HotLoopSize

    public init(origin: HotLoopPoint, size: HotLoopSize) {
        self.origin = origin
        self.size = size
    }

    public init(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        space: HotLoopCoordinateSpace
    ) {
        self.origin = HotLoopPoint(x: x, y: y, space: space)
        self.size = HotLoopSize(width: width, height: height, space: space)
    }

    public var space: HotLoopCoordinateSpace {
        origin.space
    }

    public var hasPositiveArea: Bool {
        size.hasPositiveArea && origin.space == size.space
    }
}

public struct HotLoopCoordinateMapper: Codable, Equatable, Sendable {
    public var windowBoundsInScreen: HotLoopRect
    public var cropBoundsInWindow: HotLoopRect

    public init(
        windowBoundsInScreen: HotLoopRect,
        cropBoundsInWindow: HotLoopRect
    ) {
        self.windowBoundsInScreen = windowBoundsInScreen
        self.cropBoundsInWindow = cropBoundsInWindow
    }

    public func convert(
        _ point: HotLoopPoint,
        to targetSpace: HotLoopCoordinateSpace
    ) -> HotLoopPoint? {
        guard let windowPoint = pointInWindowSpace(point) else { return nil }
        return pointFromWindowSpace(windowPoint, to: targetSpace)
    }

    public func convert(
        _ rect: HotLoopRect,
        to targetSpace: HotLoopCoordinateSpace
    ) -> HotLoopRect? {
        guard rect.hasPositiveArea,
              let origin = convert(rect.origin, to: targetSpace),
              let size = convert(rect.size, from: rect.space, to: targetSpace)
        else {
            return nil
        }

        return HotLoopRect(origin: origin, size: size)
    }

    public func convert(
        _ size: HotLoopSize,
        from sourceSpace: HotLoopCoordinateSpace,
        to targetSpace: HotLoopCoordinateSpace
    ) -> HotLoopSize? {
        guard size.hasPositiveArea,
              sourceSpace == size.space,
              cropBoundsInWindow.hasPositiveArea,
              windowBoundsInScreen.hasPositiveArea
        else {
            return nil
        }

        if sourceSpace == targetSpace {
            return size
        }

        let windowSize: HotLoopSize
        switch sourceSpace {
        case .screen, .window:
            windowSize = HotLoopSize(
                width: size.width,
                height: size.height,
                space: .window
            )
        case .crop:
            windowSize = HotLoopSize(
                width: size.width,
                height: size.height,
                space: .window
            )
        case .normalizedTarget:
            windowSize = HotLoopSize(
                width: size.width * cropBoundsInWindow.size.width,
                height: size.height * cropBoundsInWindow.size.height,
                space: .window
            )
        }

        switch targetSpace {
        case .screen, .window:
            return HotLoopSize(
                width: windowSize.width,
                height: windowSize.height,
                space: targetSpace
            )
        case .crop:
            return HotLoopSize(
                width: windowSize.width,
                height: windowSize.height,
                space: .crop
            )
        case .normalizedTarget:
            return HotLoopSize(
                width: windowSize.width / cropBoundsInWindow.size.width,
                height: windowSize.height / cropBoundsInWindow.size.height,
                space: .normalizedTarget
            )
        }
    }

    private func pointInWindowSpace(_ point: HotLoopPoint) -> HotLoopPoint? {
        guard cropBoundsInWindow.hasPositiveArea,
              windowBoundsInScreen.hasPositiveArea
        else {
            return nil
        }

        switch point.space {
        case .screen:
            return HotLoopPoint(
                x: point.x - windowBoundsInScreen.origin.x,
                y: point.y - windowBoundsInScreen.origin.y,
                space: .window
            )
        case .window:
            return point
        case .crop:
            return HotLoopPoint(
                x: point.x + cropBoundsInWindow.origin.x,
                y: point.y + cropBoundsInWindow.origin.y,
                space: .window
            )
        case .normalizedTarget:
            return HotLoopPoint(
                x: cropBoundsInWindow.origin.x + point.x * cropBoundsInWindow.size.width,
                y: cropBoundsInWindow.origin.y + point.y * cropBoundsInWindow.size.height,
                space: .window
            )
        }
    }

    private func pointFromWindowSpace(
        _ point: HotLoopPoint,
        to targetSpace: HotLoopCoordinateSpace
    ) -> HotLoopPoint? {
        guard point.space == .window,
              cropBoundsInWindow.hasPositiveArea,
              windowBoundsInScreen.hasPositiveArea
        else {
            return nil
        }

        switch targetSpace {
        case .screen:
            return HotLoopPoint(
                x: point.x + windowBoundsInScreen.origin.x,
                y: point.y + windowBoundsInScreen.origin.y,
                space: .screen
            )
        case .window:
            return point
        case .crop:
            return HotLoopPoint(
                x: point.x - cropBoundsInWindow.origin.x,
                y: point.y - cropBoundsInWindow.origin.y,
                space: .crop
            )
        case .normalizedTarget:
            return HotLoopPoint(
                x: (point.x - cropBoundsInWindow.origin.x) / cropBoundsInWindow.size.width,
                y: (point.y - cropBoundsInWindow.origin.y) / cropBoundsInWindow.size.height,
                space: .normalizedTarget
            )
        }
    }
}

public struct HotLoopCrop: Codable, Equatable, Sendable {
    public var id: String
    public var bounds: HotLoopRect
    public var outputSize: HotLoopSize

    public init(
        id: String,
        bounds: HotLoopRect,
        outputSize: HotLoopSize
    ) {
        self.id = id
        self.bounds = bounds
        self.outputSize = outputSize
    }
}

public enum HotLoopFrameSourceKind: String, Codable, Equatable, Sendable {
    case synthetic
    case recorded
    case targetWindow
}

public struct HotLoopFrame: Codable, Equatable, Sendable {
    public var id: String
    public var traceID: String
    public var targetID: String
    public var capturedAt: RunTraceTimestamp
    public var sourceKind: HotLoopFrameSourceKind
    public var windowBounds: HotLoopRect
    public var crop: HotLoopCrop?
    public var pixelSize: HotLoopSize
    public var plannerHintID: String?
    public var metadata: [String: String]

    public init(
        id: String,
        traceID: String,
        targetID: String,
        capturedAt: RunTraceTimestamp,
        sourceKind: HotLoopFrameSourceKind,
        windowBounds: HotLoopRect,
        crop: HotLoopCrop? = nil,
        pixelSize: HotLoopSize,
        plannerHintID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.traceID = traceID
        self.targetID = targetID
        self.capturedAt = capturedAt
        self.sourceKind = sourceKind
        self.windowBounds = windowBounds
        self.crop = crop
        self.pixelSize = pixelSize
        self.plannerHintID = plannerHintID
        self.metadata = metadata
    }
}

public struct HotLoopPerceptionObservation: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var bounds: HotLoopRect?
    public var confidence: Double
    public var metadata: [String: String]

    public init(
        id: String,
        label: String,
        bounds: HotLoopRect? = nil,
        confidence: Double,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.label = label
        self.bounds = bounds
        self.confidence = confidence
        self.metadata = metadata
    }
}

public struct HotLoopPerceptionSignal: Codable, Equatable, Sendable {
    public var id: String
    public var traceID: String
    public var frameID: String
    public var kind: String
    public var capturedAt: RunTraceTimestamp
    public var observedAt: RunTraceTimestamp
    public var confidence: Double
    public var observations: [HotLoopPerceptionObservation]
    public var plannerHintID: String?
    public var metadata: [String: String]

    public init(
        id: String,
        traceID: String,
        frameID: String,
        kind: String,
        capturedAt: RunTraceTimestamp,
        observedAt: RunTraceTimestamp,
        confidence: Double,
        observations: [HotLoopPerceptionObservation] = [],
        plannerHintID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.traceID = traceID
        self.frameID = frameID
        self.kind = kind
        self.capturedAt = capturedAt
        self.observedAt = observedAt
        self.confidence = confidence
        self.observations = observations
        self.plannerHintID = plannerHintID
        self.metadata = metadata
    }

    public func sourceAgeMS(at timestamp: RunTraceTimestamp) -> Double? {
        capturedAt.milliseconds(until: timestamp)
    }

    public func isStale(
        at timestamp: RunTraceTimestamp,
        thresholdMS: Double
    ) -> Bool {
        guard let age = sourceAgeMS(at: timestamp) else { return true }
        return age > thresholdMS
    }
}

public struct HotLoopPerceptionSignalSummary: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var confidence: Double
    public var sourceAgeMS: Double?
    public var observationCount: Int

    public init(
        id: String,
        kind: String,
        confidence: Double,
        sourceAgeMS: Double? = nil,
        observationCount: Int
    ) {
        self.id = id
        self.kind = kind
        self.confidence = confidence
        self.sourceAgeMS = sourceAgeMS
        self.observationCount = observationCount
    }
}

public struct HotLoopActionAffordance: Codable, Equatable, Sendable {
    public var id: String
    public var kind: HotLoopActionKind
    public var targetBounds: HotLoopRect?
    public var confidence: Double
    public var sourceSignalID: String

    public init(
        id: String,
        kind: HotLoopActionKind,
        targetBounds: HotLoopRect? = nil,
        confidence: Double,
        sourceSignalID: String
    ) {
        self.id = id
        self.kind = kind
        self.targetBounds = targetBounds
        self.confidence = confidence
        self.sourceSignalID = sourceSignalID
    }
}

public struct HotLoopWorldState: Codable, Equatable, Sendable {
    public var id: String
    public var traceID: String
    public var frameID: String
    public var targetID: String
    public var observedAt: RunTraceTimestamp
    public var signalSummaries: [HotLoopPerceptionSignalSummary]
    public var staleSignalIDs: [String]
    public var actionAffordances: [HotLoopActionAffordance]
    public var confidence: Double
    public var plannerHintID: String?
    public var metadata: [String: String]

    public init(
        id: String,
        traceID: String,
        frameID: String,
        targetID: String,
        observedAt: RunTraceTimestamp,
        signalSummaries: [HotLoopPerceptionSignalSummary],
        staleSignalIDs: [String] = [],
        actionAffordances: [HotLoopActionAffordance] = [],
        confidence: Double,
        plannerHintID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.traceID = traceID
        self.frameID = frameID
        self.targetID = targetID
        self.observedAt = observedAt
        self.signalSummaries = signalSummaries
        self.staleSignalIDs = staleSignalIDs
        self.actionAffordances = actionAffordances
        self.confidence = confidence
        self.plannerHintID = plannerHintID
        self.metadata = metadata
    }

    public static func build(
        id: String,
        frame: HotLoopFrame,
        signals: [HotLoopPerceptionSignal],
        observedAt: RunTraceTimestamp,
        staleThresholdMS: Double,
        actionAffordances: [HotLoopActionAffordance] = [],
        metadata: [String: String] = [:]
    ) -> HotLoopWorldState {
        let summaries = signals.map { signal in
            HotLoopPerceptionSignalSummary(
                id: signal.id,
                kind: signal.kind,
                confidence: signal.confidence,
                sourceAgeMS: signal.sourceAgeMS(at: observedAt),
                observationCount: signal.observations.count
            )
        }
        let staleSignalIDs = signals
            .filter { $0.isStale(at: observedAt, thresholdMS: staleThresholdMS) }
            .map(\.id)
        let confidence: Double
        if signals.isEmpty {
            confidence = 0
        } else {
            confidence = signals.map(\.confidence).reduce(0, +) / Double(signals.count)
        }

        return HotLoopWorldState(
            id: id,
            traceID: frame.traceID,
            frameID: frame.id,
            targetID: frame.targetID,
            observedAt: observedAt,
            signalSummaries: summaries,
            staleSignalIDs: staleSignalIDs,
            actionAffordances: actionAffordances,
            confidence: confidence,
            plannerHintID: frame.plannerHintID,
            metadata: metadata
        )
    }
}

public enum HotLoopActionKind: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case observe
    case wait
    case tapTarget
    case focusWindow
    case switchTab
    case openAppSwitcher
    case activateCandidate
}

public struct HotLoopControllerAction: Codable, Equatable, Sendable {
    public var id: String
    public var traceID: String
    public var frameID: String
    public var stateID: String
    public var kind: HotLoopActionKind
    public var target: HotLoopRect?
    public var policyName: String
    public var confidence: Double
    public var rationale: String
    public var plannerHintID: String?
    public var metadata: [String: String]

    public init(
        id: String,
        traceID: String,
        frameID: String,
        stateID: String,
        kind: HotLoopActionKind,
        target: HotLoopRect? = nil,
        policyName: String,
        confidence: Double,
        rationale: String,
        plannerHintID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.traceID = traceID
        self.frameID = frameID
        self.stateID = stateID
        self.kind = kind
        self.target = target
        self.policyName = policyName
        self.confidence = confidence
        self.rationale = rationale
        self.plannerHintID = plannerHintID
        self.metadata = metadata
    }
}

public enum HotLoopActionExecutionMode: String, Codable, Equatable, Sendable {
    case dryRun
    case live
}

public struct HotLoopActionResult: Codable, Equatable, Sendable {
    public var id: String
    public var traceID: String
    public var frameID: String
    public var stateID: String
    public var actionID: String
    public var mode: HotLoopActionExecutionMode
    public var executed: Bool
    public var enqueuedAt: RunTraceTimestamp
    public var completedAt: RunTraceTimestamp
    public var summary: String
    public var metadata: [String: String]

    public init(
        id: String,
        traceID: String,
        frameID: String,
        stateID: String,
        actionID: String,
        mode: HotLoopActionExecutionMode,
        executed: Bool,
        enqueuedAt: RunTraceTimestamp,
        completedAt: RunTraceTimestamp,
        summary: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.traceID = traceID
        self.frameID = frameID
        self.stateID = stateID
        self.actionID = actionID
        self.mode = mode
        self.executed = executed
        self.enqueuedAt = enqueuedAt
        self.completedAt = completedAt
        self.summary = summary
        self.metadata = metadata
    }
}
