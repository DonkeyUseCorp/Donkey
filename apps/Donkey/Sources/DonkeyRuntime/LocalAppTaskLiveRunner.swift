@preconcurrency import ApplicationServices
import AppKit
import DonkeyContracts
import Foundation

public enum LocalAppTaskLiveRunStatus: String, Equatable, Sendable {
    case completed
    case needsUserReview
    case unsupportedCommand
    case needsConfirmation
    case appUnavailable
    case failedSafe
}

public struct LocalAppTaskLiveRunResult: Equatable, Sendable {
    public var command: String
    public var traceID: String
    public var status: LocalAppTaskLiveRunStatus
    public var resolution: LocalAppTaskCatalogResolution
    public var initialActionPlan: LocalAppEvidenceBackedActionPlan?
    public var finalActionPlan: LocalAppEvidenceBackedActionPlan?
    public var observation: LocalAppTaskObservation?
    public var documentFormFillPlan: DocumentFormFillPlan?
    public var actionTraces: [ActionEngineCommandTrace]
    public var workflowProgress: LocalAppTaskWorkflowProgress
    public var metadata: [String: String]

    public init(
        command: String,
        traceID: String,
        status: LocalAppTaskLiveRunStatus,
        resolution: LocalAppTaskCatalogResolution,
        initialActionPlan: LocalAppEvidenceBackedActionPlan? = nil,
        finalActionPlan: LocalAppEvidenceBackedActionPlan? = nil,
        observation: LocalAppTaskObservation? = nil,
        documentFormFillPlan: DocumentFormFillPlan? = nil,
        actionTraces: [ActionEngineCommandTrace] = [],
        workflowProgress: LocalAppTaskWorkflowProgress = LocalAppTaskWorkflowProgress(),
        metadata: [String: String] = [:]
    ) {
        self.command = command
        self.traceID = traceID
        self.status = status
        self.resolution = resolution
        self.initialActionPlan = initialActionPlan
        self.finalActionPlan = finalActionPlan
        self.observation = observation
        self.documentFormFillPlan = documentFormFillPlan
        self.actionTraces = actionTraces
        self.workflowProgress = workflowProgress
        self.metadata = metadata
    }
}

public protocol LocalAppTaskAppControlling: Sendable {
    @MainActor
    func launchOrFocus(
        definition: LocalAppTaskDefinition,
        availability: LocalAppAvailability
    ) async -> LocalAppTaskObservation

    @MainActor
    func observe(definition: LocalAppTaskDefinition) async -> LocalAppTaskObservation
}

public struct LocalAppTaskLiveRunner: Sendable {
    public typealias ActionEngineFactory = @Sendable (LocalAppTaskDefinition) -> ActionEngineGuardrail

    public var catalog: LocalAppTaskCatalog
    public var appController: any LocalAppTaskAppControlling
    public var contextProvider: any LocalAppTaskContextProviding
    public var documentFormFillPlanner: DocumentFormFillPlanner
    public var actionEngineFactory: ActionEngineFactory
    public var permissionPolicy: ToolCallPolicy
    public var coordinator: RunCoordinator?

    public init(
        catalog: LocalAppTaskCatalog = .defaultLocal(),
        appController: any LocalAppTaskAppControlling = MacLocalAppTaskController(),
        contextProvider: any LocalAppTaskContextProviding = MacLocalAppTaskContextProvider(),
        documentFormFillPlanner: DocumentFormFillPlanner = DocumentFormFillPlanner(),
        actionEngineFactory: @escaping ActionEngineFactory = Self.defaultActionEngine(for:),
        permissionPolicy: ToolCallPolicy = ToolCallPolicy(
            allowedCapabilities: ToolCallPolicy.defaultAllowedCapabilities.union([.input]),
            deniedCapabilities: []
        ),
        coordinator: RunCoordinator? = nil
    ) {
        self.catalog = catalog
        self.appController = appController
        self.contextProvider = contextProvider
        self.documentFormFillPlanner = documentFormFillPlanner
        self.actionEngineFactory = actionEngineFactory
        self.permissionPolicy = permissionPolicy
        self.coordinator = coordinator
    }

    public func run(
        command: String,
        traceID: String = "local-app-task-\(UUID().uuidString)"
    ) async -> LocalAppTaskLiveRunResult {
        await run(
            command: command,
            traceID: traceID,
            resolution: catalog.resolve(command: command),
            metadata: ["intentParser": "externalRequired"]
        )
    }

