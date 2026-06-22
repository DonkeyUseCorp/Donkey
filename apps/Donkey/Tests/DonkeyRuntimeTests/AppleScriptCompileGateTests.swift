import DonkeyContracts
import DonkeyHarness
import DonkeyRuntime
import Foundation
import Testing

/// Validation of dynamically generated AppleScript is deterministic: unresolved template tokens,
/// commands outside the app's dictionary, and real compile failures are all rejected before
/// execution, with the actual error surfaced to the planner.
@Suite
struct AppleScriptCompileGateTests {
    private func registry(
        scriptStore: HarnessGeneratedScriptStore,
        compiler: (@Sendable (String, String?, String?) async -> HarnessScriptCompileOutcome)? = nil,
        generator: @escaping @Sendable (HarnessScriptGenerationRequest) async -> HarnessScriptGenerationOutcome
    ) -> HarnessToolRegistry {
        BuiltInHarnessToolCatalog.registryWithBuiltInExecutors(
            services: HarnessBuiltInToolServices(
                generatedScripts: scriptStore,
                appleScriptGenerator: generator,
                appleScriptCompiler: compiler
            )
        )
    }

    private func generate(
        _ registry: HarnessToolRegistry,
        artifactID: String,
        targetApp: String = "Notes"
    ) async -> HarnessToolResult {
        await registry.execute(
            HarnessToolCall(
                id: "\(artifactID)-generate",
                name: "automation.applescript.generate",
                input: [
                    "scriptArtifactID": artifactID,
                    "targetApp": targetApp,
                    "goal": "do the thing"
                ]
            ),
            taskID: "task-compile-gate",
            worldModel: HarnessWorldModel(),
            grantedPermissions: [.appLookup]
        )
    }

    private func validate(
        _ registry: HarnessToolRegistry,
        artifactID: String,
        targetApp: String = "Notes"
    ) async -> HarnessToolResult {
        await registry.execute(
            HarnessToolCall(
                id: "\(artifactID)-validate",
                name: "automation.applescript.validate",
                input: ["scriptArtifactID": artifactID, "targetApp": targetApp]
            ),
            taskID: "task-compile-gate",
            worldModel: HarnessWorldModel(),
            grantedPermissions: [.appLookup]
        )
    }

    @Test
    func compileFailureRejectsTheArtifactWithTheRealCompilerError() async {
        let scriptStore = HarnessGeneratedScriptStore()
        let registry = registry(
            scriptStore: scriptStore,
            compiler: { source, targetApp, _ in
                #expect(source.contains("frobnicate"))
                #expect(targetApp == "Notes")
                return HarnessScriptCompileOutcome(
                    compiled: false,
                    errorMessage: "The variable frobnicate is not defined.",
                    errorRangeDescription: "characters 28–38"
                )
            },
            generator: { _ in
                HarnessScriptGenerationOutcome(
                    succeeded: true,
                    source: #"tell application "Notes" to frobnicate"#,
                    summary: "Bad terminology."
                )
            }
        )

        _ = await generate(registry, artifactID: "bad-terminology")
        let validated = await validate(registry, artifactID: "bad-terminology")
        let artifact = await scriptStore.artifact(id: "bad-terminology")

        #expect(validated.status == .failed)
        #expect(validated.metadata["reason"] == "appleScriptCompileFailed")
        #expect(validated.summary.contains("The variable frobnicate is not defined."))
        #expect(validated.metadata["compile.errorMessage"] == "The variable frobnicate is not defined.")
        #expect(validated.metadata["compile.errorRange"] == "characters 28–38")
        #expect(artifact?.validationStatus == .rejected)
    }

    @Test
    func compileSuccessValidatesTheArtifact() async {
        let scriptStore = HarnessGeneratedScriptStore()
        let registry = registry(
            scriptStore: scriptStore,
            compiler: { _, _, _ in HarnessScriptCompileOutcome(compiled: true) },
            generator: { _ in
                HarnessScriptGenerationOutcome(
                    succeeded: true,
                    source: #"tell application "Notes" to count notes"#,
                    summary: "Counts notes."
                )
            }
        )

        _ = await generate(registry, artifactID: "good-script")
        let validated = await validate(registry, artifactID: "good-script")
        let artifact = await scriptStore.artifact(id: "good-script")

        #expect(validated.status == .succeeded)
        #expect(artifact?.validationStatus == .validated)
    }

    @Test
    func unresolvedTemplateTokensAreRejectedButRecordLiteralsAreNot() async {
        let scriptStore = HarnessGeneratedScriptStore()
        let registry = registry(
            scriptStore: scriptStore,
            compiler: { _, _, _ in HarnessScriptCompileOutcome(compiled: true) },
            generator: { _ in
                HarnessScriptGenerationOutcome(
                    succeeded: true,
                    source: #"tell application "Notes" to make new note with properties {name:"{query}"}"#,
                    summary: "Left a placeholder unbound."
                )
            }
        )

        _ = await generate(registry, artifactID: "unbound-placeholder")
        let validated = await validate(registry, artifactID: "unbound-placeholder")

        #expect(validated.status == .failed)
        #expect(validated.metadata["reason"] == "unresolvedTemplatePlaceholder:{query}")

        // AppleScript record/list literals use braces too; only the known token set rejects.
        let literalRegistry = registry2(scriptStore: scriptStore)
        _ = await generate(literalRegistry, artifactID: "record-literal")
        let literalValidated = await validate(literalRegistry, artifactID: "record-literal")
        #expect(literalValidated.status == .succeeded)
    }

