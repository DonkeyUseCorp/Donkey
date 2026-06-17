import AppKit
import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation

/// Box-based sibling of `VertexVisionDriver`. Each turn it screenshots the app
/// window, asks `GeminiVertexVisionBoxPlanner` for the next action with the target
/// as a 2D bounding box, and — for a click — tries the box center first and then a
/// few nearby points, stopping as soon as the screen changes (or `verify()`
/// passes). This makes a single turn robust to a slightly-loose box instead of
/// waiting a whole model round-trip to recover from one missed point.
///
/// Selected by `GEMINI_VISION_BOX=1` in `GeminiLiveVoiceController.launchVision`;
/// the single-point `VertexVisionDriver` remains the default. Same constraint
/// applies: must NOT run inside the Live session's `for await session.events`
/// consumer task (ScreenCaptureKit `capture` hangs there).
@MainActor
enum VertexVisionBoxDriver {
    /// Self-contained outcome (the box variant does not depend on the single-point
    /// driver, so it survives that driver's refactors).
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
        attemptSettleNanoseconds: UInt64 = 300_000_000,
        maxTurns: Int = 16,
        capturer: ScreenCaptureKitWindowScreenshotCapturer = ScreenCaptureKitWindowScreenshotCapturer(),
        verify: (@MainActor () -> Bool)? = nil,
        onTurn: (@MainActor (Int, CapturedWindowScreenshot, GeminiVertexVisionBoxPlanner.VisionBoxAction) -> Void)? = nil
    ) async -> Outcome {
        guard var target = AccessibilityObserver.resolveTarget(appName: appName, bundleIdentifier: bundleIdentifier) else {
            return Outcome(completed: false, turns: 0, history: ["no \(appName) window"])
        }
        // Per-app operating knowledge comes from a discoverable skill pack, same
        // source the single-point driver and backend vision path use.
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

            let action: GeminiVertexVisionBoxPlanner.VisionBoxAction
            do {
                action = try await GeminiVertexVisionBoxPlanner.nextBoxAction(
                    auth: auth, model: model, goal: goal, appName: appName,
                    history: history, appGuidance: appGuidance, compressed: compressed, window: target.bounds
                )
            } catch {
                history.append("vision plan failed: \(error)"); break
            }
            turns += 1
            onTurn?(turns, shot, action)
            let reason = action.reason ?? ""

            if action.action == "done" {
                if let verify {
                    if verify() { completed = true; break }
                    history.append("claimed done but verify() false — your last action missed; return a tighter box")
                    try? await Task.sleep(nanoseconds: settleNanoseconds)
                    continue
                }
                completed = true
                history.append("done: \(reason)")
                break
            }

            switch action.action {
            case "click":
                guard let points = action.screenPoints, !points.isEmpty else {
                    history.append("click without box: \(reason)")
                    break
                }
                let centerKey = "\(Int(points[0].x)),\(Int(points[0].y))"
                repeatCount = (centerKey == lastClickKey) ? repeatCount + 1 : 0
                lastClickKey = centerKey
                if repeatCount >= 4 {
                    history.append("aborting: stuck repeating box center \(centerKey)")
                    break turnLoop
                }

                var landedIndex: Int?
                for (index, point) in points.enumerated() {
                    _ = MacPointerInput.moveAndClick(at: point)
                    if verify?() == true { landedIndex = index; completed = true; break }
                    try? await Task.sleep(nanoseconds: attemptSettleNanoseconds)
                    if let after = try? await capturer.capture(target: target),
                       ScreenshotChange.changed(shot.pngData, after.pngData) {
                        landedIndex = index
                        break
                    }
                }
                if let landedIndex {
                    let landed = points[landedIndex]
                    history.append("clicked box point \(landedIndex) (\(Int(landed.x)),\(Int(landed.y))) of \(points.count)\(repeatCount >= 2 ? " AGAIN" : "") — screen changed: \(reason)")
                } else {
                    history.append("clicked \(points.count) box points, no visible change — pick a different/tighter target: \(reason)")
                }
                if completed { break turnLoop }
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
    /// hit the minimize button, breaking every later screenshot). Kept local so the
    /// box variant stays independent of the single-point driver.
    private static func ensureAppFrontAndRestored(appName: String, processID: pid_t) {
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
        // Never prompt mid-task for this internal nicety; skip it if Automation isn't already granted.
        SystemPermissionCoordinator.runSystemEventsScriptIfGranted(source)
    }
}
