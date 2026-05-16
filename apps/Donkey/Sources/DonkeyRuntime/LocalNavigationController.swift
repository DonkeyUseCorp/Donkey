import DonkeyContracts
import Foundation

public struct LocalNavigationMetadataProjector: Sendable {
    public var staleSourceThresholdMS: Double

    public init(staleSourceThresholdMS: Double = 250) {
        self.staleSourceThresholdMS = staleSourceThresholdMS
    }

    public func project(
        snapshot: MacWindowCandidateListSnapshot,
        traceID: String,
        targetID: String,
        observedAt: RunTraceTimestamp,
        sourceCapturedAt: RunTraceTimestamp,
        requestedBundleIdentifier: String? = nil,
        requestedTitleContains: String? = nil
    ) -> LocalNavigationWorldState {
        let sourceAgeMS = sourceCapturedAt.milliseconds(until: observedAt)
        let candidates = snapshot.candidates.map { labeled in
            candidate(
                labeled: labeled,
                sourceAgeMS: sourceAgeMS
            )
        }
        let usableCandidates = candidates.filter { $0.safetyStatus == .allowed }
        let confidence = usableCandidates.isEmpty
            ? 0
            : usableCandidates.map(\.confidence).reduce(0, +) / Double(usableCandidates.count)

        return LocalNavigationWorldState(
            id: "local-nav-state-\(traceID)",
            traceID: traceID,
            frameID: "local-nav-frame-\(traceID)",
            targetID: targetID,
            observedAt: observedAt,
            candidates: candidates,
            focusedCandidateID: candidates.first(where: \.isFocused)?.id,
            frontmostCandidateID: candidates.first(where: \.isFrontmost)?.id,
            requestedBundleIdentifier: requestedBundleIdentifier,
            requestedTitleContains: requestedTitleContains,
            confidence: min(max(confidence, 0), 1),
            metadata: [
                "projector": "local-navigation-metadata-projector",
                "rawPixelsExposed": "false",
                "sourceAgeMS": sourceAgeMS.map { String($0) } ?? "unknown",
                "stale": String((sourceAgeMS ?? Double.greatestFiniteMagnitude) > staleSourceThresholdMS)
            ]
        )
    }

    private func candidate(
        labeled: LabeledMacWindowTargetCandidate,
        sourceAgeMS: Double?
    ) -> LocalNavigationCandidate {
        let window = labeled.candidate
        return LocalNavigationCandidate(
            id: "window-\(window.windowID)",
            kind: .window,
            appName: window.appName,
            bundleIdentifier: window.bundleIdentifier,
            title: window.title,
            bounds: HotLoopRect(
                x: window.bounds.x,
                y: window.bounds.y,
                width: window.bounds.width,
                height: window.bounds.height,
                space: .screen
            ),
            isFrontmost: window.isFrontmost,
            isFocused: window.isFocused,
            safetyStatus: window.safetyAssessment.status,
            confidence: confidence(for: window),
            sourceAgeMS: sourceAgeMS,
            metadata: [
                "label": labeled.label,
                "windowID": String(window.windowID),
                "processID": String(window.processID),
                "isVisible": String(window.isVisible),
                "isOnScreen": String(window.isOnScreen)
            ]
        )
    }

    private func confidence(for window: MacWindowTargetCandidate) -> Double {
        guard window.isVisible, window.isOnScreen else { return 0 }

        switch window.safetyAssessment.status {
        case .allowed:
            var confidence = 0.75
            if window.isFrontmost { confidence += 0.1 }
            if window.isFocused { confidence += 0.1 }
            if window.bundleIdentifier != nil { confidence += 0.05 }
            return min(confidence, 1)
        case .reviewRequired:
            return 0.3
        case .blocked:
            return 0
        }
    }
}

public struct LocalNavigationControllerPolicy: Sendable {
    public var name: String
    public var minimumConfidence: Double

    public init(
        name: String = "local-navigation-controller-v1",
        minimumConfidence: Double = 0.6
    ) {
        self.name = name
        self.minimumConfidence = minimumConfidence
    }

    public func decide(state: LocalNavigationWorldState) -> HotLoopControllerAction {
        let candidates = state.candidates
            .filter { $0.safetyStatus == .allowed && $0.confidence >= minimumConfidence }
        let requestedCandidate = candidates
            .filter { matchesRequest($0, state: state) }
            .sorted { $0.confidence > $1.confidence }
            .first

        if let requestedCandidate {
            if requestedCandidate.isFocused {
                return action(
                    state: state,
                    candidate: requestedCandidate,
                    kind: .wait,
                    confidence: requestedCandidate.confidence,
                    rationale: "Requested navigation target is already focused",
                    fallback: true,
                    fallbackReason: "alreadyFocused"
                )
            }

            return action(
                state: state,
                candidate: requestedCandidate,
                kind: requestedCandidate.kind == .browserTab ? .switchTab : .focusWindow,
                confidence: requestedCandidate.confidence,
                rationale: "Selected requested local navigation target",
                fallback: false
            )
        }

        if state.requestedBundleIdentifier != nil || state.requestedTitleContains != nil {
            return action(
                state: state,
                candidate: nil,
                kind: .observe,
                confidence: state.confidence,
                rationale: "Requested navigation target was not found",
                fallback: true,
                fallbackReason: "targetNotFound"
            )
        }

        guard let best = candidates
            .filter({ !$0.isFocused })
            .sorted(by: { $0.confidence > $1.confidence })
            .first
        else {
            return action(
                state: state,
                candidate: nil,
                kind: state.candidates.isEmpty ? .observe : .wait,
                confidence: state.confidence,
                rationale: state.candidates.isEmpty
                    ? "No local navigation candidates are available"
                    : "No unfocused safe candidate is available",
                fallback: true,
                fallbackReason: state.candidates.isEmpty ? "noCandidates" : "noUnfocusedCandidate"
            )
        }

        return action(
            state: state,
            candidate: best,
            kind: .activateCandidate,
            confidence: best.confidence,
            rationale: "Selected highest-confidence safe local navigation candidate",
            fallback: false
        )
    }

    private func matchesRequest(
        _ candidate: LocalNavigationCandidate,
        state: LocalNavigationWorldState
    ) -> Bool {
        let bundleMatches = state.requestedBundleIdentifier.map { requested in
            candidate.bundleIdentifier == requested
        } ?? true
        let titleMatches = state.requestedTitleContains.map { requested in
            candidate.title?.localizedCaseInsensitiveContains(requested) == true
        } ?? true
        return bundleMatches && titleMatches
    }

    private func action(
        state: LocalNavigationWorldState,
        candidate: LocalNavigationCandidate?,
        kind: HotLoopActionKind,
        confidence: Double,
        rationale: String,
        fallback: Bool,
        fallbackReason: String? = nil
    ) -> HotLoopControllerAction {
        var metadata = [
            "fallback": String(fallback),
            "localNavigation": "true"
        ]
        metadata["candidateID"] = candidate?.id
        metadata["candidateKind"] = candidate?.kind.rawValue
        metadata["bundleIdentifier"] = candidate?.bundleIdentifier
        metadata["title"] = candidate?.title
        metadata["fallbackReason"] = fallbackReason

        return HotLoopControllerAction(
            id: "action-\(state.id)",
            traceID: state.traceID,
            frameID: state.frameID,
            stateID: state.id,
            kind: kind,
            target: candidate?.bounds,
            policyName: name,
            confidence: confidence,
            rationale: rationale,
            metadata: metadata
        )
    }
}
