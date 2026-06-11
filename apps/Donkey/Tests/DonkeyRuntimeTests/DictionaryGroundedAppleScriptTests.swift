import DonkeyAI
import DonkeyContracts
import DonkeyHarness
import Foundation
import Testing

/// Dynamic AppleScript generation is grounded in the target app's parsed scripting dictionary:
/// the harness fetches the digest, hands it to the generator, and records the grounding (and the
/// dictionary's command names) on the artifact for validation to cross-check.
@Suite
struct DictionaryGroundedAppleScriptTests {
    // MARK: Harness executor

    @Test
    func generateHandsTheDictionaryDigestToTheGeneratorAndStampsTheArtifact() async {
        let scriptStore = HarnessGeneratedScriptStore()
        let registry = BuiltInHarnessToolCatalog.registryWithBuiltInExecutors(
            services: HarnessBuiltInToolServices(
                generatedScripts: scriptStore,
                appleScriptGenerator: { request in
                    #expect(request.scriptingDictionaryDigest.contains("command \"make\""))
                    return HarnessScriptGenerationOutcome(
                        succeeded: true,
                        source: #"tell application "Notes" to make new note"#,
                        summary: "Creates a note.",
                        metadata: ["generator": "test-child-llm", "usedCommands": "make"]
                    )
                },
                scriptingDictionaryProvider: { targetApp, bundleIdentifier in
                    #expect(targetApp == "Notes")
                    #expect(bundleIdentifier == "com.apple.Notes")
                    return HarnessScriptingDictionarySnapshot(
                        digest: "app \"Notes\" scripting dictionary:\nsuite \"Notes Suite\":\n  command \"make\"",
                        commandNames: ["make", "show"]
                    )
                }
            )
        )

        let generated = await registry.execute(
            HarnessToolCall(
                id: "grounded-generate",
                name: "automation.applescript.generate",
                input: [
                    "scriptArtifactID": "grounded-notes-create",
                    "targetApp": "Notes",
                    "bundleIdentifier": "com.apple.Notes",
                    "goal": "create a note"
                ]
            ),
            taskID: "task-grounded",
            worldModel: HarnessWorldModel(),
            grantedPermissions: [.appLookup]
        )
        let artifact = await scriptStore.artifact(id: "grounded-notes-create")

        #expect(generated.status == .succeeded)
        #expect(artifact?.metadata["generation.dictionaryGrounded"] == "true")
        #expect(artifact?.metadata["dictionary.commandNames"] == "make\nshow")
        #expect(artifact?.metadata["generation.usedCommands"] == "make")
    }

    @Test
    func generateWithoutADictionaryProceedsUngroundedButFlagged() async {
        let scriptStore = HarnessGeneratedScriptStore()
        let registry = BuiltInHarnessToolCatalog.registryWithBuiltInExecutors(
            services: HarnessBuiltInToolServices(
                generatedScripts: scriptStore,
                appleScriptGenerator: { request in
                    #expect(request.scriptingDictionaryDigest.isEmpty)
                    return HarnessScriptGenerationOutcome(
                        succeeded: true,
                        source: #"tell application "Obscure" to activate"#,
                        summary: "Activates the app."
                    )
                },
                scriptingDictionaryProvider: { _, _ in nil }
            )
        )

        let generated = await registry.execute(
            HarnessToolCall(
                id: "ungrounded-generate",
                name: "automation.applescript.generate",
                input: [
                    "scriptArtifactID": "ungrounded-script",
                    "targetApp": "Obscure",
                    "goal": "activate"
                ]
            ),
            taskID: "task-ungrounded",
            worldModel: HarnessWorldModel(),
            grantedPermissions: [.appLookup]
        )
        let artifact = await scriptStore.artifact(id: "ungrounded-script")

        #expect(generated.status == .succeeded)
        #expect(artifact?.metadata["generation.dictionaryGrounded"] == "false")
        #expect(artifact?.metadata["dictionary.commandNames"] == nil)
    }

    // MARK: Hosted generation adapter

    @Test
    func adapterEmbedsTheDigestAndRequestsTheV2SchemaWithUsedCommands() async throws {
        let modelOutput = """
        {"canGenerate":true,"blockedReason":"","scriptSource":"tell application \\"Notes\\" to make new note with properties {name:\\"Groceries\\"}","summary":"Creates the Groceries note.","safetyNotes":[],"expectedOutput":"status=created","usedCommands":["make"],"parameterBindings":["with properties={name:Groceries}"]}
        """
        let httpClient = FixtureAppleScriptHTTPClient(
            data: try JSONSerialization.data(withJSONObject: ["output_text": modelOutput])
        )
        let adapter = HostedAppleScriptGenerationAdapter(
            configuration: DonkeyBackendInferenceConfiguration(
                baseURL: URL(string: "https://donkey.example")!,
                clientID: "client-1"
            ),
            httpClient: httpClient
        )

        let outcome = await adapter.generateAppleScript(
            HarnessScriptGenerationRequest(
                language: .appleScript,
                targetApp: "Notes",
                bundleIdentifier: "com.apple.Notes",
                goal: "create the Groceries note",
                scriptingDictionaryDigest: "suite \"Notes Suite\": command \"make\" -> note"
            )
        )

        #expect(outcome.succeeded)
        #expect(outcome.source.contains("make new note"))
        #expect(outcome.metadata["schemaID"] == "dynamic_applescript_generation_v2")
        #expect(outcome.metadata["usedCommands"] == "make")
        #expect(outcome.metadata["parameterBindings"] == "with properties={name:Groceries}")

        let request = try #require(httpClient.requests.first)
        let body = try #require(
            request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        )
        let text = try #require(body["text"] as? [String: Any])
        let format = try #require(text["format"] as? [String: Any])
        #expect(format["name"] as? String == "dynamic_applescript_generation_v2")
        let bodyString = String(data: try #require(request.httpBody), encoding: .utf8) ?? ""
        // The digest rides inside the structured prompt payload.
        #expect(bodyString.contains("scriptingDictionary"))
        #expect(bodyString.contains("Notes Suite"))
        // The instructions hard-ground generation in the digest.
        #expect(bodyString.contains("use ONLY command, parameter, class, property, and enumeration names"))
    }
}

private final class FixtureAppleScriptHTTPClient: AIHTTPClient, @unchecked Sendable {
    var data: Data
    var requests: [URLRequest] = []

    init(data: Data) {
        self.data = data
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (
            data,
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        )
    }
}
