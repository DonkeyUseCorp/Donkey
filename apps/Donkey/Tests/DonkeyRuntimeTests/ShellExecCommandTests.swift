import DonkeyContracts
import DonkeyHarness
import DonkeyRuntime
import Foundation
import Testing

@Suite
struct ShellExecCommandTests {
    @MainActor
    private func shellExec(_ command: String) async -> HarnessToolResult? {
        let descriptor = DonkeyCommandLayer.descriptors.first { $0.name == "shell_exec" }!
        let context = HarnessToolExecutionContext(
            agentID: "test",
            call: HarnessToolCall(name: "shell_exec", input: ["command": command]),
            descriptor: descriptor,
            worldModel: HarnessWorldModel(),
            grantedPermissions: []
        )
        return await DonkeyCommandBackends.makeExecutor()(context)
    }

    /// The exact "Long content" Notes path that used to fail: read a generated file from the real
    /// macOS temp directory and create a note from it. The composed command is ~460 chars — over the
    /// old 400-char cap — so it was rejected as "too long" and the run stalled into failedSafe. With
    /// the cap raised for real osascript one-liners, the length guard must let it through (it should
    /// not come back as the "too long" invalidInput).
    @Test
    @MainActor
    func notesFromFileCommandClearsLengthGuard() async {
        let filePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("donkey-llm-\(UUID().uuidString).txt").path
        let command =
            "osascript -e 'set f to (read POSIX file \"\(filePath)\" as «class utf8»)'"
            + " -e 'set AppleScript'\"'\"'s text item delimiters to (ASCII character 10)'"
            + " -e 'set parts to text items of f'"
            + " -e 'set AppleScript'\"'\"'s text item delimiters to \"<br>\"'"
            + " -e 'tell application \"Notes\" to make new note"
            + " with properties {name:\"Taylor Swift — The Tortured Poets Department\", body:(parts as text)}'"

        #expect(command.count > 400, "fixture must exceed the old cap to be a real regression")
        #expect(command.count <= 1_500)

        let result = await shellExec(command)
        // It must clear the length guard. Past it the outcome depends on the environment's shell
        // consent (a gate when not yet granted, otherwise it runs and fails on the missing fixture
        // file) — but it is never the `invalidInput` "too long" rejection that used to stall the run.
        #expect(result?.status != .invalidInput)
    }

    /// A genuinely oversized inline command is still rejected — but now with an actionable message
    /// that names the limit and points at the llm.generate(toFile) + read-from-file pattern.
    @Test
    @MainActor
    func oversizedCommandIsRejectedWithActionableMessage() async {
        let command = "echo " + String(repeating: "x", count: 1_600)
        let result = await shellExec(command)
        #expect(result?.status == .invalidInput)
        #expect(result?.summary.contains("the limit is 1500") == true)
        #expect(result?.summary.contains("llm.generate") == true)
    }
}
