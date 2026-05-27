import DonkeyContracts
import DonkeyHarness
import DonkeyRuntime
import Foundation
import Testing

@Suite
struct GenericHarnessTests {
    @Test
    func builtInRegistryContainsGenericToolsAndAppleScriptAutomationTools() async {
        let descriptors = BuiltInHarnessToolCatalog.descriptors
        let names = Set(descriptors.map(\.name))

        #expect(names.contains("app.search"))
        #expect(names.contains("elements.get"))
        #expect(names.contains("element.perform"))
        #expect(names.contains("skill.search"))
        #expect(names.contains("skill.load"))
        #expect(names.contains("skill.script.generate"))
        #expect(names.contains("skill.script.validate"))
        #expect(names.contains("skill.script.execute"))
        #expect(names.contains("automation.applescript.generate"))
        #expect(names.contains("automation.applescript.execute"))
        #expect(names.contains("application.learning.start"))
        #expect(names.contains("application.learning.captureState"))
        #expect(names.contains("application.learning.proposeExploration"))
        #expect(names.contains("application.learning.distill"))
        #expect(names.contains("application.learning.saveSkillPack"))

        let generate = descriptors.first { $0.name == "automation.applescript.generate" }
        #expect(generate?.metadata["modelBoundary"] == "required")
        #expect(generate?.metadata["directExecution"] == "false")
        #expect(generate?.requiredContext.contains("structured intent") == true)

        let execute = descriptors.first { $0.name == "automation.applescript.execute" }
        #expect(execute?.metadata["requiresGeneratedArtifact"] == "true")
        #expect(execute?.requiredPermissions == [.appControl, .input])

        let skillSearch = descriptors.first { $0.name == "skill.search" }
        #expect(skillSearch?.requiredPermissions == [.skillLookup])
        #expect(skillSearch?.pluginID == "core.skills")

        let scriptGenerate = descriptors.first { $0.name == "skill.script.generate" }
        #expect(scriptGenerate?.metadata["modelBoundary"] == "required")
        #expect(scriptGenerate?.metadata["directExecution"] == "false")

        let scriptExecute = descriptors.first { $0.name == "skill.script.execute" }
        #expect(scriptExecute?.metadata["requiresValidatedScript"] == "true")
        #expect(scriptExecute?.requiredPermissions == [.appControl, .input])

        let learningCapture = descriptors.first { $0.name == "application.learning.captureState" }
        #expect(learningCapture?.requiredPermissions == [.screenCapture, .accessibility])
        #expect(learningCapture?.verificationHints.contains { $0.contains("bounded artifacts") } == true)

        let learningExplore = descriptors.first { $0.name == "application.learning.proposeExploration" }
        #expect(learningExplore?.requiredPermissions == [.accessibility])
        #expect(learningExplore?.verificationHints.contains { $0.contains("technical roles/actions") } == true)
    }

    @Test
    func skillRegistryCanRegisterAndSearchSkills() async {
        let registry = HarnessSkillRegistry()
        await registry.register(
            HarnessSkillDescriptor(
                id: "desktop-browser",
                name: "Desktop Browser",
                summary: "Operate browser tabs and inspect web pages.",
                description: "Use for browser automation, screenshots, forms, and navigation.",
                sourceKind: .plugin,
                tags: ["browser", "computer-use"],
                providedToolNames: ["screen.observe", "element.perform"],
                scripts: [
                    HarnessSkillScriptDescriptor(
                        id: "open-devtools",
                        language: .appleScript,
                        purpose: "Open browser developer tools",
                        relativePath: "scripts/open-devtools.applescript",
                        generatedBy: "skill.script.generate",
                        validationStatus: .validated,
                        requiredPermissions: [.appControl, .input],
                        safetyClass: .guardedInput
                    )
                ]
            )
        )

        let results = await registry.search(query: "browser automation")

        #expect(results.first?.descriptor.id == "desktop-browser")
        #expect(results.first?.matchedFields.contains("name") == true || results.first?.matchedFields.contains("summary") == true)
        #expect(results.first?.descriptor.providedToolNames.contains("element.perform") == true)
        #expect(results.first?.descriptor.scripts.first?.id == "open-devtools")
    }

