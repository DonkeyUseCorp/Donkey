import DonkeyContracts
@testable import DonkeyRuntime
import Foundation
import Testing

@Suite
struct LocalAppTaskTests {
    @Test
    func structuredWeatherIntentCarriesModelSelectedEntities() throws {
        let intent = weatherIntent(rawCity: "SF", city: "San Francisco")

        #expect(intent.taskType == "weather_lookup")
        #expect(intent.targetApp.appName == "Weather")
        #expect(intent.targetApp.bundleIdentifier == "com.apple.weather")
        #expect(intent.entities["city"] == "SF")
        #expect(intent.normalizedEntities["city"] == "San Francisco")
        #expect(intent.confidence == 0.93)
        #expect(intent.parserSource == .localModel)
        #expect(intent.needsConfirmation == false)
        #expect(intent.metadata["catalogEntry"] == "built-in-weather-lookup")
    }

    @Test
    func catalogResolvesGenericAppOpenIntentFromModelSelectedLocalItem() throws {
        let catalog = LocalAppTaskCatalog(
            taskDefinitions: BuiltInLocalAppTaskDefinitions.benchmarkFixtures,
            availabilityProvider: StaticLocalAppAvailabilityProvider(
                installedBundleIdentifiers: ["com.figma.Desktop"],
                installedApplicationNames: ["Figma": "com.figma.Desktop"],
                installedLocalItemNames: ["Quarterly Plan.pdf": "file"]
            )
        )
        let resolution = catalog.resolve(intent: TaskIntent(
            intentID: "app_open-figma",
            taskType: "app_open",
            targetApp: LocalAppTarget(appName: "Local Item", metadata: ["dynamicTarget": "true"]),
            entities: ["appName": "figma"],
            normalizedEntities: ["appName": "Figma"],
            confidence: 0.91,
            parserSource: .localModel,
            metadata: ["requestedItemName": "figma"]
        ))
        let intent = try #require(resolution.intent)

        #expect(resolution.status == .resolved)
        #expect(intent.taskType == "app_open")
        #expect(intent.targetApp.appName == "Figma")
        #expect(intent.targetApp.bundleIdentifier == "com.figma.Desktop")
        #expect(intent.normalizedEntities["appName"] == "Figma")
        #expect(intent.metadata["catalogEntry"] == "generic-app-open")

        let fileResolution = catalog.resolve(intent: TaskIntent(
            intentID: "app_open-quarterly-plan",
            taskType: "app_open",
            targetApp: LocalAppTarget(appName: "Local Item", metadata: ["dynamicTarget": "true"]),
            entities: ["appName": "quarterly plan.pdf"],
            normalizedEntities: ["appName": "Quarterly Plan.pdf"],
            confidence: 0.88,
            parserSource: .localModel,
            metadata: ["requestedItemName": "quarterly plan.pdf"]
        ))
        #expect(fileResolution.status == .resolved)
        let fileDefinition = try #require(fileResolution.definition)
        #expect(LocalAppTaskVerificationPolicy.mode(for: fileDefinition) == .openedLocalItem)
        #expect(fileResolution.metadata["itemKind"] == "file")
    }

    @Test
    func lowConfidenceModelIntentAsksForConfirmationBeforeLookupExecution() {
        let catalog = LocalAppTaskCatalog(
            taskDefinitions: BuiltInLocalAppTaskDefinitions.benchmarkFixtures,
            availabilityProvider: StaticLocalAppAvailabilityProvider(
                installedBundleIdentifiers: ["com.figma.Desktop"],
                installedApplicationNames: ["Figma": "com.figma.Desktop"]
            )
        )
        let resolution = catalog.resolve(intent: TaskIntent(
            intentID: "app_open-uncertain",
            taskType: "app_open",
            targetApp: LocalAppTarget(appName: "Local Item", metadata: ["dynamicTarget": "true"]),
            entities: ["appName": "figma"],
            normalizedEntities: ["appName": "Figma"],
            confidence: 0.4,
            parserSource: .localModel
        ))

        #expect(resolution.status == .needsConfirmation)
        #expect(resolution.metadata["reason"] == "lowConfidenceIntent")
    }

    @Test
    func structuredDocumentFormFillIntentBuildsReviewOnlyTask() throws {
        let intent = documentFormFillIntent()

        #expect(intent.taskType == "document_form_fill")
        #expect(intent.targetApp.appName == "Preview")
        #expect(intent.normalizedEntities["document"] == "current PDF")
        #expect(intent.normalizedEntities["dataSource"] == "provided data")
        #expect(intent.metadata["requiresDocumentContext"] == "true")

        let plan = LocalAppTaskAdapter(definition: BuiltInLocalAppTaskDefinitions.documentFormFill)
            .evidenceBackedActionPlan(for: intent)
        #expect(plan.canExecuteGuardedActions == false)
        #expect(plan.metadata["guardedLiveDefault"] == "reviewOnly")
        #expect(plan.steps.map(\.role).contains(.custom))
    }

    @Test
    func modelIntentCanRequestConfirmationForMissingRequiredEntity() throws {
        let intent = weatherIntent(rawCity: "", city: "", needsConfirmation: true)

        #expect(intent.taskType == "weather_lookup")
        #expect(intent.intentID == "weather_lookup-needs-city")
        #expect(intent.needsConfirmation == true)
        #expect(intent.metadata["missingEntity"] == "city")
    }

    @Test
    func catalogResolveCommandDoesNotParseWordsFromUserText() {
        let resolution = catalog().resolve(command: "open my calendar")

        #expect(resolution.status == .unsupportedCommand)
        #expect(resolution.metadata["reason"] == "modelIntentRequired")
    }

