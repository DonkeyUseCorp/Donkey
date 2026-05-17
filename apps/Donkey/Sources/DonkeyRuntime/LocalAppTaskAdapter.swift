import DonkeyContracts
import Foundation

public struct LocalAppTaskAdapter: Sendable {
    public var definition: LocalAppTaskDefinition

    public init(definition: LocalAppTaskDefinition) {
        self.definition = definition
    }

    public func localNavigationFrameRequest(
        for intent: TaskIntent,
        traceID: String,
        maxFrameCount: Int = 1
    ) -> LocalNavigationMetadataFrameRequest? {
        guard supports(intent) else { return nil }

        return LocalNavigationMetadataFrameRequest(
            targetID: targetID,
            traceID: traceID,
            maxFrameCount: maxFrameCount,
            requestedBundleIdentifier: definition.targetApp.bundleIdentifier,
            requestedTitleContains: definition.targetApp.titleContains
        )
    }

    public func dryRunPlan(
        for intent: TaskIntent,
        observation: LocalAppTaskObservation? = nil
    ) -> LocalAppTaskDryRunPlan {
        guard supports(intent), intent.needsConfirmation == false else {
            return LocalAppTaskDryRunPlan(
                intent: intent,
                targetApp: definition.targetApp,
                steps: [
                    LocalAppTaskDryRunStep(
                        id: "parse-intent",
                        role: .parseIntent,
                        status: .blocked,
                        summary: "Local app task intent is unsupported or incomplete",
                        metadata: ["reason": "unsupportedOrIncompleteIntent"]
                    )
                ],
                terminalState: .failedSafe,
                canAttemptGuardedLive: false,
                verificationConfidence: 0,
                metadata: planMetadata
            )
        }

        let verification = verificationStatus(for: intent, observation: observation)
        let steps = resolvedWorkflowSteps(
            intent: intent,
            observation: observation,
            verification: verification
        )

        return LocalAppTaskDryRunPlan(
            intent: intent,
            targetApp: definition.targetApp,
            steps: steps,
            terminalState: verification.terminalState,
            canAttemptGuardedLive: definition.metadata["guardedLiveDefault"] != "reviewOnly"
                && verification.terminalState != .failedSafe,
            verificationConfidence: verification.confidence,
            metadata: planMetadata
        )
    }

    public func guardedKeyboardCommandTemplates(
        for intent: TaskIntent,
        issuedAt: RunTraceTimestamp
    ) -> [ActionEngineCommand] {
        guard supports(intent), intent.needsConfirmation == false else { return [] }

        return definition.workflowSteps.compactMap { step in
            switch step.role {
            case .focusControl:
                guard let key = step.metadata["key"] else { return nil }
                return command(
                    idSuffix: step.id,
                    intent: intent,
                    issuedAt: issuedAt,
                    key: key,
                    role: step.role,
                    metadata: step.metadata
                )
            case .enterText:
                let entityName = step.metadata["entityName"] ?? definition.verificationEntityName
                guard let entityName,
                      let text = intent.normalizedEntities[entityName]
                else {
                    return nil
                }
                return command(
                    idSuffix: step.id,
                    intent: intent,
                    issuedAt: issuedAt,
                    key: text,
                    role: step.role,
                    metadata: step.metadata.merging([
                        "inputRole": "textEntry",
                        "text": text
                    ]) { current, _ in current }
                )
            case .submit:
                guard let key = step.metadata["key"] else { return nil }
                return command(
                    idSuffix: step.id,
                    intent: intent,
                    issuedAt: issuedAt,
                    key: key,
                    role: step.role,
                    metadata: step.metadata
                )
            case .parseIntent, .launchOrFocusApp, .observeApp, .verifyResult, .custom:
                return nil
            }
        }
    }

    public func verifiesVisibleText(
        _ visibleText: String?,
        matches intent: TaskIntent
    ) -> Bool {
        guard let entityName = definition.verificationEntityName,
              let expected = intent.normalizedEntities[entityName],
              let visibleText
        else {
            return false
        }

        return Self.normalizedText(visibleText).contains(Self.normalizedText(expected))
    }

    public var targetID: String {
        "local-app-task-\(slug(definition.taskType))"
    }

    private var planMetadata: [String: String] {
        [
            "adapter": "local-app-task-adapter-v1",
            "taskType": definition.taskType,
            "appName": definition.targetApp.appName,
            "bundleIdentifier": definition.targetApp.bundleIdentifier ?? "",
            "guardedLiveRequiresInputPolicy": "true",
            "defaultOSInputBackendAvailable": "true",
            "defaultOSInputBackend": "mac-keyboard"
        ].merging(definition.metadata) { current, _ in current }
    }

    private func resolvedWorkflowSteps(
        intent: TaskIntent,
        observation: LocalAppTaskObservation?,
        verification: (
            status: LocalAppTaskStepStatus,
            terminalState: LocalAppTaskTerminalState,
            confidence: Double,
            summary: String,
            metadata: [String: String]
        )
    ) -> [LocalAppTaskDryRunStep] {
        if definition.workflowSteps.isEmpty {
            return [
                LocalAppTaskDryRunStep(
                    id: "parse-intent",
                    role: .parseIntent,
                    status: .verified,
                    summary: "Parsed local app task intent",
                    metadata: ["taskType": intent.taskType]
                )
            ]
        }

        return definition.workflowSteps.map { step in
            LocalAppTaskDryRunStep(
                id: step.id,
                role: step.role,
                status: status(for: step, observation: observation, verificationStatus: verification.status),
                summary: summary(for: step, observation: observation, verificationSummary: verification.summary),
                metadata: metadata(for: step, intent: intent, verificationMetadata: verification.metadata)
            )
        }
    }

