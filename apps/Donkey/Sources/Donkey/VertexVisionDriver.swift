import AppKit
import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation

/// Drives an app by vision: each turn it screenshots the app window, asks the
/// turn-based Vertex vision model (`GeminiVertexVisionPlanner`, default
/// `gemini-3.5-flash`) for the single next click/type/key, and executes it with the
/// app's real pointer/keyboard. This is the "look at the screen, decide, act"
/// fallback the Live command session escalates to (via `vision_control`) when no
/// fast tool can operate an app.
///
/// IMPORTANT: must NOT be driven from inside the Live session's `for await
/// session.events` consumer task — ScreenCaptureKit `capture` hangs there. Run it
/// from a separate task (see `GeminiLiveVoiceController`).
@MainActor
enum VertexVisionDriver {
    struct Outcome: Sendable {
        var completed: Bool
        var turns: Int
        var history: [String]
    }

    static func drive(
        appName: String,
        bundleIdentifier: String?,
        goal: String,
        auth: GeminiVertexVisionPlanner.VertexAuth,
        model: String,
        settleNanoseconds: UInt64 = 1_500_000_000,
        maxTurns: Int = 16,
        capturer: ScreenCaptureKitWindowScreenshotCapturer = ScreenCaptureKitWindowScreenshotCapturer(),
        verify: (@MainActor () -> Bool)? = nil
    ) async -> Outcome {
        guard var target = AccessibilityObserver.resolveTarget(appName: appName, bundleIdentifier: bundleIdentifier) else {
            return Outcome(completed: false, turns: 0, history: ["no \(appName) window"])
        }
        // Per-app operating knowledge comes from a discoverable skill pack (a
        // BuiltInSkills/<app>/SKILL.md with an `apps:` line), never a hardcoded app
        // list — same source the backend vision path uses.
        let appGuidance = BuiltInLocalAppSkillPacks.appOperatingGuidance(
            forApp: appName, bundleIdentifier: bundleIdentifier
        )
        var history: [String] = []
        var turns = 0
        var completed = false
        var lastClickKey = ""
        var repeatCount = 0

        turnLoop: for _ in 0..<maxTurns {
            if verify?() == true { completed = true; break }
            ensureAppFrontAndRestored(appName: appName, processID: target.processID)
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let refreshed = AccessibilityObserver.resolveTarget(appName: appName, bundleIdentifier: bundleIdentifier) {
                target = refreshed
            }
            guard let shot = try? await capturer.capture(target: target) else {
                history.append("screenshot failed"); break
            }
            let compressed = ScreenshotCompression.compressedForModel(shot)

            let action: VisionActionPlanner.PlannedAction
            do {
                action = try await GeminiVertexVisionPlanner.nextAction(
                    auth: auth, model: model, goal: goal, appName: appName,
                    history: history, appGuidance: appGuidance, compressed: compressed, window: target.bounds
                )
            } catch {
                history.append("vision plan failed: \(error)"); break
            }
            turns += 1
            let reason = action.reason ?? ""

            if action.action == "done" {
                // Verify-don't-trust when a verifier is provided; otherwise trust the
                // model's claim (the general case, no app-specific success signal).
                if let verify {
                    if verify() { completed = true; break }
                    history.append("claimed done but verify() false — your last action missed; click the exact target")
                    try? await Task.sleep(nanoseconds: settleNanoseconds)
                    continue
                }
                completed = true
                history.append("done: \(reason)")
                break
            }

            switch action.action {
            case "click":
                if let point = action.screenPoint {
                    let key = "\(Int(point.x)),\(Int(point.y))"
                    repeatCount = (key == lastClickKey) ? repeatCount + 1 : 0
                    lastClickKey = key
                    if repeatCount >= 4 { history.append("aborting: stuck repeating click \(key)"); break turnLoop }
                    _ = MacPointerInput.moveAndClick(at: point)
                    history.append(repeatCount >= 2
                        ? "clicked (\(key)) AGAIN — not working; pick a DIFFERENT target/exact center: \(reason)"
                        : "clicked (\(key)): \(reason)")
                } else {
                    history.append("click without point: \(reason)")
                }
            case "type":
                MacKeyboardInput.type(action.text ?? "")
                history.append("typed \"\(action.text ?? "")\"")
            case "key":
                MacKeyboardInput.pressKey(action.text ?? "return")
                history.append("key \(action.text ?? "return")")
            default:
                history.append("ignored action \(action.action)")
            }
            try? await Task.sleep(nanoseconds: settleNanoseconds)
        }

        if let verify, !completed { completed = verify() }
        return Outcome(completed: completed, turns: turns, history: history)
    }

    /// Bring an app frontmost and un-minimize its windows (a stray vision click can
    /// hit the minimize button, breaking every later screenshot).
    static func ensureAppFrontAndRestored(appName: String, processID: pid_t) {
        NSRunningApplication(processIdentifier: processID)?.activate()
        let source = """
        tell application "System Events"
            if exists process "\(appName)" then
                tell process "\(appName)"
                    set frontmost to true
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
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }
}
