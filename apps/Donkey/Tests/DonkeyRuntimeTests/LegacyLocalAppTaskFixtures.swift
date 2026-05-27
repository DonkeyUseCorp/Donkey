import DonkeyContracts
@testable import DonkeyRuntime

extension BuiltInLocalAppTaskDefinitions {
    static var weatherLookup: LocalAppTaskDefinition {
        LocalAppTaskDefinition(
            taskType: "weather_lookup",
            targetApp: LocalAppTarget(
                appName: "Weather",
                bundleIdentifier: "com.apple.weather",
                titleContains: "Weather"
            ),
            triggerTerms: [],
            entityRules: [
                LocalAppTaskEntityRule(name: "city")
            ],
            workflowSteps: commonWorkflowPrefix + [
                LocalAppTaskWorkflowStepDefinition(
                    id: "focus-search",
                    role: .focusControl,
                    summary: "Focus the task control",
                    metadata: [
                        "controlID": "search",
                        "key": "Command+F"
                    ]
                ),
                LocalAppTaskWorkflowStepDefinition(
                    id: "enter-city",
                    role: .enterText,
                    summary: "Enter the normalized entity",
                    metadata: ["entityName": "city"]
                ),
                LocalAppTaskWorkflowStepDefinition(
                    id: "submit-search",
                    role: .submit,
                    summary: "Submit the task",
                    metadata: ["key": "Return"]
                ),
                LocalAppTaskWorkflowStepDefinition(
                    id: "select-city-result",
                    role: .submit,
                    summary: "Select the matching city result",
                    metadata: ["key": "Return"]
                ),
                LocalAppTaskWorkflowStepDefinition(
                    id: "verify-city",
                    role: .verifyResult,
                    summary: "Verify the visible result"
                )
            ],
            observationStrategies: [.accessibility, .windowMetadata, .screenshotForLocalModel],
            verificationEntityName: "city",
            metadata: [
                "catalogEntry": "test-weather-lookup",
                "displayTitle": "weather lookup",
                "taskLabelTemplate": "Weather for {city}",
                "verificationTextKey": "city",
                "screenshotFallback": "missingVerificationOrControls",
                "visualFallback": "localModel",
                "ocrFallbackDefault": "false"
            ]
        )
    }

    static var benchmarkFixtures: [LocalAppTaskDefinition] {
        [
            LocalAppTaskCatalog.genericLocalItemOpenDefinition,
            LocalAppTaskCatalog.genericLocalAppInteractionDefinition,
            weatherLookup,
            documentFormFill
        ]
    }
}
