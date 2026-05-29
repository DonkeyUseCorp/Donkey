import AppKit
@testable import Donkey
import DonkeyContracts
import DonkeyRuntime
import DonkeyUI
import Foundation
import Testing

/// Live, env-gated smoke test for the guidance overlay (plan phase 2): capture a running app's
/// accessibility tree, ground a named control, and animate the pointer to it — visualization only,
/// no input. Works on any app with an accessibility tree (native or Electron).
///
///     env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer DONKEY_LIVE_SMOKE=1 \
///       [DONKEY_GUIDE_APP=Spotify] [DONKEY_GUIDE_TARGET=Search] \
///       swift test --filter GuidanceOverlayLiveSmokeTests
@Suite
struct GuidanceOverlayLiveSmokeTests {
    @Test
    @MainActor
    func showsPointerAtAControlInARunningApp() {
        let env = ProcessInfo.processInfo.environment
        guard env["DONKEY_LIVE_SMOKE"] == "1" else { return }

        let appName = env["DONKEY_GUIDE_APP"] ?? "Music"
        let targetText = env["DONKEY_GUIDE_TARGET"] ?? "Search"

        // Bring the app to the front so the overlay is visible over it.
        NSWorkspace.shared.launchApplication(appName)
        pump(0.8)

        let outcome = GuidanceOverlayFlow.cursorGuide(
            appName: appName,
            bundleIdentifier: nil,
            targets: [
                AccessibilityCursorPathTarget(query: targetText, label: "Here: \(targetText)", kind: .targetControl)
            ],
            title: "Where is \(targetText)",
            traceID: "guidance-smoke"
        )

        guard let request = outcome.request else {
            Issue.record("No grounded overlay (reason=\(outcome.reason), app=\(outcome.resolvedAppName ?? "nil")). Grant Accessibility + ensure \(appName) is running with a '\(targetText)' control.")
            return
        }

        #expect(!request.steps.isEmpty)

        if NSApplication.shared.activationPolicy() == .prohibited {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
        let overlay = PointerCoachCursorOverlayController()
        overlay.show(request: request)
        let duration = request.steps.reduce(1.5) { $0 + $1.travelDuration + $1.holdDuration }
        pump(duration)
    }

    @MainActor
    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
