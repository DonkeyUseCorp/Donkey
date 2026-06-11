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
    /// this is what lets the planner run a validated `skill_run` script for "play music"/"save a note"
    /// instead of improvising osascript when no GUI app is the drive target (the loop the user hit).
    @Test
    func includesSkillCatalogAndRoutingInstruction() {
        let catalog = "  - music — Play music locally in Apple Music · apps: Music · skill_run: scripts-play-media-by-search (Play Media By Search)"
        let prompt = DonkeyPrompts.harnessStep(
            task: task(goal: "play some coldplay"),
            descriptors: [],
            appName: "iTerm2",
            appGuidance: nil,
            understanding: nil,
            environmentSummary: nil,
            skillCatalog: catalog
        )
        #expect(prompt.contains("authoritative playbooks for these apps/domains"))
        #expect(prompt.contains("scripts-play-media-by-search"))
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
