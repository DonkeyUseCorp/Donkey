import DonkeyContracts
import DonkeyHarness
import DonkeyRuntime
import Foundation
import Testing

@Suite
struct AppCommandsCommandTests {
    @MainActor
    private func run(_ input: [String: String]) async -> HarnessToolResult? {
        let descriptor = DonkeyCommandLayer.descriptors.first { $0.name == "app_commands" }!
        let context = HarnessToolExecutionContext(
            agentID: "test",
            call: HarnessToolCall(name: "app_commands", input: input),
            descriptor: descriptor,
            worldModel: HarnessWorldModel(),
            grantedPermissions: [.appLookup]
        )
        return await DonkeyCommandBackends.makeExecutor()(context)
    }

    @Test
    @MainActor
    func requiresAnAppInput() async {
        let result = await run([:])
        #expect(result?.status == .invalidInput)
    }

    @Test
    @MainActor
    func unknownAppReportsNoDictionaryWithoutFailing() async {
        let result = await run(["app": "Definitely Not An Installed App 9000"])
        #expect(result?.status == .succeeded)
        #expect(result?.metadata["scriptable"] != "true")
        #expect(result?.metadata["digest"] == nil)
    }

    @Test
    @MainActor
    func readsARealDictionaryWithSuiteNamesAndTerminology() async {
        guard FileManager.default.fileExists(atPath: "/System/Applications/Notes.app") else { return }
        let result = await run(["app": "com.apple.Notes"])
        #expect(result?.status == .succeeded)
        #expect(result?.metadata["scriptable"] == "true")
        let digest = result?.metadata["digest"] ?? ""
        #expect(digest.contains("scripting dictionary"))
        #expect(digest.contains("Notes Suite"))
        let suites = result?.metadata["suites"] ?? ""
        #expect(suites.contains("Notes Suite"))
        // The digest IS the planner-facing summary.
        #expect(result?.summary == digest)
    }

    @Test
    @MainActor
    func drillsIntoOneSuiteAtFullDetail() async {
        guard FileManager.default.fileExists(atPath: "/System/Applications/Notes.app") else { return }
        let result = await run(["app": "Notes", "suite": "notes suite"])
        #expect(result?.status == .succeeded)
        let digest = result?.metadata["digest"] ?? ""
        #expect(digest.contains("Notes Suite"))
        #expect(!digest.contains("Standard Suite"))

        let missing = await run(["app": "Notes", "suite": "No Such Suite"])
        #expect(missing?.status == .failed)
        #expect(missing?.metadata["reason"] == "suiteNotFound")
        #expect(missing?.summary.contains("Notes Suite") == true)
    }
}