    public func run(
        command: String,
        traceID: String,
        resolution: LocalAppTaskCatalogResolution,
        metadata: [String: String] = [:]
    ) async -> LocalAppTaskLiveRunResult {
        let runStartedAt = Self.uptimeMilliseconds()
        var runMetadata = metadata
        var stepTracker = LocalAppTaskStepTracker(metadata: ["traceID": traceID])
        stepTracker.complete(
            .parseIntent,
            summary: "Task intent parsed or supplied",
            metadata: ["parser": metadata["intentParser"] ?? resolution.intent?.parserSource.rawValue ?? "external"]
        )
        guard resolution.status == .resolved else {
            stepTracker.block(
                .resolveApp,
                summary: "Local app task could not be resolved",
                metadata: ["resolution.status": resolution.status.rawValue]
            )
            await publishUnresolvedRun(
                command: command,
                traceID: traceID,
                resolution: resolution
            )
            let progress = stepTracker.snapshot()
            return unresolvedResult(
                command: command,
                traceID: traceID,
                resolution: resolution,
                workflowProgress: progress,
                metadata: metadata.merging([
                    "latency.totalMS": Self.formatLatency(Self.uptimeMilliseconds() - runStartedAt)
                ], uniquingKeysWith: { current, _ in current }).merging(
                    Self.workflowProgressMetadata(progress),
                    uniquingKeysWith: { current, _ in current }
                )
            )
        }

        stepTracker.start(
            .resolveApp,
            summary: "Resolving task definition and target app",
            metadata: ["resolution.status": resolution.status.rawValue]
        )

        guard let definition = resolution.definition,
              var intent = resolution.intent,
              let availability = resolution.availability
        else {
            stepTracker.fail(
                .resolveApp,
                summary: "Local app task resolution was incomplete",
                metadata: ["reason": "incompleteResolution"]
            )
            let progress = stepTracker.snapshot()
            await publishRunStart(
                command: command,
                traceID: traceID,
                targetID: "local-app-task-incomplete-resolution"
            )
            await coordinator?.recordToolEvent(
                capability: .controller,
                decision: .deny(reason: "local app task resolution was incomplete"),
                toolName: "local-app-task-live-runner",
                summary: "Local app task resolution incomplete",
                traceID: traceID,
                metadata: ["reason": "incompleteResolution"]
            )
            await coordinator?.fail(reason: "Local app task resolution incomplete")
            return LocalAppTaskLiveRunResult(
                command: command,
                traceID: traceID,
                status: .failedSafe,
                resolution: resolution,
                workflowProgress: progress,
                metadata: runMetadata.merging([
                    "reason": "incompleteResolution",
                    "latency.totalMS": Self.formatLatency(Self.uptimeMilliseconds() - runStartedAt)
                ], uniquingKeysWith: { current, _ in current }).merging(
                    Self.workflowProgressMetadata(progress),
                    uniquingKeysWith: { current, _ in current }
                )
            )
        }

        stepTracker.complete(
            .resolveApp,
            summary: "Resolved task definition and target app",
            metadata: [
                "taskType": definition.taskType,
                "targetApp": definition.targetApp.appName
            ]
        )

        intent.metadata["traceID"] = traceID
        let adapter = catalog.adapter(for: definition)
        await publishRunStart(
            command: command,
            traceID: traceID,
            targetID: adapter.targetID
        )
        if definition.metadata["guardedLiveDefault"] == "reviewOnly" {
            let contextStartedAt = Self.uptimeMilliseconds()
            stepTracker.start(.observe, summary: "Capturing local app task context")
            await coordinator?.recordToolEvent(
                capability: .capture,
                decision: permissionPolicy.decision(for: .capture),
                toolName: "local-app-task-context",
                summary: "Captured local app task context",
                traceID: traceID
            )
            let context = await contextProvider.snapshot()
            runMetadata["latency.observationMS"] = Self.formatLatency(
                Self.uptimeMilliseconds() - contextStartedAt
            )
            stepTracker.complete(
                .observe,
                summary: "Captured local app task context",
                metadata: ["observer": "local-app-task-context"]
            )
            stepTracker.start(.evidencePlan, summary: "Building review-first evidence-backed action plan")
            let documentPlan = documentFormFillPlanner.plan(
                intent: intent,
                definition: definition,
                context: context
            )
            let observation = LocalAppTaskObservation(
                appIsRunning: context.focusedBundleIdentifier == definition.targetApp.bundleIdentifier,
                appIsFocused: context.focusedBundleIdentifier == definition.targetApp.bundleIdentifier,
                availableControls: [:],
                visibleText: [
                    "document": context.focusedWindowTitle
                        ?? intent.normalizedEntities["document"]
                        ?? "current document"
                ],
                confidence: context.focusedWindowTitle == nil ? 0.4 : 0.72,
                metadata: [
                    "observer": "local-app-task-context",
                    "documentFormFillPlan.status": documentPlan.status.rawValue
                ]
            )
            let initialActionPlan = adapter.evidenceBackedActionPlan(for: intent, observation: observation)
            stepTracker.complete(
                .evidencePlan,
                summary: "Built review-first document form-fill plan",
                metadata: ["terminalState": initialActionPlan.terminalState.rawValue]
            )
            stepTracker.wait(
                .approval,
                summary: "Waiting for user review before Accessibility execution",
                metadata: [
                    "documentFormFillPlan.status": documentPlan.status.rawValue,
                    "proposalCount": String(documentPlan.proposals.count)
                ]
            )
            stepTracker.skip(.execute, summary: "Execution waits for user approval")
            stepTracker.skip(.verify, summary: "Verification waits for approved execution")
            let progress = stepTracker.snapshot()
            await coordinator?.complete(reason: "Local app task requires document review")
            return LocalAppTaskLiveRunResult(
                command: command,
                traceID: traceID,
                status: .needsUserReview,
                resolution: resolution,
                initialActionPlan: initialActionPlan,
                finalActionPlan: initialActionPlan,
                observation: observation,
                documentFormFillPlan: documentPlan,
                workflowProgress: progress,
                metadata: runMetadata.merging([
                    "reason": "reviewOnlyTask",
                    "documentFormFillPlan.status": documentPlan.status.rawValue,
                    "documentFormFillPlan.proposalCount": String(documentPlan.proposals.count),
                    "latency.totalMS": Self.formatLatency(Self.uptimeMilliseconds() - runStartedAt)
                ], uniquingKeysWith: { current, _ in current }).merging(
                    Self.workflowProgressMetadata(progress),
                    uniquingKeysWith: { current, _ in current }
                )
            )
        }

        await coordinator?.waitIfPaused()
        let launchStartedAt = Self.uptimeMilliseconds()
        stepTracker.start(.observe, summary: "Launching or focusing target app for observation")
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
        let launchObservation = await appController.launchOrFocus(
            definition: definition,
            availability: availability
        )
        runMetadata["latency.launchFocusMS"] = Self.formatLatency(Self.uptimeMilliseconds() - launchStartedAt)
        stepTracker.complete(
            .observe,
            summary: "Observed target app after launch or focus",
            metadata: [
                "appIsRunning": String(launchObservation.appIsRunning),
                "appIsFocused": String(launchObservation.appIsFocused)
            ]
        )
        stepTracker.start(.evidencePlan, summary: "Building evidence-backed action plan")
        let initialActionPlan = adapter.evidenceBackedActionPlan(for: intent, observation: launchObservation)
        guard initialActionPlan.canExecuteGuardedActions else {
            stepTracker.block(
                .evidencePlan,
                summary: "Evidence-backed action plan blocked live input",
                metadata: ["terminalState": initialActionPlan.terminalState.rawValue]
            )
            stepTracker.skip(.approval, summary: "No approval requested for blocked evidence plan")
            stepTracker.skip(.execute, summary: "Execution skipped because evidence was incomplete")
            stepTracker.skip(.verify, summary: "Verification skipped because evidence was incomplete")
            let progress = stepTracker.snapshot()
            await coordinator?.pause(reason: "Local app task evidence-backed action plan blocked live input")
            return LocalAppTaskLiveRunResult(
                command: command,
                traceID: traceID,
                status: blockedEvidencePlanStatus(for: initialActionPlan.terminalState),
                resolution: resolution,
                initialActionPlan: initialActionPlan,
                observation: launchObservation,
                workflowProgress: progress,
                metadata: runMetadata.merging([
                    "reason": "evidencePlanBlocked",
                    "latency.totalMS": Self.formatLatency(Self.uptimeMilliseconds() - runStartedAt)
                ], uniquingKeysWith: { current, _ in current }).merging(
                    Self.workflowProgressMetadata(progress),
                    uniquingKeysWith: { current, _ in current }
                )
            )
        }
        stepTracker.complete(
            .evidencePlan,
            summary: "Evidence-backed action plan allows guarded live execution",
            metadata: ["terminalState": initialActionPlan.terminalState.rawValue]
        )
        if LocalAppTaskVerificationPolicy.mode(for: definition) == .openedLocalItem,
           initialActionPlan.terminalState == .completed {
            stepTracker.skip(.approval, summary: "No review gate required for opened local item")
            stepTracker.skip(.execute, summary: "Local item was opened through NSWorkspace")
            stepTracker.complete(
                .verify,
                summary: "Local item open request confirmed",
                metadata: ["terminalState": initialActionPlan.terminalState.rawValue]
            )
            await coordinator?.complete(reason: "Local item opened")
            let progress = stepTracker.snapshot()
            return LocalAppTaskLiveRunResult(
                command: command,
                traceID: traceID,
                status: .completed,
                resolution: resolution,
                initialActionPlan: initialActionPlan,
                finalActionPlan: initialActionPlan,
                observation: launchObservation,
                workflowProgress: progress,
                metadata: runMetadata.merging([
                    "reason": "openedLocalItem",
                    "latency.totalMS": Self.formatLatency(Self.uptimeMilliseconds() - runStartedAt)
                ], uniquingKeysWith: { current, _ in current }).merging(
                    Self.workflowProgressMetadata(progress),
                    uniquingKeysWith: { current, _ in current }
                )
            )
        }
        stepTracker.skip(.approval, summary: "No review gate required for this local-app task")

        var actionTraces: [ActionEngineCommandTrace] = []
        let automationCommands = adapter.guardedAutomationCommandTemplates(
            for: intent,
            issuedAt: Self.now()
        )
        let usesAutomationBackend = !automationCommands.isEmpty
        var accessibilityActionMS = 0.0
        if !usesAutomationBackend {
            let accessibilityCommands = await accessibilityCommandTemplates(
                intent: intent,
                definition: definition
            )
            if !accessibilityCommands.isEmpty {
                let accessibilityEngine = Self.accessibilityActionEngine(for: definition)
                for (index, actionCommand) in accessibilityCommands.enumerated() {
                    await coordinator?.waitIfPaused()
                    let spacedCommand = actionCommand.withIssuedAt(Self.now(advancedByMilliseconds: Double(index) * 60))
                    let actionStartedAt = Self.uptimeMilliseconds()
                    await coordinator?.recordToolEvent(
                        capability: .accessibility,
                        decision: permissionPolicy.decision(for: .accessibility),
                        toolName: "mac-accessibility-action-engine",
                        summary: "Executing guarded Accessibility command",
                        traceID: traceID,
                        metadata: [
                            "commandID": spacedCommand.id,
                            "workflowStepID": spacedCommand.metadata["workflowStepID"] ?? ""
                        ]
                    )
                    let trace = await accessibilityEngine.handle(
                        spacedCommand,
                        permissionPolicy: permissionPolicy
                    )
                    accessibilityActionMS += Self.uptimeMilliseconds() - actionStartedAt
                    actionTraces.append(trace)
                    guard trace.executed || trace.decision == .skippedNoLiveInput else {
                        break
                    }
                }
            }
        }
        runMetadata["latency.accessibilityActionMS"] = Self.formatLatency(accessibilityActionMS)

        let engine = actionEngineFactory(definition)
        let accessibilityHandledStepIDs: Set<String> = Set(actionTraces.compactMap { trace -> String? in
            guard trace.executed || trace.decision == ActionEngineCommandDecision.skippedNoLiveInput else { return nil }
            return workflowStepID(from: trace.command)
        })
        runMetadata["accessibilityHandledStepIDs"] = accessibilityHandledStepIDs.sorted().joined(separator: ",")
        let commands = usesAutomationBackend
            ? automationCommands
            : adapter.guardedKeyboardCommandTemplates(
                for: intent,
                issuedAt: Self.now()
            ).filter { command in
                guard let workflowStepID = command.metadata["workflowStepID"] else { return true }
                return !accessibilityHandledStepIDs.contains(workflowStepID)
            }

        var keyboardActionMS = 0.0
        stepTracker.start(.execute, summary: "Executing guarded local-app actions")
        for (index, actionCommand) in commands.enumerated() {
            await coordinator?.waitIfPaused()
            let spacedCommand = actionCommand.withIssuedAt(Self.now(advancedByMilliseconds: Double(index) * 40))
            let actionStartedAt = Self.uptimeMilliseconds()
            let automationBackend = actionCommand.metadata["automationBackend"] ?? ""
            let actionToolName = automationBackend == "appleScript"
                ? "mac-applescript-action-engine"
                : "mac-keyboard-action-engine"
            await coordinator?.recordToolEvent(
                capability: .input,
                decision: permissionPolicy.decision(for: .input),
                toolName: actionToolName,
                summary: automationBackend == "appleScript"
                    ? "Executing guarded AppleScript command"
                    : "Executing guarded keyboard command",
                traceID: traceID,
                metadata: [
                    "commandID": spacedCommand.id,
                    "workflowStepID": spacedCommand.metadata["workflowStepID"] ?? ""
                ]
            )
            var trace = await engine.handle(
                spacedCommand,
                permissionPolicy: permissionPolicy
            )
            keyboardActionMS += Self.uptimeMilliseconds() - actionStartedAt
            actionTraces.append(trace)
            if trace.decision == .denied(reason: "focus guard failed") {
                _ = await appController.launchOrFocus(
                    definition: definition,
                    availability: availability
                )
                let retryCommand = spacedCommand.withIssuedAt(Self.now(advancedByMilliseconds: Double(index) * 40 + 25))
                trace = await engine.handle(
                    retryCommand,
                    permissionPolicy: permissionPolicy
                )
                actionTraces.append(trace)
            }

            guard trace.executed || trace.decision == ActionEngineCommandDecision.skippedNoLiveInput else {
                stepTracker.fail(
                    .execute,
                    summary: "Guarded local-app action was denied",
                    metadata: [
                        "actionDeniedReason": decisionReason(trace.decision),
                        "commandID": trace.command.id
                    ]
                )
                let observationStartedAt = Self.uptimeMilliseconds()
                await coordinator?.recordToolEvent(
                    capability: .perception,
                    decision: permissionPolicy.decision(for: .perception),
                    toolName: "local-app-observation",
                    summary: "Observing local app after denied action",
                    traceID: traceID
                )
                let finalObservation = await appController.observe(definition: definition)
                runMetadata["latency.observationMS"] = Self.formatLatency(
                    Self.uptimeMilliseconds() - observationStartedAt
                )
                let verificationStartedAt = Self.uptimeMilliseconds()
                let finalActionPlan = adapter.evidenceBackedActionPlan(for: intent, observation: finalObservation)
                runMetadata["latency.verificationMS"] = Self.formatLatency(
                    Self.uptimeMilliseconds() - verificationStartedAt
                )
                await coordinator?.fail(reason: "Local app task action was denied")
                let progress = stepTracker.snapshot()
                return LocalAppTaskLiveRunResult(
                    command: command,
                    traceID: traceID,
                    status: .failedSafe,
                    resolution: resolution,
                    initialActionPlan: initialActionPlan,
                    finalActionPlan: finalActionPlan,
                    observation: finalObservation,
                    actionTraces: actionTraces,
                    workflowProgress: progress,
                    metadata: runMetadata.merging([
                        "reason": "actionDenied",
                        "actionDeniedReason": decisionReason(trace.decision),
                        "actionDeniedCommandID": trace.command.id,
                        "actionDeniedFocusGuardPassed": String(trace.focusGuardPassed),
                        "latency.keyboardActionMS": Self.formatLatency(keyboardActionMS),
                        "latency.totalMS": Self.formatLatency(Self.uptimeMilliseconds() - runStartedAt)
                    ], uniquingKeysWith: { current, _ in current }).merging(
                        Self.actionTraceMetadata(actionTraces),
                        uniquingKeysWith: { current, _ in current }
                    ).merging(
                        Self.workflowProgressMetadata(progress),
                        uniquingKeysWith: { current, _ in current }
                    )
                )
            }
        }
        runMetadata["latency.keyboardActionMS"] = Self.formatLatency(keyboardActionMS)
        runMetadata.merge(Self.actionTraceMetadata(actionTraces)) { current, _ in current }
        if usesAutomationBackend {
            runMetadata["automation.backend"] = automationCommands.first?.metadata["automationBackend"] ?? ""
            runMetadata["automation.action"] = automationCommands.first?.metadata["appleScript.action"] ?? ""
            runMetadata["latency.automationActionMS"] = Self.formatLatency(keyboardActionMS)
        }
        stepTracker.complete(
            .execute,
            summary: "Guarded local-app actions completed",
            metadata: [
                "executedCommandCount": String(actionTraces.filter(\.executed).count),
                "skippedNoLiveInputCommandCount": String(actionTraces.filter { $0.decision == .skippedNoLiveInput }.count)
            ]
        )

        await coordinator?.waitIfPaused()
        try? await Task.sleep(nanoseconds: 700_000_000)
        await coordinator?.waitIfPaused()
        let observationStartedAt = Self.uptimeMilliseconds()
        stepTracker.start(.verify, summary: "Observing target app for result verification")
        await coordinator?.recordToolEvent(
            capability: .perception,
            decision: permissionPolicy.decision(for: .perception),
            toolName: "local-app-observation",
            summary: "Observing local app for result verification",
            traceID: traceID
        )
        var finalObservation = await appController.observe(definition: definition)
        finalObservation = observationWithActionEvidence(
            finalObservation,
            actionTraces: actionTraces
        )
        runMetadata["latency.observationMS"] = Self.formatLatency(Self.uptimeMilliseconds() - observationStartedAt)
        let verificationStartedAt = Self.uptimeMilliseconds()
        let finalActionPlan = adapter.evidenceBackedActionPlan(for: intent, observation: finalObservation)
        runMetadata["latency.verificationMS"] = Self.formatLatency(Self.uptimeMilliseconds() - verificationStartedAt)
        runMetadata["latency.totalMS"] = Self.formatLatency(Self.uptimeMilliseconds() - runStartedAt)
        if let verificationStep = finalActionPlan.steps.first(where: { $0.role == .verifyResult }) {
            runMetadata["verification.summary"] = verificationStep.summary
            runMetadata["verification.status"] = verificationStep.status.rawValue
            for (key, value) in verificationStep.metadata {
                runMetadata["verification.\(key)"] = value
            }
        }
        let status = status(for: finalActionPlan.terminalState)
        if status == .completed {
            stepTracker.complete(
                .verify,
                summary: "Local app task result verified",
                metadata: ["terminalState": finalActionPlan.terminalState.rawValue]
            )
            await coordinator?.complete(reason: "Local app task completed")
        } else {
            stepTracker.block(
                .verify,
                summary: "Local app task needs user review after verification",
                metadata: ["terminalState": finalActionPlan.terminalState.rawValue]
            )
            await coordinator?.pause(reason: "Local app task needs user review")
        }
        let progress = stepTracker.snapshot()
        return LocalAppTaskLiveRunResult(
            command: command,
            traceID: traceID,
            status: status,
            resolution: resolution,
            initialActionPlan: initialActionPlan,
            finalActionPlan: finalActionPlan,
            observation: finalObservation,
            actionTraces: actionTraces,
            workflowProgress: progress,
            metadata: runMetadata.merging([
                "executedCommandCount": String(actionTraces.filter(\.executed).count),
                "skippedNoLiveInputCommandCount": String(actionTraces.filter { $0.decision == .skippedNoLiveInput }.count)
            ], uniquingKeysWith: { current, _ in current }).merging(
                Self.workflowProgressMetadata(progress),
                uniquingKeysWith: { current, _ in current }
            )
        )
    }

