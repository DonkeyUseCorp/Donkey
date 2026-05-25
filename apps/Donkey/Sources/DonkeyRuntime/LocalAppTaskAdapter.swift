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

    public func evidenceBackedActionPlan(
        for intent: TaskIntent,
        observation: LocalAppTaskObservation? = nil
    ) -> LocalAppEvidenceBackedActionPlan {
        guard supports(intent), intent.needsConfirmation == false else {
            return LocalAppEvidenceBackedActionPlan(
                intent: intent,
                targetApp: definition.targetApp,
                steps: [
                    LocalAppEvidenceBackedActionStep(
                        id: "parse-intent",
                        role: .parseIntent,
                        status: .blocked,
                        summary: "Local app task intent is unsupported or incomplete",
                        metadata: ["reason": "unsupportedOrIncompleteIntent"]
                    )
                ],
                terminalState: .failedSafe,
                canExecuteGuardedActions: false,
                verificationConfidence: 0,
                metadata: planMetadata
            )
        }

        let verification = verificationStatus(for: intent, observation: observation)
        let steps = evidenceBackedWorkflowSteps(
            intent: intent,
            observation: observation,
            verification: verification
        )
        let canExecuteGuardedActions = definition.metadata["guardedLiveDefault"] != "reviewOnly"
            && verification.terminalState != .failedSafe
            && steps.allSatisfy(Self.hasRequiredPreActionEvidence)

        return LocalAppEvidenceBackedActionPlan(
            intent: intent,
            targetApp: definition.targetApp,
            steps: steps,
            terminalState: verification.terminalState,
            canExecuteGuardedActions: canExecuteGuardedActions,
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

    public func guardedAutomationCommandTemplates(
        for intent: TaskIntent,
        issuedAt: RunTraceTimestamp
    ) -> [ActionEngineCommand] {
        guard supports(intent),
              intent.needsConfirmation == false,
              definition.metadata["automationBackend"] == "appleScript"
        else {
            return []
        }

        let automationMetadata = definition.metadata.merging(intent.metadata) { _, new in new }
        let action = automationMetadata["appleScript.action"] ?? "generated.\(definition.taskType)"
        let entityName = automationMetadata["appleScript.entityName"]
            ?? definition.verificationEntityName
            ?? definition.entityRules.first?.name
        let entityValue = entityName.flatMap { name in
            intent.normalizedEntities[name] ?? intent.entities[name]
        } ?? intent.normalizedEntities.values.sorted().first
            ?? intent.entities.values.sorted().first
            ?? ""
        let trimmedEntityValue = entityValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasScriptSource = automationMetadata["appleScript.source"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || automationMetadata["appleScript.template"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard !trimmedEntityValue.isEmpty || hasScriptSource else { return [] }

        let workflowStepID = "apple-script-\(slug(action))"
        var commandMetadata = automationMetadata.merging([
            "taskIntentID": intent.intentID,
            "taskType": intent.taskType,
            "targetApp": definition.targetApp.appName,
            "bundleIdentifier": definition.targetApp.bundleIdentifier ?? "",
            "workflowStepID": workflowStepID,
            "workflowStepRole": LocalAppTaskStepRole.custom.rawValue,
            "automationBackend": "appleScript",
            "appleScript.action": action,
            "appleScript.entityName": entityName ?? "",
            "appleScript.entityValue": trimmedEntityValue
        ]) { current, _ in current }
        if commandMetadata["appleScript.query"] == nil {
            commandMetadata["appleScript.query"] = trimmedEntityValue
        }

        return [
            ActionEngineCommand(
                id: "\(intent.intentID)-\(workflowStepID)",
                traceID: intent.metadata["traceID"] ?? intent.intentID,
                targetID: targetID,
                kind: .controller,
                issuedAt: issuedAt,
                key: trimmedEntityValue.isEmpty ? nil : trimmedEntityValue,
                metadata: commandMetadata
            )
        ]
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
            "evidenceContract": "pre-action-controls-require-accessibility-or-local-ui-understanding-bounds",
            "defaultOSInputBackendAvailable": "true",
            "defaultOSInputBackend": definition.metadata["automationBackend"] == "appleScript"
                ? "mac-apple-script"
                : "mac-keyboard"
        ].merging(definition.metadata) { current, _ in current }
    }

    private func evidenceBackedWorkflowSteps(
        intent: TaskIntent,
        observation: LocalAppTaskObservation?,
        verification: LocalAppTaskVerificationResult
    ) -> [LocalAppEvidenceBackedActionStep] {
        if definition.workflowSteps.isEmpty {
            return [
                LocalAppEvidenceBackedActionStep(
                    id: "parse-intent",
                    role: .parseIntent,
                    status: .verified,
                    summary: "Parsed local app task intent",
                    metadata: ["taskType": intent.taskType]
                )
            ]
        }

        var activeControlID: String?
        return definition.workflowSteps.map { step in
            let controlID = step.metadata["controlID"] ?? activeControlID
            if let stepControlID = step.metadata["controlID"] {
                activeControlID = stepControlID
            }
            return LocalAppEvidenceBackedActionStep(
                id: step.id,
                role: step.role,
                status: status(for: step, observation: observation, verificationStatus: verification.status),
                summary: summary(for: step, observation: observation, verificationSummary: verification.summary),
                metadata: metadata(
                    for: step,
                    intent: intent,
                    verificationMetadata: verification.metadata,
                    observation: observation,
                    inheritedControlID: controlID
                )
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
            return observation?.appIsFocused == true ? .verified : .needsEvidence
        case .observeApp:
            return observation == nil ? .needsEvidence : .verified
        case .focusControl:
            if Self.hasKeyboardFocusShortcut(step), observation?.appIsFocused == true {
                return .verified
            }
            if let controlID = step.metadata["controlID"],
               let observation,
               LocalAppObservationGeometry.hasNormalizedControlBounds(
                controlID: controlID,
                metadata: observation.metadata
               ) {
                return .verified
            }
            return .needsEvidence
        case .enterText, .submit, .custom:
            return .needsEvidence
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
        verificationMetadata: [String: String],
        observation: LocalAppTaskObservation?,
        inheritedControlID: String?
    ) -> [String: String] {
        var metadata = step.metadata.merging([
            "taskIntentID": intent.intentID,
            "taskType": intent.taskType
        ]) { current, _ in current }
        let controlID = step.metadata["controlID"] ?? inheritedControlID
        if let controlID,
           metadata["controlID"] == nil,
           [.enterText, .submit].contains(step.role) {
            metadata["controlID"] = controlID
        }
        metadata.merge(
            LocalAppObservationGeometry.groundedMetadata(
                controlID: controlID,
                observation: observation
            )
        ) { current, _ in current }

        for (name, value) in intent.normalizedEntities {
            metadata["normalizedEntity.\(name)"] = value
        }

        if step.role == .verifyResult {
            metadata.merge(verificationMetadata) { current, _ in current }
        }

        return metadata
    }

    private static func hasRequiredPreActionEvidence(_ step: LocalAppEvidenceBackedActionStep) -> Bool {
        switch step.role {
        case .parseIntent, .launchOrFocusApp, .observeApp, .focusControl:
            return step.status == .verified
        case .enterText, .submit, .verifyResult, .custom:
            return true
        }
    }

    private static func hasKeyboardFocusShortcut(_ step: LocalAppTaskWorkflowStepDefinition) -> Bool {
        let key = step.metadata["key"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !key.isEmpty
    }

    private func verificationStatus(
        for intent: TaskIntent,
        observation: LocalAppTaskObservation?
    ) -> LocalAppTaskVerificationResult {
        LocalAppTaskVerificationPolicy.verify(
            intent: intent,
            definition: definition,
            observation: observation
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
                "workflowStepID": idSuffix,
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
