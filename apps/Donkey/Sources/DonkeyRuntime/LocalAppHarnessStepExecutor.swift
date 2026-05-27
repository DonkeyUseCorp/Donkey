import DonkeyContracts
import DonkeyHarness
import Foundation

public actor LocalAppHarnessStepExecutor {
    public typealias ActionEngineFactory = @Sendable (LocalAppTaskDefinition) -> ActionEngineGuardrail

    private let command: String
    private let traceID: String
    private let resolution: LocalAppTaskCatalogResolution
    private let baseMetadata: [String: String]
    private let appController: any LocalAppTaskAppControlling
    private let actionEngineFactory: ActionEngineFactory
    private let permissionPolicy: ToolCallPolicy
    private let coordinator: RunCoordinator?

    private var runStartedAt = ProcessInfo.processInfo.systemUptime * 1_000
    private var runStarted = false
    private var latestObservation: LocalAppTaskObservation?
    private var initialActionPlan: LocalAppEvidenceBackedActionPlan?
    private var finalActionPlan: LocalAppEvidenceBackedActionPlan?
    private var actionTraces: [ActionEngineCommandTrace] = []
    private var executedWorkflowStepIDs: Set<String> = []
    private var latestStatus: LocalAppTaskLiveRunStatus = .failedSafe
    private var latestStatusReason = "notStarted"

    public init(
        command: String,
        traceID: String,
        resolution: LocalAppTaskCatalogResolution,
        metadata: [String: String] = [:],
        appController: any LocalAppTaskAppControlling,
        actionEngineFactory: @escaping ActionEngineFactory = LocalAppTaskActionEngines.keyboardOrAutomation(for:),
        permissionPolicy: ToolCallPolicy = ToolCallPolicy(
            allowedCapabilities: ToolCallPolicy.defaultAllowedCapabilities.union([.input]),
            deniedCapabilities: []
        ),
        coordinator: RunCoordinator? = nil
    ) {
        self.command = command
        self.traceID = traceID
        self.resolution = resolution
        self.baseMetadata = metadata
        self.appController = appController
        self.actionEngineFactory = actionEngineFactory
        self.permissionPolicy = permissionPolicy
        self.coordinator = coordinator
    }

    public static var descriptors: [HarnessToolDescriptor] {
        [
            descriptor(
                .openOrFocusApp,
                summary: "Open or focus the resolved local app and return bounded app evidence.",
                input: ["targetID": "Resolved local app target."],
                output: ["observation": "Focused app and visible state evidence."],
                permissions: [.appControl],
                safety: .reversible
            ),
            descriptor(
                .observeApp,
                summary: "Observe the resolved local app with Accessibility and screenshot evidence when needed.",
                output: ["observation": "Visible text, controls, and evidence metadata."],
                permissions: [.screenCapture, .accessibility],
                safety: .readOnly
            ),
            descriptor(
                .newDocument,
                summary: "Run one guarded model-planned new document action.",
                input: ["focusKey": "Model-selected shortcut when provided."],
                permissions: [.input],
                safety: .guardedInput
            ),
            descriptor(
                .focusSearch,
                summary: "Run one guarded model-planned search focus action.",
                input: ["controlID": "Model-selected control id.", "focusKey": "Model-selected shortcut."],
                permissions: [.input],
                safety: .guardedInput
            ),
            descriptor(
                .focusAddressBar,
                summary: "Run one guarded model-planned address-bar focus action.",
                input: ["controlID": "Model-selected control id.", "focusKey": "Model-selected shortcut."],
                permissions: [.input],
                safety: .guardedInput
            ),
            descriptor(
                .focusTextEntry,
                summary: "Run one guarded model-planned text-entry focus action.",
                input: ["controlID": "Model-selected control id.", "focusKey": "Model-selected shortcut."],
                permissions: [.input],
                safety: .guardedInput
            ),
            descriptor(
                .setText,
                summary: "Enter one model-selected structured entity into the focused local-app control.",
                input: ["inputEntity": "Structured intent entity to type.", "controlID": "Model-selected control id."],
                permissions: [.input],
                safety: .guardedInput
            ),
            descriptor(
                .clickTarget,
                summary: "Click one model-selected Accessibility or AI visual target.",
                input: ["controlID": "Model-selected Accessibility control id or AI visual segment id."],
                permissions: [.input],
                safety: .guardedInput
            ),
            descriptor(
                .pressReturn,
                summary: "Run one guarded model-planned Return submit action.",
                input: ["focusKey": "Optional model-selected key."],
                permissions: [.input],
                safety: .guardedInput
            ),
            descriptor(
                .verifyCommand,
                summary: "Observe the app and verify command progress from concrete post-action evidence.",
                output: ["verification": "Verified, blocked, or failed status with evidence."],
                permissions: [.screenCapture, .accessibility, .verification],
                safety: .readOnly
            ),
            descriptor(
                .verifyVisibleText,
                summary: "Observe the app and verify visible text from concrete post-action evidence.",
                output: ["verification": "Verified, blocked, or failed status with evidence."],
                permissions: [.screenCapture, .accessibility, .verification],
                safety: .readOnly
            )
        ]
    }

    public func registerTools(in registry: HarnessToolRegistry) async {
        for descriptor in Self.descriptors {
            await registry.register(
                HarnessTool(descriptor: descriptor) { context in
                    await self.execute(context)
                }
            )
        }
    }

    public func currentResult() -> LocalAppTaskLiveRunResult {
        makeResult(status: latestStatus, reason: latestStatusReason)
    }

    private func execute(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        guard let tool = LocalAppActionPlanTool(rawValue: context.call.name) else {
            return HarnessToolResult(
                callID: context.call.id,
                toolName: context.call.name,
                status: .unknownTool,
                summary: "Unknown local-app harness tool.",
                metadata: ["reason": "unknownLocalAppTool"]
            )
        }

        guard resolution.status == .resolved,
              let definition = resolution.definition,
              let intent = resolution.intent,
              let availability = resolution.availability
        else {
            let result = unresolvedToolResult(context)
            latestStatus = status(for: resolution.status)
            latestStatusReason = result.metadata["reason"] ?? resolution.status.rawValue
            return result
        }

        await publishRunStartIfNeeded(definition: definition, intent: intent)

        switch tool {
        case .openOrFocusApp:
            return await openOrFocus(context, definition: definition, intent: intent, availability: availability)
        case .observeApp:
            return await observe(context, definition: definition, intent: intent, reason: "observe")
        case .newDocument, .focusSearch, .focusAddressBar, .focusTextEntry, .setText, .clickTarget, .pressReturn:
            return await executeAction(context, tool: tool, definition: definition, intent: intent, availability: availability)
        case .verifyCommand, .verifyVisibleText:
            return await verify(context, tool: tool, definition: definition, intent: intent)
        }
    }

    private func openOrFocus(
        _ context: HarnessToolExecutionContext,
        definition: LocalAppTaskDefinition,
        intent: TaskIntent,
        availability: LocalAppAvailability
    ) async -> HarnessToolResult {
        await coordinator?.recordToolEvent(
            capability: .input,
            decision: permissionPolicy.decision(for: .input),
            toolName: "mac-launch-focus",
            summary: "Launching or focusing local app",
            traceID: traceID,
            metadata: [
                "targetApp": definition.targetApp.appName,
                "bundleIdentifier": definition.targetApp.bundleIdentifier ?? ""
            ]
        )
        let observation = await appController.launchOrFocus(
            definition: definition,
            availability: availability
        )
        latestObservation = observation
        initialActionPlan = LocalAppTaskAdapter(definition: definition)
            .evidenceBackedActionPlan(for: intent, observation: observation)
        latestStatus = .needsUserReview
        latestStatusReason = "openedOrFocusedAwaitingVerification"
        return observationResult(
            context,
            observation: observation,
            summary: "Observed local app after open or focus.",
            status: observation.appIsFocused || observation.appIsRunning ? .succeeded : .failed,
            extraFacts: ["localApp.lastStep": context.call.name]
        )
    }

    private func observe(
        _ context: HarnessToolExecutionContext,
        definition: LocalAppTaskDefinition,
        intent: TaskIntent,
        reason: String
    ) async -> HarnessToolResult {
        await coordinator?.recordToolEvent(
            capability: .perception,
            decision: permissionPolicy.decision(for: .perception),
            toolName: "local-app-observation",
            summary: "Observing local app",
            traceID: traceID,
            metadata: ["reason": reason]
        )
        let observation = await appController.observe(definition: definition)
        latestObservation = observation
        initialActionPlan = initialActionPlan ?? LocalAppTaskAdapter(definition: definition)
            .evidenceBackedActionPlan(for: intent, observation: observation)
        latestStatus = .needsUserReview
        latestStatusReason = "observedAwaitingVerification"
        return observationResult(
            context,
            observation: observation,
            summary: "Observed local app state.",
            status: .succeeded,
            extraFacts: ["localApp.lastStep": context.call.name]
        )
    }

    private func executeAction(
        _ context: HarnessToolExecutionContext,
        tool: LocalAppActionPlanTool,
        definition: LocalAppTaskDefinition,
        intent: TaskIntent,
        availability: LocalAppAvailability
    ) async -> HarnessToolResult {
        let adapter = LocalAppTaskAdapter(definition: definition)
        let command = commandTemplate(
            tool: tool,
            context: context,
            adapter: adapter,
            intent: intent
        )
        guard let command else {
            latestStatus = .failedSafe
            latestStatusReason = "missingModelPlannedCommand"
            return HarnessToolResult(
                callID: context.call.id,
                toolName: context.call.name,
                status: .failed,
                summary: "No guarded command matched the model-planned local-app step.",
                observations: HarnessObservationDelta(
                    facts: [
                        "localApp.status": latestStatus.rawValue,
                        "localApp.reason": latestStatusReason,
                        "localApp.missingTool": context.call.name
                    ],
                    uncertainty: ["missing guarded command for \(context.call.name)"]
                ),
                metadata: ["reason": latestStatusReason]
            )
        }

        await coordinator?.recordToolEvent(
            capability: .input,
            decision: permissionPolicy.decision(for: .input),
            toolName: command.metadata["automationBackend"] == "appleScript"
                ? "mac-applescript-action-engine"
                : "mac-keyboard-action-engine",
            summary: "Executing one guarded local-app command",
            traceID: traceID,
            metadata: [
                "commandID": command.id,
                "workflowStepID": command.metadata["workflowStepID"] ?? "",
                "modelToolName": context.call.name
            ]
        )
        let engine = actionEngineFactory(definition)
        var trace = await engine.handle(command, permissionPolicy: permissionPolicy)
        actionTraces.append(trace)
        if trace.decision == .denied(reason: "focus guard failed") {
            _ = await appController.launchOrFocus(definition: definition, availability: availability)
            let retry = command.withHarnessIssuedAt(Self.now(advancedByMilliseconds: 25))
            trace = await engine.handle(retry, permissionPolicy: permissionPolicy)
            actionTraces.append(trace)
        }

        if trace.executed || trace.decision == .skippedNoLiveInput {
            if let workflowStepID = workflowStepID(from: trace.command) {
                executedWorkflowStepIDs.insert(workflowStepID)
            }
        } else {
            latestStatus = .failedSafe
            latestStatusReason = "actionDenied"
            let observation = await appController.observe(definition: definition)
            latestObservation = observationWithActionEvidence(observation)
            return HarnessToolResult(
                callID: context.call.id,
                toolName: context.call.name,
                status: .failed,
                summary: "Guarded local-app command was denied.",
                observations: observationDelta(
                    latestObservation,
                    definition: definition,
                    extraFacts: [
                        "localApp.status": latestStatus.rawValue,
                        "localApp.reason": latestStatusReason,
                        "localApp.actionDeniedReason": decisionReason(trace.decision)
                    ],
                    uncertainty: ["guarded command denied"]
                ),
                metadata: [
                    "reason": latestStatusReason,
                    "actionDeniedReason": decisionReason(trace.decision)
                ].merging(actionTraceMetadata()) { current, _ in current }
            )
        }

        try? await Task.sleep(nanoseconds: 200_000_000)
        let observation = await appController.observe(definition: definition)
        latestObservation = observationWithActionEvidence(observation)
        latestStatus = .needsUserReview
        latestStatusReason = "actionExecutedAwaitingVerification"
        return observationResult(
            context,
            observation: latestObservation,
            summary: "Executed one guarded local-app command and observed the result.",
            status: .succeeded,
            extraFacts: [
                "localApp.status": latestStatus.rawValue,
                "localApp.lastStep": context.call.name
            ],
            metadata: actionTraceMetadata()
        )
    }

    private func verify(
        _ context: HarnessToolExecutionContext,
        tool: LocalAppActionPlanTool,
        definition: LocalAppTaskDefinition,
        intent: TaskIntent
    ) async -> HarnessToolResult {
        try? await Task.sleep(nanoseconds: 700_000_000)
        await coordinator?.recordToolEvent(
            capability: .perception,
            decision: permissionPolicy.decision(for: .perception),
            toolName: "local-app-observation",
            summary: "Observing local app for verification",
            traceID: traceID,
            metadata: ["modelToolName": context.call.name]
        )
        let observation = await appController.observe(definition: definition)
        latestObservation = observationWithActionEvidence(observation)
        let plan = LocalAppTaskAdapter(definition: definition)
            .evidenceBackedActionPlan(for: intent, observation: latestObservation)
        let verification = LocalAppTaskVerificationPolicy.verify(
            intent: intent,
            definition: definition,
            observation: latestObservation,
            tool: tool
        )
        finalActionPlan = plan
        latestStatus = status(for: verification.terminalState)
        latestStatusReason = verification.metadata["reason"] ?? verification.terminalState.rawValue
        let verified = verification.terminalState == .completed
        if verified {
            await coordinator?.complete(reason: "Local app task completed")
        } else {
            await coordinator?.pause(reason: "Local app task verification did not complete")
        }
        var facts = [
            "localApp.status": latestStatus.rawValue,
            "localApp.reason": latestStatusReason,
            "verification.status": verification.status.rawValue,
            "verification.summary": verification.summary,
            "verification.verified": String(verified),
            "lastAcceptedTool": context.call.name
        ]
        for (key, value) in verification.metadata {
            facts["verification.\(key)"] = value
        }
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: verified ? .succeeded : .failed,
            summary: verified
                ? "Local app verification succeeded."
                : "Local app verification did not find completed evidence.",
            observations: observationDelta(
                latestObservation,
                definition: definition,
                extraFacts: facts,
                uncertainty: verified ? [] : ["local app verification incomplete"]
            ),
            metadata: facts.merging(actionTraceMetadata()) { current, _ in current }
        )
    }

    private func commandTemplate(
        tool: LocalAppActionPlanTool,
        context: HarnessToolExecutionContext,
        adapter: LocalAppTaskAdapter,
        intent: TaskIntent
    ) -> ActionEngineCommand? {
        let automationCommands = adapter.guardedAutomationCommandTemplates(
            for: intent,
            issuedAt: Self.now()
        )
        let keyboardCommands = automationCommands.isEmpty
            ? adapter.guardedKeyboardCommandTemplates(for: intent, issuedAt: Self.now())
            : automationCommands
        let inputEntity = Self.trimmed(context.call.input["inputEntity"])
        let controlID = Self.trimmed(context.call.input["controlID"])
        let focusKey = Self.trimmed(context.call.input["focusKey"])
        let candidates = keyboardCommands.filter { command in
            if executedWorkflowStepIDs.contains(workflowStepID(from: command) ?? "") {
                return false
            }
            if command.metadata["plan.tool"] == tool.rawValue {
                return matchesStructuredInputs(
                    command,
                    inputEntity: inputEntity,
                    controlID: controlID,
                    focusKey: focusKey
                )
            }
            return role(for: tool) == command.metadata["workflowStepRole"]
                && matchesStructuredInputs(
                    command,
                    inputEntity: inputEntity,
                    controlID: controlID,
                    focusKey: focusKey
                )
        }
        return candidates.first?.withHarnessIssuedAt(Self.now())
            ?? visualClickCommand(
                tool: tool,
                context: context,
                adapter: adapter,
                intent: intent,
                controlID: controlID
            )
    }

    private func matchesStructuredInputs(
        _ command: ActionEngineCommand,
        inputEntity: String?,
        controlID: String?,
        focusKey: String?
    ) -> Bool {
        if let inputEntity,
           let commandEntity = command.metadata["entityName"],
           commandEntity != inputEntity {
            return false
        }
        if let controlID,
           let commandControlID = command.metadata["controlID"],
           commandControlID != controlID {
            return false
        }
        if let focusKey,
           !focusKey.isEmpty,
           command.key != focusKey,
           command.metadata["key"] != focusKey {
            return false
        }
        return true
    }

    private func visualClickCommand(
        tool: LocalAppActionPlanTool,
        context: HarnessToolExecutionContext,
        adapter: LocalAppTaskAdapter,
        intent: TaskIntent,
        controlID: String?
    ) -> ActionEngineCommand? {
        guard [.focusSearch, .focusAddressBar, .focusTextEntry, .clickTarget].contains(tool),
              let controlID,
              let observation = latestObservation,
              let targetBounds = LocalAppObservationGeometry.screenControlBounds(
                controlID: controlID,
                metadata: observation.metadata
              )
        else {
            return nil
        }

        return ActionEngineCommand(
            id: "\(intent.intentID)-visual-click-\(Self.slug(controlID))",
            traceID: intent.metadata["traceID"] ?? intent.intentID,
            targetID: adapter.targetID,
            kind: .tap,
            issuedAt: Self.now(),
            targetBounds: targetBounds,
            metadata: LocalAppObservationGeometry.groundedMetadata(
                controlID: controlID,
                observation: observation
            ).merging([
                "taskIntentID": intent.intentID,
                "taskType": intent.taskType,
                "targetApp": adapter.definition.targetApp.appName,
                "bundleIdentifier": adapter.definition.targetApp.bundleIdentifier ?? "",
                "workflowStepID": context.call.input["modelStepID"] ?? "visual-click-\(Self.slug(controlID))",
                "workflowStepRole": role(for: tool),
                "controlID": controlID,
                "inputStrategy": "visual-coordinate",
                "visualFallback": "aiOrObservedBounds",
                "plan.tool": tool.rawValue
            ]) { current, _ in current }
        )
    }

    private func observationWithActionEvidence(_ observation: LocalAppTaskObservation?) -> LocalAppTaskObservation? {
        guard var observation else { return nil }
        let executed = actionTraces.filter(\.executed)
        let submitCount = executed.filter {
            $0.command.metadata["workflowStepRole"] == LocalAppTaskStepRole.submit.rawValue
        }.count
        observation.metadata.merge([
            "postActionObservation": "true",
            "executedCommandCount": String(executed.count),
            "submittedCommandCount": String(submitCount)
        ]) { current, _ in current }
        return observation
    }

    private func observationResult(
        _ context: HarnessToolExecutionContext,
        observation: LocalAppTaskObservation?,
        summary: String,
        status: HarnessToolResultStatus,
        extraFacts: [String: String] = [:],
        metadata: [String: String] = [:]
    ) -> HarnessToolResult {
        HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: status,
            summary: summary,
            observations: observationDelta(
                observation,
                definition: resolution.definition,
                extraFacts: extraFacts,
                uncertainty: status == .succeeded ? [] : ["local app observation incomplete"]
            ),
            metadata: metadata.merging([
                "executor": "LocalAppHarnessStepExecutor",
                "traceID": traceID
            ]) { current, _ in current }
        )
    }

    private func observationDelta(
        _ observation: LocalAppTaskObservation?,
        definition: LocalAppTaskDefinition?,
        extraFacts: [String: String] = [:],
        uncertainty: [String] = []
    ) -> HarnessObservationDelta {
        var facts = extraFacts
        if let observation {
            facts.merge([
                "localApp.appIsRunning": String(observation.appIsRunning),
                "localApp.appIsFocused": String(observation.appIsFocused),
                "localApp.observationConfidence": String(format: "%.3f", observation.confidence)
            ]) { current, _ in current }
            for (key, value) in observation.metadata {
                facts["localApp.observation.\(key)"] = value
            }
        }
        if let definition {
            facts["localApp.targetApp"] = definition.targetApp.appName
            facts["localApp.taskType"] = definition.taskType
        }
        let elements = observation?.availableControls.map { key, value in
            HarnessWorldElement(
                id: key,
                label: key,
                role: "control",
                isActionEligible: value,
                actions: value ? ["focus", "setValue"] : [],
                metadata: ["source": "localAppObservation"]
            )
        }
        .sorted { $0.id < $1.id } ?? []
        return HarnessObservationDelta(
            focusedApp: observation?.appIsFocused == true ? definition?.targetApp.appName : nil,
            visibleText: observation?.visibleText ?? [:],
            elements: elements,
            facts: facts,
            uncertainty: uncertainty
        )
    }

    private func unresolvedToolResult(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        let status: HarnessToolResultStatus
        let question: String?
        switch resolution.status {
        case .resolved:
            status = .failed
            question = nil
        case .needsConfirmation:
            status = .waitingForUser
            question = resolution.metadata["assistantResponse"] ?? "What detail should I use?"
        case .unsupportedCommand:
            status = .waitingForUser
            question = "What local app task should I run?"
        case .appUnavailable:
            status = .failed
            question = nil
        }
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: status,
            summary: "Local app task resolution is \(resolution.status.rawValue).",
            observations: HarnessObservationDelta(
                facts: [
                    "localApp.status": self.status(for: resolution.status).rawValue,
                    "localApp.resolutionStatus": resolution.status.rawValue,
                    "localApp.reason": resolution.metadata["reason"] ?? resolution.status.rawValue
                ],
                uncertainty: [resolution.status.rawValue]
            ),
            question: question,
            metadata: [
                "executor": "LocalAppHarnessStepExecutor",
                "reason": resolution.metadata["reason"] ?? resolution.status.rawValue,
                "traceID": traceID
            ]
        )
    }

    private func makeResult(status: LocalAppTaskLiveRunStatus, reason: String) -> LocalAppTaskLiveRunResult {
        var metadata = baseMetadata.merging([
            "reason": reason,
            "latency.totalMS": Self.formatLatency(Self.uptimeMilliseconds() - runStartedAt),
            "executedCommandCount": String(actionTraces.filter(\.executed).count),
            "skippedNoLiveInputCommandCount": String(actionTraces.filter { $0.decision == .skippedNoLiveInput }.count)
        ]) { current, _ in current }
        metadata.merge(actionTraceMetadata()) { current, _ in current }
        if let verificationStep = finalActionPlan?.steps.first(where: { $0.role == .verifyResult }) {
            metadata["verification.summary"] = verificationStep.summary
            metadata["verification.status"] = verificationStep.status.rawValue
            for (key, value) in verificationStep.metadata {
                metadata["verification.\(key)"] = value
            }
        }
        return LocalAppTaskLiveRunResult(
            command: command,
            traceID: traceID,
            status: status,
            resolution: resolution,
            initialActionPlan: initialActionPlan,
            finalActionPlan: finalActionPlan,
            observation: latestObservation,
            actionTraces: actionTraces,
            metadata: metadata
        )
    }

    private func publishRunStartIfNeeded(
        definition: LocalAppTaskDefinition,
        intent: TaskIntent
    ) async {
        guard !runStarted else { return }
        runStarted = true
        await coordinator?.setTraceID(traceID)
        _ = await coordinator?.start(
            RunSession(
                userGoal: command,
                targetID: LocalAppTaskAdapter(definition: definition).targetID,
                runtimeProfile: "local-app-harness-step-loop",
                permissionPolicy: permissionPolicy
            )
        )
        await coordinator?.recordToolEvent(
            capability: .model,
            decision: .allow,
            toolName: "generic-harness-local-app-plan",
            summary: "Local app task plan entered guarded step loop",
            traceID: traceID,
            metadata: [
                "intentID": intent.intentID,
                "taskType": intent.taskType,
                "targetApp": definition.targetApp.appName
            ]
        )
    }

    private func status(for resolutionStatus: LocalAppTaskCatalogResolutionStatus) -> LocalAppTaskLiveRunStatus {
        switch resolutionStatus {
        case .resolved:
            return .failedSafe
        case .needsConfirmation:
            return .needsConfirmation
        case .unsupportedCommand:
            return .unsupportedCommand
        case .appUnavailable:
            return .appUnavailable
        }
    }

    private func status(for terminalState: LocalAppTaskTerminalState) -> LocalAppTaskLiveRunStatus {
        switch terminalState {
        case .completed:
            return .completed
        case .needsUserReview:
            return .needsUserReview
        case .failedSafe, .timedOut:
            return .failedSafe
        }
    }

    private func role(for tool: LocalAppActionPlanTool) -> String {
        switch tool {
        case .newDocument, .clickTarget, .pressReturn:
            return LocalAppTaskStepRole.submit.rawValue
        case .focusSearch, .focusAddressBar, .focusTextEntry:
            return LocalAppTaskStepRole.focusControl.rawValue
        case .setText:
            return LocalAppTaskStepRole.enterText.rawValue
        case .openOrFocusApp:
            return LocalAppTaskStepRole.launchOrFocusApp.rawValue
        case .observeApp:
            return LocalAppTaskStepRole.observeApp.rawValue
        case .verifyCommand, .verifyVisibleText:
            return LocalAppTaskStepRole.verifyResult.rawValue
        }
    }

    private func workflowStepID(from command: ActionEngineCommand) -> String? {
        command.metadata["workflowStepID"] ?? command.metadata["workflowStepRole"]
    }

    private func decisionReason(_ decision: ActionEngineCommandDecision) -> String {
        switch decision {
        case .skippedNoLiveInput:
            return "skippedNoLiveInput"
        case .executedLive:
            return "executedLive"
        case .denied(let reason):
            return reason
        }
    }

    private func actionTraceMetadata() -> [String: String] {
        guard !actionTraces.isEmpty else { return [:] }
        let lastTrace = actionTraces[actionTraces.count - 1]
        let backends = Set(actionTraces.compactMap { $0.metadata["liveInputBackend"] }).sorted()
        return [
            "action.traceCount": String(actionTraces.count),
            "action.executedCount": String(actionTraces.filter(\.executed).count),
            "action.backends": backends.joined(separator: ","),
            "action.lastCommandID": lastTrace.command.id,
            "action.lastCommandKind": lastTrace.command.kind.rawValue,
            "action.lastDecision": decisionReason(lastTrace.decision),
            "action.lastBackend": lastTrace.metadata["liveInputBackend"] ?? "",
            "action.overlayPointer": "visualOnly"
        ]
    }

    private static func slug(_ value: String) -> String {
        LocalAppTextNormalizer.normalizedPhrase(value)
            .split(separator: " ")
            .joined(separator: "-")
    }

    private static func descriptor(
        _ tool: LocalAppActionPlanTool,
        summary: String,
        input: [String: String] = [:],
        output: [String: String] = [:],
        permissions: [HarnessPermission],
        safety: HarnessToolSafetyClass
    ) -> HarnessToolDescriptor {
        HarnessToolDescriptor(
            name: tool.rawValue,
            pluginID: "user-query.local-app",
            summary: summary,
            inputSchema: input,
            outputSchema: output,
            requiredPermissions: permissions,
            safetyClass: safety,
            requiredContext: ["structured intent", "resolved local app task", "generic harness task"],
            verificationHints: ["Observe after the step and verify with concrete local-app evidence."],
            metadata: ["executor": "LocalAppHarnessStepExecutor"]
        )
    }

    private static func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func now(advancedByMilliseconds milliseconds: Double = 0) -> RunTraceTimestamp {
        let now = ProcessInfo.processInfo.systemUptime
        return RunTraceTimestamp(
            wallClock: Date().addingTimeInterval(milliseconds / 1_000),
            monotonicUptimeNanoseconds: UInt64((now * 1_000_000_000) + (milliseconds * 1_000_000))
        )
    }

    private static func uptimeMilliseconds() -> Double {
        ProcessInfo.processInfo.systemUptime * 1_000
    }

    private static func formatLatency(_ milliseconds: Double) -> String {
        String(format: "%.3f", max(0, milliseconds))
    }
}

private extension ActionEngineCommand {
    func withHarnessIssuedAt(_ issuedAt: RunTraceTimestamp) -> ActionEngineCommand {
        var command = self
        command.issuedAt = issuedAt
        return command
    }
}
