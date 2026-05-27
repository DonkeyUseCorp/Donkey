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

    static var mediaPlayback: LocalAppTaskDefinition {
        var metadata: [String: String] = [
            "catalogEntry": "test-media-playback",
            "displayTitle": "media playback",
            "taskLabelTemplate": "Play {query}",
            "verificationTextKey": "query",
            "verificationMode": "playbackCommandAttempted",
            "automationBackend": "appleScript",
            "appleScript.action": "music.playMediaQuery",
            "appleScript.entityName": "query",
            "appleScript.successOutputs": "played-library-track,searched-ui-first-result",
            "screenshotFallback": "missingVerificationOrControls",
            "domain": "media",
            "visualFallback": "localModel",
            "ocrFallbackDefault": "false",
            "skillID": "music-media",
            "skillScriptID": "scripts-play-media-query-applescript"
        ]
        if let template = BuiltInLocalAppSkillPacks.scriptSource(
            skillID: "music-media",
            relativePath: "scripts/play-media-query.applescript"
        ) {
            metadata["appleScript.template"] = template
        }

        return LocalAppTaskDefinition(
            taskType: "media_playback",
            targetApp: LocalAppTarget(
                appName: "Music",
                bundleIdentifier: "com.apple.Music",
                titleContains: "Music"
            ),
            triggerTerms: [],
            entityRules: [
                LocalAppTaskEntityRule(name: "query")
            ],
            workflowSteps: commonWorkflowPrefix + [
                LocalAppTaskWorkflowStepDefinition(
                    id: "focus-search",
                    role: .focusControl,
                    summary: "Focus the app search control",
                    metadata: [
                        "controlID": "search",
                        "key": "Command+F"
                    ]
                ),
                LocalAppTaskWorkflowStepDefinition(
                    id: "enter-media-query",
                    role: .enterText,
                    summary: "Enter the requested media query",
                    metadata: ["entityName": "query"]
                ),
                LocalAppTaskWorkflowStepDefinition(
                    id: "submit-media-search",
                    role: .submit,
                    summary: "Submit the media search or playback command",
                    metadata: ["key": "Return"]
                ),
                LocalAppTaskWorkflowStepDefinition(
                    id: "play-first-media-result",
                    role: .submit,
                    summary: "Play the first matching media result",
                    metadata: ["key": "Return"]
                ),
                LocalAppTaskWorkflowStepDefinition(
                    id: "verify-media-query",
                    role: .verifyResult,
                    summary: "Verify the playback command was sent"
                )
            ],
            observationStrategies: [.accessibility, .windowMetadata, .screenshotForLocalModel],
            verificationEntityName: "query",
            metadata: metadata
        )
    }

    static var benchmarkFixtures: [LocalAppTaskDefinition] {
        [
            LocalAppTaskCatalog.genericLocalItemOpenDefinition,
            LocalAppTaskCatalog.genericLocalAppInteractionDefinition,
            weatherLookup,
            mediaPlayback,
            documentFormFill
        ]
    }
}
