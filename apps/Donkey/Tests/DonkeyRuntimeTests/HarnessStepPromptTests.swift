import DonkeyAI
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
}
