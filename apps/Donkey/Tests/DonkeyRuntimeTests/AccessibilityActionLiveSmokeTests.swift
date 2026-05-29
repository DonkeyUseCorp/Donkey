import AppKit
@testable import Donkey
import DonkeyContracts
import DonkeyRuntime
import DonkeyUI
import Foundation
import Testing

/// Live, doubly-gated smoke test for the real-pointer accessibility action (plan phase 4). It
/// ACTUALLY moves the mouse and clicks a control, so it requires an explicit second flag in
/// addition to DONKEY_LIVE_SMOKE. Defaults to clicking the benign "Search" control.
///
///     env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       DONKEY_LIVE_SMOKE=1 DONKEY_LIVE_INPUT=1 \
///       [DONKEY_GUIDE_APP=Spotify] [DONKEY_GUIDE_TARGET=Search] \
///       swift test --filter AccessibilityActionLiveSmokeTests
@Suite
struct AccessibilityActionLiveSmokeTests {
    @Test
    @MainActor
    func clicksAGroundedControlWithTheRealPointer() {
        let env = ProcessInfo.processInfo.environment
        guard env["DONKEY_LIVE_SMOKE"] == "1", env["DONKEY_LIVE_INPUT"] == "1" else { return }

        let appName = env["DONKEY_GUIDE_APP"] ?? "Music"
        let targetText = env["DONKEY_GUIDE_TARGET"] ?? "Search"

        NSWorkspace.shared.launchApplication(appName)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))

        let outcome = AccessibilityActionExecutor.clickControl(
            appName: appName,
            bundleIdentifier: nil,
            targetQuery: targetText,
            liveInputEnabled: true
        )

        if !outcome.clicked {
            Issue.record("Did not click (reason=\(outcome.reason), app=\(outcome.resolvedAppName ?? "nil"), control=\(outcome.controlID ?? "nil"), point=\(outcome.screenPoint.map { "\($0.x),\($0.y)" } ?? "nil")). Grant Accessibility, ensure \(appName) is frontmost with a '\(targetText)' control.")
            return
        }
        #expect(outcome.clicked)
        #expect(outcome.screenPoint != nil)
    }
}
