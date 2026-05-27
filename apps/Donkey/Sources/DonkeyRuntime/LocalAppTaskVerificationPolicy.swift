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
        mode(for: definition, tool: nil)
    }

    static func mode(
        for definition: LocalAppTaskDefinition,
        tool: LocalAppActionPlanTool?
    ) -> LocalAppTaskVerificationMode {
        switch tool {
        case .verifyCommand:
            return .commandAttempted
        case .verifyVisibleText:
            return .visibleText
        case .openOrFocusApp, .observeApp, .newDocument, .focusSearch, .focusAddressBar,
             .focusTextEntry, .setText, .clickTarget, .pressReturn, nil:
            break
        }

        switch definition.metadata["verificationMode"] {
        case "focusedApp":
            return .focusedApp
        case "openedLocalItem":
            return .openedLocalItem
        case "commandAttempted":
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
        observation: LocalAppTaskObservation?,
        tool: LocalAppActionPlanTool? = nil
    ) -> LocalAppTaskVerificationResult {
        switch mode(for: definition, tool: tool) {
        case .focusedApp:
            return verifyFocusedApp(definition: definition, observation: observation, tool: tool)
        case .openedLocalItem:
            return verifyOpenedLocalItem(definition: definition, observation: observation, tool: tool)
        case .commandAttempted:
            return verifyCommandAttempted(definition: definition, observation: observation, tool: tool)
        case .visibleText:
            return verifyVisibleText(intent: intent, definition: definition, observation: observation, tool: tool)
        }
    }

    private static func verifyFocusedApp(
        definition: LocalAppTaskDefinition,
        observation: LocalAppTaskObservation?,
        tool: LocalAppActionPlanTool?
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
                    "verificationMode": modeName(for: definition, tool: tool),
                    "verificationTool": tool?.rawValue ?? "",
                    "targetApp": definition.targetApp.appName
                ]
            )
        }

        return blocked(
            confidence: observation.confidence,
            summary: "Target app is not focused",
            metadata: [
                "reason": "targetAppNotFocused",
                "verificationMode": modeName(for: definition, tool: tool),
                "verificationTool": tool?.rawValue ?? "",
                "targetApp": definition.targetApp.appName
            ]
        )
    }

    private static func verifyOpenedLocalItem(
        definition: LocalAppTaskDefinition,
        observation: LocalAppTaskObservation?,
        tool: LocalAppActionPlanTool?
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
                    "verificationMode": modeName(for: definition, tool: tool),
                    "verificationTool": tool?.rawValue ?? "",
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
                "verificationMode": modeName(for: definition, tool: tool),
                "verificationTool": tool?.rawValue ?? "",
                "targetItem": definition.targetApp.appName
            ]
        )
    }

    private static func verifyCommandAttempted(
        definition: LocalAppTaskDefinition,
        observation: LocalAppTaskObservation?,
        tool: LocalAppActionPlanTool?
    ) -> LocalAppTaskVerificationResult {
        guard let observation else {
            return blocked(
                summary: "\(definition.targetApp.appName) has not been observed yet",
                metadata: ["reason": "missingObservation"]
            )
        }

        guard observation.metadata["postActionObservation"] == "true" else {
            return blocked(
                confidence: observation.confidence,
                summary: "No post-action observation has been recorded for \(definition.targetApp.appName)",
                metadata: [
                    "reason": "missingPostActionObservation",
                    "verificationMode": modeName(for: definition, tool: tool),
                    "verificationTool": tool?.rawValue ?? "",
                    "targetApp": definition.targetApp.appName
                ]
            )
        }

        let executedCommandCount = Int(observation.metadata["executedCommandCount"] ?? "") ?? 0
        guard executedCommandCount > 0 else {
            return blocked(
                confidence: observation.confidence,
                summary: "No guarded command execution has been recorded for \(definition.targetApp.appName)",
                metadata: [
                    "reason": "missingCommandExecutionEvidence",
                    "verificationMode": modeName(for: definition, tool: tool),
                    "verificationTool": tool?.rawValue ?? "",
                    "targetApp": definition.targetApp.appName
                ]
            )
        }

        if observation.appIsFocused || observation.appIsRunning {
            return verified(
                confidence: max(observation.confidence, 0.72),
                summary: "Command was sent to \(definition.targetApp.appName)",
                metadata: [
                    "verificationMode": modeName(for: definition, tool: tool),
                    "verificationTool": tool?.rawValue ?? "",
                    "targetApp": definition.targetApp.appName,
                    "executedCommandCount": observation.metadata["executedCommandCount"] ?? "",
                    "submittedCommandCount": observation.metadata["submittedCommandCount"] ?? ""
                ]
            )
        }

        return blocked(
            confidence: observation.confidence,
            summary: "\(definition.targetApp.appName) is not running for command verification",
            metadata: [
                "reason": "targetAppNotRunning",
                "verificationMode": modeName(for: definition, tool: tool),
                "verificationTool": tool?.rawValue ?? "",
                "targetApp": definition.targetApp.appName
            ]
        )
    }

    private static func verifyVisibleText(
        intent: TaskIntent,
        definition: LocalAppTaskDefinition,
        observation: LocalAppTaskObservation?,
        tool: LocalAppActionPlanTool?
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
                    "verificationTool": tool?.rawValue ?? "",
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
                    "verificationTool": tool?.rawValue ?? "",
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
                    "verificationTool": tool?.rawValue ?? "",
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
                "verificationTool": tool?.rawValue ?? "",
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

    private static func modeName(
        for definition: LocalAppTaskDefinition,
        tool: LocalAppActionPlanTool?
    ) -> String {
        mode(for: definition, tool: tool).rawValue
    }

    private static func normalized(_ value: String) -> String {
        LocalAppTextNormalizer.normalizedPhrase(value)
    }
}