    public static func defaultActionEngine(for definition: LocalAppTaskDefinition) -> ActionEngineGuardrail {
        let inputBackend: any ActionEngineInputBackend = definition.metadata["automationBackend"] == "appleScript"
            ? MacAppleScriptActionEngineInputBackend()
            : MacKeyboardActionEngineInputBackend()

        return ActionEngineGuardrail(
            configuration: ActionEngineConfiguration(liveInputEnabled: true),
            focusGuard: MacLocalAppFocusGuard(
                targetID: LocalAppTaskAdapter(definition: definition).targetID,
                bundleIdentifier: definition.targetApp.bundleIdentifier
            ),
            inputBackend: inputBackend
        )
    }

    public static func accessibilityActionEngine(for definition: LocalAppTaskDefinition) -> ActionEngineGuardrail {
        ActionEngineGuardrail(
            configuration: ActionEngineConfiguration(liveInputEnabled: true),
            focusGuard: MacLocalAppFocusGuard(
                targetID: LocalAppTaskAdapter(definition: definition).targetID,
                bundleIdentifier: definition.targetApp.bundleIdentifier
            ),
            inputBackend: MacAccessibilityActionEngineInputBackend()
        )
    }

    private func unresolvedResult(
        command: String,
        traceID: String,
        resolution: LocalAppTaskCatalogResolution,
        workflowProgress: LocalAppTaskWorkflowProgress,
        metadata: [String: String]
    ) -> LocalAppTaskLiveRunResult {
        let status: LocalAppTaskLiveRunStatus
        switch resolution.status {
        case .resolved:
            status = .failedSafe
        case .needsConfirmation:
            status = .needsConfirmation
        case .unsupportedCommand:
            status = .unsupportedCommand
        case .appUnavailable:
            status = .appUnavailable
        }

        return LocalAppTaskLiveRunResult(
            command: command,
            traceID: traceID,
            status: status,
            resolution: resolution,
            workflowProgress: workflowProgress,
            metadata: metadata
        )
    }

