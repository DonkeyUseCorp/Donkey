import DonkeyContracts
import Foundation

/// A control to point at, resolved from an accessibility observation by text.
public struct AccessibilityCursorPathTarget: Equatable, Sendable {
    /// Text used to resolve the control (matched against control label / id / metadata controlID).
    public var query: String
    /// Human-facing label shown on the overlay for this step.
    public var label: String
    /// Path-step semantics (e.g. `.targetControl` to point, `.act` to indicate a click).
    public var kind: AgentPathStepKind

    public init(query: String, label: String, kind: AgentPathStepKind = .targetControl) {
        self.query = query
        self.label = label
        self.kind = kind
    }
}

/// Builds a grounded cursor path from an accessibility observation, decoupled from any execution
/// backend. Works for any app that exposes an accessibility tree — native or Electron (Chromium) —
/// which is exactly the case where AppleScript cannot help.
///
/// This type is pure: it takes already-observed controls + the target window bounds and produces
/// `normalizedTarget` `AgentPathStep`s. Live capture (snapshot → controls) and overlay presentation
/// are wired separately. Targets that cannot be resolved to a positive-area control are dropped, so
/// the overlay never invents motion to an ungrounded point.
public enum AccessibilityCursorPathBuilder {
    public static func buildSteps(
        targetApp: String,
        windowBounds: WindowTargetBounds,
        controls: [LocalAppDiscoveredControl],
        targets: [AccessibilityCursorPathTarget],
        phaseID: String = ""
    ) -> [AgentPathStep] {
        guard windowBounds.width > 0, windowBounds.height > 0 else { return [] }
        var usedControlIDs: Set<String> = []
        return targets.compactMap { target in
            guard let control = resolve(target.query, in: controls, excluding: usedControlIDs),
                  let frame = control.frame,
                  frame.hasPositiveArea,
                  let bounds = normalized(frame, in: windowBounds)
            else {
                return nil
            }
            usedControlIDs.insert(control.id)
            return AgentPathStep(
                id: stepID(for: target.query),
                phaseID: phaseID,
                kind: target.kind,
                label: target.label,
                targetApp: targetApp,
                point: center(of: bounds),
                bounds: bounds,
                controlID: control.id,
                source: .accessibility,
                status: .observed
            )
        }
    }

    // MARK: - Control resolution

    /// Resolves the best control for `query` by normalized-text relevance. Prefers an exact label
    /// match, then containment, then token overlap; ties break toward the larger control.
    static func resolve(
        _ query: String,
        in controls: [LocalAppDiscoveredControl],
        excluding used: Set<String> = []
    ) -> LocalAppDiscoveredControl? {
        let normalizedQuery = LocalAppTextNormalizer.normalizedPhrase(query)
        guard !normalizedQuery.isEmpty else { return nil }
        let queryTokens = ControlTextRelevance.tokens(in: normalizedQuery)

        var best: (control: LocalAppDiscoveredControl, score: Double)?
        for control in controls where !used.contains(control.id) {
            guard let frame = control.frame, frame.hasPositiveArea else { continue }
            let candidates = [control.label, control.metadata["controlID"] ?? "", control.id]
                .map(LocalAppTextNormalizer.normalizedPhrase)
                .filter { !$0.isEmpty }
            guard !candidates.isEmpty else { continue }

            let score = ControlTextRelevance.score(
                normalizedQuery: normalizedQuery,
                queryTokens: queryTokens,
                candidates: candidates
            )
            guard score > 0 else { continue }
            // Tie-break toward the larger control (more likely the intended, prominent target).
            let area = frame.width * frame.height
            let composite = score * 1_000_000 + area
            if best == nil || composite > best!.score {
                best = (control, composite)
            }
        }
        return best?.control
    }

    // MARK: - Geometry

    /// Normalizes a screen-space control frame to the target window's `normalizedTarget` space,
    /// clamping each edge so the rect stays within [0, 1] even for controls partly off-window.
    static func normalized(_ frame: WindowTargetBounds, in window: WindowTargetBounds) -> HotLoopRect? {
        guard window.width > 0, window.height > 0 else { return nil }
        let left = clamp((frame.x - window.x) / window.width)
        let top = clamp((frame.y - window.y) / window.height)
        let right = clamp((frame.x + frame.width - window.x) / window.width)
        let bottom = clamp((frame.y + frame.height - window.y) / window.height)
        let width = right - left
        let height = bottom - top
        guard width > 0, height > 0 else { return nil }
        return HotLoopRect(x: left, y: top, width: width, height: height, space: .normalizedTarget)
    }

    private static func center(of bounds: HotLoopRect) -> HotLoopPoint {
        HotLoopPoint(
            x: clamp(bounds.origin.x + bounds.size.width / 2),
            y: clamp(bounds.origin.y + bounds.size.height / 2),
            space: .normalizedTarget
        )
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func stepID(for query: String) -> String {
        let slug = LocalAppTextNormalizer.normalizedPhrase(query)
            .split(separator: " ")
            .joined(separator: "-")
        return slug.isEmpty ? "target" : slug
    }
}
