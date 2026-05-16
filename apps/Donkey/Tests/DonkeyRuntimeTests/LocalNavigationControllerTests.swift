import DonkeyContracts
@testable import DonkeyRuntime
import Foundation
import Testing

@Suite
struct LocalNavigationControllerTests {
    @Test
    func metadataProjectorBuildsTypedLocalNavigationWorldState() {
        let projector = LocalNavigationMetadataProjector()

        let state = projector.project(
            snapshot: MacWindowCandidateListSnapshot(candidates: [
                window(
                    id: 100,
                    appName: "Code",
                    bundleIdentifier: "com.microsoft.VSCode",
                    title: "Donkey",
                    isFrontmost: false,
                    isFocused: false
                ),
                window(
                    id: 200,
                    appName: "Safari",
                    bundleIdentifier: "com.apple.Safari",
                    title: "Docs",
                    isFrontmost: true,
                    isFocused: true
                )
            ]),
            traceID: "trace-nav",
            targetID: "local-navigation",
            observedAt: timestamp(20),
            sourceCapturedAt: timestamp(10),
            requestedBundleIdentifier: "com.microsoft.VSCode"
        )

        #expect(state.candidates.map(\.id) == ["window-100", "window-200"])
        #expect(state.focusedCandidateID == "window-200")
        #expect(state.frontmostCandidateID == "window-200")
        #expect(state.requestedBundleIdentifier == "com.microsoft.VSCode")
        #expect(state.hotLoopWorldState().actionAffordances.count == 2)
        #expect(state.hotLoopWorldState().metadata["localNavigation.candidateCount"] == "2")
    }

    @Test
    func controllerSelectsRequestedWindowFocusAction() {
        let state = navigationState(
            requestedBundleIdentifier: "com.microsoft.VSCode",
            windows: [
                window(
                    id: 100,
                    appName: "Code",
                    bundleIdentifier: "com.microsoft.VSCode",
                    title: "Donkey",
                    isFrontmost: false,
                    isFocused: false
                ),
                window(
                    id: 200,
                    appName: "Safari",
                    bundleIdentifier: "com.apple.Safari",
                    title: "Docs",
                    isFrontmost: true,
                    isFocused: true
                )
            ]
        )

        let action = LocalNavigationControllerPolicy().decide(state: state)

        #expect(action.kind == .focusWindow)
        #expect(action.metadata["candidateID"] == "window-100")
        #expect(action.metadata["bundleIdentifier"] == "com.microsoft.VSCode")
        #expect(action.metadata["fallback"] == "false")
    }

    @Test
    func controllerFallsBackWhenRequestedTargetIsAlreadyFocusedOrMissing() {
        let alreadyFocused = navigationState(
            requestedBundleIdentifier: "com.apple.Safari",
            windows: [
                window(
                    id: 200,
                    appName: "Safari",
                    bundleIdentifier: "com.apple.Safari",
                    title: "Docs",
                    isFrontmost: true,
                    isFocused: true
                )
            ]
        )
        let wait = LocalNavigationControllerPolicy().decide(state: alreadyFocused)
        #expect(wait.kind == .wait)
        #expect(wait.metadata["fallbackReason"] == "alreadyFocused")

        let missing = navigationState(
            requestedBundleIdentifier: "com.apple.Terminal",
            windows: [
                window(
                    id: 200,
                    appName: "Safari",
                    bundleIdentifier: "com.apple.Safari",
                    title: "Docs",
                    isFrontmost: true,
                    isFocused: true
                )
            ]
        )
        let observe = LocalNavigationControllerPolicy().decide(state: missing)
        #expect(observe.kind == .observe)
        #expect(observe.metadata["fallbackReason"] == "targetNotFound")
    }

    @Test
    func blockedWindowsAreNotSelectedForNavigation() {
        let state = navigationState(
            requestedBundleIdentifier: "com.apple.systempreferences",
            windows: [
                window(
                    id: 300,
                    appName: "System Settings",
                    bundleIdentifier: "com.apple.systempreferences",
                    title: "Passwords",
                    isFrontmost: false,
                    isFocused: false,
                    safetyStatus: .blocked
                )
            ]
        )

        let action = LocalNavigationControllerPolicy().decide(state: state)

        #expect(action.kind == .observe)
        #expect(action.metadata["fallbackReason"] == "targetNotFound")
    }

    private func navigationState(
        requestedBundleIdentifier: String?,
        windows: [MacWindowTargetCandidate]
    ) -> LocalNavigationWorldState {
        LocalNavigationMetadataProjector().project(
            snapshot: MacWindowCandidateListSnapshot(candidates: windows),
            traceID: "trace-nav",
            targetID: "local-navigation",
            observedAt: timestamp(20),
            sourceCapturedAt: timestamp(10),
            requestedBundleIdentifier: requestedBundleIdentifier
        )
    }

    private func window(
        id: UInt32,
        appName: String,
        bundleIdentifier: String,
        title: String,
        isFrontmost: Bool,
        isFocused: Bool,
        safetyStatus: WindowTargetSafetyStatus = .allowed
    ) -> MacWindowTargetCandidate {
        MacWindowTargetCandidate(
            windowID: id,
            processID: Int32(id),
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            title: title,
            bounds: WindowTargetBounds(x: 10, y: 20, width: 300, height: 200),
            isVisible: true,
            isOnScreen: true,
            isFrontmost: isFrontmost,
            isFocused: isFocused,
            isIPhoneMirroring: false,
            safetyAssessment: WindowTargetSafetyAssessment(
                status: safetyStatus,
                reasons: safetyStatus == .blocked ? [.passwordSurface] : [],
                summary: safetyStatus.rawValue
            )
        )
    }

    private func timestamp(_ milliseconds: UInt64) -> RunTraceTimestamp {
        RunTraceTimestamp(
            wallClock: Date(timeIntervalSince1970: Double(milliseconds) / 1_000),
            monotonicUptimeNanoseconds: milliseconds * 1_000_000
        )
    }
}
