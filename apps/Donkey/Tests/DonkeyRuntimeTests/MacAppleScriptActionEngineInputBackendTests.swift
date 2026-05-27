import DonkeyContracts
@testable import DonkeyRuntime
import Foundation
import Testing

@Suite
struct MacAppleScriptActionEngineInputBackendTests {
    @Test
    func generatedAppleScriptTemplateRunsEscapedSource() async throws {
        let template = "set donkeyQuery to {query}\nreturn donkeyQuery"
        let runner = RecordingAppleScriptRunner(
            result: AppleScriptExecutionResult(
                succeeded: true,
                output: #"Justin "JB" Bieber"#
            )
        )
        let backend = MacAppleScriptActionEngineInputBackend(runner: runner)
        let result = await backend.execute(
            ActionEngineCommand(
                id: "generated-template",
                traceID: "trace-template",
                targetID: "local-app-task-generated-template",
                kind: .controller,
                issuedAt: timestamp(100),
                key: "Justin \"JB\" Bieber",
                metadata: [
                    "automationBackend": "appleScript",
                    "appleScript.action": "generated.template",
                    "appleScript.query": "Justin \"JB\" Bieber",
                    "appleScript.template": template
                ]
            )
        )

        let scripts = await runner.scripts()
        #expect(result.executed)
        #expect(result.metadata["liveInputBackend"] == "mac-apple-script")
        #expect(result.metadata["appleScript.output"] == #"Justin "JB" Bieber"#)
        #expect(scripts.count == 1)
        #expect(scripts.first?.contains(#"set donkeyQuery to "Justin \"JB\" Bieber""#) == true)
        #expect(result.metadata["appleScript.scriptKind"] == "template")
    }

    @Test
    func unsupportedAppleScriptCommandDoesNotExecute() async {
        let runner = RecordingAppleScriptRunner(
            result: AppleScriptExecutionResult(succeeded: true, output: "searched-ui-first-result")
        )
        let backend = MacAppleScriptActionEngineInputBackend(runner: runner)
        let result = await backend.execute(
            ActionEngineCommand(
                id: "bad-command",
                traceID: "trace-media",
                targetID: "local-app-task-media-playback",
                kind: .key,
                issuedAt: timestamp(100),
                key: "Return",
                metadata: ["automationBackend": "appleScript"]
            )
        )

        #expect(result.executed == false)
        #expect(result.metadata["reason"] == "unsupportedCommandKind")
        let scripts = await runner.scripts()
        #expect(scripts.isEmpty)
    }

    @Test
    func generatedAppleScriptSourceRunsWithoutBuiltinAction() async throws {
        let runner = RecordingAppleScriptRunner(
            result: AppleScriptExecutionResult(succeeded: true, output: "ok")
        )
        let backend = MacAppleScriptActionEngineInputBackend(runner: runner)
        let result = await backend.execute(
            ActionEngineCommand(
                id: "generated-command",
                traceID: "trace-generated",
                targetID: "local-app-task-generated",
                kind: .controller,
                issuedAt: timestamp(100),
                metadata: [
                    "automationBackend": "appleScript",
                    "appleScript.action": "generated.test",
                    "appleScript.source": #"return "ok""#
                ]
            )
        )

        #expect(result.executed)
        #expect(result.metadata["appleScript.scriptKind"] == "source")
        let scripts = await runner.scripts()
        #expect(scripts == [#"return "ok""#])
    }

    @Test
    func generatedAppleScriptTemplateEscapesEntityValues() async throws {
        let runner = RecordingAppleScriptRunner(
            result: AppleScriptExecutionResult(succeeded: true, output: "ok")
        )
        let backend = MacAppleScriptActionEngineInputBackend(runner: runner)
        let result = await backend.execute(
            ActionEngineCommand(
                id: "template-command",
                traceID: "trace-template",
                targetID: "local-app-task-template",
                kind: .controller,
                issuedAt: timestamp(100),
                key: #"A "quoted" value"#,
                metadata: [
                    "automationBackend": "appleScript",
                    "appleScript.action": "generated.template",
                    "appleScript.query": #"A "quoted" value"#,
                    "appleScript.template": "set q to {query}\nreturn \"ok\""
                ]
            )
        )

        #expect(result.executed)
        #expect(result.metadata["appleScript.scriptKind"] == "template")
        let scripts = await runner.scripts()
        #expect(scripts.first == #"set q to "A \"quoted\" value""# + "\nreturn \"ok\"")
    }

    private func timestamp(_ milliseconds: UInt64) -> RunTraceTimestamp {
        RunTraceTimestamp(
            wallClock: Date(timeIntervalSince1970: Double(milliseconds) / 1_000),
            monotonicUptimeNanoseconds: milliseconds * 1_000_000
        )
    }
}

private actor RecordingAppleScriptRunner: AppleScriptRunning {
    private let result: AppleScriptExecutionResult
    private var recordedScripts: [String] = []

    init(result: AppleScriptExecutionResult) {
        self.result = result
    }

    func run(_ script: String) async -> AppleScriptExecutionResult {
        recordedScripts.append(script)
        return result
    }

    func scripts() -> [String] {
        recordedScripts
    }
}
