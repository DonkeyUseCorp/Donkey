@preconcurrency import ApplicationServices
import DonkeyContracts
import Foundation

/// Produces an accessibility-grounded cursor overlay for a guidance request ("show me where X is").
///
/// Visualization-only: it captures the target app's accessibility tree, grounds the requested
/// controls to a cursor path, and returns an overlay request. It never performs input
/// (`realPointerMoved` stays false). Because it relies only on the accessibility tree, it works on
/// any app that exposes one — native or Electron (Chromium) — which is exactly the case where
/// AppleScript cannot help.
@MainActor
public enum GuidanceOverlayFlow {
    public struct Outcome: Sendable {
        public var request: PointerCoachCursorGuideRequest?
        public var reason: String
        public var resolvedAppName: String?

        public init(request: PointerCoachCursorGuideRequest?, reason: String, resolvedAppName: String?) {
            self.request = request
            self.reason = reason
            self.resolvedAppName = resolvedAppName
        }
    }

    public static func cursorGuide(
        appName: String?,
        bundleIdentifier: String?,
        targets: [AccessibilityCursorPathTarget],
        title: String,
        traceID: String,
        windowResolver: MacWindowResolver = MacWindowResolver()
    ) -> Outcome {
        guard AXIsProcessTrusted() else {
            return Outcome(request: nil, reason: "accessibilityNotTrusted", resolvedAppName: nil)
        }
        guard !targets.isEmpty else {
            return Outcome(request: nil, reason: "noTargets", resolvedAppName: nil)
        }
        guard let target = resolveTarget(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            resolver: windowResolver
        ) else {
            return Outcome(request: nil, reason: "noWindowForApp", resolvedAppName: nil)
        }

        let limits = MacAccessibilitySnapshotLimits(maxDepth: 8, maxChildrenPerNode: 120, maxTotalNodes: 1_200)
        guard let tree = try? ApplicationServicesMacAccessibilitySnapshotCapturer().captureTree(
            target: target,
            limits: limits
        ) else {
            return Outcome(request: nil, reason: "accessibilityCaptureFailed", resolvedAppName: target.appName)
        }
        let snapshot = MacAccessibilitySnapshot(
            target: target,
            limits: limits,
            root: tree.root,
            totalNodeCount: tree.totalNodeCount,
            isTreeTruncated: tree.isTreeTruncated
        )
        let index = LocalAppAccessibilityControlDiscovery().discover(in: snapshot)
        let steps = AccessibilityCursorPathBuilder.buildSteps(
            targetApp: target.appName ?? appName ?? "",
            windowBounds: snapshot.target.bounds,
            controls: index.controls,
            targets: targets,
            phaseID: "guidance"
        )
        guard !steps.isEmpty else {
            return Outcome(request: nil, reason: "noGroundedTargets", resolvedAppName: target.appName)
        }
        let trace = AgentPathTrace(
            taskID: traceID,
            title: title,
            sourceTraceID: traceID,
            steps: steps,
            metadata: ["mode": "guidance", "realPointerMoved": "false"]
        )
        guard let request = trace.visualizationPlan()?.cursorOverlayRequest() else {
            return Outcome(request: nil, reason: "noOverlayRequest", resolvedAppName: target.appName)
        }
        return Outcome(request: request, reason: "ok", resolvedAppName: target.appName)
    }

    private static func resolveTarget(
        appName: String?,
        bundleIdentifier: String?,
        resolver: MacWindowResolver
    ) -> MacWindowTargetCandidate? {
        if appName != nil || bundleIdentifier != nil {
            let candidates = resolver.enumerateCandidates()
            if let match = candidates.first(where: { candidate in
                if let bundleIdentifier, let candidateBundle = candidate.bundleIdentifier {
                    return candidateBundle.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
                }
                if let appName, let candidateApp = candidate.appName {
                    return candidateApp.localizedCaseInsensitiveContains(appName)
                        || appName.localizedCaseInsensitiveContains(candidateApp)
                }
                return false
            }) {
                return match
            }
        }
        return try? resolver.selectTarget()
    }
}
