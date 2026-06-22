import AppKit
@preconcurrency import ApplicationServices
@testable import DonkeyRuntime
import DonkeyContracts
import Foundation
import Testing

/// Live smoke for handle-anchored resolution and the expanded semantic AX vocabulary. It observes a
/// real app, then drives the real Accessibility action backend, so it requires the test runner to hold
/// Accessibility trust (System Settings ▸ Privacy & Security ▸ Accessibility — add the binary that runs
/// `swift test`). Without trust it records a clear, actionable issue and returns.
///
///     env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       DONKEY_LIVE_SMOKE=1 [DONKEY_GUIDE_APP=Finder] \
///       swift test --filter AXSemanticActionLiveSmokeTests
///
/// What it pins:
///  - Change 1: observe populates the live-handle cache for the process.
///  - Change 2 gating: an action a control does not advertise is refused (`accessibilityActionNotAdvertised`).
///  - Stale signal: an unknown node neither in cache nor resolvable returns `accessibilityNodeStale`.
///  - Risk items: AXShowMenu opens a context menu that a follow-up observe can see; AXOpen lands —
///    each exercised only when a real control advertises it (otherwise logged as not-present).
@Suite
struct AXSemanticActionLiveSmokeTests {
    @Test
    @MainActor
    func anchorsHandlesAndRoutesSemanticActions() async {
        guard ProcessInfo.processInfo.environment["DONKEY_LIVE_SMOKE"] == "1" else { return }
        guard AXIsProcessTrusted() else {
            Issue.record("Accessibility is not granted to the test runner. Grant it in System Settings ▸ Privacy & Security ▸ Accessibility and re-run.")
            return
        }

        let appName = ProcessInfo.processInfo.environment["DONKEY_GUIDE_APP"] ?? "Finder"
        NSWorkspace.shared.launchApplication(appName)
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        guard let observation = AccessibilityObserver.observe(appName: appName, bundleIdentifier: nil) else {
            Issue.record("Could not observe \(appName); ensure it is running and frontmost.")
            return
        }
        let pid = observation.target.processID
        guard let bundle = observation.target.bundleIdentifier else {
            Issue.record("No bundle identifier for \(appName)."); return
        }
        let controls = observation.controls
        print("[smoke] observed \(controls.count) control(s) in \(appName) (pid \(pid))")

        // Change 1 — the observe retained live handles in the cache, keyed by node id.
        let anchored = controls.first { MacAccessibilityElementHandleCache.shared.handle(processID: pid, nodeID: $0.id) != nil }
        #expect(anchored != nil)
        print("[smoke] cache anchored node: \(anchored?.id ?? "none")")

        // Stale signal — a node that was never observed has no handle and no positional resolution.
        let stale = await dispatch(nodeID: "ax-1.99999.99999", action: "AXPress", bundle: bundle)
        #expect(stale.reason == "accessibilityNodeStale")

        // Change 2 gating — ask a press-only control to AXOpen; the live re-check must refuse it.
        if let pressOnly = controls.first(where: { $0.actions.contains("AXPress") && !$0.actions.contains("AXOpen") }) {
            let refused = await dispatch(nodeID: pressOnly.id, action: "AXOpen", bundle: bundle)
            #expect(refused.executed == false)
            #expect(refused.reason == "accessibilityActionNotAdvertised")
            print("[smoke] gating refused AXOpen on \(pressOnly.label): \(refused.reason)")
        } else {
            print("[smoke] no press-only control found to exercise gating")
        }

        // Risk item — right-click → AXShowMenu opens a context menu a follow-up observe can see.
        if let menuControl = controls.first(where: { $0.actions.contains("AXShowMenu") }) {
            let outcome = await dispatch(nodeID: menuControl.id, action: "AXShowMenu", bundle: bundle)
            print("[smoke] AXShowMenu on \(menuControl.label): executed=\(outcome.executed) reason=\(outcome.reason)")
            if outcome.executed {
                try? await Task.sleep(nanoseconds: 600_000_000)
                let after = AccessibilityObserver.observe(appName: appName, bundleIdentifier: nil)
                let menuItems = after?.controls.filter { ($0.role ?? "").contains("Menu") } ?? []
                print("[smoke] post-AXShowMenu: \(after?.controls.count ?? -1) controls, \(menuItems.count) menu-role")
                MacKeyboardInput.pressKey("escape", modifiers: [])
            }
        } else {
            print("[smoke] no control advertised AXShowMenu")
        }

        // Risk item — double-click → AXOpen on an openable item.
        if let openable = controls.first(where: { $0.actions.contains("AXOpen") }) {
            let outcome = await dispatch(nodeID: openable.id, action: "AXOpen", bundle: bundle)
            print("[smoke] AXOpen on \(openable.label): executed=\(outcome.executed) reason=\(outcome.reason)")
        } else {
            print("[smoke] no control advertised AXOpen")
        }
    }

    private func dispatch(nodeID: String, action: String, bundle: String) async -> (executed: Bool, reason: String) {
        let command = ActionEngineCommand(
            id: UUID().uuidString,
            traceID: "ax-semantic-smoke",
            targetID: nodeID,
            kind: .tap,
            issuedAt: RunTraceTimestamp(
                wallClock: Date(),
                monotonicUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            ),
            metadata: [
                "accessibility.nodeID": nodeID,
                "accessibility.action": action,
                "bundleIdentifier": bundle,
                "controlID": nodeID
            ]
        )
        let result = await MacAccessibilityActionEngineInputBackend().execute(command)
        return (result.executed, result.metadata["accessibility.result"] ?? "")
    }
}