    @Test
    func skillFileSystemSourceDiscoversSkillMarkdownFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("donkey-harness-skill-test-\(UUID().uuidString)", isDirectory: true)
        let skillDirectory = root.appendingPathComponent("spreadsheet-helper", isDirectory: true)
        try FileManager.default.createDirectory(
            at: skillDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: skillDirectory.appendingPathComponent("scripts", isDirectory: true),
            withIntermediateDirectories: true
        )
        try """
        id: spreadsheet-helper
        description: Build and inspect spreadsheet documents.
        tags: sheets, documents
        tools: memory.retrieve, automation.applescript.generate

        # Spreadsheet Helper

        Use when a task needs spreadsheet reasoning or document automation.
        """.write(
            to: skillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try """
        tell application "Numbers"
            activate
        end tell
        """.write(
            to: skillDirectory.appendingPathComponent("scripts/open-numbers.applescript"),
            atomically: true,
            encoding: .utf8
        )
        try """
        #!/usr/bin/env bash
        echo preparing
        """.write(
            to: skillDirectory.appendingPathComponent("scripts/prepare.sh"),
            atomically: true,
            encoding: .utf8
        )
        try """
        print("inspect")
        """.write(
            to: skillDirectory.appendingPathComponent("scripts/inspect.py"),
            atomically: true,
            encoding: .utf8
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let source = HarnessSkillFileSystemSource(roots: [root])
        let skills = source.discover()

        #expect(skills.count == 1)
        #expect(skills.first?.id == "spreadsheet-helper")
        #expect(skills.first?.name == "Spreadsheet Helper")
        #expect(skills.first?.tags == ["documents", "sheets"])
        #expect(skills.first?.providedToolNames == ["automation.applescript.generate", "memory.retrieve"])
        #expect(skills.first?.scripts.count == 3)
        let scriptsByID = Dictionary(uniqueKeysWithValues: (skills.first?.scripts ?? []).map { ($0.id, $0) })
        #expect(scriptsByID["scripts-open-numbers"]?.language == .appleScript)
        #expect(scriptsByID["scripts-open-numbers"]?.validationStatus == .pendingValidation)
        #expect(scriptsByID["scripts-open-numbers"]?.requiredPermissions == [.appControl, .input])
        #expect(scriptsByID["scripts-prepare"]?.language == .shell)
        #expect(scriptsByID["scripts-inspect"]?.language == .python)
        #expect(skills.first?.instructionPath?.hasSuffix("SKILL.md") == true)
    }

    @Test
    func builtInLocalAppSkillPacksProvideBoundedIntentGuidance() async throws {
        let skills = BuiltInLocalAppSkillPacks.descriptors()
        #expect(skills.contains { $0.id == "music-media" })
        #expect(skills.contains { $0.id == "browser-navigation" })

        let context = LocalAppTaskSkillContext.defaultContext(
            taskDefinitions: LocalAppTaskDefinitionLoader.runtimeSeedDefinitions,
            appFinderCatalog: []
        )

        #expect(context.snippets.contains { $0.contains("Skill ID: music-media") })
        #expect(context.snippets.joined(separator: "\n").contains("metadata.mediaSelection.kind"))
    }

    @Test
    func unknownToolIsRejectedByRegistry() async {
        let registry = BuiltInHarnessToolCatalog.registryWithBuiltInExecutors()
        let result = await registry.execute(
            HarnessToolCall(id: "call-1", name: "missing.tool"),
            taskID: "task-1",
            worldModel: HarnessWorldModel(),
            grantedPermissions: []
        )

        #expect(result.status == .unknownTool)
        #expect(result.metadata["reason"] == "unknownTool")
    }

    @Test
    func builtInExecutorsRetrieveMemoryAndResolveApps() async {
        let registry = BuiltInHarnessToolCatalog.registryWithBuiltInExecutors(
            services: HarnessBuiltInToolServices(
                memoryEntries: [
                    HarnessMemoryEntry(
                        id: "memory-calendar",
                        summary: "Calendar is the preferred scheduling app.",
                        value: "Use Calendar for schedule lookups."
                    )
                ],
                appEntries: [
                    HarnessAppLookupEntry(
                        id: "com.apple.iCal",
                        name: "Calendar",
                        bundleIdentifier: "com.apple.iCal",
                        path: "/System/Applications/Calendar.app"
                    )
                ]
            )
        )

        let memory = await registry.execute(
            HarnessToolCall(id: "memory-call", name: "memory.retrieve", input: ["query": "scheduling app"]),
            taskID: "task-tools",
            worldModel: HarnessWorldModel(),
            grantedPermissions: [.memory]
        )
        let appSearch = await registry.execute(
            HarnessToolCall(id: "app-search-call", name: "app.search", input: ["query": "calendar"]),
            taskID: "task-tools",
            worldModel: HarnessWorldModel(),
            grantedPermissions: [.appLookup]
        )
        let open = await registry.execute(
            HarnessToolCall(id: "app-open-call", name: "app.openOrFocus", input: ["targetID": "com.apple.iCal"]),
            taskID: "task-tools",
            worldModel: HarnessWorldModel(),
            grantedPermissions: [.appControl]
        )

        #expect(memory.status == .succeeded)
        #expect(memory.observations.facts["memory.retrieve.count"] == "1")
        #expect(appSearch.metadata["targetIDs"] == "com.apple.iCal")
        #expect(open.observations.focusedApp == "Calendar")
        #expect(open.observations.facts["focusedApp.bundleIdentifier"] == "com.apple.iCal")
    }

    @Test
    func builtInExecutorsObserveElementsInputAndVerification() async {
        let registry = BuiltInHarnessToolCatalog.registryWithBuiltInExecutors()
        let worldModel = HarnessWorldModel(
            focusedApp: "TextEdit",
            focusedWindowTitle: "Notes",
            visibleText: ["main": "Ready to search"],
            elements: [
                HarnessWorldElement(
                    id: "search-field",
                    label: "Search",
                    role: "AXTextField",
                    isActionEligible: true,
                    actions: ["AXPress", "AXSetValue"],
                    metadata: ["scope": "toolbar"]
                )
            ]
        )

        let observed = await registry.execute(
            HarnessToolCall(id: "observe-call", name: "screen.observe"),
            taskID: "task-elements",
            worldModel: worldModel,
            grantedPermissions: [.screenCapture]
        )
        let elements = await registry.execute(
            HarnessToolCall(id: "elements-call", name: "elements.get", input: ["scope": "toolbar"]),
            taskID: "task-elements",
            worldModel: worldModel,
            grantedPermissions: [.accessibility]
        )
        let performed = await registry.execute(
            HarnessToolCall(id: "perform-call", name: "element.perform", input: ["elementID": "search-field", "action": "press"]),
            taskID: "task-elements",
            worldModel: worldModel,
            grantedPermissions: [.accessibility, .input]
        )
        let text = await registry.execute(
            HarnessToolCall(id: "text-call", name: "text.enter", input: ["elementID": "search-field", "text": "Quarterly notes"]),
            taskID: "task-elements",
            worldModel: worldModel,
            grantedPermissions: [.input]
        )
        let key = await registry.execute(
            HarnessToolCall(id: "key-call", name: "keyboard.press", input: ["key": "Return"]),
            taskID: "task-elements",
            worldModel: worldModel,
            grantedPermissions: [.input]
        )
        let verified = await registry.execute(
            HarnessToolCall(id: "verify-call", name: "state.verify", input: ["criteria": "Ready to search"]),
            taskID: "task-elements",
            worldModel: worldModel,
            grantedPermissions: [.verification]
        )

        #expect(observed.observations.focusedApp == "TextEdit")
        #expect(elements.observations.elements.map(\.id) == ["search-field"])
        #expect(performed.status == .succeeded)
        #expect(performed.observations.facts["element.perform.action"] == "press")
        #expect(text.observations.facts["text.enter.characterCount"] == "15")
        #expect(key.observations.facts["keyboard.press.key"] == "Return")
        #expect(verified.status == .succeeded)
        #expect(verified.metadata["verified"] == "true")
    }

    @Test
    func builtInExecutorsGateScriptGenerationValidationAndExecution() async {
        let scriptStore = HarnessGeneratedScriptStore()
        let registry = BuiltInHarnessToolCatalog.registryWithBuiltInExecutors(
            services: HarnessBuiltInToolServices(
                generatedScripts: scriptStore,
                appleScriptExecutor: { artifact, _ in
                    HarnessScriptExecutionOutcome(
                        succeeded: artifact.language == .appleScript,
                        summary: "AppleScript backend executed artifact.",
                        output: "ok",
                        metadata: ["backend": "test-applescript"]
                    )
                },
                skillScriptExecutor: { artifact, _ in
                    HarnessScriptExecutionOutcome(
                        succeeded: artifact.language == .shell,
                        summary: "Skill script backend executed artifact.",
                        output: "prepared",
                        metadata: ["backend": "test-skill-script"]
                    )
                }
            )
        )

        let generatedAppleScript = await registry.execute(
            HarnessToolCall(
                id: "as-generate",
                name: "automation.applescript.generate",
                input: [
                    "scriptArtifactID": "script-open-notes",
                    "targetApp": "Notes",
                    "goal": "Open a note",
                    "scriptSource": #"tell application "Notes" to activate"#
                ]
            ),
            taskID: "task-scripts",
            worldModel: HarnessWorldModel(),
            grantedPermissions: [.appLookup]
        )
        let validatedAppleScript = await registry.execute(
            HarnessToolCall(
                id: "as-validate",
                name: "skill.script.validate",
                input: ["scriptArtifactID": "script-open-notes", "validationPolicy": "static safe subset"]
            ),
            taskID: "task-scripts",
            worldModel: HarnessWorldModel(),
            grantedPermissions: [.skillLookup]
        )
        let executedAppleScript = await registry.execute(
            HarnessToolCall(
                id: "as-execute",
                name: "automation.applescript.execute",
                input: ["scriptArtifactID": "script-open-notes", "targetApp": "Notes"]
            ),
            taskID: "task-scripts",
            worldModel: HarnessWorldModel(),
            grantedPermissions: [.appControl, .input]
        )
        let generatedSkillScript = await registry.execute(
            HarnessToolCall(
                id: "skill-generate",
                name: "skill.script.generate",
                input: [
                    "skillID": "desktop-helper",
                    "scriptID": "prepare-workspace",
                    "language": "shell",
                    "purpose": "Prepare workspace",
                    "scriptSource": "echo prepared"
                ]
            ),
            taskID: "task-scripts",
            worldModel: HarnessWorldModel(),
            grantedPermissions: [.skillLookup]
        )
        _ = await registry.execute(
            HarnessToolCall(
                id: "skill-validate",
                name: "skill.script.validate",
                input: ["scriptID": "prepare-workspace", "validationPolicy": "static safe subset"]
            ),
            taskID: "task-scripts",
            worldModel: HarnessWorldModel(),
            grantedPermissions: [.skillLookup]
        )
        let executedSkillScript = await registry.execute(
            HarnessToolCall(
                id: "skill-execute",
                name: "skill.script.execute",
                input: ["scriptID": "prepare-workspace"]
            ),
            taskID: "task-scripts",
            worldModel: HarnessWorldModel(),
            grantedPermissions: [.appControl, .input]
        )

        #expect(generatedAppleScript.metadata["validationStatus"] == HarnessSkillScriptValidationStatus.pendingValidation.rawValue)
        #expect(validatedAppleScript.metadata["validationStatus"] == HarnessSkillScriptValidationStatus.validated.rawValue)
        #expect(executedAppleScript.status == .succeeded)
        #expect(executedAppleScript.observations.facts["script.executed.output"] == "ok")
        #expect(generatedSkillScript.metadata["scriptArtifactID"] == "prepare-workspace")
        #expect(executedSkillScript.status == .succeeded)
        #expect(executedSkillScript.observations.facts["script.executed.output"] == "prepared")
    }

    @Test
    func applicationLearningFlowSavesSearchableSkillPackWithValidatedScripts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("donkey-learned-skill-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let skillRegistry = HarnessSkillRegistry()
        let scriptStore = HarnessGeneratedScriptStore()
        let learningStore = HarnessApplicationLearningStore()
        let registry = BuiltInHarnessToolCatalog.registryWithBuiltInExecutors(
            services: HarnessBuiltInToolServices(
                skillRegistry: skillRegistry,
                generatedScripts: scriptStore,
                applicationLearningStore: learningStore,
                applicationSkillPackWriter: HarnessApplicationSkillPackWriter(rootDirectory: root)
            )
        )
        let baseWorld = HarnessWorldModel(
            focusedApp: "DraftPad",
            focusedWindowTitle: "DraftPad - Untitled",
            visibleText: ["main": "Untitled document"],
            elements: [
                HarnessWorldElement(
                    id: "toolbar-new",
                    label: "New Document",
                    role: "AXButton",
                    isActionEligible: true,
                    actions: ["AXPress"],
                    metadata: ["scope": "toolbar"]
                ),
                HarnessWorldElement(
                    id: "editor",
                    label: "Editor",
                    role: "AXTextArea",
                    isActionEligible: true,
                    actions: ["AXSetValue"],
                    metadata: ["scope": "main"]
                )
            ],
            facts: [
                "screen.observe.screenshotArtifactURL": "file:///tmp/draftpad-main.png",
                "screen.observe.accessibilityArtifactURL": "file:///tmp/draftpad-main-accessibility.json"
            ]
        )

        let started = await registry.execute(
            HarnessToolCall(
                id: "learn-start",
                name: "application.learning.start",
                input: [
                    "appName": "DraftPad",
                    "bundleIdentifier": "com.example.DraftPad",
                    "goal": "Learn safe writing workflows.",
                    "skillID": "learned-draftpad"
                ]
            ),
            taskID: "task-learn-draftpad",
            worldModel: baseWorld,
            grantedPermissions: [.appLookup, .skillLookup]
        )
        let capturedMain = await registry.execute(
            HarnessToolCall(
                id: "learn-capture-main",
                name: "application.learning.captureState",
                input: [
                    "draftID": "task-learn-draftpad-learned-draftpad",
                    "stateID": "main-editor",
                    "title": "Main editor",
                    "navigationPath": "launch",
                    "changedFromPrevious": "Initial focused window",
                    "safetyNotes": "Typing requires explicit user content"
                ]
            ),
            taskID: "task-learn-draftpad",
            worldModel: baseWorld,
            grantedPermissions: [.screenCapture, .accessibility]
        )
        let menuWorld = HarnessWorldModel(
            focusedApp: "DraftPad",
            focusedWindowTitle: "DraftPad - File Menu",
            visibleText: ["menu": "New Open Save Export"],
            elements: [
                HarnessWorldElement(
                    id: "file-new",
                    label: "New",
                    role: "AXMenuItem",
                    isActionEligible: true,
                    actions: ["AXPress"]
                )
            ],
            facts: [
                "screen.observe.screenshotArtifactURL": "file:///tmp/draftpad-menu.png",
                "screen.observe.accessibilityArtifactURL": "file:///tmp/draftpad-menu-accessibility.json"
            ]
        )
        let capturedMenu = await registry.execute(
            HarnessToolCall(
                id: "learn-capture-menu",
                name: "application.learning.captureState",
                input: [
                    "draftID": "task-learn-draftpad-learned-draftpad",
                    "stateID": "file-menu",
                    "title": "File menu",
                    "navigationPath": "launch, menu:file",
                    "changedFromPrevious": "Opened File menu"
                ]
            ),
            taskID: "task-learn-draftpad",
            worldModel: menuWorld,
            grantedPermissions: [.screenCapture, .accessibility]
        )
        let proposedExploration = await registry.execute(
            HarnessToolCall(
                id: "learn-propose-exploration",
                name: "application.learning.proposeExploration",
                input: ["draftID": "task-learn-draftpad-learned-draftpad"]
            ),
            taskID: "task-learn-draftpad",
            worldModel: menuWorld,
            grantedPermissions: [.accessibility]
        )
        let generatedScript = await registry.execute(
            HarnessToolCall(
                id: "learn-script-generate",
                name: "skill.script.generate",
                input: [
                    "skillID": "learned-draftpad",
                    "scriptID": "focus-editor",
                    "language": "applescript",
                    "purpose": "Focus the DraftPad editor",
                    "scriptSource": #"tell application "DraftPad" to activate"#
                ]
            ),
            taskID: "task-learn-draftpad",
            worldModel: baseWorld,
            grantedPermissions: [.skillLookup]
        )
        let validatedScript = await registry.execute(
            HarnessToolCall(
                id: "learn-script-validate",
                name: "skill.script.validate",
                input: [
                    "scriptID": "focus-editor",
                    "validationPolicy": "activate-only app automation"
                ]
            ),
            taskID: "task-learn-draftpad",
            worldModel: baseWorld,
            grantedPermissions: [.skillLookup]
        )
        let distilled = await registry.execute(
            HarnessToolCall(
                id: "learn-distill",
                name: "application.learning.distill",
                input: [
                    "draftID": "task-learn-draftpad-learned-draftpad",
                    "workflowName": "Write a draft",
                    "workflowSummary": "Focus the editor, enter user-provided text, and verify the text is visible.",
                    "verificationCriteria": "editor visible, text visible",
                    "scriptIDs": "focus-editor"
                ]
            ),
            taskID: "task-learn-draftpad",
            worldModel: menuWorld,
            grantedPermissions: [.skillLookup]
        )
        let saved = await registry.execute(
            HarnessToolCall(
                id: "learn-save",
                name: "application.learning.saveSkillPack",
                input: ["draftID": "task-learn-draftpad-learned-draftpad"]
            ),
            taskID: "task-learn-draftpad",
            worldModel: menuWorld,
            grantedPermissions: [.skillLookup]
        )

        #expect(started.status == .succeeded)
        #expect(capturedMain.metadata["observationCount"] == "1")
        #expect(capturedMenu.metadata["observationCount"] == "2")
        #expect(proposedExploration.metadata["safeCandidates"] == "file-new:press")
        #expect(generatedScript.metadata["validationStatus"] == HarnessSkillScriptValidationStatus.pendingValidation.rawValue)
        #expect(validatedScript.metadata["validationStatus"] == HarnessSkillScriptValidationStatus.validated.rawValue)
        #expect(distilled.metadata["workflowCount"] == "1")
        #expect(saved.status == .succeeded)
        #expect(saved.metadata["skillID"] == "learned-draftpad")
        #expect(saved.metadata["scriptCount"] == "1")

        let savedDirectory = root.appendingPathComponent("learned-draftpad", isDirectory: true)
        let skillMarkdown = try String(
            contentsOf: savedDirectory.appendingPathComponent("SKILL.md"),
            encoding: .utf8
        )
        let profileData = try Data(contentsOf: savedDirectory.appendingPathComponent("app-profile.json"))
        let profile = try JSONDecoder().decode(HarnessApplicationProfile.self, from: profileData)
        let scriptSource = try String(
            contentsOf: savedDirectory.appendingPathComponent("scripts/focus-editor.applescript"),
            encoding: .utf8
        )
        let results = await skillRegistry.search(query: "DraftPad learned app")

        #expect(skillMarkdown.contains("DraftPad Learned Application"))
        #expect(profile.observations.map(\.id) == ["main-editor", "file-menu"])
        #expect(profile.generatedScriptIDs == ["focus-editor"])
        #expect(scriptSource.contains("DraftPad"))
        #expect(results.first?.descriptor.id == "learned-draftpad")
        #expect(results.first?.descriptor.scripts.first?.validationStatus == .validated)
    }

    @Test
    func missingPermissionStopsTaskAndStoresContinuation() async {
        let coordinator = HarnessTaskCoordinator()
        let runtime = GenericHarnessRuntime(
            coordinator: coordinator,
            registry: BuiltInHarnessToolCatalog.registryWithBuiltInExecutors()
        )
        let task = await coordinator.createTask(
            id: "task-permission",
            threadID: "thread-1",
            goal: "click a button"
        )

        let call = HarnessToolCall(
            id: "call-click",
            name: "element.perform",
            input: ["elementID": "button-1", "action": "press"]
        )
        let result = await runtime.executeToolCall(taskID: task.id, call: call)

        #expect(result?.stoppedForGate == true)
        #expect(result?.task.status == .waitingForPermission)
        #expect(result?.task.pendingContinuation?.stage == .permissionGate)
        #expect(result?.task.pendingContinuation?.pendingToolCall?.id == "call-click")
        #expect(result?.task.pendingContinuation?.missingPermissions == [.accessibility, .input])
        #expect(result?.toolResult?.status == .permissionDenied)
    }

    @Test
    func permissionApprovalResumesFromCheckpointAndAllowsToolExecution() async {
        let coordinator = HarnessTaskCoordinator()
        let runtime = GenericHarnessRuntime(
            coordinator: coordinator,
            registry: BuiltInHarnessToolCatalog.registryWithBuiltInExecutors()
        )
        let task = await coordinator.createTask(
            id: "task-resume-permission",
            threadID: "thread-1",
            goal: "click a button"
        )
        let call = HarnessToolCall(
            id: "call-click",
            name: "element.perform",
            input: ["elementID": "button-1", "action": "press"]
        )

        _ = await runtime.executeToolCall(taskID: task.id, call: call)
        let resumed = await coordinator.grantPermissions(
            taskID: task.id,
            permissions: [.accessibility, .input]
        )
        let executed = await runtime.executeToolCall(taskID: task.id, call: call)

        #expect(resumed?.status == .resuming)
        #expect(resumed?.pendingContinuation == nil)
        #expect(executed?.stoppedForGate == false)
        #expect(executed?.toolResult?.status == .succeeded)
        #expect(executed?.task.worldModel.facts["lastAcceptedTool"] == "element.perform")
        #expect(executed?.task.toolHistory.count == 1)
    }

    @Test
    func clarificationStopsTaskAndUserResponseResumesIt() async {
        let coordinator = HarnessTaskCoordinator()
        let runtime = GenericHarnessRuntime(
            coordinator: coordinator,
            registry: BuiltInHarnessToolCatalog.registryWithBuiltInExecutors()
        )
        let task = await coordinator.createTask(
            id: "task-clarify",
            threadID: "thread-1",
            goal: "send a message",
            grantedPermissions: [.userPrompt]
        )
        let call = HarnessToolCall(
            id: "call-clarify",
            name: "user.clarify",
            input: ["question": "Which Alex should I message?"]
        )

        let stopped = await runtime.executeToolCall(taskID: task.id, call: call)
        let resumed = await coordinator.provideUserResponse(
            taskID: task.id,
            response: "Alex Chen"
        )

        #expect(stopped?.task.status == .waitingForUser)
        #expect(stopped?.task.pendingContinuation?.question == "Which Alex should I message?")
        #expect(stopped?.toolResult?.status == .waitingForUser)
        #expect(resumed?.status == .resuming)
        #expect(resumed?.pendingContinuation == nil)
        #expect(resumed?.worldModel.facts["lastUserClarification"] == "Alex Chen")
    }

    @Test
    func multipleTasksKeepSeparateWorldModelsPlansAndToolHistory() async {
        let coordinator = HarnessTaskCoordinator()
        let runtime = GenericHarnessRuntime(
            coordinator: coordinator,
            registry: BuiltInHarnessToolCatalog.registryWithBuiltInExecutors()
        )
        let first = await coordinator.createTask(
            id: "task-a",
            threadID: "thread-a",
            goal: "search apps",
            grantedPermissions: [.appLookup]
        )
        let second = await coordinator.createTask(
            id: "task-b",
            threadID: "thread-b",
            goal: "observe screen",
            grantedPermissions: [.screenCapture]
        )

        _ = await runtime.executeToolCall(
            taskID: first.id,
            call: HarnessToolCall(id: "call-a", name: "app.search", input: ["query": "Calendar"])
        )
        _ = await runtime.executeToolCall(
            taskID: second.id,
            call: HarnessToolCall(id: "call-b", name: "screen.observe")
        )

        let updatedFirst = await coordinator.task(id: first.id)
        let updatedSecond = await coordinator.task(id: second.id)
        let active = await coordinator.activeTasks()

        #expect(active.map(\.id).contains("task-a"))
        #expect(active.map(\.id).contains("task-b"))
        #expect(updatedFirst?.worldModel.facts["lastAcceptedTool"] == "app.search")
        #expect(updatedSecond?.worldModel.facts["lastAcceptedTool"] == "screen.observe")
        #expect(updatedFirst?.toolHistory.first?.call.id == "call-a")
        #expect(updatedSecond?.toolHistory.first?.call.id == "call-b")
    }

    @Test
    func interruptChangesCourseWithoutLosingTaskIdentity() async {
        let coordinator = HarnessTaskCoordinator()
        let task = await coordinator.createTask(
            id: "task-interrupt",
            threadID: "thread-1",
            goal: "draft an email"
        )

        let interrupted = await coordinator.interrupt(
            taskID: task.id,
            newGoal: "draft a shorter email",
            turn: AppHarnessTurn(text: "actually make it short", source: .followUp, taskID: task.id, isFollowUp: true)
        )

        #expect(interrupted?.id == task.id)
        #expect(interrupted?.status == .interrupted)
        #expect(interrupted?.goal == "draft a shorter email")
        #expect(interrupted?.plan == nil)
        #expect(interrupted?.pendingContinuation?.metadata["newGoal"] == "draft a shorter email")
        #expect(interrupted?.context.turn?.text == "actually make it short")
    }

    @Test
    func plannedLoopExecutesOneToolAtATime() async {
        let coordinator = HarnessTaskCoordinator()
        let runtime = GenericHarnessRuntime(
            coordinator: coordinator,
            registry: BuiltInHarnessToolCatalog.registryWithBuiltInExecutors()
        )
        let task = await coordinator.createTask(
            id: "task-loop",
            threadID: "thread-1",
            goal: "observe then verify",
            grantedPermissions: [.screenCapture, .verification]
        )
        let plan = HarnessPlan(
            goal: "observe then verify",
            steps: [
                HarnessPlanStep(
                    id: "observe",
                    summary: "Observe screen",
                    toolCall: HarnessToolCall(id: "observe-call", name: "screen.observe")
                ),
                HarnessPlanStep(
                    id: "verify",
                    summary: "Verify state",
                    toolCall: HarnessToolCall(id: "verify-call", name: "state.verify")
                )
            ]
        )
        _ = await coordinator.updatePlan(taskID: task.id, plan: plan)

        let first = await runtime.executeNextPlannedStep(taskID: task.id)
        let second = await runtime.executeNextPlannedStep(taskID: task.id)

        #expect(first?.toolResult?.toolName == "screen.observe")
        #expect(second?.toolResult?.toolName == "state.verify")
        #expect(second?.task.toolHistory.map(\.call.id) == ["observe-call", "verify-call"])
    }

    @Test
    func lifecycleToolsMutateTaskStatusThroughGenericRuntime() async {
        let coordinator = HarnessTaskCoordinator()
        let runtime = GenericHarnessRuntime(
            coordinator: coordinator,
            registry: BuiltInHarnessToolCatalog.registryWithBuiltInExecutors()
        )
        let task = await coordinator.createTask(
            id: "task-lifecycle-tools",
            threadID: "thread-lifecycle-tools",
            goal: "pause and resume",
            grantedPermissions: [.lifecycle]
        )

        let paused = await runtime.executeToolCall(
            taskID: task.id,
            call: HarnessToolCall(id: "pause-call", name: "run.pause", input: ["reason": "Need a break"])
        )
        let resumed = await runtime.executeToolCall(
            taskID: task.id,
            call: HarnessToolCall(id: "resume-call", name: "run.resume", input: ["reason": "Continue"])
        )
        let completed = await runtime.executeToolCall(
            taskID: task.id,
            call: HarnessToolCall(id: "complete-call", name: "run.complete", input: ["reason": "Done"])
        )

        #expect(paused?.task.status == .paused)
        #expect(resumed?.task.status == .resuming)
        #expect(completed?.task.status == .completed)
        #expect(completed?.task.toolHistory.map(\.call.name) == ["run.pause", "run.resume", "run.complete"])
    }

    @Test
    func pointerPromptLifecycleMirrorsThreadAndCreatesGenericTask() async {
        let store = InMemoryHarnessThreadStore()
        let coordinator = HarnessTaskCoordinator()
        let lifecycle = AppHarnessGenericLifecycle(
            threadStore: store,
            coordinator: coordinator
        )
        let task = PointerPromptNotchTask(
            id: "pointer-task-1",
            title: "Open Calendar",
            detail: "Running",
            commandText: "open calendar",
            status: .running,
            accentIndex: 0
        )
        let request = AppHarnessTurnRequest(
            turn: AppHarnessTurn(
                id: "turn-1",
                text: "open calendar",
                source: .typedPrompt,
                taskID: task.id
            ),
            recentEvents: [
                PointerPromptTaskEvent(
                    id: "event-1",
                    taskID: task.id,
                    role: .user,
                    text: "open calendar",
                    sequence: 0
                )
            ],
            assets: [
                PointerPromptTaskAsset(
                    id: "asset-1",
                    taskID: task.id,
                    source: .userUploaded,
                    displayName: "brief.txt",
                    contentType: "text/plain",
                    urlString: "file:///tmp/brief.txt"
                )
            ],
            policy: ["localInput": "guarded"]
        )

        let prepared = await lifecycle.preparePointerPromptTurn(
            request: request,
            pointerTask: task,
            traceID: "trace-1",
            availableToolNames: [AppHarnessGenericLifecycleToolNames.localAppRun],
            grantedPermissions: [.verification]
        )

        #expect(prepared.thread.id == task.id)
        #expect(prepared.thread.activeTaskIDs == [task.id])
        #expect(prepared.task.id == task.id)
        #expect(prepared.task.context.turn?.id == "turn-1")
        #expect(prepared.task.context.availableToolNames == [AppHarnessGenericLifecycleToolNames.localAppRun])
        #expect(prepared.task.grantedPermissions == [.verification])
        #expect(prepared.compactedContext.events.map(\.id) == ["event-1"])
        #expect(prepared.compactedContext.assets.map(\.id) == ["asset-1"])
        #expect(prepared.compactedContext.promptText.contains("Current turn: open calendar"))
    }

    @Test
    func pointerPromptLifecyclePlansLocalRunAndStopsForExecutorUserGate() async {
        let store = InMemoryHarnessThreadStore()
        let coordinator = HarnessTaskCoordinator()
        let lifecycle = AppHarnessGenericLifecycle(threadStore: store, coordinator: coordinator)
        let task = await coordinator.createTask(
            id: "pointer-task-gate",
            threadID: "thread-gate",
            goal: "send a message",
            grantedPermissions: [.verification]
        )
        let intent = TaskIntent(
            intentID: "intent-1",
            taskType: "local_app_interaction",
            targetApp: LocalAppTarget(appName: "Messages"),
            entities: ["recipient": "Alex"],
            normalizedEntities: ["recipient": "Alex"],
            confidence: 0.8,
            parserSource: .onlineModel
        )
        let resolution = LocalAppTaskCatalogResolution(
            status: .needsConfirmation,
            intent: intent,
            metadata: ["reason": "missing message"]
        )
        _ = await lifecycle.planLocalTaskRun(
            taskID: task.id,
            resolution: resolution,
            fallbackGoal: "send a message",
            traceID: "trace-gate"
        )
        let registry = BuiltInHarnessToolCatalog.registryWithBuiltInExecutors()
        await registry.register(
            HarnessTool(descriptor: AppHarnessGenericLifecycle.localTaskRunDescriptor()) { context in
                HarnessToolResult(
                    callID: context.call.id,
                    toolName: context.call.name,
                    status: .waitingForUser,
                    summary: "Need the message text.",
                    question: "What should I send?"
                )
            }
        )
        let runtime = GenericHarnessRuntime(
            coordinator: coordinator,
            registry: registry
        )

        let result = await runtime.executeNextPlannedStep(taskID: task.id)

        #expect(result?.stoppedForGate == true)
        #expect(result?.task.status == .waitingForUser)
        #expect(result?.task.pendingContinuation?.question == "What should I send?")
        #expect(result?.task.pendingContinuation?.pendingToolCall?.name == AppHarnessGenericLifecycleToolNames.localAppRun)
        #expect(result?.toolResult?.status == .waitingForUser)
    }

    @Test
    func pointerPromptLifecycleUsesHostedGenericPlanningMetadata() async {
        let store = InMemoryHarnessThreadStore()
        let coordinator = HarnessTaskCoordinator()
        let lifecycle = AppHarnessGenericLifecycle(threadStore: store, coordinator: coordinator)
        let task = await coordinator.createTask(
            id: "pointer-task-hosted-plan",
            threadID: "thread-hosted-plan",
            goal: "open a site"
        )
        let intent = TaskIntent(
            intentID: "intent-hosted-plan",
            taskType: "local_app_interaction",
            targetApp: LocalAppTarget(appName: "Safari"),
            entities: ["query": "https://example.org"],
            normalizedEntities: ["query": "https://example.org"],
            confidence: 0.92,
            parserSource: .onlineModel,
            metadata: [
                "genericHarness.schemaVersion": "generic_harness_planning",
                "genericHarness.intent.goal": "open example.org in Safari",
                "genericHarness.ambiguity.class": "safe",
                "genericHarness.risk.level": "low",
                "genericHarness.shouldAskBeforeActing": "false",
                "genericHarness.missingInformationJSON": "[]",
                "genericHarness.planStepsJSON": """
                [{"controlID":"addressBar","expectedObservation":"Address bar is focused.","focusKey":"Command+L","id":"focus-address","inputEntity":"","summary":"Focus the browser address bar.","toolName":"ui.focusAddressBar"},{"controlID":"addressBar","expectedObservation":"Requested URL is entered.","focusKey":"","id":"enter-url","inputEntity":"query","summary":"Enter the requested URL.","toolName":"ui.setText"}]
                """,
                "genericHarness.verificationCriteriaJSON": #"["The requested website navigation is attempted."]"#,
                "genericHarness.fallbacksJSON": #"["Ask before navigating if the URL is ambiguous."]"#,
                "genericHarness.clarification.questionsJSON": #"["Which URL should I open?"]"#,
                "genericHarness.clarification.policy": "Ask only if the requested URL is missing."
            ]
        )
        let resolution = LocalAppTaskCatalogResolution(
            status: .resolved,
            intent: intent
        )

        _ = await lifecycle.planLocalTaskRun(
            taskID: task.id,
            resolution: resolution,
            fallbackGoal: "open a site",
            traceID: "trace-hosted-plan"
        )
        let planned = await coordinator.task(id: task.id)

        #expect(planned?.intent?.goal == "open example.org in Safari")
        #expect(planned?.intent?.riskLevel == .low)
        #expect(planned?.plan?.steps.first?.id == "model-focus-address")
        #expect(planned?.plan?.steps.first?.toolCall == nil)
        #expect(planned?.plan?.steps.first?.metadata["toolName"] == "ui.focusAddressBar")
        #expect(planned?.plan?.steps.contains { $0.id == "run-local-app-task" } == true)
        #expect(planned?.plan?.successCriteria == ["The requested website navigation is attempted."])
        #expect(planned?.plan?.fallbackPolicy == ["Ask before navigating if the URL is ambiguous."])
        #expect(planned?.plan?.clarificationPolicy == [
            "Which URL should I open?",
            "Ask only if the requested URL is missing."
        ])
        #expect(planned?.plan?.metadata["modelPlan.schemaVersion"] == "generic_harness_planning")
        #expect(planned?.plan?.metadata["modelPlan.stepCount"] == "2")
    }

    @Test
    func pointerPromptLifecycleConsumesPendingContinuationOnFollowUpTurn() async {
        let store = InMemoryHarnessThreadStore()
        let coordinator = HarnessTaskCoordinator()
        let lifecycle = AppHarnessGenericLifecycle(threadStore: store, coordinator: coordinator)
        let task = await coordinator.createTask(
            id: "pointer-task-answer",
            threadID: "pointer-task-answer",
            goal: "send a message"
        )
        _ = await coordinator.waitForUser(
            taskID: task.id,
            question: "What should I send?",
            pendingToolCall: HarnessToolCall(
                id: "pending-run",
                name: AppHarnessGenericLifecycleToolNames.localAppRun
            )
        )
        let pointerTask = PointerPromptNotchTask(
            id: task.id,
            title: "Send Message",
            detail: "Waiting",
            status: .waitingForClarification,
            accentIndex: 0
        )
        let request = AppHarnessTurnRequest(
            turn: AppHarnessTurn(
                id: "turn-answer",
                text: "Tell Alex I am running late",
                source: .followUp,
                taskID: task.id,
                isFollowUp: true
            )
        )

        let prepared = await lifecycle.preparePointerPromptTurn(
            request: request,
            pointerTask: pointerTask,
            traceID: "trace-answer",
            availableToolNames: [AppHarnessGenericLifecycleToolNames.localAppRun]
        )

        #expect(prepared.task.status == .resuming)
        #expect(prepared.task.pendingContinuation == nil)
        #expect(prepared.task.worldModel.facts["lastUserClarification"] == "Tell Alex I am running late")
        #expect(prepared.compactedContext.activeTasks.first?.status == .resuming)
    }

    @Test
    func pointerPromptLifecyclePauseResumeUsesGenericTaskState() async {
        let store = InMemoryHarnessThreadStore()
        let coordinator = HarnessTaskCoordinator()
        let lifecycle = AppHarnessGenericLifecycle(threadStore: store, coordinator: coordinator)
        let task = await coordinator.createTask(
            id: "pointer-task-pause",
            threadID: "thread-pause",
            goal: "open an app"
        )

        let paused = await lifecycle.pauseTask(
            taskID: task.id,
            reason: "User paused from notch"
        )
        let resumed = await lifecycle.resumeTask(
            taskID: task.id,
            reason: "User resumed from notch"
        )

        #expect(paused?.status == .paused)
        #expect(resumed?.status == .resuming)
        #expect(resumed?.pendingContinuation == nil)
    }

    @Test
    func pointerPromptLifecyclePlansRecoveryAsGenericToolStep() async {
        let store = InMemoryHarnessThreadStore()
        let coordinator = HarnessTaskCoordinator()
        let lifecycle = AppHarnessGenericLifecycle(threadStore: store, coordinator: coordinator)
        let task = await coordinator.createTask(
            id: "pointer-task-recover",
            threadID: "thread-recover",
            goal: "open an app",
            grantedPermissions: [.lifecycle]
        )
        _ = await lifecycle.planRecovery(
            taskID: task.id,
            reason: "App not found",
            traceID: "trace-recover"
        )
        let runtime = GenericHarnessRuntime(
            coordinator: coordinator,
            registry: BuiltInHarnessToolCatalog.registryWithBuiltInExecutors()
        )

        let result = await runtime.executeNextPlannedStep(taskID: task.id)

        #expect(result?.toolResult?.toolName == "run.recover")
        #expect(result?.toolResult?.status == .succeeded)
        #expect(result?.task.toolHistory.map(\.call.name) == ["run.recover"])
        #expect(result?.task.plan?.metadata["planner"] == "genericHarnessPointerPromptRecovery")
    }

    @Test
    func threadStorePersistsThreadsEventsAndAssetsByThreadID() async {
        let store = InMemoryHarnessThreadStore()
        let thread = HarnessThread(
            id: "thread-1",
            title: "Plan a desktop task",
            activeTaskIDs: ["task-1"]
        )
        await store.upsertThread(thread)
        await store.appendEvent(
            HarnessThreadEvent(
                threadID: thread.id,
                taskID: "task-1",
                role: .user,
                text: "learn this app",
                sequence: 1
            )
        )
        await store.appendAsset(
            HarnessThreadAsset(
                threadID: thread.id,
                taskID: "task-1",
                displayName: "screen.png",
                contentType: "image/png",
                urlString: "file:///tmp/screen.png"
            )
        )

        let loadedThread = await store.thread(id: thread.id)
        let events = await store.events(threadID: thread.id)
        let assets = await store.assets(threadID: thread.id)
        await store.upsertTaskSnapshot(
            HarnessTaskState(
                id: "task-1",
                threadID: thread.id,
                goal: "learn this app",
                status: .completed
            )
        )
        let completedThread = await store.thread(id: thread.id)

        #expect(loadedThread?.title == "Plan a desktop task")
        #expect(events.map(\.text) == ["learn this app"])
        #expect(assets.first?.displayName == "screen.png")
        #expect(completedThread?.activeTaskIDs == [])
        #expect(completedThread?.status == .completed)
    }

    @Test
    func fileThreadStorePersistsGenericThreadTaskAndCompactionState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("donkey-harness-store-\(UUID().uuidString)", isDirectory: true)
        let storeURL = root.appendingPathComponent("store.json")
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let store = FileHarnessThreadStore(storeURL: storeURL)
        let thread = HarnessThread(
            id: "thread-durable",
            title: "Learn an app",
            activeTaskIDs: ["task-durable"],
            metadata: ["source": "test"]
        )
        await store.upsertThread(thread)
        await store.appendEvent(
            HarnessThreadEvent(
                id: "event-summary",
                threadID: thread.id,
                taskID: "task-durable",
                role: .summary,
                text: "User wants app learning.",
                sequence: 0
            )
        )
        await store.appendAsset(
            HarnessThreadAsset(
                id: "asset-screen",
                threadID: thread.id,
                taskID: "task-durable",
                displayName: "screen.png",
                contentType: "image/png",
                urlString: "file:///tmp/screen.png"
            )
        )

        let coordinator = HarnessTaskCoordinator(threadStore: store)
        _ = await coordinator.createTask(
            id: "task-durable",
            threadID: thread.id,
            goal: "learn this application",
            grantedPermissions: [.screenCapture]
        )
        _ = await coordinator.waitForUser(
            taskID: "task-durable",
            question: "Which workflow should I learn first?",
            pendingToolCall: HarnessToolCall(id: "pending-clarify", name: "user.clarify")
        )
        await store.appendCompactionSnapshot(
            HarnessCompactionSnapshot(
                id: "compact-1",
                threadID: thread.id,
                taskIDs: ["task-durable"],
                eventIDs: ["event-summary"],
                assetIDs: ["asset-screen"],
                promptCharacterCount: 240,
                records: [
                    AppHarnessContextCompactionRecord(
                        itemKind: .recentEvent,
                        originalCount: 3,
                        includedCount: 1,
                        droppedCount: 2
                    )
                ],
                metadata: ["compactor": "smart-priority-v1"]
            )
        )

        let reloadedStore = FileHarnessThreadStore(storeURL: storeURL)
        let reloadedCoordinator = HarnessTaskCoordinator(threadStore: reloadedStore)
        let reloadedThread = await reloadedStore.thread(id: thread.id)
        let reloadedEvents = await reloadedStore.events(threadID: thread.id)
        let reloadedAssets = await reloadedStore.assets(threadID: thread.id)
        let reloadedTask = await reloadedCoordinator.task(id: "task-durable")
        let reloadedTaskEvents = await reloadedCoordinator.events(taskID: "task-durable")
        let reloadedCompactions = await reloadedStore.compactionSnapshots(threadID: thread.id, limit: 1)

        #expect(reloadedThread?.activeTaskIDs == ["task-durable"])
        #expect(reloadedEvents.map(\.role) == [.summary])
        #expect(reloadedAssets.first?.displayName == "screen.png")
        #expect(reloadedTask?.status == .waitingForUser)
        #expect(reloadedTask?.pendingContinuation?.question == "Which workflow should I learn first?")
        #expect(reloadedTask?.grantedPermissions == [.screenCapture])
        #expect(reloadedTaskEvents.map(\.summary) == ["Task created", "Task needs user clarification"])
        #expect(reloadedCompactions.first?.metadata["compactor"] == "smart-priority-v1")
        #expect(reloadedCompactions.first?.records.first?.droppedCount == 2)
    }

    @Test
    func smartCompactionPreservesPinnedSummariesRecentEventsAndWaitingTaskState() async {
        let thread = HarnessThread(id: "thread-compact", title: "Long task")
        let events = (1...20).map { index in
            HarnessThreadEvent(
                id: "event-\(index)",
                threadID: thread.id,
                role: index == 2 ? .summary : (index.isMultiple(of: 5) ? .tool : .user),
                text: index == 20 ? String(repeating: "latest ", count: 200) : "event \(index)",
                sequence: index,
                isPinned: index == 1
            )
        }
        let waitingTask = HarnessTaskState(
            id: "task-waiting",
            threadID: thread.id,
            goal: "learn app",
            status: .waitingForUser,
            pendingContinuation: HarnessPendingContinuation(
                stage: .clarification,
                reason: "Need scope",
                question: "Which part of the app should I learn first?"
            )
        )
        let completedTask = HarnessTaskState(
            id: "task-complete",
            threadID: thread.id,
            goal: "old task",
            status: .completed
        )
        let compactor = HarnessThreadCompactor(
            policy: HarnessCompactionPolicy(
                maxEvents: 4,
                maxPinnedEvents: 2,
                maxToolEvents: 1,
                maxAssets: 1,
                maxEventCharacters: 40,
                maxPromptCharacters: 1_200
            )
        )

        let compacted = compactor.compact(
            thread: thread,
            currentTurn: AppHarnessTurn(text: "continue", source: .followUp, taskID: waitingTask.id, isFollowUp: true),
            events: events,
            assets: [
                HarnessThreadAsset(threadID: thread.id, displayName: "old.png", contentType: "image/png", urlString: "file:///tmp/old.png"),
                HarnessThreadAsset(threadID: thread.id, displayName: "new.png", contentType: "image/png", urlString: "file:///tmp/new.png")
            ],
            activeTasks: [waitingTask, completedTask]
        )

        #expect(compacted.events.contains { $0.id == "event-1" })
        #expect(compacted.events.contains { $0.role == .summary })
        #expect(compacted.events.contains { $0.id == "event-20" })
        #expect(compacted.events.first(where: { $0.id == "event-20" })?.text.count == 40)
        #expect(compacted.assets.count == 1)
        #expect(compacted.activeTasks.map(\.id) == ["task-waiting"])
        #expect(compacted.promptText.contains("waitingForUser"))
        #expect(compacted.promptText.contains("Which part of the app should I learn first?"))
        #expect(compacted.metadata["compactor"] == "smart-priority-v1")
        #expect(compacted.compactionRecords.contains { $0.itemKind == .recentEvent && $0.droppedCount > 0 })
    }
}