    @Test
    func genericAdapterBuildsLocalNavigationRequestForTargetApp() throws {
        let intent = weatherIntent(rawCity: "San Francisco", city: "San Francisco")
        let request = try #require(adapter().localNavigationFrameRequest(
            for: intent,
            traceID: "trace-local-app-task",
            maxFrameCount: 2
        ))

        #expect(request.targetID == "local-app-task-weather-lookup")
        #expect(request.traceID == "trace-local-app-task")
        #expect(request.maxFrameCount == 2)
        #expect(request.requestedBundleIdentifier == "com.apple.weather")
        #expect(request.requestedTitleContains == "Weather")
    }

    @Test
    func genericAdapterBuildsEvidenceBackedActionPlanAndGuardedKeyboardTemplates() throws {
        let intent = weatherIntent(rawCity: "SF", city: "San Francisco")
        let localAdapter = adapter()

        let plan = localAdapter.evidenceBackedActionPlan(for: intent)
        #expect(plan.terminalState == .needsUserReview)
        #expect(plan.canExecuteGuardedActions == false)
        #expect(plan.verificationConfidence == 0)
        #expect(plan.steps.map(\.role) == [
            .parseIntent,
            .launchOrFocusApp,
            .observeApp,
            .focusControl,
            .enterText,
            .submit,
            .submit,
            .verifyResult
        ])
        #expect(plan.steps.last?.status == .blocked)
        #expect(plan.metadata["defaultOSInputBackendAvailable"] == "true")
        #expect(plan.metadata["defaultOSInputBackend"] == "mac-keyboard")
        #expect(plan.metadata["visualFallback"] == "localModel")
        #expect(plan.metadata["ocrFallbackDefault"] == "false")

        let commands = localAdapter.guardedKeyboardCommandTemplates(
            for: intent,
            issuedAt: timestamp(100)
        )
        #expect(commands.map(\.kind) == [.key, .key, .key, .key])
        #expect(commands.map(\.key) == ["Command+F", "San Francisco", "Return", "Return"])
        #expect(commands[1].metadata["workflowStepRole"] == "enterText")
        #expect(commands[1].metadata["text"] == "San Francisco")
        #expect(commands[1].metadata["bundleIdentifier"] == "com.apple.weather")
    }

    @Test
    func genericAdapterVerifiesObservedVisibleText() throws {
        let intent = weatherIntent(rawCity: "SF", city: "San Francisco")
        let localAdapter = adapter()
        let plan = localAdapter.evidenceBackedActionPlan(
            for: intent,
            observation: LocalAppTaskObservation(
                appIsRunning: true,
                appIsFocused: true,
                availableControls: ["search": true],
                visibleText: ["city": "San Francisco, CA"],
                confidence: 0.91,
                metadata: groundedControlMetadata()
            )
        )

        #expect(plan.terminalState == .completed)
        #expect(plan.verificationConfidence == 0.91)
        #expect(plan.steps.first(where: { $0.role == .verifyResult })?.status == .verified)
        #expect(localAdapter.verifiesVisibleText("San Francisco, CA", matches: intent) == true)
        #expect(localAdapter.verifiesVisibleText("New York", matches: intent) == false)
    }

    @Test
    func appOpenAdapterVerifiesFocusedApp() throws {
        let catalog = LocalAppTaskCatalog(
            taskDefinitions: BuiltInLocalAppTaskDefinitions.benchmarkFixtures,
            availabilityProvider: StaticLocalAppAvailabilityProvider(installedBundleIdentifiers: ["com.apple.Music"])
        )
        let resolution = catalog.resolve(intent: TaskIntent(
            intentID: "app_open-music",
            taskType: "app_open",
            targetApp: LocalAppTarget(appName: "Local Item", metadata: ["dynamicTarget": "true"]),
            entities: ["appName": "music"],
            normalizedEntities: ["appName": "Music"],
            confidence: 0.9,
            parserSource: .localModel
        ))
        let intent = try #require(resolution.intent)
        let definition = try #require(resolution.definition)
        let localAdapter = LocalAppTaskAdapter(definition: definition)
        let plan = localAdapter.evidenceBackedActionPlan(
            for: intent,
            observation: LocalAppTaskObservation(
                appIsRunning: true,
                appIsFocused: true,
                confidence: 0.72
            )
        )

        #expect(plan.terminalState == .completed)
        #expect(plan.verificationConfidence == 0.8)
        #expect(plan.steps.first(where: { $0.role == .verifyResult })?.status == .verified)
    }

    @Test
    func catalogResolvesGenericModelPlannedLocalAppInteraction() throws {
        let catalog = LocalAppTaskCatalog(
            taskDefinitions: LocalAppTaskDefinitionLoader.runtimeSeedDefinitions,
            availabilityProvider: StaticLocalAppAvailabilityProvider(
                installedBundleIdentifiers: ["com.apple.Music"]
            )
        )

        let resolution = catalog.resolve(intent: genericLocalAppInteractionIntent(
            appName: "Music",
            query: "Justin Bieber",
            planTools: [
                .openOrFocusApp,
                .observeApp,
                .focusSearch,
                .setText,
                .pressReturn,
                .pressReturn,
                .verifyCommand
            ]
        ))
        let intent = try #require(resolution.intent)
        let definition = try #require(resolution.definition)
        let localAdapter = LocalAppTaskAdapter(definition: definition)
        let plan = localAdapter.evidenceBackedActionPlan(
            for: intent,
            observation: LocalAppTaskObservation(
                appIsRunning: true,
                appIsFocused: true,
                availableControls: ["search": true],
                confidence: 0.7,
                metadata: groundedControlMetadata()
            )
        )

        #expect(resolution.status == .resolved)
        #expect(intent.taskType == "local_app_interaction")
        #expect(intent.targetApp.appName == "Music")
        #expect(intent.targetApp.bundleIdentifier == "com.apple.Music")
        #expect(definition.metadata["modelPlanned"] == "true")
        #expect(definition.metadata["plan.tools"] == "app.openOrFocus,app.observe,ui.focusSearch,ui.setText,ui.pressReturn,ui.pressReturn,app.verifyCommand")
        #expect(plan.terminalState == .completed)
        #expect(plan.steps.map(\.role) == [
            .parseIntent,
            .launchOrFocusApp,
            .observeApp,
            .focusControl,
            .enterText,
            .submit,
            .submit,
            .verifyResult
        ])

        let commands = localAdapter.guardedKeyboardCommandTemplates(
            for: intent,
            issuedAt: timestamp(100)
        )
        #expect(commands.map(\.key) == ["Command+F", "Justin Bieber", "Return", "Return"])
        #expect(commands.first?.metadata["plan.tool"] == "ui.focusSearch")
    }

    @Test
    func genericInteractionShortcutFocusDoesNotRequireControlBounds() throws {
        let catalog = LocalAppTaskCatalog(
            taskDefinitions: LocalAppTaskDefinitionLoader.runtimeSeedDefinitions,
            availabilityProvider: StaticLocalAppAvailabilityProvider(
                installedBundleIdentifiers: ["com.apple.Music"]
            )
        )
        let resolution = catalog.resolve(intent: genericLocalAppInteractionIntent(
            appName: "Music",
            query: "Coldplay",
            planTools: [
                .openOrFocusApp,
                .observeApp,
                .focusSearch,
                .setText,
                .pressReturn,
                .verifyCommand
            ]
        ))
        let intent = try #require(resolution.intent)
        let definition = try #require(resolution.definition)
        let plan = catalog.adapter(for: definition).evidenceBackedActionPlan(
            for: intent,
            observation: LocalAppTaskObservation(
                appIsRunning: true,
                appIsFocused: true,
                availableControls: [:],
                confidence: 0.7
            )
        )

        #expect(resolution.status == .resolved)
        #expect(plan.canExecuteGuardedActions == true)
        #expect(plan.terminalState == .completed)
        #expect(plan.steps.first(where: { $0.role == .focusControl })?.status == .verified)
    }

    @Test
    func catalogKeepsValidatedPlayMediaCapabilityOnGenericInteraction() throws {
        let catalog = LocalAppTaskCatalog(
            taskDefinitions: LocalAppTaskDefinitionLoader.runtimeSeedDefinitions,
            availabilityProvider: StaticLocalAppAvailabilityProvider(
                installedBundleIdentifiers: ["com.apple.Music"]
            )
        )
        var genericIntent = genericLocalAppInteractionIntent(
            appName: "Music",
            query: "Viva La Vida Coldplay",
            planTools: [
                .openOrFocusApp,
                .observeApp,
                .focusSearch,
                .setText,
                .pressReturn,
                .verifyCommand
            ]
        )
        genericIntent.metadata.merge([
            "appFinder.selectedAppID": "com.apple.Music",
            "appFinder.selectedCapabilityID": "play_media",
            "appFinder.controlProfile": "search_then_enter",
            "mediaSelection.kind": "representative_song",
            "mediaSelection.seed": "Coldplay",
            "mediaSelection.selectedTitle": "Viva La Vida"
        ]) { _, new in new }

        let resolution = catalog.resolve(intent: genericIntent)
        let intent = try #require(resolution.intent)
        let definition = try #require(resolution.definition)
        let automationCommands = catalog.adapter(for: definition).guardedAutomationCommandTemplates(
            for: intent,
            issuedAt: timestamp(100)
        )
        let keyboardCommands = catalog.adapter(for: definition).guardedKeyboardCommandTemplates(
            for: intent,
            issuedAt: timestamp(100)
        )

        #expect(resolution.status == .resolved)
        #expect(intent.taskType == "local_app_interaction")
        #expect(intent.targetApp.appName == "Music")
        #expect(intent.normalizedEntities["query"] == "Viva La Vida Coldplay")
        #expect(intent.metadata["appFinder.selectedCapabilityID"] == "play_media")
        #expect(definition.taskType == "local_app_interaction")
        #expect(definition.metadata["automationBackend"] == nil)
        #expect(automationCommands.isEmpty)
        #expect(keyboardCommands.map(\.key) == ["Command+F", "Viva La Vida Coldplay", "Return"])
    }

    @Test
    func staticProviderBuildsAppFinderCatalogWithSupportAndDenyMetadata() throws {
        let provider = StaticLocalAppAvailabilityProvider(
            installedBundleIdentifiers: [
                "com.apple.Music",
                "com.apple.Terminal",
                "com.example.DraftPad"
            ],
            installedApplicationNames: ["DraftPad": "com.example.DraftPad"]
        )
        let entries = provider.appFinderCatalogEntries()
        let music = try #require(entries.first { $0.appID == "com.apple.Music" })
        let terminal = try #require(entries.first { $0.appID == "com.apple.Terminal" })
        let draftPad = try #require(entries.first { $0.appID == "com.example.DraftPad" })

        #expect(music.supportStatus == .candidate)
        #expect(music.capabilities.isEmpty)
        #expect(terminal.supportStatus == .denied)
        #expect(terminal.capabilities.isEmpty)
        #expect(terminal.denyReason?.contains("shell") == true)
        #expect(draftPad.supportStatus == .candidate)
        #expect(draftPad.capabilities.isEmpty)
    }

    @Test
    func catalogResolvesGenericModelPlannedTextEntryCreation() throws {
        let catalog = LocalAppTaskCatalog(
            taskDefinitions: LocalAppTaskDefinitionLoader.runtimeSeedDefinitions,
            availabilityProvider: StaticLocalAppAvailabilityProvider(
                installedBundleIdentifiers: ["com.example.DraftPad"],
                installedApplicationNames: ["DraftPad": "com.example.DraftPad"]
            )
        )
        let textToEnter = "Checklist\n- First item\n- Second item\n- Third item"
        let intent = TaskIntent(
            intentID: "local_app_interaction-draftpad-checklist",
            taskType: "local_app_interaction",
            targetApp: LocalAppTarget(appName: "DraftPad", titleContains: "DraftPad"),
            entities: [
                "appName": "DraftPad",
                "goal": "create text content",
                "query": textToEnter
            ],
            normalizedEntities: [
                "appName": "DraftPad",
                "goal": "create text content",
                "query": textToEnter
            ],
            confidence: 0.9,
            parserSource: .onlineModel,
            actionPlan: LocalAppActionPlan(
                tools: [
                    .openOrFocusApp,
                    .observeApp,
                    .newDocument,
                    .setText,
                    .verifyCommand
                ],
                inputEntity: "query",
                controlID: "editor",
                focusKey: "",
                verification: .commandAttempted
            ),
            metadata: ["requestedItemName": "DraftPad"]
        )

        let resolution = catalog.resolve(intent: intent)
        let resolvedIntent = try #require(resolution.intent)
        let definition = try #require(resolution.definition)
        let localAdapter = LocalAppTaskAdapter(definition: definition)
        let plan = localAdapter.evidenceBackedActionPlan(
            for: resolvedIntent,
            observation: LocalAppTaskObservation(
                appIsRunning: true,
                appIsFocused: true,
                confidence: 0.72
            )
        )
        let commands = localAdapter.guardedKeyboardCommandTemplates(
            for: resolvedIntent,
            issuedAt: timestamp(100)
        )

        #expect(resolution.status == .resolved)
        #expect(resolvedIntent.targetApp.bundleIdentifier == "com.example.DraftPad")
        #expect(definition.metadata["plan.tools"] == "app.openOrFocus,app.observe,ui.newDocument,ui.setText,app.verifyCommand")
        #expect(definition.metadata["plan.setTextInputContract"] == "inputEntityValueIsExactTextToEnter")
        #expect(plan.terminalState == .completed)
        #expect(commands.map(\.key) == ["Command+N", textToEnter])
        #expect(commands.first?.metadata["plan.tool"] == "ui.newDocument")
        #expect(commands.last?.metadata["inputRole"] == "textEntry")
    }

    @Test
    func genericModelPlannedInteractionRequiresTypedActionPlanBeforeExecution() {
        let catalog = LocalAppTaskCatalog(
            taskDefinitions: LocalAppTaskDefinitionLoader.runtimeSeedDefinitions,
            availabilityProvider: StaticLocalAppAvailabilityProvider(
                installedBundleIdentifiers: ["com.apple.Music"]
            )
        )

        let resolution = catalog.resolve(intent: genericLocalAppInteractionIntent(
            appName: "Music",
            query: "Justin Bieber",
            planTools: nil
        ))

        #expect(resolution.status == .needsConfirmation)
        #expect(resolution.metadata["reason"] == "missingActionPlan")
    }

    @Test
    func catalogResolvesStructuredIntentAgainstAvailableInstalledAppDefinition() throws {
        let catalog = LocalAppTaskCatalog(
            taskDefinitions: BuiltInLocalAppTaskDefinitions.benchmarkFixtures,
            availabilityProvider: StaticLocalAppAvailabilityProvider(installedBundleIdentifiers: [
                "com.apple.weather",
                "com.apple.Music",
                "com.apple.Preview"
            ])
        )

        let resolution = catalog.resolve(intent: weatherIntent(rawCity: "SF", city: "San Francisco"))

        #expect(resolution.status == .resolved)
        #expect(resolution.intent?.normalizedEntities["city"] == "San Francisco")
        #expect(resolution.definition?.taskType == "weather_lookup")
        #expect(resolution.definition?.observationStrategies == [.accessibility, .windowMetadata, .screenshotForLocalModel])
        #expect(resolution.availability?.isInstalled == true)

        let definition = try #require(resolution.definition)
        let intent = try #require(resolution.intent)
        let plan = catalog.adapter(for: definition).evidenceBackedActionPlan(for: intent)
        #expect(plan.steps.map(\.role).contains(.verifyResult))

        let documentResolution = catalog.resolve(intent: documentFormFillIntent())
        #expect(documentResolution.status == .resolved)
        #expect(documentResolution.definition?.taskType == "document_form_fill")
    }

    @Test
    func catalogSeparatesUnsupportedMissingEntityAndUnavailableApp() {
        let availableCatalog = LocalAppTaskCatalog(
            taskDefinitions: BuiltInLocalAppTaskDefinitions.benchmarkFixtures,
            availabilityProvider: StaticLocalAppAvailabilityProvider(installedBundleIdentifiers: ["com.apple.weather"])
        )
        let unavailableAppResolution = availableCatalog.resolve(intent: TaskIntent(
            intentID: "app_open-missing",
            taskType: "app_open",
            targetApp: LocalAppTarget(appName: "Local Item", metadata: ["dynamicTarget": "true"]),
            entities: ["appName": "an app that does not exist"],
            normalizedEntities: ["appName": "An App That Does Not Exist"],
            confidence: 0.86,
            parserSource: .localModel
        ))
        #expect(unavailableAppResolution.status == .appUnavailable)
        #expect(unavailableAppResolution.metadata["reason"] == "targetAppUnavailable")
        #expect(availableCatalog.resolve(intent: weatherIntent(rawCity: "", city: "", needsConfirmation: true)).status == .needsConfirmation)

        let unavailableCatalog = LocalAppTaskCatalog(
            taskDefinitions: BuiltInLocalAppTaskDefinitions.benchmarkFixtures,
            availabilityProvider: StaticLocalAppAvailabilityProvider(installedBundleIdentifiers: [])
        )
        #expect(unavailableCatalog.resolve(intent: weatherIntent(rawCity: "SF", city: "San Francisco")).status == .appUnavailable)
    }

    @Test
    func taskDefinitionLoaderLoadsLocalJSONDefinitions() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DonkeyTaskDefinitionLoader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let definition = LocalAppTaskDefinition(
            taskType: "notes_capture",
            targetApp: LocalAppTarget(appName: "Notes", bundleIdentifier: "com.apple.Notes"),
            triggerTerms: [],
            entityRules: [
                LocalAppTaskEntityRule(
                    name: "note"
                )
            ],
            workflowSteps: [
                LocalAppTaskWorkflowStepDefinition(
                    id: "parse-intent",
                    role: .parseIntent,
                    summary: "Parse note intent"
                )
            ],
            verificationEntityName: "note",
            metadata: ["source": "test-json"]
        )
        let fileURL = directoryURL.appendingPathComponent("notes.json")
        try JSONEncoder().encode(definition).write(to: fileURL)

        let storeURL = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = try SQLiteAgentMemoryStore(baseDirectory: storeURL, cleanupLegacyStores: false)
        let definitions = try LocalAppTaskDefinitionLoader(memoryStore: store).cachedDefinitions(from: directoryURL)
        let loaded = try #require(definitions.first(where: { $0.taskType == "notes_capture" }))
        #expect(loaded.targetApp.bundleIdentifier == "com.apple.Notes")
        #expect(loaded.metadata["source"] == "test-json")
        #expect(store.taskDefinitions().map(\.taskType).contains("notes_capture"))

        let catalog = LocalAppTaskCatalog(
            taskDefinitions: definitions,
            availabilityProvider: StaticLocalAppAvailabilityProvider(installedBundleIdentifiers: ["com.apple.Notes"])
        )
        #expect(catalog.resolve(intent: TaskIntent(
            intentID: "notes_capture-buy-milk",
            taskType: "notes_capture",
            targetApp: LocalAppTarget(appName: "Notes", bundleIdentifier: "com.apple.Notes"),
            entities: ["note": "buy milk"],
            normalizedEntities: ["note": "buy milk"],
            confidence: 0.9,
            parserSource: .localModel
        )).status == .resolved)
    }

    @Test
    func defaultLocalCatalogLoadsRuntimeDefinitionsFromCache() {
        let storeURL = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = try? SQLiteAgentMemoryStore(baseDirectory: storeURL, cleanupLegacyStores: false)
        let loader = LocalAppTaskDefinitionLoader(memoryStore: store)

        let catalog = LocalAppTaskCatalog.defaultLocal(
            availabilityProvider: StaticLocalAppAvailabilityProvider(installedBundleIdentifiers: []),
            loader: loader
        )

        #expect(catalog.taskDefinitions.map(\.taskType) == ["app_open", "local_app_interaction"])
        #expect(store?.taskDefinitions().map(\.taskType) == ["app_open", "local_app_interaction"])
        #expect(catalog.taskDefinitions.contains { $0.targetApp.appName == "Weather" } == false)
        #expect(catalog.taskDefinitions.contains { $0.targetApp.appName == "Music" } == false)
        #expect(catalog.taskDefinitions.contains { $0.targetApp.appName == "Preview" } == false)
    }

    @Test
    func appFinderProfilesLoadFromBundledJSON() throws {
        let store = LocalAppFinderProfileStore.defaultStore

        #expect(store.profile(appName: "Music", bundleIdentifier: "com.apple.Music") == nil)
        #expect(store.profile(appName: "Chrome", bundleIdentifier: nil) == nil)

        let terminal = try #require(store.profile(appName: "Terminal", bundleIdentifier: "com.apple.Terminal"))
        #expect(terminal.supportStatus == .denied)
        #expect(terminal.capabilities.isEmpty)
    }

    @Test
    func dynamicCatalogRefreshProfilesOnlyNewApplicationsOncePerDay() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DonkeyAppCatalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let seedURL = rootURL.appendingPathComponent("seed.json")
        let seedEntry = LocalAppFinderCatalogEntry(
            appID: "com.apple.Notes",
            appName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            description: "Seeded Notes profile.",
            supportStatus: .supported,
            capabilities: [
                LocalAppFinderCapability(
                    id: "write_text",
                    summary: "Write text.",
                    controlProfiles: ["new_document_text"],
                    requiredEntities: ["query"]
                )
            ]
        )
        try JSONEncoder().encode(LocalAppFinderProfileCatalog(entries: [seedEntry])).write(to: seedURL)

        let profileStore = LocalAppFinderProfileStore(
            seedCatalogURL: seedURL,
            generatedCatalogURL: rootURL.appendingPathComponent("generated.json"),
            resolvedCatalogURL: rootURL.appendingPathComponent("snapshot.json"),
            refreshStateURL: rootURL.appendingPathComponent("state.json")
        )
        let scanner = RecordingApplicationCatalogScanner(applications: [
            LocalApplicationCatalogCandidate(
                appName: "Notes",
                bundleIdentifier: "com.apple.Notes",
                path: "/Applications/Notes.app"
            ),
            LocalApplicationCatalogCandidate(
                appName: "Figma",
                bundleIdentifier: "com.figma.Desktop",
                path: "/Applications/Figma.app"
            )
        ])
        let generator = RecordingCatalogProfileGenerator()
        let refreshLoop = LocalAppDynamicCatalogRefreshLoop(
            scanner: scanner,
            profileStore: profileStore,
            profileGenerator: generator,
            refreshInterval: 86_400
        )
        let now = Date(timeIntervalSince1970: 1_000)

        let firstRefresh = await refreshLoop.refreshIfNeeded(now: now)

        #expect(firstRefresh.status == "refreshed")
        #expect(firstRefresh.newApplicationCount == 1)
        #expect(firstRefresh.generatedProfileCount == 1)
        #expect(await generator.requestedBatches() == [["com.figma.Desktop"]])
        let figmaProfile = try #require(profileStore.profile(
            appName: "Figma",
            bundleIdentifier: "com.figma.Desktop"
        ))
        #expect(figmaProfile.supportStatus == .supported)
        #expect(profileStore.resolvedCatalogEntries().contains {
            $0.appID == "com.figma.Desktop" && $0.supportStatus == .supported
        })

        let skippedRefresh = await refreshLoop.refreshIfNeeded(
            now: now.addingTimeInterval(3_600)
        )
        #expect(skippedRefresh.status == "skipped")
        #expect(await generator.requestedBatches() == [["com.figma.Desktop"]])

        scanner.setApplications([
            LocalApplicationCatalogCandidate(
                appName: "Notes",
                bundleIdentifier: "com.apple.Notes",
                path: "/Applications/Notes.app"
            ),
            LocalApplicationCatalogCandidate(
                appName: "Figma",
                bundleIdentifier: "com.figma.Desktop",
                path: "/Applications/Figma.app"
            ),
            LocalApplicationCatalogCandidate(
                appName: "Linear",
                bundleIdentifier: "com.linear",
                path: "/Applications/Linear.app"
            )
        ])

        let nextDayRefresh = await refreshLoop.refreshIfNeeded(
            now: now.addingTimeInterval(90_000)
        )

        #expect(nextDayRefresh.status == "refreshed")
        #expect(nextDayRefresh.newApplicationCount == 1)
        #expect(await generator.requestedBatches() == [
            ["com.figma.Desktop"],
            ["com.linear"]
        ])
    }

    @Test
    func documentFormFillPlannerMapsStructuredDataToObservedFieldsForReview() throws {
        let intent = documentFormFillIntent()
        let context = LocalAppTaskContext(
            focusedAppName: "Preview",
            focusedBundleIdentifier: "com.apple.Preview",
            focusedWindowTitle: "W-9.pdf",
            structuredData: [
                "Name": "Ada Lovelace",
                "Address": "12 Algorithm Ave"
            ],
            observedFormFields: [
                LocalDocumentFormField(id: "field-name", label: "Name", isRequired: true),
                LocalDocumentFormField(id: "field-address", label: "Mailing Address", isRequired: true)
            ]
        )

        let plan = DocumentFormFillPlanner().plan(
            intent: intent,
            definition: BuiltInLocalAppTaskDefinitions.documentFormFill,
            context: context
        )

        #expect(plan.status == .readyForReview)
        #expect(plan.proposals.count == 2)
        #expect(plan.proposals.first(where: { $0.fieldID == "field-name" })?.proposedValue == "Ada Lovelace")
        #expect(plan.metadata["requiresReview"] == "true")
    }

    @Test
    func documentFormFillApprovalBuildsOnlyApprovedAccessibilityCommands() throws {
        let intent = documentFormFillIntent()
        let context = LocalAppTaskContext(
            focusedWindowTitle: "W-9.pdf",
            structuredData: [
                "Name": "Ada Lovelace",
                "Address": "12 Algorithm Ave"
            ],
            observedFormFields: [
                LocalDocumentFormField(id: "ax-1.1", label: "Name", isRequired: true),
                LocalDocumentFormField(id: "ax-1.2", label: "Address", isRequired: true)
            ]
        )
        let planner = DocumentFormFillPlanner()
        let plan = planner.plan(
            intent: intent,
            definition: BuiltInLocalAppTaskDefinitions.documentFormFill,
            context: context
        )
        let approval = planner.approval(
            for: plan,
            traceID: "trace-approval",
            approvedFieldIDs: ["ax-1.1"]
        )
        let commands = LocalAppAccessibilityActionPlanner().fillCommands(
            approval: approval,
            definition: BuiltInLocalAppTaskDefinitions.documentFormFill,
            issuedAt: timestamp(200)
        )

        #expect(approval.status == .partiallyApproved)
        #expect(approval.approvedProposals.map(\.fieldID) == ["ax-1.1"])
        #expect(approval.rejectedFieldIDs == ["ax-1.2"])
        #expect(commands.count == 1)
        #expect(commands.first?.metadata["accessibility.action"] == "AXSetValue")
        #expect(commands.first?.metadata["accessibility.nodeID"] == "ax-1.1")
        #expect(commands.first?.metadata["documentFormFill.approvalID"] == approval.id)
    }

    @Test
    func accessibilityControlDiscoveryIndexesControlsAndFormFields() throws {
        let target = MacWindowTargetCandidate(
            windowID: 7,
            processID: 99,
            appName: "Preview",
            bundleIdentifier: "com.apple.Preview",
            title: "Form.pdf",
            bounds: WindowTargetBounds(x: 0, y: 0, width: 600, height: 800),
            isVisible: true,
            isOnScreen: true,
            isFrontmost: true,
            isFocused: true,
            isIPhoneMirroring: false,
            safetyAssessment: WindowTargetSafetyAssessment(status: .allowed, summary: "allowed")
        )
        let snapshot = MacAccessibilitySnapshot(
            target: target,
            limits: .default,
            root: MacAccessibilitySnapshotNode(
                nodeID: "ax-1",
                role: "AXWindow",
                title: "Form.pdf",
                children: [
                    MacAccessibilitySnapshotNode(
                        nodeID: "ax-1.1",
                        role: "AXSearchField",
                        label: "Search",
                        frame: WindowTargetBounds(x: 20, y: 20, width: 200, height: 30),
                        actions: ["AXPress"]
                    ),
                    MacAccessibilitySnapshotNode(
                        nodeID: "ax-1.2",
                        role: "AXTextField",
                        label: "Name",
                        valueSummary: "",
                        frame: WindowTargetBounds(x: 40, y: 90, width: 240, height: 30)
                    )
                ]
            ),
            totalNodeCount: 3,
            isTreeTruncated: false
        )
        let discovery = LocalAppAccessibilityControlDiscovery()
        let index = discovery.discover(in: snapshot)
        let fields = discovery.observedFormFields(in: snapshot)

        #expect(index.controls.count == 2)
        #expect(index.firstControl(matching: "search")?.id == "ax-1.1")
        #expect(fields.map(\.id) == ["ax-1.1", "ax-1.2"])
        #expect(fields.first(where: { $0.id == "ax-1.2" })?.label == "Name")
    }

    @Test
    func accessibilityActionPlannerPressesExplicitSubmitControls() throws {
        let definition = LocalAppTaskDefinition(
            taskType: "button_submit",
            targetApp: LocalAppTarget(appName: "Music", bundleIdentifier: "com.apple.Music"),
            triggerTerms: [],
            workflowSteps: [
                LocalAppTaskWorkflowStepDefinition(
                    id: "play-result",
                    role: .submit,
                    summary: "Play the selected result",
                    metadata: ["controlID": "play-result"]
                )
            ]
        )
        let intent = TaskIntent(
            intentID: "button-submit-play-result",
            taskType: definition.taskType,
            targetApp: definition.targetApp,
            entities: [:],
            normalizedEntities: [:],
            confidence: 0.9,
            parserSource: .localModel
        )
        let index = LocalAppAccessibilityControlIndex(
            controls: [
                LocalAppDiscoveredControl(
                    id: "ax-1.4",
                    kind: .button,
                    role: "AXButton",
                    label: "Play Result",
                    frame: WindowTargetBounds(x: 320, y: 240, width: 42, height: 28),
                    actions: ["AXPress"],
                    metadata: ["controlID": "play-result"]
                )
            ],
            visibleText: "Play Result"
        )

        let commands = LocalAppAccessibilityActionPlanner().commands(
            for: intent,
            definition: definition,
            index: index,
            issuedAt: timestamp(200)
        )
        let command = try #require(commands.first)

        #expect(commands.count == 1)
        #expect(command.kind == .tap)
        #expect(command.metadata["workflowStepID"] == "play-result")
        #expect(command.metadata["inputIntent"] == "submit")
        #expect(command.metadata["accessibility.action"] == "AXPress")
        #expect(command.metadata["controlID"] == "play-result")
        #expect(command.targetBounds?.origin.x == 320)
        #expect(command.targetBounds?.origin.y == 240)
        #expect(command.targetBounds?.size.width == 42)
        #expect(command.targetBounds?.size.height == 28)
        #expect(command.targetBounds?.space == .screen)
    }

    @Test @MainActor
    func liveRunnerReturnsReviewPlanForDocumentFormFillWithoutExecutingInput() async throws {
        let catalog = LocalAppTaskCatalog(
            taskDefinitions: BuiltInLocalAppTaskDefinitions.benchmarkFixtures,
            availabilityProvider: StaticLocalAppAvailabilityProvider(installedBundleIdentifiers: ["com.apple.Preview"])
        )
        let context = LocalAppTaskContext(
            focusedAppName: "Preview",
            focusedBundleIdentifier: "com.apple.Preview",
            focusedWindowTitle: "Application.pdf",
            structuredData: ["Name": "Grace Hopper"],
            observedFormFields: [
                LocalDocumentFormField(id: "name", label: "Name", isRequired: true)
            ]
        )
        let runner = LocalAppTaskLiveRunner(
            catalog: catalog,
            contextProvider: StaticLocalAppTaskContextProvider(context: context)
        )
        let intent = documentFormFillIntent()

        let result = await runner.run(
            command: "fill out this PDF using this data",
            traceID: "trace-document-fill",
            resolution: catalog.resolve(intent: intent),
            metadata: ["intentParser": "test-model"]
        )

        #expect(result.status == .needsUserReview)
        #expect(result.actionTraces.isEmpty)
        #expect(result.documentFormFillPlan?.status == .readyForReview)
        #expect(result.documentFormFillPlan?.proposals.first?.proposedValue == "Grace Hopper")
        #expect(result.metadata["reason"] == "reviewOnlyTask")
        #expect(result.workflowProgress.state(for: .approval)?.status == .waiting)
        #expect(result.workflowProgress.state(for: .execute)?.status == .skipped)
    }

    @Test @MainActor
    func liveRunnerLaunchesFocusesExecutesGuardedCommandsAndVerifies() async throws {
        let backend = RecordingLocalAppTaskInputBackend()
        let controller = FakeLocalAppTaskAppController(
            launchObservation: LocalAppTaskObservation(
                appIsRunning: true,
                appIsFocused: true,
                availableControls: ["search": true],
                confidence: 0.5,
                metadata: groundedControlMetadata()
            ),
            finalObservation: LocalAppTaskObservation(
                appIsRunning: true,
                appIsFocused: true,
                availableControls: ["search": true],
                visibleText: ["city": "San Francisco, CA"],
                confidence: 0.92,
                metadata: groundedControlMetadata()
            )
        )
        let catalog = LocalAppTaskCatalog(
            taskDefinitions: BuiltInLocalAppTaskDefinitions.benchmarkFixtures,
            availabilityProvider: StaticLocalAppAvailabilityProvider(installedBundleIdentifiers: ["com.apple.weather"])
        )
        let runner = LocalAppTaskLiveRunner(
            catalog: catalog,
            appController: controller,
            actionEngineFactory: { _ in
                ActionEngineGuardrail(
                    configuration: ActionEngineConfiguration(liveInputEnabled: true),
                    inputBackend: backend
                )
            },
            permissionPolicy: ToolCallPolicy(deniedCapabilities: [])
        )
        let intent = weatherIntent(rawCity: "SF", city: "San Francisco")

        let result = await runner.run(
            command: "show me the weather for SF",
            traceID: "trace-live-task",
            resolution: catalog.resolve(intent: intent),
            metadata: ["intentParser": "test-model"]
        )

        #expect(result.status == .completed)
        #expect(result.finalActionPlan?.terminalState == .completed)
        #expect(result.actionTraces.count == 4)
        #expect(result.actionTraces.allSatisfy { $0.executed })
        #expect(await backend.executedKeys() == ["Command+F", "San Francisco", "Return", "Return"])
        #expect(controller.launchCount == 1)
        #expect(controller.observeCount == 1)
        #expect(result.workflowProgress.state(for: .parseIntent)?.status == .completed)
        #expect(result.workflowProgress.state(for: .resolveApp)?.status == .completed)
        #expect(result.workflowProgress.state(for: .evidencePlan)?.status == .completed)
        #expect(result.workflowProgress.state(for: .approval)?.status == .skipped)
        #expect(result.workflowProgress.state(for: .execute)?.status == .completed)
        #expect(result.workflowProgress.state(for: .verify)?.status == .completed)
        #expect(result.metadata["workflow.verify.status"] == "completed")
    }

    @Test @MainActor
    func liveRunnerExecutesOnlyModelPlannedGenericPlayMediaSteps() async throws {
        let backend = RecordingLocalAppTaskInputBackend()
        let controller = FakeLocalAppTaskAppController(
            launchObservation: LocalAppTaskObservation(
                appIsRunning: true,
                appIsFocused: true,
                availableControls: [:],
                confidence: 0.7
            ),
            finalObservation: LocalAppTaskObservation(
                appIsRunning: true,
                appIsFocused: true,
                availableControls: [:],
                confidence: 0.74
            )
        )
        let catalog = LocalAppTaskCatalog(
            taskDefinitions: LocalAppTaskDefinitionLoader.runtimeSeedDefinitions,
            availabilityProvider: StaticLocalAppAvailabilityProvider(installedBundleIdentifiers: ["com.apple.Music"])
        )
        let runner = LocalAppTaskLiveRunner(
            catalog: catalog,
            appController: controller,
            actionEngineFactory: { _ in
                ActionEngineGuardrail(
                    configuration: ActionEngineConfiguration(liveInputEnabled: true),
                    inputBackend: backend
                )
            },
            permissionPolicy: ToolCallPolicy(deniedCapabilities: [])
        )
        var intent = genericLocalAppInteractionIntent(
            appName: "Music",
            query: "Viva La Vida Coldplay",
            planTools: [
                .openOrFocusApp,
                .observeApp,
                .focusSearch,
                .setText,
                .pressReturn,
                .verifyCommand
            ]
        )
        intent.metadata.merge([
            "appFinder.selectedAppID": "com.apple.Music",
            "appFinder.selectedCapabilityID": "play_media",
            "appFinder.controlProfile": "search_then_enter",
            "mediaSelection.kind": "representative_song",
            "mediaSelection.seed": "Coldplay",
            "mediaSelection.selectedTitle": "Viva La Vida"
        ]) { _, new in new }

        let result = await runner.run(
            command: "play some cold play",
            traceID: "trace-generic-play-media-automation",
            resolution: catalog.resolve(intent: intent),
            metadata: ["intentParser": "test-model"]
        )

        #expect(result.status == .completed)
        #expect(result.resolution.definition?.taskType == "local_app_interaction")
        #expect(result.metadata["reason"] != "evidencePlanBlocked")
        #expect(result.metadata["automation.backend"] == nil)
        #expect(result.metadata["automation.action"] == nil)
        #expect(result.workflowProgress.state(for: .evidencePlan)?.status == .completed)
        #expect(result.workflowProgress.state(for: .execute)?.status == .completed)
        #expect(result.metadata["verification.executedCommandCount"] == "3")
        #expect(await backend.executedKeys() == ["Command+F", "Viva La Vida Coldplay", "Return"])
    }

    @Test @MainActor
    func liveRunnerExecutesGenericShortcutFocusPlanWithoutControlBounds() async throws {
        let backend = RecordingLocalAppTaskInputBackend()
        let controller = FakeLocalAppTaskAppController(
            launchObservation: LocalAppTaskObservation(
                appIsRunning: true,
                appIsFocused: true,
                availableControls: [:],
                confidence: 0.7
            ),
            finalObservation: LocalAppTaskObservation(
                appIsRunning: true,
                appIsFocused: true,
                availableControls: [:],
                confidence: 0.74
            )
        )
        let catalog = LocalAppTaskCatalog(
            taskDefinitions: LocalAppTaskDefinitionLoader.runtimeSeedDefinitions,
            availabilityProvider: StaticLocalAppAvailabilityProvider(installedBundleIdentifiers: ["com.apple.Music"])
        )
        let runner = LocalAppTaskLiveRunner(
            catalog: catalog,
            appController: controller,
            actionEngineFactory: { _ in
                ActionEngineGuardrail(
                    configuration: ActionEngineConfiguration(liveInputEnabled: true),
                    inputBackend: backend
                )
            },
            permissionPolicy: ToolCallPolicy(deniedCapabilities: [])
        )
        let intent = genericLocalAppInteractionIntent(
            appName: "Music",
            query: "Coldplay",
            planTools: [
                .openOrFocusApp,
                .observeApp,
                .focusSearch,
                .setText,
                .pressReturn,
                .verifyCommand
            ]
        )

        let result = await runner.run(
            command: "play some cold play",
            traceID: "trace-generic-shortcut-focus",
            resolution: catalog.resolve(intent: intent),
            metadata: ["intentParser": "test-model"]
        )

        #expect(result.status == .completed)
        #expect(result.metadata["reason"] != "evidencePlanBlocked")
        #expect(result.workflowProgress.state(for: .evidencePlan)?.status == .completed)
        #expect(result.workflowProgress.state(for: .execute)?.status == .completed)
        #expect(await backend.executedKeys() == ["Command+F", "Coldplay", "Return"])
    }

    @Test @MainActor
    func liveRunnerDoesNotReportCompletedWhenEvidencePlanBlocks() async throws {
        let backend = RecordingLocalAppTaskInputBackend()
        let controller = FakeLocalAppTaskAppController(
            launchObservation: LocalAppTaskObservation(
                appIsRunning: true,
                appIsFocused: true,
                availableControls: [:],
                confidence: 0.7
            ),
            finalObservation: LocalAppTaskObservation(
                appIsRunning: true,
                appIsFocused: true,
                availableControls: [:],
                confidence: 0.74
            )
        )
        let catalog = LocalAppTaskCatalog(
            taskDefinitions: LocalAppTaskDefinitionLoader.runtimeSeedDefinitions,
            availabilityProvider: StaticLocalAppAvailabilityProvider(installedBundleIdentifiers: ["com.apple.Music"])
        )
        let runner = LocalAppTaskLiveRunner(
            catalog: catalog,
            appController: controller,
            actionEngineFactory: { _ in
                ActionEngineGuardrail(
                    configuration: ActionEngineConfiguration(liveInputEnabled: true),
                    inputBackend: backend
                )
            },
            permissionPolicy: ToolCallPolicy(deniedCapabilities: [])
        )
        let intent = TaskIntent(
            intentID: "local_app_interaction-no-focus-evidence",
            taskType: "local_app_interaction",
            targetApp: LocalAppTarget(appName: "Music", titleContains: "Music"),
            entities: [
                "appName": "Music",
                "goal": "play media",
                "query": "Coldplay"
            ],
            normalizedEntities: [
                "appName": "Music",
                "goal": "play media",
                "query": "Coldplay"
            ],
            confidence: 0.93,
            parserSource: .localModel,
            actionPlan: LocalAppActionPlan(
                tools: [
                    .openOrFocusApp,
                    .observeApp,
                    .focusSearch,
                    .setText,
                    .pressReturn,
                    .verifyCommand
                ],
                inputEntity: "query",
                controlID: "search",
                focusKey: "",
                verification: .commandAttempted
            ),
            metadata: ["requestedItemName": "Music"]
        )

        let result = await runner.run(
            command: "play some cold play",
            traceID: "trace-blocked-evidence-plan",
            resolution: catalog.resolve(intent: intent),
            metadata: ["intentParser": "test-model"]
        )

        #expect(result.status == .needsUserReview)
        #expect(result.metadata["reason"] == "evidencePlanBlocked")
        #expect(result.workflowProgress.state(for: .evidencePlan)?.status == .blocked)
        #expect(await backend.executedKeys() == [])
    }

    @Test @MainActor
    func liveRunnerPublishesCoordinatorEventsForGuardedRun() async throws {
        let backend = RecordingLocalAppTaskInputBackend()
        let controller = FakeLocalAppTaskAppController(
            launchObservation: LocalAppTaskObservation(
                appIsRunning: true,
                appIsFocused: true,
                availableControls: ["search": true],
                confidence: 0.5,
                metadata: groundedControlMetadata()
            ),
            finalObservation: LocalAppTaskObservation(
                appIsRunning: true,
                appIsFocused: true,
                availableControls: ["search": true],
                visibleText: ["city": "San Francisco, CA"],
                confidence: 0.92,
                metadata: groundedControlMetadata()
            )
        )
        let coordinator = RunCoordinator()
        let catalog = LocalAppTaskCatalog(
            taskDefinitions: BuiltInLocalAppTaskDefinitions.benchmarkFixtures,
            availabilityProvider: StaticLocalAppAvailabilityProvider(installedBundleIdentifiers: ["com.apple.weather"])
        )
        let runner = LocalAppTaskLiveRunner(
            catalog: catalog,
            appController: controller,
            actionEngineFactory: { _ in
                ActionEngineGuardrail(
                    configuration: ActionEngineConfiguration(liveInputEnabled: true),
                    inputBackend: backend
                )
            },
            permissionPolicy: ToolCallPolicy(deniedCapabilities: []),
            coordinator: coordinator
        )
        let intent = weatherIntent(rawCity: "SF", city: "San Francisco")

        let result = await runner.run(
            command: "show me the weather for SF",
            traceID: "trace-live-task-events",
            resolution: catalog.resolve(intent: intent),
            metadata: ["intentParser": "test-model"]
        )
        let events = await coordinator.events()

        #expect(result.status == .completed)
        #expect(events.contains { $0.stream == .lifecycle })
        #expect(events.contains { $0.stream == .tool && $0.summary == "Launching or focusing local app" })
        #expect(events.contains { $0.stream == .tool && $0.summary == "Executing guarded keyboard command" })
        #expect(events.last?.summary == "Run completed")
    }

    @Test
    func screenshotUnderstandingIsOnlyUsedWhenAccessibilityIsInsufficient() {
        let definition = BuiltInLocalAppTaskDefinitions.weatherLookup
        var boundedSearchMetadata = LocalAppObservationGeometry.targetBoundsMetadata(
            WindowTargetBounds(x: 100, y: 120, width: 900, height: 700)
        )
        boundedSearchMetadata.merge(
            LocalAppObservationGeometry.controlMetadata(
                controlID: "search",
                frame: HotLoopRect(x: 140, y: 180, width: 320, height: 44, space: .screen),
                source: .accessibility,
                label: "Search",
                kind: .searchField,
                confidence: 0.86
            )
        ) { current, _ in current }

        #expect(LocalAppTaskObservationFallbackPolicy.shouldUseScreenshotUnderstanding(
            definition: definition,
            accessibilityObservation: LocalAppTaskObservation(
                appIsRunning: true,
                appIsFocused: true,
                availableControls: ["search": true],
                visibleText: ["city": "San Francisco"],
                confidence: 0.9,
                metadata: boundedSearchMetadata
            ),
            verificationKey: "city"
        ) == false)

        #expect(LocalAppTaskObservationFallbackPolicy.shouldUseScreenshotUnderstanding(
            definition: definition,
            accessibilityObservation: LocalAppTaskObservation(
                appIsRunning: true,
                appIsFocused: true,
                availableControls: ["search": true],
                visibleText: ["city": "San Francisco"],
                confidence: 0.9
            ),
            verificationKey: "city"
        ) == true)

        #expect(LocalAppTaskObservationFallbackPolicy.shouldUseScreenshotUnderstanding(
            definition: definition,
            accessibilityObservation: LocalAppTaskObservation(
                appIsRunning: true,
                appIsFocused: true,
                availableControls: [:],
                visibleText: [:],
                confidence: 0.4
            ),
            verificationKey: "city"
        ) == true)

        var neverFallback = definition
        neverFallback.metadata["screenshotFallback"] = "never"
        #expect(LocalAppTaskObservationFallbackPolicy.shouldUseScreenshotUnderstanding(
            definition: neverFallback,
            accessibilityObservation: LocalAppTaskObservation(
                appIsRunning: true,
                appIsFocused: true,
                availableControls: [:],
                visibleText: [:],
                confidence: 0.4
            ),
            verificationKey: "city"
        ) == false)

        var controlFallback = definition
        controlFallback.metadata["screenshotFallback"] = "missingControls"
        #expect(LocalAppTaskObservationFallbackPolicy.shouldUseScreenshotUnderstanding(
            definition: controlFallback,
            accessibilityObservation: LocalAppTaskObservation(
                appIsRunning: true,
                appIsFocused: true,
                availableControls: [:],
                visibleText: ["city": "San Francisco"],
                confidence: 0.7
            ),
            verificationKey: "city"
        ) == true)
    }

    @Test
    func localUIUnderstandingObservationDeduplicatesModelControlIDs() {
        let request = LocalUIUnderstandingRequest(
            traceID: "trace-duplicate-controls",
            targetID: "weather",
            metadata: LocalAppObservationGeometry.targetBoundsMetadata(
                WindowTargetBounds(x: 100, y: 120, width: 900, height: 700)
            )
        )
        let result = LocalUIUnderstandingResult(
            controls: [
                LocalUIUnderstandingControl(
                    id: "search-field",
                    label: "Search",
                    kind: .searchField,
                    frame: HotLoopRect(x: 140, y: 180, width: 320, height: 44, space: .screen),
                    confidence: 0.86,
                    metadata: ["controlID": "search"]
                ),
                LocalUIUnderstandingControl(
                    id: "search-button",
                    label: "Search",
                    kind: .button,
                    frame: HotLoopRect(x: 480, y: 180, width: 80, height: 44, space: .screen),
                    confidence: 0.72,
                    metadata: ["controlID": "search"]
                )
            ],
            confidence: 0.84
        )

        let observation = result.observation(for: request)

        #expect(observation.availableControls["search"] == true)
        #expect(observation.availableControls["search-field"] == true)
        #expect(observation.availableControls["search-button"] == true)
        #expect(observation.metadata["control.search.bounds.space"] == HotLoopCoordinateSpace.screen.rawValue)
        let groundedMetadata = LocalAppObservationGeometry.groundedMetadata(
            controlID: "search",
            observation: observation
        )
        #expect(groundedMetadata["control.bounds.space"] == HotLoopCoordinateSpace.normalizedTarget.rawValue)
    }

    @Test @MainActor
    func documentApprovalRunnerExecutesOnlyApprovedFields() async throws {
        let backend = RecordingLocalAppTaskInputBackend()
        let controller = FakeLocalAppTaskAppController(
            launchObservation: LocalAppTaskObservation(appIsRunning: true, appIsFocused: true),
            finalObservation: LocalAppTaskObservation(appIsRunning: true, appIsFocused: true)
        )
        let plan = DocumentFormFillPlan(
            status: .readyForReview,
            proposals: [
                DocumentFormFillProposal(
                    fieldID: "ax-1.1",
                    fieldLabel: "Name",
                    proposedValue: "Ada Lovelace",
                    sourceKey: "Name",
                    confidence: 0.94
                ),
                DocumentFormFillProposal(
                    fieldID: "ax-1.2",
                    fieldLabel: "Address",
                    proposedValue: "12 Algorithm Ave",
                    sourceKey: "Address",
                    confidence: 0.94
                )
            ]
        )
        let coordinator = RunCoordinator()
        let runner = DocumentFormFillApprovalLiveRunner(
            appController: controller,
            availabilityProvider: StaticLocalAppAvailabilityProvider(installedBundleIdentifiers: ["com.apple.Preview"]),
            coordinator: coordinator,
            actionEngineFactory: { _ in
                ActionEngineGuardrail(
                    configuration: ActionEngineConfiguration(liveInputEnabled: true),
                    inputBackend: backend
                )
            }
        )

        let result = await runner.run(
            plan: plan,
            definition: BuiltInLocalAppTaskDefinitions.documentFormFill,
            traceID: "trace-document-approval",
            approvedFieldIDs: ["ax-1.1"]
        )

        #expect(result.status == .completed)
        #expect(result.approval.approvedProposals.map(\.fieldID) == ["ax-1.1"])
        #expect(await backend.executedKeys() == ["Ada Lovelace"])
        #expect(controller.launchCount == 1)
    }

    private func catalog() -> LocalAppTaskCatalog {
        LocalAppTaskCatalog(
            taskDefinitions: BuiltInLocalAppTaskDefinitions.benchmarkFixtures,
            availabilityProvider: StaticLocalAppAvailabilityProvider(installedBundleIdentifiers: [])
        )
    }

    private func weatherIntent(
        rawCity: String,
        city: String,
        confidence: Double = 0.93,
        needsConfirmation: Bool = false
    ) -> TaskIntent {
        let definition = BuiltInLocalAppTaskDefinitions.weatherLookup
        return TaskIntent(
            intentID: needsConfirmation ? "weather_lookup-needs-city" : "weather_lookup-\(slug(city))",
            taskType: definition.taskType,
            targetApp: definition.targetApp,
            entities: rawCity.isEmpty ? [:] : ["city": rawCity],
            normalizedEntities: city.isEmpty ? [:] : ["city": city],
            confidence: confidence,
            parserSource: .localModel,
            needsConfirmation: needsConfirmation,
            metadata: definition.metadata.merging(
                needsConfirmation ? ["missingEntity": "city"] : [:]
            ) { current, _ in current }
        )
    }

    private func genericLocalAppInteractionIntent(
        appName: String,
        query: String,
        planTools: [LocalAppActionPlanTool]?,
        confidence: Double = 0.93
    ) -> TaskIntent {
        let actionPlan = planTools.map {
            LocalAppActionPlan(
                tools: $0,
                inputEntity: "query",
                controlID: "search",
                focusKey: "Command+F",
                verification: .commandAttempted
            )
        }
        return TaskIntent(
            intentID: "local_app_interaction-\(slug(query))",
            taskType: "local_app_interaction",
            targetApp: LocalAppTarget(appName: appName, titleContains: appName),
            entities: [
                "appName": appName,
                "goal": "play media",
                "query": query
            ],
            normalizedEntities: [
                "appName": appName,
                "goal": "play media",
                "query": query
            ],
            confidence: confidence,
            parserSource: .localModel,
            actionPlan: actionPlan,
            metadata: [
                "requestedItemName": appName
            ]
        )
    }

    private func documentFormFillIntent(confidence: Double = 0.9) -> TaskIntent {
        let definition = BuiltInLocalAppTaskDefinitions.documentFormFill
        return TaskIntent(
            intentID: "document_form_fill-current-pdf",
            taskType: definition.taskType,
            targetApp: definition.targetApp,
            entities: [
                "document": "this PDF",
                "dataSource": "this data"
            ],
            normalizedEntities: [
                "document": "current PDF",
                "dataSource": "provided data"
            ],
            confidence: confidence,
            parserSource: .localModel,
            metadata: definition.metadata
        )
    }

    private func adapter() -> LocalAppTaskAdapter {
        LocalAppTaskAdapter(definition: BuiltInLocalAppTaskDefinitions.weatherLookup)
    }

    private func slug(_ value: String) -> String {
        LocalAppTaskIntentParser.normalizedPhrase(value)
            .split(separator: " ")
            .joined(separator: "-")
    }

    private func timestamp(_ milliseconds: UInt64) -> RunTraceTimestamp {
        RunTraceTimestamp(
            wallClock: Date(timeIntervalSince1970: Double(milliseconds) / 1_000),
            monotonicUptimeNanoseconds: milliseconds * 1_000_000
        )
    }

    private func groundedControlMetadata(controlID: String = "search") -> [String: String] {
        var metadata = LocalAppObservationGeometry.targetBoundsMetadata(
            WindowTargetBounds(x: 100, y: 120, width: 900, height: 700)
        )
        metadata.merge(
            LocalAppObservationGeometry.controlMetadata(
                controlID: controlID,
                frame: HotLoopRect(x: 140, y: 180, width: 320, height: 44, space: .screen),
                source: .accessibility,
                label: "Search",
                kind: .searchField,
                confidence: 0.86
            )
        ) { current, _ in current }
        return metadata
    }

    private func temporaryStoreDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("donkey-task-memory-\(UUID().uuidString)", isDirectory: true)
    }
}

