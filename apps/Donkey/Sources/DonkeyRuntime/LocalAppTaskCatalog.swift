import AppKit
import DonkeyContracts
import Foundation

public struct LocalAppAvailability: Equatable, Sendable {
    public var target: LocalAppTarget
    public var isInstalled: Bool
    public var appURL: URL?
    public var metadata: [String: String]

    public init(
        target: LocalAppTarget,
        isInstalled: Bool,
        appURL: URL? = nil,
        metadata: [String: String] = [:]
    ) {
        self.target = target
        self.isInstalled = isInstalled
        self.appURL = appURL
        self.metadata = metadata
    }
}

public protocol LocalAppAvailabilityProviding: Sendable {
    func availability(for target: LocalAppTarget) -> LocalAppAvailability
}

public struct MacLocalAppAvailabilityProvider: LocalAppAvailabilityProviding {
    public init() {}

    public func availability(for target: LocalAppTarget) -> LocalAppAvailability {
        guard let bundleIdentifier = target.bundleIdentifier else {
            return LocalAppAvailability(
                target: target,
                isInstalled: false,
                metadata: ["reason": "missingBundleIdentifier"]
            )
        }

        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        return LocalAppAvailability(
            target: target,
            isInstalled: appURL != nil,
            appURL: appURL,
            metadata: [
                "bundleIdentifier": bundleIdentifier,
                "provider": "mac-nsworkspace"
            ]
        )
    }
}

public struct StaticLocalAppAvailabilityProvider: LocalAppAvailabilityProviding {
    public var installedBundleIdentifiers: Set<String>

    public init(installedBundleIdentifiers: Set<String>) {
        self.installedBundleIdentifiers = installedBundleIdentifiers
    }

    public func availability(for target: LocalAppTarget) -> LocalAppAvailability {
        let bundleIdentifier = target.bundleIdentifier ?? ""
        return LocalAppAvailability(
            target: target,
            isInstalled: installedBundleIdentifiers.contains(bundleIdentifier),
            metadata: [
                "bundleIdentifier": bundleIdentifier,
                "provider": "static"
            ]
        )
    }
}

public enum LocalAppTaskCatalogResolutionStatus: String, Equatable, Sendable {
    case resolved
    case needsConfirmation
    case unsupportedCommand
    case appUnavailable
}

public struct LocalAppTaskCatalogResolution: Equatable, Sendable {
    public var status: LocalAppTaskCatalogResolutionStatus
    public var intent: TaskIntent?
    public var definition: LocalAppTaskDefinition?
    public var availability: LocalAppAvailability?
    public var metadata: [String: String]

    public init(
        status: LocalAppTaskCatalogResolutionStatus,
        intent: TaskIntent? = nil,
        definition: LocalAppTaskDefinition? = nil,
        availability: LocalAppAvailability? = nil,
        metadata: [String: String] = [:]
    ) {
        self.status = status
        self.intent = intent
        self.definition = definition
        self.availability = availability
        self.metadata = metadata
    }
}

public struct LocalAppTaskCatalog: Sendable {
    public var taskDefinitions: [LocalAppTaskDefinition]
    public var availabilityProvider: any LocalAppAvailabilityProviding

    public init(
        taskDefinitions: [LocalAppTaskDefinition],
        availabilityProvider: any LocalAppAvailabilityProviding = MacLocalAppAvailabilityProvider()
    ) {
        self.taskDefinitions = taskDefinitions
        self.availabilityProvider = availabilityProvider
    }

    public func resolve(command: String) -> LocalAppTaskCatalogResolution {
        guard let intent = LocalAppTaskIntentParser(taskDefinitions: taskDefinitions).parse(command) else {
            return LocalAppTaskCatalogResolution(
                status: .unsupportedCommand,
                metadata: ["reason": "noTaskDefinitionMatched"]
            )
        }

        return resolve(intent: intent)
    }

    public func resolve(intent: TaskIntent) -> LocalAppTaskCatalogResolution {
        guard let definition = taskDefinitions.first(where: { supports(intent: intent, definition: $0) }) else {
            return LocalAppTaskCatalogResolution(
                status: .unsupportedCommand,
                intent: intent,
                metadata: ["reason": "parsedIntentDefinitionMissing"]
            )
        }

        if intent.needsConfirmation {
            return LocalAppTaskCatalogResolution(
                status: .needsConfirmation,
                intent: intent,
                definition: definition,
                metadata: ["reason": intent.metadata["missingEntity"] ?? "needsConfirmation"]
            )
        }

        let availability = availabilityProvider.availability(for: definition.targetApp)
        guard availability.isInstalled else {
            return LocalAppTaskCatalogResolution(
                status: .appUnavailable,
                intent: intent,
                definition: definition,
                availability: availability,
                metadata: ["reason": "targetAppUnavailable"]
            )
        }

        return LocalAppTaskCatalogResolution(
            status: .resolved,
            intent: intent,
            definition: definition,
            availability: availability,
            metadata: [
                "taskType": definition.taskType,
                "targetApp": definition.targetApp.appName
            ]
        )
    }

    public func adapter(for definition: LocalAppTaskDefinition) -> LocalAppTaskAdapter {
        LocalAppTaskAdapter(definition: definition)
    }

    private func supports(
        intent: TaskIntent,
        definition: LocalAppTaskDefinition
    ) -> Bool {
        intent.taskType == definition.taskType
            && intent.targetApp.appName == definition.targetApp.appName
            && intent.targetApp.bundleIdentifier == definition.targetApp.bundleIdentifier
    }
}

