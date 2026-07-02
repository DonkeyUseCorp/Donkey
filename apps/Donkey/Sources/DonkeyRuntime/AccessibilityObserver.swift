@preconcurrency import ApplicationServices
import DonkeyContracts
import Foundation

/// A resolved live accessibility observation of one app window: the window target and its controls.
struct ResolvedAccessibilityObservation {
    var target: MacWindowTargetCandidate
    var controls: [LocalAppDiscoveredControl]
}

/// Captures a running app's accessibility tree and discovers its controls. Shared by the guidance
/// overlay and the accessibility action executor so both ground against the same observation.
@MainActor
public enum AccessibilityObserver {
    static func observe(
        appName: String?,
        bundleIdentifier: String?,
        windowTitleHint: String? = nil,
        resolver: MacWindowResolver = MacWindowResolver()
    ) -> ResolvedAccessibilityObservation? {
        guard AXIsProcessTrusted(),
              let target = resolveTarget(
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                windowTitleHint: windowTitleHint,
                resolver: resolver
              )
        else {
            return nil
        }
        let limits = MacAccessibilitySnapshotLimits(maxDepth: 8, maxChildrenPerNode: 120, maxTotalNodes: 1_200)
        // Retain the live AXUIElement for each node so a later action resolves against the exact control
        // we observed (identity-stable across list reordering) instead of re-walking by node index.
        var handles: [String: AXUIElement] = [:]
        guard let tree = try? ApplicationServicesMacAccessibilitySnapshotCapturer().captureTree(
            target: target,
            limits: limits,
            onNode: { _ in },
            onLiveElement: { nodeID, element in handles[nodeID] = element }
        ) else {
            return nil
        }
        MacAccessibilityElementHandleCache.shared.replace(processID: target.processID, handles: handles)
        let snapshot = MacAccessibilitySnapshot(
            target: target,
            limits: limits,
            root: tree.root,
            totalNodeCount: tree.totalNodeCount,
            isTreeTruncated: tree.isTreeTruncated
        )
        let index = LocalAppAccessibilityControlDiscovery().discover(in: snapshot)
        return ResolvedAccessibilityObservation(target: target, controls: index.controls)
    }

    public static func resolveTarget(
        appName: String?,
        bundleIdentifier: String?,
        windowTitleHint: String? = nil,
        resolver: MacWindowResolver = MacWindowResolver()
    ) -> MacWindowTargetCandidate? {
        if appName != nil || bundleIdentifier != nil {
            // A specific app was requested: only ever return that app's window. If it isn't running /
            // has no window, return nil — never fall back to the frontmost window, which would
            // silently ground (and potentially click) in an unrelated app the user didn't name.
            let appWindows = resolver.enumerateCandidates().filter { candidate in
                if let bundleIdentifier, let candidateBundle = candidate.bundleIdentifier {
                    return candidateBundle.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
                }
                if let appName, let candidateApp = candidate.appName {
                    return AppNameMatching.matches(candidateApp, appName)
                }
                return false
            }
            // A specific window was named (a conversation, a document): return the app window whose title
            // matches it, and NEVER fall back to another window when none match — silently reading or
            // clicking the wrong window of the app is exactly the failure this pin exists to prevent. The
            // caller reports "no such window; open it first" so the planner opens the chat rather than
            // acting on the contact list.
            if let hint = windowTitleHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
                return appWindows.first { candidate in
                    guard let title = candidate.title, !title.isEmpty else { return false }
                    return titleMatches(title, hint)
                }
            }
            return appWindows.first
        }
        return try? resolver.selectTarget()
    }

    /// Whether a window's title identifies the window the planner named. Case-insensitive containment in
    /// either direction so a hint of "Juyoung" matches a window titled "Juyoung Lee", and a CG title that
    /// the system truncated still matches a longer hint. Matching by the human name the user already gave
    /// keeps this app-agnostic — no per-app window heuristics.
    static func titleMatches(_ title: String, _ hint: String) -> Bool {
        let normalizedTitle = title.lowercased()
        let normalizedHint = hint.lowercased()
        return normalizedTitle.contains(normalizedHint) || normalizedHint.contains(normalizedTitle)
    }
}