    private func publishUnresolvedRun(
        command: String,
        traceID: String,
        resolution: LocalAppTaskCatalogResolution
    ) async {
        await publishRunStart(
            command: command,
            traceID: traceID,
            targetID: resolution.definition.map { LocalAppTaskAdapter(definition: $0).targetID }
                ?? "local-app-task-unresolved"
        )
        await coordinator?.recordToolEvent(
            capability: .controller,
            decision: .deny(reason: resolution.metadata["reason"] ?? resolution.status.rawValue),
            toolName: "local-app-task-catalog",
            summary: "Local app task could not be resolved",
            traceID: traceID,
            metadata: resolution.metadata.merging([
                "resolution.status": resolution.status.rawValue
            ]) { current, _ in current }
        )

        switch resolution.status {
        case .needsConfirmation:
            await coordinator?.pause(reason: "Local app task needs confirmation")
        case .unsupportedCommand, .appUnavailable, .resolved:
            await coordinator?.fail(reason: "Local app task could not be resolved")
        }
    }

    private func publishRunStart(
        command: String,
        traceID: String,
        targetID: String
    ) async {
        guard let coordinator else { return }

        await coordinator.setTraceID(traceID)
        _ = await coordinator.start(
            RunSession(
                userGoal: command,
                targetID: targetID,
                runtimeProfile: "local-app-task",
                permissionPolicy: permissionPolicy
            )
        )
    }

