import DonkeyAI
import DonkeyContracts
import DonkeyHarness
import Foundation
import Testing

@Suite
struct HarnessStepPromptTests {
    private func task(goal: String) -> HarnessTaskState {
        HarnessTaskState(id: "t", threadID: "th", goal: goal, status: .running, worldModel: HarnessWorldModel())
    }

    /// The installed-skill catalog must reach the planner prompt verbatim, with routing instructions —
    /// this is what lets the planner route "save a note"/"play music" to a skill's documented tools
    /// instead of improvising osascript when no GUI app is the drive target (the loop the user hit).
    @Test
    func includesSkillCatalogAndRoutingInstruction() {
        let catalog = "  - notes — Capture notes by script · apps: Notes · skill_run: scripts-save-note (Save Note)"
        let prompt = DonkeyPrompts.harnessStep(
            task: task(goal: "note this down"),
            descriptors: [],
            appName: "iTerm2",
            appGuidance: nil,
            understanding: nil,
            environmentSummary: nil,
            skillCatalog: catalog
        )
        #expect(prompt.contains("authoritative playbooks for these apps/domains"))
        #expect(prompt.contains("scripts-save-note"))
        #expect(prompt.contains("skill_run"))
    }

    /// With no catalog the block is omitted entirely (no empty header dangling in the prompt).
    @Test
    func omitsSkillCatalogWhenNil() {
        let prompt = DonkeyPrompts.harnessStep(
            task: task(goal: "what time is it"),
            descriptors: [],
            appName: "iTerm2",
            appGuidance: nil,
            understanding: nil,
            environmentSummary: nil,
            skillCatalog: nil
        )
        #expect(!prompt.contains("authoritative playbooks for these apps/domains"))
    }

    private func window(app: String, title: String, frontmost: Bool) -> MacWindowTargetCandidate {
        MacWindowTargetCandidate(
            windowID: 1, processID: 2, appName: app, bundleIdentifier: "com.example.\(app)",
            title: title, bounds: WindowTargetBounds(x: 0, y: 0, width: 1440, height: 900),
            isVisible: true, isOnScreen: true, isFrontmost: frontmost, isFocused: frontmost,
            isIPhoneMirroring: false,
            safetyAssessment: WindowTargetSafetyAssessment(status: .allowed, summary: "")
        )
    }

    /// The other windows on screen must reach the prompt so a request that lives in a window the user
    /// isn't looking at exists in the world before the planner can navigate to it.
    @Test
    func includesOpenWindowsBlock() {
        let prompt = DonkeyPrompts.harnessStep(
            task: task(goal: "open my github tab"),
            descriptors: [],
            appName: "Notes",
            appGuidance: nil,
            understanding: nil,
            environmentSummary: nil,
            openWindows: [window(app: "Safari", title: "GitHub", frontmost: true)]
        )
        #expect(prompt.contains("OPEN WINDOWS"))
        #expect(prompt.contains("Safari"))
        #expect(prompt.contains("\"GitHub\""))
        #expect(prompt.contains("[frontmost]"))
    }

    /// With no other windows the block is omitted (no dangling header).
    @Test
    func omitsOpenWindowsWhenNone() {
        let prompt = DonkeyPrompts.harnessStep(
            task: task(goal: "what time is it"),
            descriptors: [],
            appName: "iTerm2",
            appGuidance: nil,
            understanding: nil,
            environmentSummary: nil,
            openWindows: []
        )
        #expect(!prompt.contains("OPEN WINDOWS"))
    }
}
