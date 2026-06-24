import DonkeyAI
import DonkeyContracts
import Foundation
import Testing
@testable import Donkey

@Suite
@MainActor
struct ResolveDriveTargetTests {
    @Test
    func runningUnderstoodTargetWinsWithItsResolvedIdentity() {
        let target = LocalAppUserQueryCommandHandler.resolveDriveTarget(
            understanding: HarnessRequestUnderstanding(restatedGoal: "Play music", targetAppName: "Music"),
            frontmost: ("iTerm2", "com.googlecode.iterm2"),
            resolveRunningWindow: { _ in (appName: "Music", bundleIdentifier: "com.apple.Music") },
            resolveInstalledBundle: { _ in nil }
        )

        #expect(target?.appName == "Music")
        #expect(target?.bundleIdentifier == "com.apple.Music")
    }

    @Test
    func installedButNotRunningTargetStaysPinnedByName() {
        // The exact failure of the "play some blackpink" runs: Music named by the understanding but
        // not running at submit, so the run pinned to iTerm2 and every observe/click/focus-recovery
        // aimed at the wrong app. An installed target must stay pinned even with no window yet.
        let target = LocalAppUserQueryCommandHandler.resolveDriveTarget(
            understanding: HarnessRequestUnderstanding(restatedGoal: "Play music", targetAppName: "Music"),
            frontmost: ("iTerm2", "com.googlecode.iterm2"),
            resolveRunningWindow: { _ in nil },
            resolveInstalledBundle: { _ in URL(fileURLWithPath: "/System/Applications/Music.app") }
        )

        #expect(target?.appName == "Music")
        #expect(target?.bundleIdentifier == "com.apple.Music")
    }

    @Test
    func unknownTargetFallsBackToFrontmost() {
        // A name that matches nothing running and nothing installed (hallucinated/misheard app)
        // must not pin the run to a window that can never resolve.
        let target = LocalAppUserQueryCommandHandler.resolveDriveTarget(
            understanding: HarnessRequestUnderstanding(restatedGoal: "Do a thing", targetAppName: "Nonexistent App"),
            frontmost: ("iTerm2", "com.googlecode.iterm2"),
            resolveRunningWindow: { _ in nil },
            resolveInstalledBundle: { _ in nil }
        )

        #expect(target?.appName == "iTerm2")
        #expect(target?.bundleIdentifier == "com.googlecode.iterm2")
    }

    @Test
    func noNamedTargetKeepsFrontmost() {
        let target = LocalAppUserQueryCommandHandler.resolveDriveTarget(
            understanding: HarnessRequestUnderstanding(restatedGoal: "Check battery", targetAppName: nil),
            frontmost: ("iTerm2", "com.googlecode.iterm2"),
            resolveRunningWindow: { _ in nil },
            resolveInstalledBundle: { _ in nil }
        )

        #expect(target?.appName == "iTerm2")
        #expect(target?.bundleIdentifier == "com.googlecode.iterm2")
    }

    @Test
    func targetMatchingFrontmostKeepsFrontmostIdentity() {
        let target = LocalAppUserQueryCommandHandler.resolveDriveTarget(
            understanding: HarnessRequestUnderstanding(restatedGoal: "Type here", targetAppName: "iterm2"),
            frontmost: ("iTerm2", "com.googlecode.iterm2"),
            resolveRunningWindow: { _ in nil },
            resolveInstalledBundle: { _ in nil }
        )

        #expect(target?.appName == "iTerm2")
        #expect(target?.bundleIdentifier == "com.googlecode.iterm2")
    }

    @Test
    func applessSurfaceDrivesNoAppEvenWithFrontmost() {
        // The "show the fifa standings in a nice image" failure: an artifact task is produced with
        // generative/web tools, not by driving an app. It must NOT pin whatever happens to be in front —
        // the typed `.appless` surface resolves to no drive target regardless of the frontmost app.
        let target = LocalAppUserQueryCommandHandler.resolveDriveTarget(
            understanding: HarnessRequestUnderstanding(
                restatedGoal: "Generate an image of the current FIFA standings",
                actionSurface: .appless
            ),
            frontmost: ("Finder", "com.apple.finder"),
            resolveRunningWindow: { _ in nil },
            resolveInstalledBundle: { _ in nil }
        )

        #expect(target == nil)
    }

    @Test
    func noNamedTargetAndNoFrontmostRunsAppless() {
        // A GUI-ish turn typed into the notch with nothing in front (frontmost == nil) has nothing to
        // drive. It resolves to nil — an app-less run — instead of the old hard `noFrontmostApp` abort.
        let target = LocalAppUserQueryCommandHandler.resolveDriveTarget(
            understanding: HarnessRequestUnderstanding(restatedGoal: "Make a chart of this", targetAppName: nil),
            frontmost: nil,
            resolveRunningWindow: { _ in nil },
            resolveInstalledBundle: { _ in nil }
        )

        #expect(target == nil)
    }
}