    @MainActor
    private func accessibilityCommandTemplates(
        intent: TaskIntent,
        definition: LocalAppTaskDefinition
    ) -> [ActionEngineCommand] {
        guard AXIsProcessTrusted(),
              let target = try? MacWindowResolver().selectTarget(),
              target.bundleIdentifier == definition.targetApp.bundleIdentifier
        else {
            return []
        }

        let limits = MacAccessibilitySnapshotLimits(maxDepth: 6, maxChildrenPerNode: 80, maxTotalNodes: 500)
        guard let tree = try? ApplicationServicesMacAccessibilitySnapshotCapturer().captureTree(
            target: target,
            limits: limits
        ) else {
            return []
        }
        let snapshot = MacAccessibilitySnapshot(
            target: target,
            limits: limits,
            root: tree.root,
            totalNodeCount: tree.totalNodeCount,
            isTreeTruncated: tree.isTreeTruncated
        )
        let index = LocalAppAccessibilityControlDiscovery().discover(in: snapshot)
        return LocalAppAccessibilityActionPlanner().commands(
            for: intent,
            definition: definition,
            index: index,
            issuedAt: Self.now()
        )
    }

    private func observationWithActionEvidence(
        _ observation: LocalAppTaskObservation,
        actionTraces: [ActionEngineCommandTrace]
    ) -> LocalAppTaskObservation {
        var enriched = observation
        let executed = actionTraces.filter(\.executed)
        let submitCount = executed.filter { Self.isReturnSubmitCommand($0.command) }.count
        enriched.metadata.merge([
            "postActionObservation": "true",
            "executedCommandCount": String(executed.count),
            "submittedCommandCount": String(submitCount)
        ]) { current, _ in current }
        return enriched
    }

