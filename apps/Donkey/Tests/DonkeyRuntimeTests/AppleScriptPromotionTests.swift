import DonkeyContracts
import DonkeyHarness
import DonkeyRuntime
import Foundation
import Testing

/// A generated AppleScript that compiled, validated, and executed successfully is promoted into a
/// learned skill pack, so the next run of the same task is `app_skill` → `skill_run` with no model
/// in the loop.
@Suite
struct AppleScriptPromotionTests {
    private func makeRegistry(
        root: URL,
        scriptStore: HarnessGeneratedScriptStore,
        executionSucceeds: Bool = true,
        source: String = #"tell application "Notes" to make new note with properties {name:"Groceries"}"#,
        generationMetadata: [String: String] = [
            "usedCommands": "make",
            "parameterBindings": "name=Groceries"
        ]
    ) -> HarnessToolRegistry {
        BuiltInHarnessToolCatalog.registryWithBuiltInExecutors(
            services: HarnessBuiltInToolServices(
                generatedScripts: scriptStore,
                applicationSkillPackWriter: HarnessApplicationSkillPackWriter(rootDirectory: root),
                appleScriptGenerator: { _ in
                    HarnessScriptGenerationOutcome(
                        succeeded: true,
                        source: source,
                        summary: "Creates the note.",
                        metadata: generationMetadata
                    )
                },
                appleScriptExecutor: { _, _ in
                    HarnessScriptExecutionOutcome(
                        succeeded: executionSucceeds,
                        summary: executionSucceeds ? "Done." : "Failed.",
                        output: executionSucceeds ? "status=created" : "status=failed"
                    )
                }
            )
        )
    }

