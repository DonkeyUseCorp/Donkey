import DonkeyContracts
import Foundation

/// The single, typed decision for whether an action runs in the background (no cursor move, no app
/// raise) or the foreground (the existing activate-and-recover path). It replaces the ad-hoc frontmost
/// checks the act tools used to make inline, so background eligibility is decided in one place.
///
/// Background is permitted only when all of:
/// 1. the turn asked for it (`ExecutionPreference.background`), set by the understanding boundary —
///    never inferred from raw text;
/// 2. the action uses a background-capable lane — the Accessibility action lane (`AXUIElementPerformAction`
///    is a focus-neutral cross-process RPC) or the pid-routed event-post lane (`CGEvent.postToPid` and the
///    SkyLight bridge deliver to a process without moving the cursor); and
/// 3. the resolved window is a safe surface (not a login/password/payment/system surface), because a
///    background action runs on a window the user is not watching.
///
/// Anything else returns `.foreground`, which is always available, so an unsafe surface or a foreground
/// turn gracefully degrades instead of failing. The target is resolved from the on-screen window list,
/// so a returned candidate is inherently on the active Space and not minimized — no Space query needed.
public enum TargetActionGuard {
    /// The mechanism an action will use. Both lanes can run in the background; the lane records which
    /// delivery the caller will use so this stays a single, explicit decision point.
    public enum Lane: Equatable, Sendable {
        /// `AXUIElementPerformAction` on a cached element handle.
        case axAction
        /// A synthetic CGEvent delivered to the target process (public `postToPid`, optionally the
        /// SkyLight bridge) — for coordinate clicks, scroll, drag, and keystrokes AX can't express.
        case pidEventPost
    }

    public enum Decision: Equatable, Sendable {
        /// Act on the pinned target without raising it or moving the cursor.
        case background(InputTarget)
        /// Use the existing path: activate the target (one recovery) and act in front.
        case foreground
    }

    public static func resolve(
        candidate: MacWindowTargetCandidate,
        preference: ExecutionPreference,
        lane: Lane
    ) -> Decision {
        // Both lanes are background-capable; the gate is the turn's preference and the surface safety.
        _ = lane
        guard preference == .background,
              candidate.safetyAssessment.status == .allowed
        else {
            return .foreground
        }
        return .background(InputTarget(candidate: candidate))
    }
}