private final class RecordingApplicationCatalogScanner: LocalApplicationCatalogScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var applications: [LocalApplicationCatalogCandidate]

    init(applications: [LocalApplicationCatalogCandidate]) {
        self.applications = applications
    }

    func installedApplications() -> [LocalApplicationCatalogCandidate] {
        lock.lock()
        defer { lock.unlock() }
        return applications
    }

    func setApplications(_ applications: [LocalApplicationCatalogCandidate]) {
        lock.lock()
        self.applications = applications
        lock.unlock()
    }
}

private actor RecordingCatalogProfileGenerator: LocalAppCatalogProfileGenerating {
    private var batches: [[String]] = []

    func generateProfiles(
        for applications: [LocalApplicationCatalogCandidate],
        existingProfiles _: [LocalAppFinderCatalogEntry],
        sourceTraceID _: String
    ) async -> LocalAppCatalogProfileGenerationResult {
        let ids = applications.map(\.catalogID).sorted()
        batches.append(ids)

        let entries = applications.map { application in
            LocalAppFinderCatalogEntry(
                appID: application.catalogID,
                appName: application.appName,
                bundleIdentifier: application.bundleIdentifier,
                description: "Generated profile for \(application.appName).",
                supportStatus: .supported,
                capabilities: [
                    LocalAppFinderCapability(
                        id: "write_text",
                        summary: "Write text in \(application.appName).",
                        controlProfiles: ["new_document_text"],
                        requiredEntities: ["query"]
                    )
                ],
                metadata: ["generated": "test"]
            )
        }
        return LocalAppCatalogProfileGenerationResult(
            generatedEntries: entries,
            attemptedApplicationIDs: Set(ids),
            metadata: ["generator": "recording-test"]
        )
    }

    func requestedBatches() -> [[String]] {
        batches
    }
}