    private func runPipeline(
        _ registry: HarnessToolRegistry,
        artifactID: String
    ) async -> HarnessToolResult {
        _ = await registry.execute(
            HarnessToolCall(
                id: "\(artifactID)-generate",
                name: "automation.applescript.generate",
                input: [
                    "scriptArtifactID": artifactID,
                    "targetApp": "Notes",
                    "bundleIdentifier": "com.apple.Notes",
                    "goal": "create the Groceries note"
                ]
            ),
            taskID: "task-promotion",
            worldModel: HarnessWorldModel(),
            grantedPermissions: [.appLookup]
        )
        _ = await registry.execute(
            HarnessToolCall(
                id: "\(artifactID)-validate",
                name: "automation.applescript.validate",
                input: ["scriptArtifactID": artifactID, "targetApp": "Notes"]
            ),
            taskID: "task-promotion",
            worldModel: HarnessWorldModel(),
            grantedPermissions: [.appLookup]
        )
        return await registry.execute(
            HarnessToolCall(
                id: "\(artifactID)-execute",
                name: "automation.applescript.execute",
                input: ["scriptArtifactID": artifactID, "targetApp": "Notes"]
            ),
            taskID: "task-promotion",
            worldModel: HarnessWorldModel(),
            grantedPermissions: [.appControl, .input]
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("applescript-promotion-tests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test
    func successfulExecutionPromotesAParameterizedSkillPack() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = makeRegistry(root: root, scriptStore: HarnessGeneratedScriptStore())

        let executed = await runPipeline(registry, artifactID: "notes-create-groceries")

        #expect(executed.status == .succeeded)
        let skillID = try #require(executed.metadata["promotion.skillID"])
        #expect(executed.metadata["promotion.parameterized"] == "true")

        let skillDirectory = root.appendingPathComponent(skillID, isDirectory: true)
        let skillMarkdown = try String(
            contentsOf: skillDirectory.appendingPathComponent("SKILL.md"), encoding: .utf8
        )
        // The pack is app-matched (apps: frontmatter) so app_skill discovers it for Notes.
        #expect(skillMarkdown.contains("apps: Notes, com.apple.Notes"))

        let scriptID = try #require(executed.metadata["promotion.scriptID"])
        let promotedSource = try String(
            contentsOf: skillDirectory.appendingPathComponent("scripts/\(scriptID).applescript"),
            encoding: .utf8
        )
        // The task-specific value became a reusable slot…
        #expect(promotedSource.contains(#"{name:"{query}"}"#))
        // …and re-rendering the slot with the original value reproduces the verified script exactly.
        let rerendered = promotedSource.replacingOccurrences(of: "{query}", with: "Groceries")
        #expect(rerendered == #"tell application "Notes" to make new note with properties {name:"Groceries"}"#)
    }

    @Test
    func repeatSuccessUpdatesTheSamePackInsteadOfDuplicating() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = makeRegistry(root: root, scriptStore: HarnessGeneratedScriptStore())

        let first = await runPipeline(registry, artifactID: "first-run")
        let second = await runPipeline(registry, artifactID: "second-run")

        // Same app + same dictionary-command signature → same pack, updated in place.
        #expect(first.metadata["promotion.skillID"] == second.metadata["promotion.skillID"])
        let packs = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(packs.count == 1)
        let scriptsPath = root
            .appendingPathComponent(packs[0], isDirectory: true)
            .appendingPathComponent("scripts", isDirectory: true)
        let scripts = try FileManager.default.contentsOfDirectory(atPath: scriptsPath.path)
        #expect(scripts.count == 1)
    }

    @Test
    func failedExecutionDoesNotPromote() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = makeRegistry(
            root: root,
            scriptStore: HarnessGeneratedScriptStore(),
            executionSucceeds: false
        )

        let executed = await runPipeline(registry, artifactID: "failing-run")

        #expect(executed.status == .failed)
        #expect(executed.metadata["promotion.skillID"] == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test
    func unparameterizableScriptsPromoteAsFixedWorkflows() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = makeRegistry(
            root: root,
            scriptStore: HarnessGeneratedScriptStore(),
            source: #"tell application "Notes" to count notes"#,
            generationMetadata: ["usedCommands": "count", "parameterBindings": ""]
        )

        let executed = await runPipeline(registry, artifactID: "count-notes")

        #expect(executed.status == .succeeded)
        let skillID = try #require(executed.metadata["promotion.skillID"])
        #expect(executed.metadata["promotion.parameterized"] == "false")
        let scriptID = try #require(executed.metadata["promotion.scriptID"])
        let promotedSource = try String(
            contentsOf: root
                .appendingPathComponent(skillID, isDirectory: true)
                .appendingPathComponent("scripts/\(scriptID).applescript"),
            encoding: .utf8
        )
        #expect(promotedSource == #"tell application "Notes" to count notes"#)
    }

    @Test
    func skillPackScriptsAreNotRePromoted() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A pre-validated skill-pack artifact (not created by automation.applescript.generate)
        // executes through skill.script.execute without triggering promotion.
        let artifact = HarnessGeneratedScriptArtifact(
            id: "builtin-script",
            language: .appleScript,
            source: #"tell application "Music" to play"#,
            validationStatus: .validated,
            createdByToolName: "built-in-skill-pack",
            ownerSkillID: "music-helper",
            metadata: ["targetApp": "Music"]
        )
        let registry = BuiltInHarnessToolCatalog.registryWithBuiltInExecutors(
            services: HarnessBuiltInToolServices(
                generatedScripts: HarnessGeneratedScriptStore(artifacts: [artifact]),
                applicationSkillPackWriter: HarnessApplicationSkillPackWriter(rootDirectory: root),
                skillScriptExecutor: { _, _ in
                    HarnessScriptExecutionOutcome(succeeded: true, summary: "Played.", output: "status=played")
                }
            )
        )

        let executed = await registry.execute(
            HarnessToolCall(
                id: "builtin-execute",
                name: "skill.script.execute",
                input: ["scriptID": "builtin-script"]
            ),
            taskID: "task-builtin",
            worldModel: HarnessWorldModel(),
            grantedPermissions: [.appControl, .input]
        )

        #expect(executed.status == .succeeded)
        #expect(executed.metadata["promotion.skillID"] == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
