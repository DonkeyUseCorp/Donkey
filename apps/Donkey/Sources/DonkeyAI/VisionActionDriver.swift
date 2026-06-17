import AppKit
import CoreGraphics
import DonkeyContracts
import DonkeyRuntime
import Foundation

/// Drives a non-scriptable app by vision: a bounded per-turn loop that screenshots the app window,
/// asks `VisionActionPlanner` for the next click/type/key, and executes it with the real
/// pointer/keyboard until the model reports `done`. Shared by the production command router
/// (`UserQueryCommandHandler.handleVisionAction`) and the Spotify live smoke test, so both exercise
/// the exact same loop, guards, and action handling.
///
/// Safety: every real-input action is gated behind a frontmost check — the target window must be the
/// frontmost app at the instant of the click/keystroke, so input never lands on a window the user
/// switched to during a model round-trip.
@MainActor
public enum VisionActionDriver {
    public typealias ScreenshotCapture = @MainActor (MacWindowTargetCandidate) async throws -> CapturedWindowScreenshot

    /// Plans the single next UI action from the current screenshot. Injected so the
    /// loop, guards, and action handling are shared across planner backends — the
    /// `backend.createResponse` path (`VisionActionPlanner`) and the direct-Vertex
    /// path (`GeminiVertexVisionPlanner`) differ only in this one step.
    public typealias ActionPlanner = @MainActor (
        _ goal: String,
        _ appName: String,
        _ screenshot: CapturedWindowScreenshot,
        _ window: WindowTargetBounds,
        _ history: [String],
        _ appGuidance: String?
    ) async throws -> VisionActionPlanner.PlannedAction

    /// Repeated identical clicks mean the model is stuck (clicking a target that
    /// never responds); abort rather than burn the whole turn budget on it.
    private static let stuckClickRepeatLimit = 4

    public struct Outcome: Sendable {
        public var completed: Bool
        public var turns: Int
        /// "ok" | "noWindowForApp" | "screenshotFailed" | "visionPlanFailed" | "targetNotFrontmost" | "stuckRepeatingClick" | "maxTurnsReached"
        public var reason: String
        public var lastNarration: String?
        public var history: [String]
    }

    /// Per-turn callback (the planned action + the exact screenshot the model saw) for logging/dumping.
    public struct TurnInfo: Sendable {
        public var turn: Int
        public var screenshot: CapturedWindowScreenshot
        public var action: VisionActionPlanner.PlannedAction
    }

    /// Convenience: drive via the backend `createResponse` planner
    /// (`VisionActionPlanner`). Used by the production command router and the
    /// Spotify live smoke test; the loop itself is `drive(planner:)` below.
    public static func drive(
        appName: String,
        bundleIdentifier: String?,
        goal: String,
        appGuidance: String?,
        backend: DonkeyBackendInferenceClient,
        maxTurns: Int = 12,
        settleNanoseconds: UInt64 = 1_200_000_000,
        capture: @escaping ScreenshotCapture = { try await ScreenCaptureKitWindowScreenshotCapturer().capture(target: $0) },
        verify: (@MainActor () -> Bool)? = nil,
        onTurn: (@MainActor (TurnInfo) -> Void)? = nil
    ) async -> Outcome {
        await drive(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            goal: goal,
            appGuidance: appGuidance,
            maxTurns: maxTurns,
            settleNanoseconds: settleNanoseconds,
            capture: capture,
            verify: verify,
            onTurn: onTurn,
            planner: { goal, app, shot, window, history, guidance in
                try await VisionActionPlanner.nextAction(
                    goal: goal, app: app, screenshot: shot, window: window,
                    history: history, appGuidance: guidance, backend: backend
                )
            }
        )
    }

