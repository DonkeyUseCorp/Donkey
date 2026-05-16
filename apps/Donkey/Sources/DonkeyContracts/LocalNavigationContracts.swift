import Foundation

public enum LocalNavigationCandidateKind: String, Codable, Equatable, Sendable {
    case window
    case browserTab
    case app
    case focusedSurface
}

public struct LocalNavigationCandidate: Codable, Equatable, Sendable {
    public var id: String
    public var kind: LocalNavigationCandidateKind
    public var appName: String?
    public var bundleIdentifier: String?
    public var title: String?
    public var bounds: HotLoopRect?
    public var isFrontmost: Bool
    public var isFocused: Bool
    public var safetyStatus: WindowTargetSafetyStatus
    public var confidence: Double
    public var sourceAgeMS: Double?
    public var metadata: [String: String]

    public init(
        id: String,
        kind: LocalNavigationCandidateKind,
        appName: String? = nil,
        bundleIdentifier: String? = nil,
        title: String? = nil,
        bounds: HotLoopRect? = nil,
        isFrontmost: Bool = false,
        isFocused: Bool = false,
        safetyStatus: WindowTargetSafetyStatus = .allowed,
        confidence: Double,
        sourceAgeMS: Double? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.bounds = bounds
        self.isFrontmost = isFrontmost
        self.isFocused = isFocused
        self.safetyStatus = safetyStatus
        self.confidence = confidence
        self.sourceAgeMS = sourceAgeMS
        self.metadata = metadata
    }
}

public struct LocalNavigationWorldState: Codable, Equatable, Sendable {
    public var id: String
    public var traceID: String
    public var frameID: String
    public var targetID: String
    public var observedAt: RunTraceTimestamp
    public var candidates: [LocalNavigationCandidate]
    public var focusedCandidateID: String?
    public var frontmostCandidateID: String?
    public var requestedBundleIdentifier: String?
    public var requestedTitleContains: String?
    public var confidence: Double
    public var metadata: [String: String]

    public init(
        id: String,
        traceID: String,
        frameID: String,
        targetID: String,
        observedAt: RunTraceTimestamp,
        candidates: [LocalNavigationCandidate],
        focusedCandidateID: String? = nil,
        frontmostCandidateID: String? = nil,
        requestedBundleIdentifier: String? = nil,
        requestedTitleContains: String? = nil,
        confidence: Double,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.traceID = traceID
        self.frameID = frameID
        self.targetID = targetID
        self.observedAt = observedAt
        self.candidates = candidates
        self.focusedCandidateID = focusedCandidateID
        self.frontmostCandidateID = frontmostCandidateID
        self.requestedBundleIdentifier = requestedBundleIdentifier
        self.requestedTitleContains = requestedTitleContains
        self.confidence = confidence
        self.metadata = metadata
    }

    public func hotLoopWorldState() -> HotLoopWorldState {
        HotLoopWorldState(
            id: id,
            traceID: traceID,
            frameID: frameID,
            targetID: targetID,
            observedAt: observedAt,
            signalSummaries: [
                HotLoopPerceptionSignalSummary(
                    id: "signal-\(id)",
                    kind: "localNavigationMetadata",
                    confidence: confidence,
                    sourceAgeMS: candidates.compactMap(\.sourceAgeMS).max(),
                    observationCount: candidates.count
                )
            ],
            actionAffordances: candidates.map { candidate in
                HotLoopActionAffordance(
                    id: "affordance-\(candidate.id)",
                    kind: candidate.kind == .browserTab ? .switchTab : .focusWindow,
                    targetBounds: candidate.bounds,
                    confidence: candidate.confidence,
                    sourceSignalID: "signal-\(id)"
                )
            },
            confidence: confidence,
            metadata: metadata.merging([
                "localNavigation.candidateCount": String(candidates.count),
                "localNavigation.focusedCandidateID": focusedCandidateID ?? "",
                "localNavigation.frontmostCandidateID": frontmostCandidateID ?? ""
            ]) { current, _ in current }
        )
    }
}
