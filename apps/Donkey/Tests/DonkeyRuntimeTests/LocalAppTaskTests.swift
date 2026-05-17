import DonkeyContracts
@testable import DonkeyRuntime
import Foundation
import Testing

@Suite
struct LocalAppTaskTests {
    @Test
    func deterministicParserBuildsGenericTaskIntentWithAliasExpansion() throws {
        let intent = try #require(parser().parse("show me the weather for SF"))

        #expect(intent.taskType == "weather_lookup")
        #expect(intent.targetApp.appName == "Weather")
        #expect(intent.targetApp.bundleIdentifier == "com.apple.weather")
        #expect(intent.entities["city"] == "sf")
        #expect(intent.normalizedEntities["city"] == "San Francisco")
        #expect(intent.confidence == 0.96)
        #expect(intent.parserSource == .deterministic)
        #expect(intent.needsConfirmation == false)
        #expect(intent.metadata["catalogEntry"] == "built-in-weather-lookup")
        #expect(intent.metadata["entityAliasExpanded"] == "true")
    }

    @Test
    func deterministicParserBuildsMediaPlaybackIntentWithoutWeatherSpecificCode() throws {
        let intent = try #require(parser().parse("play cold play"))

        #expect(intent.taskType == "media_playback")
        #expect(intent.targetApp.appName == "Music")
        #expect(intent.targetApp.bundleIdentifier == "com.apple.Music")
        #expect(intent.entities["query"] == "cold play")
        #expect(intent.normalizedEntities["query"] == "Coldplay")
        #expect(intent.metadata["catalogEntry"] == "built-in-media-playback")
    }

    @Test
    func deterministicParserBuildsDocumentFormFillIntentAsReviewOnlyTask() throws {
        let intent = try #require(parser().parse("fill out this PDF using this data"))

        #expect(intent.taskType == "document_form_fill")
        #expect(intent.targetApp.appName == "Preview")
        #expect(intent.normalizedEntities["document"] == "current PDF")
        #expect(intent.normalizedEntities["dataSource"] == "provided data")
        #expect(intent.metadata["requiresDocumentContext"] == "true")

        let plan = LocalAppTaskAdapter(definition: BuiltInLocalAppTaskDefinitions.documentFormFill)
            .dryRunPlan(for: intent)
        #expect(plan.canAttemptGuardedLive == false)
        #expect(plan.metadata["guardedLiveDefault"] == "reviewOnly")
        #expect(plan.steps.map(\.role).contains(.custom))
    }

    @Test
    func deterministicParserRequestsConfirmationForMissingRequiredEntity() throws {
        let intent = try #require(parser().parse("show me the weather"))

        #expect(intent.taskType == "weather_lookup")
        #expect(intent.intentID == "weather_lookup-needs-city")
        #expect(intent.needsConfirmation == true)
        #expect(intent.metadata["missingEntity"] == "city")
    }

    @Test
    func deterministicParserIgnoresUnsupportedCommands() {
        #expect(parser().parse("open my calendar") == nil)
    }

