import DonkeyContracts
import Foundation

enum LocalAppTaskVerificationMode: String, Equatable, Sendable {
    case focusedApp
    case openedLocalItem
    case commandAttempted
    case visibleText
}

struct LocalAppTaskVerificationResult: Equatable, Sendable {
    var status: LocalAppTaskStepStatus
    var terminalState: LocalAppTaskTerminalState
    var confidence: Double
    var summary: String
    var metadata: [String: String]
}

enum LocalAppTaskVerificationPolicy {
    static func mode(for definition: LocalAppTaskDefinition) -> LocalAppTaskVerificationMode {
        switch definition.metadata["verificationMode"] {
        case "focusedApp":
            return .focusedApp
        case "openedLocalItem":
            return .openedLocalItem
        case "playbackCommandAttempted", "commandAttempted":
            return .commandAttempted
        case "visibleText":
            return .visibleText
        default:
            if let itemKind = definition.metadata["localItem.kind"], !itemKind.isEmpty {
                return itemKind == LocalItemKind.application.rawValue ? .focusedApp : .openedLocalItem
            }
            if definition.metadata["automationBackend"]?.isEmpty == false {
                return .commandAttempted
            }
            return .visibleText
        }
    }

    static func verify(
        intent: TaskIntent,
        definition: LocalAppTaskDefinition,
        observation: LocalAppTaskObservation?
    ) -> LocalAppTaskVerificationResult {
        switch mode(for: definition) {
        case .focusedApp:
            return verifyFocusedApp(definition: definition, observation: observation)
        case .openedLocalItem:
            return verifyOpenedLocalItem(definition: definition, observation: observation)
        case .commandAttempted:
            return verifyCommandAttempted(definition: definition, observation: observation)
        case .visibleText:
            return verifyVisibleText(intent: intent, definition: definition, observation: observation)
        }
    }

    private static func verifyFocusedApp(
        definition: LocalAppTaskDefinition,
        observation: LocalAppTaskObservation?
    ) -> LocalAppTaskVerificationResult {
        guard let observation else {
            return blocked(
                summary: "Target app has not been observed yet",
                metadata: ["reason": "missingObservation"]
            )
        }

        if observation.appIsFocused {
            return verified(
                confidence: max(observation.confidence, 0.8),
                summary: "Target app is focused",
                metadata: [
                    "verificationMode": modeName(for: definition),
                    "targetApp": definition.targetApp.appName
                ]
            )
        }

        return blocked(
            confidence: observation.confidence,
            summary: "Target app is not focused",
            metadata: [
                "reason": "targetAppNotFocused",
                "verificationMode": modeName(for: definition),
                "targetApp": definition.targetApp.appName
            ]
        )
    }

    private static func verifyOpenedLocalItem(
        definition: LocalAppTaskDefinition,
        observation: LocalAppTaskObservation?
    ) -> LocalAppTaskVerificationResult {
        guard let observation else {
            return blocked(
                summary: "Local item has not been observed yet",
                metadata: ["reason": "missingObservation"]
            )
        }

        if observation.metadata["openedLocalItem"] == "true" || observation.appIsFocused {
            return verified(
                confidence: max(observation.confidence, 0.72),
                summary: "Local item was opened",
                metadata: [
                    "verificationMode": modeName(for: definition),
                    "targetItem": definition.targetApp.appName,
                    "localItem.kind": definition.metadata["localItem.kind"] ?? ""
                ]
            )
        }

        return blocked(
            confidence: observation.confidence,
            summary: "Local item could not be confirmed open",
            metadata: [
                "reason": "localItemOpenUnconfirmed",
                "verificationMode": modeName(for: definition),
                "targetItem": definition.targetApp.appName
            ]
        )
    }

    private static func verifyCommandAttempted(
        definition: LocalAppTaskDefinition,
        observation: LocalAppTaskObservation?
    ) -> LocalAppTaskVerificationResult {
        guard let observation else {
            return blocked(
                summary: "\(definition.targetApp.appName) has not been observed yet",
                metadata: ["reason": "missingObservation"]
            )
        }

        if observation.appIsFocused || observation.appIsRunning {
            return verified(
                confidence: max(observation.confidence, 0.72),
                summary: "Command was sent to \(definition.targetApp.appName)",
                metadata: [
                    "verificationMode": modeName(for: definition),
                    "targetApp": definition.targetApp.appName
                ]
            )
        }

        return blocked(
            confidence: observation.confidence,
            summary: "\(definition.targetApp.appName) is not running for command verification",
            metadata: [
                "reason": "targetAppNotRunning",
                "verificationMode": modeName(for: definition),
                "targetApp": definition.targetApp.appName
            ]
        )
    }

    private static func verifyVisibleText(
        intent: TaskIntent,
        definition: LocalAppTaskDefinition,
        observation: LocalAppTaskObservation?
    ) -> LocalAppTaskVerificationResult {
        guard let entityName = definition.verificationEntityName,
              let expected = intent.normalizedEntities[entityName]
        else {
            return blocked(
                summary: "No verification entity is configured for this task",
                metadata: ["reason": "missingVerificationEntity"]
            )
        }

        guard let observation else {
            return blocked(
                summary: "Visible app result has not been observed yet",
                metadata: [
                    "reason": "missingObservation",
                    "expectedEntityName": entityName,
                    "expectedEntityValue": expected
                ]
            )
        }

        let visibleTextKey = definition.metadata["verificationTextKey"] ?? entityName
        guard let visibleText = observation.visibleText[visibleTextKey] else {
            return blocked(
                confidence: observation.confidence,
                summary: "Verification text is not available yet",
                metadata: [
                    "reason": "missingVisibleText",
                    "visibleTextKey": visibleTextKey,
                    "expectedEntityValue": expected
                ]
            )
        }

        if normalized(visibleText).contains(normalized(expected)) {
            return verified(
                confidence: max(observation.confidence, 0.8),
                summary: "Visible app result matches the requested entity",
                metadata: [
                    "visibleText": visibleText,
                    "expectedEntityName": entityName,
                    "expectedEntityValue": expected
                ]
            )
        }

        return blocked(
            confidence: observation.confidence,
            summary: "Visible app result does not match the requested entity",
            metadata: [
                "reason": "resultMismatch",
                "visibleText": visibleText,
                "expectedEntityName": entityName,
                "expectedEntityValue": expected
            ]
        )
    }

    private static func verified(
        confidence: Double,
        summary: String,
        metadata: [String: String]
    ) -> LocalAppTaskVerificationResult {
        LocalAppTaskVerificationResult(
            status: .verified,
            terminalState: .completed,
            confidence: confidence,
            summary: summary,
            metadata: metadata
        )
    }

    private static func blocked(
        confidence: Double = 0,
        summary: String,
        metadata: [String: String]
    ) -> LocalAppTaskVerificationResult {
        LocalAppTaskVerificationResult(
            status: .blocked,
            terminalState: .needsUserReview,
            confidence: confidence,
            summary: summary,
            metadata: metadata
        )
    }

    private static func modeName(for definition: LocalAppTaskDefinition) -> String {
        definition.metadata["verificationMode"] ?? mode(for: definition).rawValue
    }

    private static func normalized(_ value: String) -> String {
        LocalAppTaskIntentParser.normalizedPhrase(value)
    }
}