@MainActor
private final class FakeLocalAppTaskAppController: LocalAppTaskAppControlling {
    private let launchObservation: LocalAppTaskObservation
    private let finalObservation: LocalAppTaskObservation
    private(set) var launchCount = 0
    private(set) var observeCount = 0

    init(
        launchObservation: LocalAppTaskObservation,
        finalObservation: LocalAppTaskObservation
    ) {
        self.launchObservation = launchObservation
        self.finalObservation = finalObservation
    }

    func launchOrFocus(
        definition: LocalAppTaskDefinition,
        availability: LocalAppAvailability
    ) async -> LocalAppTaskObservation {
        launchCount += 1
        return launchObservation
    }

    func observe(definition: LocalAppTaskDefinition) async -> LocalAppTaskObservation {
        observeCount += 1
        return finalObservation
    }
}

private actor RecordingLocalAppTaskInputBackend: ActionEngineInputBackend {
    private var keys: [String] = []

    func execute(_ command: ActionEngineCommand) async -> ActionEngineInputBackendResult {
        keys.append(command.key ?? "")
        return ActionEngineInputBackendResult(
            executed: true,
            completedAt: command.issuedAt,
            metadata: ["liveInputBackend": "recording-local-app-task"]
        )
    }

    func executedKeys() -> [String] {
        keys
    }
}