    private static func isReturnSubmitCommand(_ command: ActionEngineCommand) -> Bool {
        command.metadata["workflowStepRole"] == LocalAppTaskStepRole.submit.rawValue
            && command.key == "Return"
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

    private func blockedEvidencePlanStatus(
        for terminalState: LocalAppTaskTerminalState
    ) -> LocalAppTaskLiveRunStatus {
        switch terminalState {
        case .completed, .needsUserReview:
            return .needsUserReview
        case .failedSafe, .timedOut:
            return .failedSafe
        }
    }

    private func decisionReason(_ decision: ActionEngineCommandDecision) -> String {
        switch decision {
        case .denied(let reason):
            return reason
        case .skippedNoLiveInput:
            return "skippedNoLiveInput"
        case .executedLive:
            return "executedLive"
        }
    }

    private func workflowStepID(from command: ActionEngineCommand) -> String? {
        if let workflowStepID = command.metadata["workflowStepID"] {
            return workflowStepID
        }

        guard let markerRange = command.id.range(of: "-ax-") else {
            return command.metadata["workflowStepRole"]
        }

        return String(command.id[markerRange.upperBound...])
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

    private static func workflowProgressMetadata(
        _ progress: LocalAppTaskWorkflowProgress
    ) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: progress.stages.map { state in
                ("workflow.\(state.stage.rawValue).status", state.status.rawValue)
            }
        )
    }

    private static func actionTraceMetadata(_ traces: [ActionEngineCommandTrace]) -> [String: String] {
        guard !traces.isEmpty else { return [:] }

        let lastTrace = traces[traces.count - 1]
        let backends = Set(traces.compactMap { trace in
            trace.metadata["liveInputBackend"]
        }).sorted()
        let elementClickCount = traces.filter { trace in
            isElementClick(trace.command)
        }.count
        let targetedElementCount = traces.filter { trace in
            trace.command.targetBounds != nil || trace.command.metadata["controlID"]?.isEmpty == false
        }.count

        return [
            "action.traceCount": String(traces.count),
            "action.executedCount": String(traces.filter(\.executed).count),
            "action.backends": backends.joined(separator: ","),
            "action.elementClickCount": String(elementClickCount),
            "action.targetedElementCount": String(targetedElementCount),
            "action.lastCommandID": lastTrace.command.id,
            "action.lastCommandKind": lastTrace.command.kind.rawValue,
            "action.lastDecision": decisionDescription(lastTrace.decision),
            "action.lastBackend": lastTrace.metadata["liveInputBackend"] ?? "",
            "action.lastTarget": actionTargetDescription(lastTrace.command),
            "action.lastAppleScriptOutput": lastTrace.metadata["appleScript.output"] ?? "",
            "action.lastAccessibilityResult": lastTrace.metadata["accessibility.result"] ?? "",
            "action.overlayPointer": "visualOnly"
        ]
    }

    private static func isElementClick(_ command: ActionEngineCommand) -> Bool {
        (command.kind == .tap || command.kind == .mouse) &&
            (command.targetBounds != nil || command.metadata["controlID"]?.isEmpty == false)
    }

    private static func actionTargetDescription(_ command: ActionEngineCommand) -> String {
        if let controlID = command.metadata["controlID"],
           !controlID.isEmpty {
            return "control:\(controlID)"
        }
        guard let bounds = command.targetBounds else { return "none" }
        return String(
            format: "bounds:x=%.3f,y=%.3f,w=%.3f,h=%.3f,space=%@",
            bounds.origin.x,
            bounds.origin.y,
            bounds.size.width,
            bounds.size.height,
            bounds.space.rawValue
        )
    }

    private static func decisionDescription(_ decision: ActionEngineCommandDecision) -> String {
        switch decision {
        case .skippedNoLiveInput:
            return "skippedNoLiveInput"
        case .executedLive:
            return "executedLive"
        case .denied(let reason):
            return "denied:\(reason)"
        }
    }
}

public struct MacLocalAppFocusGuard: ActionEngineFocusGuard {
    public var targetID: String
    public var bundleIdentifier: String?

    public init(targetID: String, bundleIdentifier: String?) {
        self.targetID = targetID
        self.bundleIdentifier = bundleIdentifier
    }

    public func targetIsSafeForInput(targetID: String) async -> Bool {
        guard targetID == self.targetID,
              let bundleIdentifier
        else {
            return false
        }

        return await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier
        }
    }
}

public struct MacLocalAppTaskController: LocalAppTaskAppControlling {
    public var uiUnderstandingRunner: any LocalUIUnderstandingRunning

    public init(
        uiUnderstandingRunner: any LocalUIUnderstandingRunning = ProcessBackedLocalUIUnderstandingAdapter()
    ) {
        self.uiUnderstandingRunner = uiUnderstandingRunner
    }

