import DonkeyContracts
import DonkeyHarness
import DonkeyRuntime
import Foundation
import Testing

@Suite
struct AppSkillCommandTests {
    @MainActor
    private func lookup(_ app: String) async -> HarnessToolResult? {
        let descriptor = DonkeyCommandLayer.descriptors.first { $0.name == "app_skill" }!
        let context = HarnessToolExecutionContext(
            taskID: "test",
            call: HarnessToolCall(name: "app_skill", input: ["app": app]),
            descriptor: descriptor,
            worldModel: HarnessWorldModel(),
            grantedPermissions: [.skillLookup]
        )
        return await DonkeyCommandBackends.makeExecutor()(context)
    }

    @Test
    @MainActor
    func discoversAppOperatingPlaybooksFromSkillPacks() async {
        // App knowledge comes from the discoverable skill packs, never a
        // hardcoded list: the bundled Spotify pack matches by display name and
        // by bundle id, and its playbook says the app is driven by vision.
        for key in ["Spotify", "com.spotify.client"] {
            let result = await lookup(key)
            #expect(result?.status == .succeeded)
            #expect(result?.metadata["found"] == "true")
            #expect(result?.summary.lowercased().contains("vision") == true)
        }
    }

    @Test
    @MainActor
    func discoversCorePlaybooksForHighTrafficApps() async {
        // The built-in catalog covers the apps people actually drive daily, each
        // matched by display name and bundle id from its `apps:` frontmatter.
        let coverage: [(key: String, marker: String)] = [
            ("Mail", "outgoing message"),
            ("com.apple.mail", "mail attachment"),
            ("Finder", "trash"),
            ("Safari", "current tab"),
            ("com.apple.Safari", "current tab"),
            ("Calendar", "make new event"),
            ("Messages", "iMessage"),
            ("System Settings", "defaults write"),
            ("Notes", "make new note"),
            ("com.apple.Notes", "make new note"),
            ("Reminders", "make new reminder"),
            ("Preview", "kMDItemTextContent"),
            ("Contacts", "formatted address"),
            ("Numbers", "export front document"),
            ("com.apple.iWork.Numbers", "export front document")
        ]
        for (key, marker) in coverage {
            let result = await lookup(key)
            #expect(result?.metadata["found"] == "true", "no skill found for \(key)")
            #expect(result?.summary.contains(marker) == true, "playbook for \(key) is missing \(marker)")
        }
    }

    @Test
    @MainActor
    func reportsMissingSkillsPlainly() async {
        let result = await lookup("Some App Without A Skill")
        #expect(result?.status == .succeeded)
        #expect(result?.metadata["found"] == "false")
    }

    @Test
    @MainActor
    func advertisesValidatedScriptsForScriptBackedSkills() async {
        // The music skill is discovered like any other app skill (its `apps:`
        // frontmatter, no hardcoded list) and advertises its validated script
        // so the model can execute the workflow with skill_run.
        for key in ["Music", "Apple Music", "com.apple.Music"] {
            let result = await lookup(key)
            #expect(result?.metadata["found"] == "true")
            #expect(result?.metadata["skillID"] == "music")
            #expect(result?.metadata["scriptIDs"]?.contains("scripts-play-media-by-search") == true)
            #expect(result?.summary.contains("skill_run") == true)
        }
    }

    @Test
    @MainActor
    func skillRunRejectsUnknownScriptsWithoutSideEffects() async {
        let descriptor = DonkeyCommandLayer.descriptors.first { $0.name == "skill_run" }!
        func run(_ input: [String: String]) async -> HarnessToolResult? {
            await DonkeyCommandBackends.makeExecutor()(HarnessToolExecutionContext(
                taskID: "test",
                call: HarnessToolCall(name: "skill_run", input: input),
                descriptor: descriptor,
                worldModel: HarnessWorldModel(),
                grantedPermissions: [.appControl, .input]
            ))
        }

        let missing = await run(["scriptID": "scripts-play-media-by-search"])
        #expect(missing?.status == .invalidInput)

        // A script id must belong to the named skill — ids from one skill can't
        // execute under another.
        let mismatched = await run(["skillID": "spotify-operate", "scriptID": "scripts-play-media-by-search"])
        #expect(mismatched?.status == .failed)
        #expect(mismatched?.metadata["reason"] == "skillScriptUnavailable")

        let unknown = await run(["skillID": "music", "scriptID": "no-such-script"])
        #expect(unknown?.status == .failed)
        #expect(unknown?.metadata["reason"] == "skillScriptUnavailable")
    }
}