    private func registry2(scriptStore: HarnessGeneratedScriptStore) -> HarnessToolRegistry {
        registry(
            scriptStore: scriptStore,
            compiler: { _, _, _ in HarnessScriptCompileOutcome(compiled: true) },
            generator: { _ in
                HarnessScriptGenerationOutcome(
                    succeeded: true,
                    source: #"tell application "Notes" to make new note with properties {name:"Groceries", body:"eggs"}"#,
                    summary: "Concrete record literal."
                )
            }
        )
    }

    @Test
    func usedCommandsOutsideTheDictionaryAreRejectedBeforeCompile() async {
        let scriptStore = HarnessGeneratedScriptStore()
        let registry = BuiltInHarnessToolCatalog.registryWithBuiltInExecutors(
            services: HarnessBuiltInToolServices(
                generatedScripts: scriptStore,
                appleScriptGenerator: { _ in
                    HarnessScriptGenerationOutcome(
                        succeeded: true,
                        source: #"tell application "Notes" to teleport"#,
                        summary: "Hallucinated command.",
                        metadata: ["usedCommands": "teleport"]
                    )
                },
                scriptingDictionaryProvider: { _, _ in
                    HarnessScriptingDictionarySnapshot(
                        digest: "command \"make\"; command \"show\"",
                        commandNames: ["make", "show"]
                    )
                },
                appleScriptCompiler: { _, _, _ in
                    Issue.record("compile must not run when the cross-check already rejected")
                    return HarnessScriptCompileOutcome(compiled: true)
                }
            )
        )

        _ = await generate(registry, artifactID: "hallucinated-command")
        let validated = await validate(registry, artifactID: "hallucinated-command")
        let artifact = await scriptStore.artifact(id: "hallucinated-command")

        #expect(validated.status == .failed)
        #expect(validated.metadata["reason"] == "commandNotInDictionary:teleport")
        #expect(artifact?.validationStatus == .rejected)
    }

    @Test
    func withoutACompilerStaticChecksStillValidate() async {
        let scriptStore = HarnessGeneratedScriptStore()
        let registry = registry(
            scriptStore: scriptStore,
            compiler: nil,
            generator: { _ in
                HarnessScriptGenerationOutcome(
                    succeeded: true,
                    source: #"tell application "Notes" to count notes"#,
                    summary: "Counts notes."
                )
            }
        )

        _ = await generate(registry, artifactID: "no-compiler")
        let validated = await validate(registry, artifactID: "no-compiler")

        #expect(validated.status == .succeeded)
    }

    @Test
    func skillTemplateArtifactsKeepTheirTokensThroughValidation() async {
        // Skill-pack templates legitimately carry tokens until execution renders them; the
        // placeholder/compile gates apply only to the dynamic automation path.
        let scriptStore = HarnessGeneratedScriptStore()
        let registry = BuiltInHarnessToolCatalog.registryWithBuiltInExecutors(
            services: HarnessBuiltInToolServices(
                generatedScripts: scriptStore,
                appleScriptCompiler: { _, _, _ in
                    Issue.record("skill templates must not be compile-gated")
                    return HarnessScriptCompileOutcome(compiled: false)
                }
            )
        )

        _ = await registry.execute(
            HarnessToolCall(
                id: "skill-template-generate",
                name: "skill.script.generate",
                input: [
                    "skillID": "music-helper",
                    "scriptID": "play-template",
                    "language": "appleScript",
                    "purpose": "play a track",
                    "scriptSource": #"tell application "Music" to play track "{query}""#
                ]
            ),
            taskID: "task-template",
            worldModel: HarnessWorldModel(),
            grantedPermissions: [.skillLookup]
        )
        let validated = await registry.execute(
            HarnessToolCall(
                id: "skill-template-validate",
                name: "skill.script.validate",
                input: ["scriptID": "play-template", "targetApp": "Music"]
            ),
            taskID: "task-template",
            worldModel: HarnessWorldModel(),
            grantedPermissions: [.skillLookup]
        )

        #expect(validated.status == .succeeded)
    }
}

/// Live compile-gate smokes against real installed apps. Run with:
///   DEVELOPER_DIR=… DONKEY_LIVE_SMOKE=1 swift test --filter NSAppleScriptCompileGateLiveTests
@Suite
struct NSAppleScriptCompileGateLiveTests {
    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["DONKEY_LIVE_SMOKE"] == "1"
    }

    @Test
    func compilesRealTerminologyAgainstFinder() async {
        guard isEnabled else { return }
        let outcome = await NSAppleScriptCompileGate().compile(
            source: #"tell application "Finder" to get name of home"#,
            targetApp: "Finder",
            bundleIdentifier: "com.apple.finder"
        )
        #expect(outcome.compiled, "\(outcome.errorMessage)")
    }

    @Test
    func rejectsFakeTerminologyWithARealCompilerMessage() async {
        guard isEnabled else { return }
        let outcome = await NSAppleScriptCompileGate().compile(
            source: #"tell application "Finder" to frobnicate the wuzzle"#,
            targetApp: "Finder",
            bundleIdentifier: "com.apple.finder"
        )
        #expect(!outcome.compiled)
        #expect(!outcome.errorMessage.isEmpty)
    }

    @Test
    func rejectsAnUnresolvableAppWithoutTouchingNSAppleScript() async {
        guard isEnabled else { return }
        let outcome = await NSAppleScriptCompileGate().compile(
            source: #"tell application "Definitely Not Installed 9000" to activate"#,
            targetApp: "Definitely Not Installed 9000",
            bundleIdentifier: nil
        )
        #expect(!outcome.compiled)
        #expect(outcome.metadata["reason"] == "targetAppUnresolvable")
    }
}