public enum BuiltInLocalAppTaskDefinitions {
    private static var commonWorkflowPrefix: [LocalAppTaskWorkflowStepDefinition] {
        [
            LocalAppTaskWorkflowStepDefinition(
                id: "parse-intent",
                role: .parseIntent,
                summary: "Parse the local app task intent"
            ),
            LocalAppTaskWorkflowStepDefinition(
                id: "launch-or-focus",
                role: .launchOrFocusApp,
                summary: "Launch or focus the target app"
            ),
            LocalAppTaskWorkflowStepDefinition(
                id: "observe-app",
                role: .observeApp,
                summary: "Observe the target app state",
                metadata: ["strategyOrder": "accessibility,windowMetadata,screenshotForLocalModel"]
            )
        ]
    }

    public static var weatherLookup: LocalAppTaskDefinition {
        LocalAppTaskDefinition(
            taskType: "weather_lookup",
            targetApp: LocalAppTarget(
                appName: "Weather",
                bundleIdentifier: "com.apple.weather",
                titleContains: "Weather"
            ),
            triggerTerms: ["weather", "forecast", "temperature", "temp"],
            entityRules: [
                LocalAppTaskEntityRule(
                    name: "city",
                    markers: ["for", "in", "at", "near"],
                    aliases: [
                        "sf": "San Francisco",
                        "san fran": "San Francisco",
                        "san francisco": "San Francisco",
                        "nyc": "New York",
                        "new york city": "New York",
                        "la": "Los Angeles",
                        "los angeles": "Los Angeles"
                    ]
                )
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
                    id: "verify-city",
                    role: .verifyResult,
                    summary: "Verify the visible result"
                )
            ],
            observationStrategies: [.accessibility, .windowMetadata, .screenshotForLocalModel],
            verificationEntityName: "city",
            metadata: [
                "catalogEntry": "built-in-weather-lookup",
                "verificationTextKey": "city",
                "visualFallback": "localModel",
                "ocrFallbackDefault": "false"
            ]
        )
    }

    public static var mediaPlayback: LocalAppTaskDefinition {
        LocalAppTaskDefinition(
            taskType: "media_playback",
            targetApp: LocalAppTarget(
                appName: "Music",
                bundleIdentifier: "com.apple.Music",
                titleContains: "Music"
            ),
            triggerTerms: ["play", "listen to", "put on"],
            entityRules: [
                LocalAppTaskEntityRule(
                    name: "query",
                    markers: ["play", "listen to", "put on"],
                    aliases: [
                        "cold play": "Coldplay",
                        "coldplay": "Coldplay"
                    ],
                    metadata: ["capture": "afterTrigger"]
                )
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
                    id: "verify-media-query",
                    role: .verifyResult,
                    summary: "Verify the requested media is visible or selected"
                )
            ],
            observationStrategies: [.accessibility, .windowMetadata, .screenshotForLocalModel],
            verificationEntityName: "query",
            metadata: [
                "catalogEntry": "built-in-media-playback",
                "verificationTextKey": "query",
                "domain": "media",
                "visualFallback": "localModel",
                "ocrFallbackDefault": "false"
            ]
        )
    }

    public static var documentFormFill: LocalAppTaskDefinition {
        LocalAppTaskDefinition(
            taskType: "document_form_fill",
            targetApp: LocalAppTarget(
                appName: "Preview",
                bundleIdentifier: "com.apple.Preview",
                titleContains: nil
            ),
            triggerTerms: ["fill pdf", "fill out pdf", "complete pdf", "fill form", "fill out this pdf"],
            entityRules: [
                LocalAppTaskEntityRule(
                    name: "document",
                    markers: ["fill", "complete"],
                    aliases: [
                        "this pdf": "current PDF",
                        "the pdf": "current PDF",
                        "this form": "current form"
                    ],
                    metadata: ["contextRole": "documentTarget"]
                ),
                LocalAppTaskEntityRule(
                    name: "dataSource",
                    markers: ["using", "with", "from"],
                    aliases: [
                        "this data": "provided data",
                        "the data": "provided data",
                        "these details": "provided data"
                    ],
                    metadata: ["contextRole": "structuredInputData"]
                )
            ],
            workflowSteps: commonWorkflowPrefix + [
                LocalAppTaskWorkflowStepDefinition(
                    id: "observe-form-fields",
                    role: .custom,
                    summary: "Discover fillable fields from Accessibility or bounded local UI understanding",
                    metadata: [
                        "requiresStructuredDataMapping": "true",
                        "preferredObservation": "accessibility,localModel"
                    ]
                ),
                LocalAppTaskWorkflowStepDefinition(
                    id: "map-data-to-fields",
                    role: .custom,
                    summary: "Map provided data to detected document fields",
                    metadata: [
                        "requiresUserData": "true",
                        "outputMustBeReviewed": "true"
                    ]
                ),
                LocalAppTaskWorkflowStepDefinition(
                    id: "verify-filled-document",
                    role: .verifyResult,
                    summary: "Verify all required fields have a proposed value"
                )
            ],
            observationStrategies: [.accessibility, .screenshotForLocalModel],
            verificationEntityName: "document",
            metadata: [
                "catalogEntry": "built-in-document-form-fill",
                "domain": "document",
                "requiresDocumentContext": "true",
                "requiresStructuredData": "true",
                "guardedLiveDefault": "reviewOnly",
                "visualFallback": "localModel",
                "ocrFallbackDefault": "false"
            ]
        )
    }

    public static var defaults: [LocalAppTaskDefinition] {
        [
            weatherLookup,
            mediaPlayback,
            documentFormFill
        ]
    }
}