    private func status(
        for step: LocalAppTaskWorkflowStepDefinition,
        observation: LocalAppTaskObservation?,
        verificationStatus: LocalAppTaskStepStatus
    ) -> LocalAppTaskStepStatus {
        switch step.role {
        case .parseIntent:
            return .verified
        case .launchOrFocusApp:
            return observation?.appIsFocused == true ? .verified : .projected
        case .observeApp:
            return observation == nil ? .projected : .verified
        case .focusControl:
            if let controlID = step.metadata["controlID"],
               observation?.availableControls[controlID] == true {
                return .verified
            }
            return .projected
        case .enterText, .submit, .custom:
            return .projected
        case .verifyResult:
            return verificationStatus
        }
    }

    private func summary(
        for step: LocalAppTaskWorkflowStepDefinition,
        observation: LocalAppTaskObservation?,
        verificationSummary: String
    ) -> String {
        if step.role == .verifyResult {
            return verificationSummary
        }

        if step.role == .launchOrFocusApp, observation?.appIsFocused == true {
            return "\(definition.targetApp.appName) is already focused"
        }

        return step.summary
    }

    private func metadata(
        for step: LocalAppTaskWorkflowStepDefinition,
        intent: TaskIntent,
        verificationMetadata: [String: String]
    ) -> [String: String] {
        var metadata = step.metadata.merging([
            "taskIntentID": intent.intentID,
            "taskType": intent.taskType
        ]) { current, _ in current }

        for (name, value) in intent.normalizedEntities {
            metadata["normalizedEntity.\(name)"] = value
        }

        if step.role == .verifyResult {
            metadata.merge(verificationMetadata) { current, _ in current }
        }

        return metadata
    }

    private func verificationStatus(
        for intent: TaskIntent,
        observation: LocalAppTaskObservation?
    ) -> (
        status: LocalAppTaskStepStatus,
        terminalState: LocalAppTaskTerminalState,
        confidence: Double,
        summary: String,
        metadata: [String: String]
    ) {
        guard let entityName = definition.verificationEntityName,
              let expected = intent.normalizedEntities[entityName]
        else {
            return (
                .blocked,
                .needsUserReview,
                0,
                "No verification entity is configured for this task",
                ["reason": "missingVerificationEntity"]
            )
        }

        guard let observation else {
            return (
                .blocked,
                .needsUserReview,
                0,
                "Visible app result has not been observed yet",
                [
                    "reason": "missingObservation",
                    "expectedEntityName": entityName,
                    "expectedEntityValue": expected
                ]
            )
        }

        let visibleTextKey = definition.metadata["verificationTextKey"] ?? entityName
        guard let visibleText = observation.visibleText[visibleTextKey] else {
            return (
                .blocked,
                .needsUserReview,
                observation.confidence,
                "Verification text is not available yet",
                [
                    "reason": "missingVisibleText",
                    "visibleTextKey": visibleTextKey,
                    "expectedEntityValue": expected
                ]
            )
        }

        if verifiesVisibleText(visibleText, matches: intent) {
            return (
                .verified,
                .completed,
                max(observation.confidence, 0.8),
                "Visible app result matches the requested entity",
                [
                    "visibleText": visibleText,
                    "expectedEntityName": entityName,
                    "expectedEntityValue": expected
                ]
            )
        }

        return (
            .blocked,
            .needsUserReview,
            observation.confidence,
            "Visible app result does not match the requested entity",
            [
                "reason": "resultMismatch",
                "visibleText": visibleText,
                "expectedEntityName": entityName,
                "expectedEntityValue": expected
            ]
        )
    }

    private func supports(_ intent: TaskIntent) -> Bool {
        intent.taskType == definition.taskType
            && intent.targetApp.appName == definition.targetApp.appName
            && intent.targetApp.bundleIdentifier == definition.targetApp.bundleIdentifier
    }

    private func command(
        idSuffix: String,
        intent: TaskIntent,
        issuedAt: RunTraceTimestamp,
        key: String,
        role: LocalAppTaskStepRole,
        metadata: [String: String]
    ) -> ActionEngineCommand {
        ActionEngineCommand(
            id: "\(intent.intentID)-\(idSuffix)",
            traceID: intent.metadata["traceID"] ?? intent.intentID,
            targetID: targetID,
            kind: .key,
            issuedAt: issuedAt,
            key: key,
            metadata: metadata.merging([
                "taskIntentID": intent.intentID,
                "taskType": intent.taskType,
                "targetApp": definition.targetApp.appName,
                "bundleIdentifier": definition.targetApp.bundleIdentifier ?? "",
                "workflowStepRole": role.rawValue
            ]) { current, _ in current }
        )
    }

    private func slug(_ value: String) -> String {
        Self.normalizedText(value)
            .split(separator: " ")
            .joined(separator: "-")
    }

    private static func normalizedText(_ value: String) -> String {
        LocalAppTaskIntentParser.normalizedPhrase(value)
    }
}