    @MainActor
    public func launchOrFocus(
        definition: LocalAppTaskDefinition,
        availability: LocalAppAvailability
    ) async -> LocalAppTaskObservation {
        if let itemURL = availability.appURL,
           let itemKind = availability.metadata["itemKind"],
           itemKind != "application" {
            let opened = await openLocalItem(at: itemURL)
            if let bundleIdentifier = definition.targetApp.bundleIdentifier {
                await waitForFrontmostApplication(
                    LocalAppTarget(
                        appName: definition.targetApp.appName,
                        bundleIdentifier: bundleIdentifier,
                        titleContains: definition.targetApp.titleContains
                    )
                )
            }
            let isFocused = definition.targetApp.bundleIdentifier == nil
                || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == definition.targetApp.bundleIdentifier
            return LocalAppTaskObservation(
                appIsRunning: opened,
                appIsFocused: opened && isFocused,
                availableControls: [:],
                visibleText: ["appName": definition.targetApp.appName],
                confidence: opened ? 0.72 : 0.2,
                metadata: [
                    "observer": "mac-local-app-controller",
                    "openedLocalItem": String(opened),
                    "localItem.kind": itemKind,
                    "localItem.path": itemURL.path,
                    "defaultApplication": availability.metadata["defaultApplication"] ?? ""
                ]
            )
        }

        if let appURL = availability.appURL {
            await openApplication(at: appURL)
        } else if let runningApplication = runningApplication(for: definition.targetApp) {
            runningApplication.activate(options: [.activateAllWindows])
        }

        await waitForFrontmostApplication(definition.targetApp)
        return await observe(definition: definition)
    }

    @MainActor
    public func observe(definition: LocalAppTaskDefinition) async -> LocalAppTaskObservation {
        let runningApplication = runningApplication(for: definition.targetApp)
        let isFocused = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == definition.targetApp.bundleIdentifier
        let verificationKey = definition.metadata["verificationTextKey"]
            ?? definition.verificationEntityName
            ?? "visibleText"
        let accessibilityIndex = accessibilityControlIndex(for: definition, runningApplication: runningApplication)
        let visibleText = accessibilityIndex?.visibleText ?? accessibilityVisibleText(for: runningApplication)
        var controls: [String: Bool] = Dictionary(
            uniqueKeysWithValues: definition.workflowSteps.compactMap { step in
                guard step.role == .focusControl,
                      let controlID = step.metadata["controlID"]
                else {
                    return nil
                }
                let discovered = accessibilityIndex?.firstControl(matching: controlID) != nil
                return (controlID, discovered)
            }
        )

        var textValues: [String: String] = [:]
        if let visibleText {
            textValues["visibleText"] = visibleText
            textValues[verificationKey] = visibleText
        }

        var accessibilityMetadata = [
            "observer": "mac-local-app-controller",
            "accessibilityTrusted": String(AXIsProcessTrusted()),
            "accessibilityControlDiscovery": String(accessibilityIndex != nil),
            "accessibilityControlCount": accessibilityIndex?.metadata["controlCount"] ?? "0"
        ].merging(accessibilityIndex?.metadata ?? [:]) { current, _ in current }
        for step in definition.workflowSteps {
            guard let controlID = step.metadata["controlID"],
                  let control = accessibilityIndex?.firstControl(matching: controlID)
            else {
                continue
            }
            let frame = control.frame.map {
                HotLoopRect(
                    x: $0.x,
                    y: $0.y,
                    width: $0.width,
                    height: $0.height,
                    space: .screen
                )
            }
            accessibilityMetadata.merge(
                LocalAppObservationGeometry.controlMetadata(
                    controlID: controlID,
                    frame: frame,
                    source: .accessibility,
                    label: control.label,
                    kind: control.kind,
                    confidence: 0.86,
                    extra: control.metadata
                )
            ) { current, _ in current }
        }

        let accessibilityObservation = LocalAppTaskObservation(
            appIsRunning: runningApplication != nil,
            appIsFocused: isFocused,
            availableControls: controls,
            visibleText: textValues,
            confidence: accessibilityIndex == nil ? (visibleText == nil ? 0.4 : 0.75) : 0.86,
            metadata: accessibilityMetadata
        )

        guard shouldIncludeScreenshotUnderstanding(
            definition: definition,
            accessibilityObservation: accessibilityObservation,
            verificationKey: verificationKey
        ) else {
            return accessibilityObservation
        }

        guard let screenshotObservation = await screenshotUnderstandingObservation(
            definition: definition,
            runningApplication: runningApplication,
            isFocused: isFocused,
            verificationKey: verificationKey
        ) else {
            var metadata = accessibilityObservation.metadata
            metadata["screenshotUnderstanding.status"] = "unavailable"
            return LocalAppTaskObservation(
                appIsRunning: accessibilityObservation.appIsRunning,
                appIsFocused: accessibilityObservation.appIsFocused,
                availableControls: accessibilityObservation.availableControls,
                visibleText: accessibilityObservation.visibleText,
                confidence: accessibilityObservation.confidence,
                metadata: metadata
            )
        }

        controls.merge(screenshotObservation.availableControls) { current, new in current || new }
        return LocalAppTaskObservation(
            appIsRunning: accessibilityObservation.appIsRunning || screenshotObservation.appIsRunning,
            appIsFocused: accessibilityObservation.appIsFocused || screenshotObservation.appIsFocused,
            availableControls: controls,
            visibleText: accessibilityObservation.visibleText.merging(
                screenshotObservation.visibleText
            ) { current, _ in current },
            confidence: max(accessibilityObservation.confidence, screenshotObservation.confidence),
            metadata: accessibilityObservation.metadata.merging(
                screenshotObservation.metadata
            ) { current, _ in current }
        )
    }

    private func shouldIncludeScreenshotUnderstanding(
        definition: LocalAppTaskDefinition,
        accessibilityObservation: LocalAppTaskObservation,
        verificationKey: String
    ) -> Bool {
        LocalAppTaskObservationFallbackPolicy.shouldUseScreenshotUnderstanding(
            definition: definition,
            accessibilityObservation: accessibilityObservation,
            verificationKey: verificationKey
        )
    }