    /// The single vision-driving loop: screenshot → `planner` → execute, until the
    /// model reports `done` (optionally re-checked by `verify`), the goal is
    /// independently verified, the model gets stuck, or `maxTurns` is reached.
    public static func drive(
        appName: String,
        bundleIdentifier: String?,
        goal: String,
        appGuidance: String?,
        maxTurns: Int = 12,
        settleNanoseconds: UInt64 = 1_200_000_000,
        capture: @escaping ScreenshotCapture = { try await ScreenCaptureKitWindowScreenshotCapturer().capture(target: $0) },
        verify: (@MainActor () -> Bool)? = nil,
        onTurn: (@MainActor (TurnInfo) -> Void)? = nil,
        planner: @escaping ActionPlanner
    ) async -> Outcome {
        var history: [String] = []
        var lastNarration: String?
        var turnsTaken = 0
        var lastClickKey = ""
        var clickRepeatCount = 0

        // Resolve the target window once and reuse it; only re-resolve when a capture fails (the
        // window moving/closing is the only thing that invalidates the cached bounds).
        guard var target = AccessibilityObserver.resolveTarget(appName: appName, bundleIdentifier: bundleIdentifier) else {
            return Outcome(completed: false, turns: 0, reason: "noWindowForApp", lastNarration: nil, history: history)
        }
        activate(target, appName: appName)

        for _ in 0..<maxTurns {
            // An independent success signal (e.g. "Spotify is playing") wins immediately —
            // don't spend a turn asking the model whether it's done when we can check.
            if verify?() == true {
                return finish(true, turnsTaken, "ok", lastNarration, history)
            }

            // Ensure the target is frontmost before we screenshot + act; re-activate only if needed.
            if !isFrontmost(target) {
                activate(target, appName: appName)
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let refreshed = AccessibilityObserver.resolveTarget(appName: appName, bundleIdentifier: bundleIdentifier) else {
                    return finish(false, turnsTaken, "noWindowForApp", lastNarration, history)
                }
                target = refreshed
                guard isFrontmost(target) else {
                    return finish(false, turnsTaken, "targetNotFrontmost", lastNarration, history)
                }
            }

            guard let shot = await captureWithRetry(target, appName: appName, bundleIdentifier: bundleIdentifier, capture: capture, target: &target) else {
                return finish(false, turnsTaken, "screenshotFailed", lastNarration, history)
            }

            let action: VisionActionPlanner.PlannedAction
            do {
                action = try await planner(goal, appName, shot, target.bounds, history, appGuidance)
            } catch {
                return finish(false, turnsTaken, "visionPlanFailed", lastNarration, history)
            }
            turnsTaken += 1
            lastNarration = action.reason.flatMap { $0.isEmpty ? nil : $0 } ?? lastNarration
            onTurn?(TurnInfo(turn: turnsTaken - 1, screenshot: shot, action: action))

            // Focus can change during the model round-trip; re-check before any real input so we never
            // click/type into a window the user switched to.
            guard isFrontmost(target) else {
                return finish(false, turnsTaken, "targetNotFrontmost", lastNarration, history)
            }

            // A "click" that carries text but no resolvable point is really a "type".
            var effective = action.action
            if effective == "click", action.screenPoint == nil, let text = action.text, !text.isEmpty {
                effective = "type"
            }

            switch effective {
            case "done":
                // Verify-don't-trust when an independent signal is available: the model
                // claiming done while verify() is false means its last action missed.
                if let verify {
                    if verify() { return finish(true, turnsTaken, "ok", lastNarration, history) }
                    history.append("claimed done but the goal isn't satisfied yet — your last action missed; click the exact target")
                } else {
                    return finish(true, turnsTaken, "ok", lastNarration, history)
                }
            case "click":
                if let point = action.screenPoint {
                    let key = "\(Int(point.x)),\(Int(point.y))"
                    clickRepeatCount = (key == lastClickKey) ? clickRepeatCount + 1 : 0
                    lastClickKey = key
                    if clickRepeatCount >= stuckClickRepeatLimit {
                        history.append("aborting: stuck repeating click \(key)")
                        return finish(false, turnsTaken, "stuckRepeatingClick", lastNarration, history)
                    }
                    _ = MacPointerInput.moveAndClick(at: point)
                    history.append(clickRepeatCount >= 2
                        ? "clicked (\(key)) AGAIN — not working; pick a DIFFERENT target/exact center: \(action.reason ?? "")"
                        : "clicked at (\(key)): \(action.reason ?? "")")
                } else {
                    history.append("skipped click with no resolvable point")
                }
            case "type":
                let text = action.text ?? ""
                MacKeyboardInput.type(text)
                history.append("typed \"\(text)\"")
            case "key":
                let key = action.text ?? "return"
                MacKeyboardInput.pressKey(key)
                history.append("pressed key \(key)")
            default:
                history.append("ignored unknown action \(action.action)")
            }

            try? await Task.sleep(nanoseconds: settleNanoseconds)
        }

        // Last chance: the final action may have satisfied the goal on the turn we ran out.
        if verify?() == true {
            return finish(true, turnsTaken, "ok", lastNarration, history)
        }
        return finish(false, turnsTaken, "maxTurnsReached", lastNarration, history)
    }

    private static func finish(
        _ completed: Bool,
        _ turns: Int,
        _ reason: String,
        _ lastNarration: String?,
        _ history: [String]
    ) -> Outcome {
        Outcome(completed: completed, turns: turns, reason: reason, lastNarration: lastNarration, history: history)
    }

    private static func captureWithRetry(
        _ candidate: MacWindowTargetCandidate,
        appName: String,
        bundleIdentifier: String?,
        capture: ScreenshotCapture,
        target: inout MacWindowTargetCandidate
    ) async -> CapturedWindowScreenshot? {
        if let shot = try? await capture(candidate) { return shot }
        // The window may have moved/closed; re-resolve once and retry.
        guard let refreshed = AccessibilityObserver.resolveTarget(appName: appName, bundleIdentifier: bundleIdentifier),
              let shot = try? await capture(refreshed)
        else {
            return nil
        }
        target = refreshed
        return shot
    }

    private static func isFrontmost(_ target: MacWindowTargetCandidate) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid_t(target.processID)
    }

    private static func activate(_ target: MacWindowTargetCandidate, appName: String) {
        let app = NSRunningApplication(processIdentifier: pid_t(target.processID))
        _ = app?.activate()
        restoreMinimizedWindows(appName: appName)
    }

    /// Un-minimize the app's windows: a stray vision click can hit the minimize
    /// button, which would break every later screenshot. Best-effort — silently
    /// no-ops without Automation permission. Only runs on (re)activation, not every
    /// turn, so the System Events round-trip isn't on the hot path.
    private static func restoreMinimizedWindows(appName: String) {
        let source = """
        tell application "System Events"
            if exists process "\(appName)" then
                tell process "\(appName)"
                    try
                        repeat with w in windows
                            if value of attribute "AXMinimized" of w is true then
                                set value of attribute "AXMinimized" of w to false
                            end if
                        end repeat
                    end try
                end tell
            end if
        end tell
        """
        // Never prompt mid-task for this internal nicety; skip it if Automation isn't already granted.
        SystemPermissionCoordinator.runSystemEventsScriptIfGranted(source)
    }
}
