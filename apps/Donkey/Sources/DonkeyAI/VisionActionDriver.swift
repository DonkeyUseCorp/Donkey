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

    public struct Outcome: Sendable {
        public var completed: Bool
        public var turns: Int
        /// "ok" | "noWindowForApp" | "screenshotFailed" | "visionPlanFailed" | "targetNotFrontmost" | "maxTurnsReached"
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

    public static func drive(
        appName: String,
        bundleIdentifier: String?,
        goal: String,
        appGuidance: String?,
        backend: DonkeyBackendInferenceClient,
        maxTurns: Int = 12,
        settleNanoseconds: UInt64 = 1_200_000_000,
        capture: @escaping ScreenshotCapture = { try await ScreenCaptureKitWindowScreenshotCapturer().capture(target: $0) },
        onTurn: (@MainActor (TurnInfo) -> Void)? = nil
    ) async -> Outcome {
        var history: [String] = []
        var lastNarration: String?
        var turnsTaken = 0

        // Resolve the target window once and reuse it; only re-resolve when a capture fails (the
        // window moving/closing is the only thing that invalidates the cached bounds).
        guard var target = AccessibilityObserver.resolveTarget(appName: appName, bundleIdentifier: bundleIdentifier) else {
            return Outcome(completed: false, turns: 0, reason: "noWindowForApp", lastNarration: nil, history: history)
        }
        activate(target)

        for _ in 0..<maxTurns {
            // Ensure the target is frontmost before we screenshot + act; re-activate only if needed.
            if !isFrontmost(target) {
                activate(target)
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
                action = try await VisionActionPlanner.nextAction(
                    goal: goal,
                    app: appName,
                    screenshot: shot,
                    window: target.bounds,
                    history: history,
                    appGuidance: appGuidance,
                    backend: backend
                )
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
                return finish(true, turnsTaken, "ok", lastNarration, history)
            case "click":
                if let point = action.screenPoint {
                    _ = MacPointerInput.moveAndClick(at: point)
                    history.append("clicked at (\(Int(point.x)),\(Int(point.y))): \(action.reason ?? "")")
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

    private static func activate(_ target: MacWindowTargetCandidate) {
        let app = NSRunningApplication(processIdentifier: pid_t(target.processID))
        _ = app?.activate()
    }
}
