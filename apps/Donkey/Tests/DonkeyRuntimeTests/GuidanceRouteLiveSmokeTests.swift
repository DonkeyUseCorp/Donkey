import AppKit
@testable import Donkey
import DonkeyContracts
import DonkeyUI
import Foundation
import Testing

/// Live, env-gated end-to-end test for the guidance route (plan phase 2): a natural-language
/// "show me where X is" goes through the real handler → hosted planner classifies `guidance` →
/// GuidanceOverlayFlow grounds the control → a cursor overlay is produced and presented.
///
///     env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer DONKEY_LIVE_SMOKE=1 \
///       DONKEY_WEB_BASE_URL=http://localhost:3000 DONKEY_DEV_AUTH_BYPASS=1 \
///       swift test --filter GuidanceRouteLiveSmokeTests
@Suite
struct GuidanceRouteLiveSmokeTests {
    @Test
    @MainActor
    func showMeWhereRoutesToGuidanceAndOverlays() async {
        let env = ProcessInfo.processInfo.environment
        guard env["DONKEY_LIVE_SMOKE"] == "1" else { return }
        if env["DONKEY_WEB_BASE_URL"]?.isEmpty != false {
            Issue.record("DONKEY_WEB_BASE_URL not set")
            return
        }

        let appName = env["DONKEY_GUIDE_APP"] ?? "Music"
        NSWorkspace.shared.launchApplication(appName)
        try? await Task.sleep(nanoseconds: 800_000_000)

        let handler = LocalAppUserQueryCommandHandler()
        let result = await handler.handleSubmittedCommand("show me where the search field is in \(appName)")

        // The planner should have classified this as the guidance route.
        #expect(result.metadata["router"] == "modelGuidance")
        if result.cursorOverlayRequest == nil {
            Issue.record("Guidance produced no overlay: reason=\(result.metadata["guidance.reason"] ?? "?") app=\(result.metadata["guidance.resolvedApp"] ?? "?") targets=\(result.metadata["guidance.targetCount"] ?? "?")")
            return
        }

        let request = result.cursorOverlayRequest!
        #expect(!request.steps.isEmpty)

        if NSApplication.shared.activationPolicy() == .prohibited {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
        let overlay = PointerCoachCursorOverlayController()
        overlay.show(request: request)
        let duration = request.steps.reduce(1.5) { $0 + $1.travelDuration + $1.holdDuration }
        Self.pump(forSeconds: duration)
    }

    @MainActor
    private static func pump(forSeconds seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
