import DonkeyContracts
import Foundation

public struct CheapPerceptionAdapter: DryRunPerceptionAdapting {
    public var adapterName: String
    public var defaultSignalKind: String
    public var observationDelayMS: UInt64

    public init(
        adapterName: String = "cheap-metadata-perception",
        defaultSignalKind: String = "template",
        observationDelayMS: UInt64 = 2
    ) {
        self.adapterName = adapterName
        self.defaultSignalKind = defaultSignalKind
        self.observationDelayMS = observationDelayMS
    }

    public func perceive(frame: HotLoopFrame) async -> [HotLoopPerceptionSignal] {
        let confidence = Self.clampedConfidence(
            Double(frame.metadata["signalConfidence"] ?? "")
                ?? Double(frame.metadata["perception.confidence"] ?? "")
                ?? 1
        )
        let signalKind = frame.metadata["signalKind"]
            ?? frame.metadata["perception.kind"]
            ?? defaultSignalKind
        let observedAt = frame.capturedAt.addingMilliseconds(observationDelayMS)
        let observations = observations(from: frame, signalConfidence: confidence)

        return [
            HotLoopPerceptionSignal(
                id: "signal-\(frame.id)",
                traceID: frame.traceID,
                frameID: frame.id,
                kind: signalKind,
                capturedAt: frame.capturedAt,
                observedAt: observedAt,
                confidence: confidence,
                observations: observations,
                plannerHintID: frame.plannerHintID,
                metadata: [
                    "adapter": adapterName,
                    "rawPixelsExposed": "false"
                ]
            )
        ]
    }

    private func observations(
        from frame: HotLoopFrame,
        signalConfidence: Double
    ) -> [HotLoopPerceptionObservation] {
        guard let x = Double(frame.metadata["tapTargetX"] ?? frame.metadata["target.x"] ?? ""),
              let y = Double(frame.metadata["tapTargetY"] ?? frame.metadata["target.y"] ?? "")
        else {
            return []
        }

        let width = Double(frame.metadata["tapTargetWidth"] ?? frame.metadata["target.width"] ?? "") ?? 0.1
        let height = Double(frame.metadata["tapTargetHeight"] ?? frame.metadata["target.height"] ?? "") ?? 0.1
        let confidence = Self.clampedConfidence(
            Double(frame.metadata["tapTargetConfidence"] ?? frame.metadata["target.confidence"] ?? "")
                ?? signalConfidence
        )

        return [
            HotLoopPerceptionObservation(
                id: "observation-\(frame.id)",
                label: frame.metadata["tapTargetLabel"]
                    ?? frame.metadata["target.label"]
                    ?? "tap-target",
                bounds: HotLoopRect(
                    x: x,
                    y: y,
                    width: width,
                    height: height,
                    space: .normalizedTarget
                ),
                confidence: confidence,
                metadata: [
                    "source": "frame.metadata"
                ]
            )
        ]
    }

