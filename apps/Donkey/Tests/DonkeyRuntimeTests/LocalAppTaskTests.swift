import DonkeyContracts
import DonkeyHarness
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
    func modelIntentCanRequestConfirmationForMissingRequiredEntity() throws {
        let intent = weatherIntent(rawCity: "", city: "", needsConfirmation: true)

        #expect(intent.taskType == "weather_lookup")
        #expect(intent.intentID == "weather_lookup-needs-city")
        #expect(intent.needsConfirmation == true)
        #expect(intent.metadata["missingEntity"] == "city")
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

        #expect(music.supportStatus == .supported)
        #expect(music.capabilities.map(\.id) == ["play_media"])
        #expect(music.capabilities.first?.controlProfiles == ["search_then_enter"])
        #expect(terminal.supportStatus == .denied)
        #expect(terminal.capabilities.isEmpty)
        #expect(terminal.denyReason?.contains("shell") == true)
        #expect(draftPad.supportStatus == .candidate)
        #expect(draftPad.capabilities.isEmpty)
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

    private func adapter() -> LocalAppTaskAdapter {
        LocalAppTaskAdapter(definition: BuiltInLocalAppTaskDefinitions.weatherLookup)
    }

    private func slug(_ value: String) -> String {
        LocalAppTextNormalizer.normalizedPhrase(value)
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
    private var commands: [ActionEngineCommand] = []

    func execute(_ command: ActionEngineCommand) async -> ActionEngineInputBackendResult {
        commands.append(command)
        keys.append(command.key ?? "")
        return ActionEngineInputBackendResult(
            executed: true,
            completedAt: command.issuedAt,
            metadata: [
                "liveInputBackend": "recording-local-app-task",
                "inputMode": command.kind == .tap ? "coordinateClick" : "keyCommand",
                "elementClick": String(command.kind == .tap),
                "controlID": command.metadata["controlID"] ?? ""
            ]
        )
    }

    func executedKeys() -> [String] {
        keys
    }

    func executedCommands() -> [ActionEngineCommand] {
        commands
    }
}
