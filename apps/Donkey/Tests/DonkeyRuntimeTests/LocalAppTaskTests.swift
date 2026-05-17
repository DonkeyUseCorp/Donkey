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
        #expect(plan.metadata["defaultOSInputBackendAvailable"] == "false")
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
            availabilityProvider: StaticLocalAppAvailabilityProvider(installedBundleIdentifiers: ["com.apple.weather"])
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

    private func parser() -> LocalAppTaskIntentParser {
        LocalAppTaskIntentParser(taskDefinitions: [BuiltInLocalAppTaskDefinitions.weatherLookup])
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