    private static func clampedConfidence(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

public struct HotLoopWorldStateProjector: DryRunWorldStateProjecting {
    public var staleSignalThresholdMS: Double

    public init(staleSignalThresholdMS: Double = 250) {
        self.staleSignalThresholdMS = staleSignalThresholdMS
    }

    public func project(
        frame: HotLoopFrame,
        signals: [HotLoopPerceptionSignal],
        observedAt: RunTraceTimestamp
    ) async -> HotLoopWorldState {
        HotLoopWorldState.build(
            id: "state-\(frame.id)",
            frame: frame,
            signals: signals,
            observedAt: observedAt,
            staleThresholdMS: staleSignalThresholdMS,
            actionAffordances: actionAffordances(from: signals),
            metadata: [
                "projector": "hot-loop-world-state-projector",
                "rawPixelsExposed": "false"
            ]
        )
    }

    private func actionAffordances(
        from signals: [HotLoopPerceptionSignal]
    ) -> [HotLoopActionAffordance] {
        signals.flatMap { signal in
            signal.observations.map { observation in
                HotLoopActionAffordance(
                    id: "affordance-\(observation.id)",
                    kind: .tapTarget,
                    targetBounds: observation.bounds,
                    confidence: min(signal.confidence, observation.confidence),
                    sourceSignalID: signal.id
                )
            }
        }
    }
}

public struct DeterministicControllerPolicy: DryRunControllerPolicy {
    public var name: String
    public var minimumActionConfidence: Double

    public init(
        name: String = "deterministic-tap-target-v1",
        minimumActionConfidence: Double = 0.6
    ) {
        self.name = name
        self.minimumActionConfidence = minimumActionConfidence
    }

    public func decide(state: HotLoopWorldState) async -> HotLoopControllerAction {
        if let affordance = state.actionAffordances
            .filter({ !state.staleSignalIDs.contains($0.sourceSignalID) })
            .sorted(by: { $0.confidence > $1.confidence })
            .first {
            if affordance.confidence >= minimumActionConfidence {
                return action(
                    state: state,
                    kind: .tapTarget,
                    target: affordance.targetBounds,
                    confidence: affordance.confidence,
                    rationale: "Selected highest-confidence tap target affordance",
                    metadata: affordance.metadata.merging([
                        "fallback": "false",
                        "sourceSignalID": affordance.sourceSignalID
                    ]) { current, _ in current }
                )
            }

            return action(
                state: state,
                kind: .wait,
                confidence: affordance.confidence,
                rationale: "Best affordance confidence is below action threshold",
                metadata: affordance.metadata.merging([
                    "fallback": "true",
                    "fallbackReason": "lowConfidence",
                    "sourceSignalID": affordance.sourceSignalID,
                    "minimumActionConfidence": String(minimumActionConfidence)
                ]) { current, _ in current }
            )
        }

        if !state.signalSummaries.isEmpty {
            return action(
                state: state,
                kind: .wait,
                confidence: state.confidence,
                rationale: "Perception is present but no fresh action affordance is available",
                metadata: [
                    "fallback": "true",
                    "fallbackReason": state.staleSignalIDs.isEmpty ? "noAffordance" : "staleSignal"
                ]
            )
        }

        return action(
            state: state,
            kind: .observe,
            confidence: 0,
            rationale: "No perception signal is available",
            metadata: [
                "fallback": "true",
                "fallbackReason": "noSignal"
            ]
        )
    }

    private func action(
        state: HotLoopWorldState,
        kind: HotLoopActionKind,
        target: HotLoopRect? = nil,
        confidence: Double,
        rationale: String,
        metadata: [String: String]
    ) -> HotLoopControllerAction {
        HotLoopControllerAction(
            id: "action-\(state.id)",
            traceID: state.traceID,
            frameID: state.frameID,
            stateID: state.id,
            kind: kind,
            target: target,
            policyName: name,
            confidence: confidence,
            rationale: rationale,
            plannerHintID: state.plannerHintID,
            metadata: metadata
        )
    }
}

public struct DryRunActionProjector: DryRunActionProjecting {
    public init() {}

    public func project(
        action: HotLoopControllerAction,
        state: HotLoopWorldState
    ) async -> HotLoopActionResult {
        let enqueuedAt = state.observedAt.addingMilliseconds(2)
        let completedAt = enqueuedAt

        return HotLoopActionResult(
            id: "result-\(action.id)",
            traceID: action.traceID,
            frameID: action.frameID,
            stateID: action.stateID,
            actionID: action.id,
            mode: .dryRun,
            executed: false,
            enqueuedAt: enqueuedAt,
            completedAt: completedAt,
            summary: "Dry-run projected \(action.kind.rawValue)",
            metadata: [
                "policyName": action.policyName,
                "rationale": action.rationale,
                "fallback": action.metadata["fallback"] ?? "false"
            ]
        )
    }
}

private extension RunTraceTimestamp {
    func addingMilliseconds(_ milliseconds: UInt64) -> RunTraceTimestamp {
        RunTraceTimestamp(
            wallClock: wallClock.addingTimeInterval(Double(milliseconds) / 1_000),
            monotonicUptimeNanoseconds: monotonicUptimeNanoseconds + milliseconds * 1_000_000
        )
    }
}
