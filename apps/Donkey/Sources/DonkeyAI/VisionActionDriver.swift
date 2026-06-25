import AppKit
import CoreGraphics
import DonkeyContracts
import DonkeyRuntime
import Foundation

/// Drives a non-scriptable app by vision: a bounded per-turn loop that screenshots the app window,
/// asks a computer-use planner for the next action, and runs it through
/// `VisionComputerActionExecutor` until the model stops calling the tool (goal done). Shared by the
/// Live → vision escalation and the Spotify live smoke test, so both exercise the exact same loop,
/// guards, and action handling.
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
    ) async throws -> VisionComputerAction

    /// Repeating the same action with no effect means the model is stuck; abort rather than burn the
    /// whole turn budget on it. Applies to any action except scroll/wait, where repeating is normal.
    private static let stuckRepeatLimit = 4

    public struct Outcome: Sendable {
        public var completed: Bool
        public var turns: Int
        /// "ok" | "noWindowForApp" | "screenshotFailed" | "visionPlanFailed" | "targetNotFrontmost" | "stuckRepeatingAction" | "maxTurnsReached"
        public var reason: String
        public var lastNarration: String?
        public var history: [String]
    }

    /// Per-turn callback (the planned action + the exact screenshot the model saw) for logging/dumping.
    public struct TurnInfo: Sendable {
        public var turn: Int
        public var screenshot: CapturedWindowScreenshot
        public var action: VisionComputerAction
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
        var lastActionSignature = ""
        var repeatCount = 0

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

            let action: VisionComputerAction
            do {
                action = try await planner(goal, appName, shot, target.bounds, history, appGuidance)
            } catch {
                return finish(false, turnsTaken, "visionPlanFailed", lastNarration, history)
            }
            turnsTaken += 1
            lastNarration = action.intent.isEmpty ? lastNarration : action.intent
            onTurn?(TurnInfo(turn: turnsTaken - 1, screenshot: shot, action: action))

            // Focus can change during the model round-trip; re-check before any real input so we never
            // click/type into a window the user switched to.
            guard isFrontmost(target) else {
                return finish(false, turnsTaken, "targetNotFrontmost", lastNarration, history)
            }

            // The computer-use model signals completion by replying in words instead of calling the
            // tool. Verify-don't-trust when an independent signal is available: a "done" while
            // verify() is false means the last action missed.
            if case let .done(text) = action.kind {
                let summary = text.isEmpty ? lastNarration : text
                if let verify {
                    if verify() { return finish(true, turnsTaken, "ok", summary, history) }
                    history.append("claimed done but the goal isn't satisfied yet — your last action missed; act on the exact target")
                } else {
                    return finish(true, turnsTaken, "ok", summary, history)
                }
            } else {
                // Stop a stuck loop that keeps repeating the same no-op action (a missed click, a
                // browser action the desktop can't run, …). Scroll/wait are exempt — repeating them is
                // a normal pattern (paging a long list, waiting for load), so their signature is nil.
                if let signature = actionSignature(action, window: target.bounds) {
                    repeatCount = (signature == lastActionSignature) ? repeatCount + 1 : 0
                    lastActionSignature = signature
                    if repeatCount >= stuckRepeatLimit {
                        history.append("aborting: stuck repeating \(signature)")
                        return finish(false, turnsTaken, "stuckRepeatingAction", lastNarration, history)
                    }
                } else {
                    repeatCount = 0
                    lastActionSignature = ""
                }
                let line = await VisionComputerActionExecutor.execute(action, window: target.bounds)
                history.append(repeatCount >= 2
                    ? "\(line) — repeated; if nothing changed pick a DIFFERENT target/exact center"
                    : line)
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

    /// A stable signature for stuck-repeat detection, or nil for kinds where consecutive repeats are a
    /// legitimate pattern (scrolling a long list, waiting for load) and must not trip the guard.
    private static func actionSignature(_ action: VisionComputerAction, window: WindowTargetBounds) -> String? {
        switch action.kind {
        case .scroll, .wait, .done:
            return nil
        case let .click(button, count, point):
            let screen = VisionComputerActionExecutor.screenPoint(point, window: window)
            return "click:\(button.rawValue):\(count):\(Int(screen.x)),\(Int(screen.y))"
        case let .move(point):
            let screen = VisionComputerActionExecutor.screenPoint(point, window: window)
            return "move:\(Int(screen.x)),\(Int(screen.y))"
        case let .drag(from, to):
            return "drag:\(Int(from.x)),\(Int(from.y))->\(Int(to.x)),\(Int(to.y))"
        case let .type(text, _, _, _):
            return "type:\(text)"
        case let .keys(keys):
            return "keys:\(keys.joined(separator: "+"))"
        case let .unsupported(name):
            return "unsupported:\(name)"
        }
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