    @MainActor
    private func screenshotUnderstandingObservation(
        definition: LocalAppTaskDefinition,
        runningApplication: NSRunningApplication?,
        isFocused: Bool,
        verificationKey: String
    ) async -> LocalAppTaskObservation? {
        guard runningApplication != nil,
              let target = try? MacWindowResolver().selectTarget(),
              target.bundleIdentifier == definition.targetApp.bundleIdentifier,
              target.safetyAssessment.status == .allowed
        else {
            return nil
        }

        let screenshot: CapturedWindowScreenshot
        do {
            screenshot = try await ScreenCaptureKitWindowScreenshotCapturer().capture(target: target)
        } catch {
            return nil
        }

        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("donkey-ui-understanding-\(UUID().uuidString).png")
        do {
            try screenshot.pngData.write(to: imageURL, options: .atomic)
        } catch {
            return nil
        }
        defer {
            try? FileManager.default.removeItem(at: imageURL)
        }

        let request = LocalUIUnderstandingRequest(
            traceID: "local-ui-understanding-\(UUID().uuidString)",
            targetID: LocalAppTaskAdapter(definition: definition).targetID,
            appIsRunning: true,
            appIsFocused: isFocused,
            imageFileURL: imageURL,
            cropBounds: HotLoopRect(
                x: 0,
                y: 0,
                width: Double(screenshot.imageWidth),
                height: Double(screenshot.imageHeight),
                space: .window
            ),
            pixelSize: HotLoopSize(
                width: Double(screenshot.imageWidth),
                height: Double(screenshot.imageHeight),
                space: .window
            ),
            metadata: [
                "observer": "mac-local-app-controller",
                "observation.source": "screenshot",
                "verificationTextKey": verificationKey,
                "screenshot.scope": "targetWindow",
                "screenshot.desktopCaptureAllowed": "false",
                "target.windowID": String(target.windowID),
                "capture.method": screenshot.captureMethod.rawValue
            ].merging(LocalAppObservationGeometry.targetBoundsMetadata(target.bounds)) { current, _ in current }
        )

        do {
            return try await uiUnderstandingRunner.understand(request).observation(for: request)
        } catch {
            return nil
        }
    }

    @MainActor
    private func accessibilityControlIndex(
        for definition: LocalAppTaskDefinition,
        runningApplication: NSRunningApplication?
    ) -> LocalAppAccessibilityControlIndex? {
        guard AXIsProcessTrusted(),
              runningApplication != nil,
              let target = try? MacWindowResolver().selectTarget(),
              target.bundleIdentifier == definition.targetApp.bundleIdentifier
        else {
            return nil
        }

        let limits = MacAccessibilitySnapshotLimits(maxDepth: 6, maxChildrenPerNode: 80, maxTotalNodes: 500)
        guard let tree = try? ApplicationServicesMacAccessibilitySnapshotCapturer().captureTree(
            target: target,
            limits: limits
        ) else {
            return nil
        }
        let snapshot = MacAccessibilitySnapshot(
            target: target,
            limits: limits,
            root: tree.root,
            totalNodeCount: tree.totalNodeCount,
            isTreeTruncated: tree.isTreeTruncated
        )
        return LocalAppAccessibilityControlDiscovery().discover(in: snapshot)
    }

    @MainActor
    private func runningApplication(for target: LocalAppTarget) -> NSRunningApplication? {
        guard let bundleIdentifier = target.bundleIdentifier else { return nil }
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first
    }

    @MainActor
    private func openApplication(at url: URL) async {
        await withCheckedContinuation { continuation in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(
                at: url,
                configuration: configuration
            ) { _, _ in
                continuation.resume()
            }
        }
    }

    @MainActor
    private func openLocalItem(at url: URL) async -> Bool {
        NSWorkspace.shared.open(url)
    }

    @MainActor
    private func waitForFrontmostApplication(_ target: LocalAppTarget) async {
        let bundleIdentifier = target.bundleIdentifier
        for _ in 0..<16 {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier {
                return
            }
            try? await Task.sleep(nanoseconds: 125_000_000)
        }
    }

    @MainActor
    private func accessibilityVisibleText(for application: NSRunningApplication?) -> String? {
        guard AXIsProcessTrusted(),
              let processIdentifier = application?.processIdentifier
        else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(processIdentifier)
        let elements = windows(from: appElement)
        let roots = elements.isEmpty ? [appElement] : elements
        let values = roots.flatMap { textValues(from: $0, depth: 0, remaining: 160) }
        let joined = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    @MainActor
    private func windows(from appElement: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success else {
            return []
        }

        return value as? [AXUIElement] ?? []
    }

    @MainActor
    private func textValues(
        from element: AXUIElement,
        depth: Int,
        remaining: Int
    ) -> [String] {
        guard depth <= 8, remaining > 0 else { return [] }

        var values: [String] = []
        for attribute in [
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXValueAttribute,
            kAXHelpAttribute
        ] {
            if let text = stringAttribute(attribute as CFString, from: element) {
                values.append(text)
            }
        }

        let children = children(from: element)
        let nextRemaining = max(0, remaining - values.count)
        for child in children.prefix(nextRemaining) {
            values.append(contentsOf: textValues(
                from: child,
                depth: depth + 1,
                remaining: max(0, nextRemaining - values.count)
            ))
            if values.count >= remaining {
                break
            }
        }

        return values
    }

    @MainActor
    private func children(from element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success else {
            return []
        }

        return value as? [AXUIElement] ?? []
    }

    @MainActor
    private func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value
        else {
            return nil
        }

        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }
}

private extension ActionEngineCommand {
    var commandName: String {
        metadata["taskType"] ?? id
    }

    func withIssuedAt(_ issuedAt: RunTraceTimestamp) -> ActionEngineCommand {
        ActionEngineCommand(
            id: id,
            traceID: traceID,
            targetID: targetID,
            stateID: stateID,
            actionID: actionID,
            kind: kind,
            issuedAt: issuedAt,
            targetBounds: targetBounds,
            key: key,
            holdDurationMS: holdDurationMS,
            metadata: metadata
        )
    }
}