    @Test
    func genericAdapterBuildsLocalNavigationRequestForTargetApp() throws {
        let intent = try #require(parser().parse("weather in San Francisco"))
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
    func genericAdapterProjectsDryRunStepsAndGuardedKeyboardTemplates() throws {
        let intent = try #require(parser().parse("show me the weather for SF"))
        let localAdapter = adapter()

        let plan = localAdapter.dryRunPlan(for: intent)
        #expect(plan.terminalState == .needsUserReview)
        #expect(plan.canAttemptGuardedLive == true)
        #expect(plan.verificationConfidence == 0)
        #expect(plan.steps.map(\.role) == [
            .parseIntent,
            .launchOrFocusApp,
            .observeApp,
            .focusControl,
            .enterText,
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
        #expect(commands.map(\.kind) == [.key, .key, .key])
        #expect(commands.map(\.key) == ["Command+F", "San Francisco", "Return"])
        #expect(commands[1].metadata["workflowStepRole"] == "enterText")
        #expect(commands[1].metadata["text"] == "San Francisco")
        #expect(commands[1].metadata["bundleIdentifier"] == "com.apple.weather")
    }

    @Test
    func genericAdapterVerifiesObservedVisibleText() throws {
        let intent = try #require(parser().parse("weather for SF"))
        let localAdapter = adapter()
        let plan = localAdapter.dryRunPlan(
            for: intent,
            observation: LocalAppTaskObservation(
                appIsRunning: true,
                appIsFocused: true,
                availableControls: ["search": true],
                visibleText: ["city": "San Francisco, CA"],
                confidence: 0.91
            )
        )

        #expect(plan.terminalState == .completed)
        #expect(plan.verificationConfidence == 0.91)
        #expect(plan.steps.first(where: { $0.role == .verifyResult })?.status == .verified)
        #expect(localAdapter.verifiesVisibleText("San Francisco, CA", matches: intent) == true)
        #expect(localAdapter.verifiesVisibleText("New York", matches: intent) == false)
    }

    @Test
    func catalogResolvesCommandAgainstAvailableInstalledAppDefinition() throws {
        let catalog = LocalAppTaskCatalog(
            taskDefinitions: BuiltInLocalAppTaskDefinitions.defaults,
            availabilityProvider: StaticLocalAppAvailabilityProvider(installedBundleIdentifiers: [
                "com.apple.weather",
                "com.apple.Music",
                "com.apple.Preview"
            ])
        )

        let resolution = catalog.resolve(command: "show me the weather for SF")

        #expect(resolution.status == .resolved)
        #expect(resolution.intent?.normalizedEntities["city"] == "San Francisco")
        #expect(resolution.definition?.taskType == "weather_lookup")
        #expect(resolution.definition?.observationStrategies == [.accessibility, .windowMetadata, .screenshotForLocalModel])
        #expect(resolution.availability?.isInstalled == true)

        let definition = try #require(resolution.definition)
        let intent = try #require(resolution.intent)
        let plan = catalog.adapter(for: definition).dryRunPlan(for: intent)
        #expect(plan.steps.map(\.role).contains(.verifyResult))

        let mediaResolution = catalog.resolve(command: "play Coldplay")
        #expect(mediaResolution.status == .resolved)
        #expect(mediaResolution.definition?.taskType == "media_playback")

        let documentResolution = catalog.resolve(command: "fill out this PDF using this data")
        #expect(documentResolution.status == .resolved)
        #expect(documentResolution.definition?.taskType == "document_form_fill")
    }

    @Test
    func catalogSeparatesUnsupportedMissingEntityAndUnavailableApp() {
        let availableCatalog = LocalAppTaskCatalog(
            taskDefinitions: BuiltInLocalAppTaskDefinitions.defaults,
            availabilityProvider: StaticLocalAppAvailabilityProvider(installedBundleIdentifiers: ["com.apple.weather"])
        )
        #expect(availableCatalog.resolve(command: "open my calendar").status == .unsupportedCommand)
        #expect(availableCatalog.resolve(command: "show me the weather").status == .needsConfirmation)

        let unavailableCatalog = LocalAppTaskCatalog(
            taskDefinitions: BuiltInLocalAppTaskDefinitions.defaults,
            availabilityProvider: StaticLocalAppAvailabilityProvider(installedBundleIdentifiers: [])
        )
        #expect(unavailableCatalog.resolve(command: "show me the weather for SF").status == .appUnavailable)
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
            triggerTerms: ["note", "remember"],
            entityRules: [
                LocalAppTaskEntityRule(
                    name: "note",
                    markers: ["note", "remember"],
                    metadata: ["capture": "afterTrigger"]
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

        let definitions = try LocalAppTaskDefinitionLoader().mergedWithBuiltIns(from: directoryURL)
        let loaded = try #require(definitions.first(where: { $0.taskType == "notes_capture" }))
        #expect(loaded.targetApp.bundleIdentifier == "com.apple.Notes")
        #expect(loaded.metadata["source"] == "test-json")

        let catalog = LocalAppTaskCatalog(
            taskDefinitions: definitions,
            availabilityProvider: StaticLocalAppAvailabilityProvider(installedBundleIdentifiers: ["com.apple.Notes"])
        )
        #expect(catalog.resolve(command: "remember buy milk").status == .resolved)
    }

    @Test
    func documentFormFillPlannerMapsStructuredDataToObservedFieldsForReview() throws {
        let intent = try #require(parser().parse("fill out this PDF using this data"))
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
        let intent = try #require(parser().parse("fill out this PDF using this data"))
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

    @Test @MainActor
    func liveRunnerReturnsReviewPlanForDocumentFormFillWithoutExecutingInput() async throws {
        let catalog = LocalAppTaskCatalog(
            taskDefinitions: BuiltInLocalAppTaskDefinitions.defaults,
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

        let result = await runner.run(
            command: "fill out this PDF using this data",
            traceID: "trace-document-fill"
        )

        #expect(result.status == .needsUserReview)
        #expect(result.actionTraces.isEmpty)
        #expect(result.documentFormFillPlan?.status == .readyForReview)
        #expect(result.documentFormFillPlan?.proposals.first?.proposedValue == "Grace Hopper")
        #expect(result.metadata["reason"] == "reviewOnlyTask")
    }

    @Test @MainActor
    func liveRunnerLaunchesFocusesExecutesGuardedCommandsAndVerifies() async throws {
        let backend = RecordingLocalAppTaskInputBackend()
        let controller = FakeLocalAppTaskAppController(
            launchObservation: LocalAppTaskObservation(
                appIsRunning: true,
                appIsFocused: true,
                availableControls: ["search": true],
                confidence: 0.5
            ),
            finalObservation: LocalAppTaskObservation(
                appIsRunning: true,
                appIsFocused: true,
                availableControls: ["search": true],
                visibleText: ["city": "San Francisco, CA"],
                confidence: 0.92
            )
        )
        let catalog = LocalAppTaskCatalog(
            taskDefinitions: BuiltInLocalAppTaskDefinitions.defaults,
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

        let result = await runner.run(command: "show me the weather for SF", traceID: "trace-live-task")

        #expect(result.status == .completed)
        #expect(result.finalPlan?.terminalState == .completed)
        #expect(result.actionTraces.count == 3)
        #expect(result.actionTraces.allSatisfy { $0.executed })
        #expect(await backend.executedKeys() == ["Command+F", "San Francisco", "Return"])
        #expect(controller.launchCount == 1)
        #expect(controller.observeCount == 1)
    }

    private func parser() -> LocalAppTaskIntentParser {
        LocalAppTaskIntentParser(taskDefinitions: BuiltInLocalAppTaskDefinitions.defaults)
    }

    private func adapter() -> LocalAppTaskAdapter {
        LocalAppTaskAdapter(definition: BuiltInLocalAppTaskDefinitions.weatherLookup)
    }

    private func timestamp(_ milliseconds: UInt64) -> RunTraceTimestamp {
        RunTraceTimestamp(
            wallClock: Date(timeIntervalSince1970: Double(milliseconds) / 1_000),
            monotonicUptimeNanoseconds: milliseconds * 1_000_000
        )
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
