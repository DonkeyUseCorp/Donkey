import DonkeyAI
import DonkeyContracts
import DonkeyHarness
import DonkeyRuntime
import Foundation
import OSLog

private enum UserQueryLog {
    #if DEBUG
    static let isEnabled = true
    #else
    static let isEnabled = false
    #endif

    static let commands = Logger(subsystem: "com.donkey.app", category: "user-query")
}

/// End-to-end vision-grounding telemetry. Intentionally NOT `#if DEBUG`-gated and mirrored to
/// stdout: these are the latency numbers we capture for marketing, so they must be visible when
/// running a release binary from the terminal — not just in a debug build's os_log stream.
private enum VisionGroundingLog {
    static let logger = Logger(subsystem: "com.donkey.app", category: "vision-grounding")

    static func emit(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        print("[grounding-e2e] \(message)")
    }
}

/// Configurable, env-gated "vision navigation" route. When enabled, a typed query is grounded
/// straight into on-screen actions by `VisionActionDriver` against the FRONTMOST user app —
/// bypassing the intent/AppleScript pipeline entirely. Gated by `DONKEY_VISION_NAV` so it is
/// trivial to turn off and revert to the standard route; the value is injectable so callers and
/// tests can force it on or off without touching the environment.
struct VisionNavigationMode: Equatable, Sendable {
    var isEnabled: Bool

    static let disabled = VisionNavigationMode(isEnabled: false)

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> VisionNavigationMode {
        let raw = (environment["DONKEY_VISION_NAV"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return VisionNavigationMode(isEnabled: ["1", "true", "yes", "on"].contains(raw))
    }
}

struct UserQueryCommandHandlingResult: Equatable, Sendable {
    var status: LocalAppTaskLiveRunStatus
    var threadStatus: UserQueryTaskStatus
    var decision: AppHarnessDecision
    var summary: String
    var taskLabel: String?
    var traceID: String
    var metadata: [String: String]
    var documentReviewRequest: DocumentFormFillReviewRequest?
    var agentVisualizationPlan: AgentVisualizationPlan?
    var cursorOverlayRequest: PointerCoachCursorGuideRequest?

    init(
        status: LocalAppTaskLiveRunStatus,
        threadStatus: UserQueryTaskStatus,
        decision: AppHarnessDecision,
        summary: String,
        traceID: String,
        metadata: [String: String],
        taskLabel: String? = nil,
        documentReviewRequest: DocumentFormFillReviewRequest? = nil,
        agentVisualizationPlan: AgentVisualizationPlan? = nil,
        cursorOverlayRequest: PointerCoachCursorGuideRequest? = nil
    ) {
        self.status = status
        self.threadStatus = threadStatus
        self.decision = decision
        self.summary = summary
        self.taskLabel = taskLabel
        self.traceID = traceID
        self.metadata = metadata
        self.documentReviewRequest = documentReviewRequest
        self.agentVisualizationPlan = agentVisualizationPlan
        self.cursorOverlayRequest = cursorOverlayRequest
    }
}

struct DocumentFormFillReviewRequest: Equatable, Sendable {
    var plan: DocumentFormFillPlan
    var definition: LocalAppTaskDefinition
    var traceID: String
}

private struct UserQueryModelIntentInput: Equatable, Sendable {
    var command: String
    var contextSnippets: [String]
}

struct UserQueryCommandContext: Sendable {
    var task: UserQueryNotchTask
    var recentEvents: [UserQueryTaskEvent]
    var assets: [UserQueryTaskAsset]
    var isFollowUp: Bool
    var turnSource: AppHarnessTurnSource = .typedPrompt
    var spawnProgressChanged: (@MainActor @Sendable (UserQuerySpawnProgressUpdate) -> Void)?
    var agentVisualizationChanged: (@MainActor @Sendable (AgentVisualizationPlan) -> Void)?
}

protocol UserQueryCommandHandling: Sendable {
    func handleSubmittedCommand(
        _ command: String,
        context: UserQueryCommandContext?
    ) async -> UserQueryCommandHandlingResult
    func pauseCommand(taskID: String) async -> Bool
    func resumeCommand(taskID: String) async -> Bool
    func approvePermissionGate(taskID: String) async -> Bool
}

extension UserQueryCommandHandling {
    func handleSubmittedCommand(_ command: String) async -> UserQueryCommandHandlingResult {
        await handleSubmittedCommand(command, context: nil)
    }
}

struct LocalAppUserQueryCommandHandler: UserQueryCommandHandling {
    var catalog: LocalAppTaskCatalog
    var taskIntentAdapter: any TaskIntentParsingAdapter
    var appController: any LocalAppTaskAppControlling
    var actionEngineFactory: LocalAppHarnessStepExecutor.ActionEngineFactory
    var permissionPolicy: ToolCallPolicy
    var redactor: AIHarnessRedactor
    var memoryRetriever: SemanticRunMemoryRetriever
    var coordinatorRegistry: UserQueryRunCoordinatorRegistry
    var genericHarnessLifecycle: AppHarnessGenericLifecycle
    var memoryStore: SQLiteAgentMemoryStore?
    var visionNavigationMode: VisionNavigationMode

    init(
        catalog: LocalAppTaskCatalog = .defaultLocal(),
        taskIntentAdapter: (any TaskIntentParsingAdapter)? = nil,
        appController: any LocalAppTaskAppControlling = MacLocalAppTaskController(
            uiUnderstandingRunner: DonkeyUIUnderstandingRunnerFactory.defaultRunner()
        ),
        actionEngineFactory: @escaping LocalAppHarnessStepExecutor.ActionEngineFactory = LocalAppTaskActionEngines.keyboardOrAutomation(for:),
        permissionPolicy: ToolCallPolicy = ToolCallPolicy(
            allowedCapabilities: ToolCallPolicy.defaultAllowedCapabilities.union([.input]),
            deniedCapabilities: []
        ),
        redactor: AIHarnessRedactor = AIHarnessRedactor(),
        memoryRetriever: SemanticRunMemoryRetriever = SemanticRunMemoryRetriever(),
        coordinatorRegistry: UserQueryRunCoordinatorRegistry = UserQueryRunCoordinatorRegistry(),
        genericHarnessLifecycle: AppHarnessGenericLifecycle = AppHarnessGenericLifecycle(),
        memoryStore: SQLiteAgentMemoryStore? = .shared,
        visionNavigationMode: VisionNavigationMode = .fromEnvironment()
    ) {
        self.catalog = catalog
        self.coordinatorRegistry = coordinatorRegistry
        self.taskIntentAdapter = taskIntentAdapter ?? HostedTaskIntentParsingAdapter()
        self.appController = appController
        self.actionEngineFactory = actionEngineFactory
        self.permissionPolicy = permissionPolicy
        self.redactor = redactor
        self.memoryRetriever = memoryRetriever
        self.genericHarnessLifecycle = genericHarnessLifecycle
        self.memoryStore = memoryStore
        self.visionNavigationMode = visionNavigationMode
    }

    func handleSubmittedCommand(
        _ command: String,
        context: UserQueryCommandContext?
    ) async -> UserQueryCommandHandlingResult {
        let traceID = "user-query-\(UUID().uuidString)"
        let taskID = context?.task.id ?? traceID
        logSubmittedCommand(command, traceID: traceID, taskID: taskID, context: context)
        return await continueHandlingNonVisualizationCommand(
            command: command,
            context: context,
            traceID: traceID,
            taskID: taskID
        )
    }

    private func continueHandlingNonVisualizationCommand(
        command: String,
        context: UserQueryCommandContext?,
        traceID: String,
        taskID: String
    ) async -> UserQueryCommandHandlingResult {
        let harnessRequest = Self.harnessRequest(command: command, context: context)
        let genericPreparedTurn = await genericHarnessLifecycle.prepareUserQueryTurn(
            request: harnessRequest,
            pointerTask: context?.task,
            traceID: traceID,
            availableToolNames: Self.genericHarnessToolNames(),
            grantedPermissions: Self.userQueryGrantedPermissions
        )

        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let decision = AppHarnessDecision(
                kind: .noOp,
                traceID: traceID,
                metadata: [
                    "structuredDecision": "true",
                    "router": "emptyTurn"
                ]
            )
            let result = UserQueryCommandHandlingResult(
                status: .completed,
                threadStatus: .chatting,
                decision: decision,
                summary: "",
                traceID: traceID,
                metadata: [
                    "appHarness.decision": decision.kind.rawValue,
                    "appHarness.decision.traceID": traceID,
                    "appHarness.router": "emptyTurn"
                ].merging(Self.genericHarnessMetadata(preparedTurn: genericPreparedTurn)) { current, _ in current }
            )
            _ = await genericHarnessLifecycle.coordinator.complete(
                taskID: genericPreparedTurn.task.id,
                reason: "User query empty turn"
            )
            logHandlingResult(result, stage: "empty", hint: "Empty command; no action was run.")
            return result
        }

        let coordinator = await coordinatorRegistry.coordinator(for: taskID)

        // Vision-navigation route (env-gated by `DONKEY_VISION_NAV`): ground the typed query
        // directly into on-screen actions against the frontmost app, skipping intent parsing and
        // the AppleScript pipeline. Configurable so we can revert to the standard route below.
        if visionNavigationMode.isEnabled {
            return await handleVisionNavigation(
                command: command,
                traceID: traceID,
                taskID: taskID,
                preparedTurnMetadata: Self.genericHarnessMetadata(preparedTurn: genericPreparedTurn)
            )
        }

        let modelInput = Self.modelInput(
            for: command,
            context: context,
            compactedContext: genericPreparedTurn.compactedContext
        )
        let commandRedaction = redactor.redact(modelInput.command, surface: .modelContext)
        let contextRedactions = modelInput.contextSnippets.map {
            redactor.redact($0, surface: .modelContext)
        }
        let redactedContextSnippets = contextRedactions.map(\.redactedText)
        let redactionCount = commandRedaction.redactionCount
            + contextRedactions.reduce(0) { $0 + $1.redactionCount }
        let memoryProposalDecisions = (try? ProviderDecodedMemoryProposalHandler.decisions(
            from: Data("[]".utf8),
            decidedAt: Self.now()
        )) ?? []
        let parseStartedAt = Self.uptimeMilliseconds()
        let taskIntentResult = await resolveTaskIntent(
            command: commandRedaction.redactedText,
            contextSnippets: redactedContextSnippets,
            availableToolNames: Self.genericHarnessToolNames(),
            sourceTraceID: traceID
        )
        let resolution = taskIntentResult.resolution
        let parseLatencyMS = Self.uptimeMilliseconds() - parseStartedAt
        logModelResolution(
            command: commandRedaction.redactedText,
            traceID: traceID,
            resolution: resolution,
            trace: taskIntentResult.trace,
            latencyMS: parseLatencyMS
        )
        let semanticMemoryResults = await retrieveSemanticMemory(
            command: commandRedaction.redactedText,
            resolution: resolution
        )
        let modelObservability = AIModelObservabilityReportBuilder.build(from: [taskIntentResult.trace])
        let modelMetadata = [
            "appHarness.router": "genericHarnessPlanner",
            "appHarness.context.promptCharacters": String(genericPreparedTurn.compactedContext.promptText.count),
            "appHarness.context.redactionCount": String(redactionCount),
            "intentParser": "hostedHarnessPlanner",
            "latency.commandParseMS": Self.formatLatency(parseLatencyMS),
            "modelCallID": taskIntentResult.trace.id,
            "modelCallStatus": taskIntentResult.trace.status.rawValue,
            "modelValidationStatus": taskIntentResult.trace.validationStatus,
            "modelObservability.callCount": String(modelObservability.callCount),
            "modelObservability.acceptedCount": String(modelObservability.acceptedCount),
            "modelObservability.recoverySuccessCount": String(modelObservability.recoverySuccessCount),
            "redaction.modelContext.count": String(redactionCount),
            "semanticMemory.resultCount": String(semanticMemoryResults.count),
            "semanticMemory.recordIDs": semanticMemoryResults.map(\.record.id).joined(separator: ","),
            "semanticMemory.targetID": semanticMemoryTargetID(for: resolution) ?? "",
            "memoryProposal.decisionCount": String(memoryProposalDecisions.count)
        ]
        .merging(Self.contextMetadata(context)) { current, _ in current }
        .merging(Self.genericHarnessMetadata(preparedTurn: genericPreparedTurn)) { current, _ in current }

        await coordinator.recordToolEvent(
            capability: .model,
            decision: .allow,
            toolName: "generic-harness-planner",
            summary: "Planned user query turn",
            traceID: traceID,
            metadata: [
                "modelCallID": taskIntentResult.trace.id,
                "modelCallStatus": taskIntentResult.trace.status.rawValue,
                "modelValidationStatus": taskIntentResult.trace.validationStatus
            ]
        )

        if taskIntentResult.trace.metadata["genericHarness.intent.route"] == "guidance" {
            return await handleGuidance(
                trace: taskIntentResult.trace, traceID: traceID, taskID: taskID,
                modelMetadata: modelMetadata
            )
        }

        if Self.shouldFailSafelyWithoutLocalTask(resolution) {
            return await handleFailSafe(
                resolution: resolution, traceID: traceID, taskID: taskID,
                modelMetadata: modelMetadata
            )
        }

        if Self.shouldAskClarificationBeforeLocalTask(resolution) {
            return await handleClarification(
                resolution: resolution, traceID: traceID, taskID: taskID,
                modelMetadata: modelMetadata
            )
        }

        if Self.shouldRespondWithoutLocalTask(resolution) {
            return await handleConversation(
                resolution: resolution, traceID: traceID, taskID: taskID,
                modelMetadata: modelMetadata
            )
        }

        // Execution-strategy router: for a non-scriptable target app (Electron, no dictionary), the
        // AppleScript/skill path can't act — drive it by vision instead. Scriptable/unknown apps fall
        // through to the AppleScript-first generic harness loop below.
        if let visionResult = await handleVisionActionIfNonScriptable(
            resolution: resolution,
            trace: taskIntentResult.trace,
            command: commandRedaction.redactedText,
            traceID: traceID,
            taskID: taskID,
            modelMetadata: modelMetadata
        ) {
            return visionResult
        }

        let decision = AppHarnessDecision(
            kind: .runLocalTask,
            taskIntentID: resolution.intent?.intentID,
            traceID: traceID,
            metadata: [
                "structuredDecision": "true",
                "router": "modelLocalAppTask",
                "resolution.status": resolution.status.rawValue
            ]
        )
        _ = await genericHarnessLifecycle.planLocalTaskRun(
            taskID: taskID,
            resolution: resolution,
            fallbackGoal: commandRedaction.redactedText,
            traceID: traceID,
            availableToolNames: Self.genericHarnessToolNames()
        )
        var harnessServices = LocalAppUserQueryHarnessServices.builtInSkillBackedServices()
        let appleScriptGenerationAdapter = HostedAppleScriptGenerationAdapter()
        harnessServices.appleScriptGenerator = { request in
            await appleScriptGenerationAdapter.generateAppleScript(request)
        }
        let registry = BuiltInHarnessToolCatalog.registryWithBuiltInExecutors(
            services: harnessServices
        )
        let localStepExecutor = LocalAppHarnessStepExecutor(
            command: commandRedaction.redactedText,
            traceID: traceID,
            resolution: resolution,
            metadata: modelMetadata.merging([
                "appHarness.decision": AppHarnessDecisionKind.runLocalTask.rawValue,
                "genericHarness.taskID": taskID
            ]) { current, _ in current },
            appController: appController,
            actionEngineFactory: actionEngineFactory,
            permissionPolicy: permissionPolicy,
            coordinator: coordinator
        )
        await localStepExecutor.registerTools(in: registry)
        let genericRuntime = GenericHarnessRuntime(
            coordinator: genericHarnessLifecycle.coordinator,
            registry: registry
        )
        let runSteps = await executeGenericHarnessLoop(
            taskID: taskID,
            runtime: genericRuntime
        )
        Self.recordAppleScriptScriptability(resolution: resolution, runSteps: runSteps)
        let runStep = runSteps.last
        let verificationStep = runSteps.last { step in
            step.toolResult?.toolName == LocalAppActionPlanTool.verifyCommand.rawValue
                || step.toolResult?.toolName == LocalAppActionPlanTool.verifyVisibleText.rawValue
        }
        let result = Self.integratingGenericToolOutcome(
            into: await localStepExecutor.currentResult(),
            runSteps: runSteps
        )
        let finalized = await finalizeGenericHarnessTask(
            taskID: taskID,
            result: result,
            runStep: runStep,
            verificationStep: verificationStep,
            runtime: genericRuntime
        )
        let finalizedTask = await genericHarnessLifecycle.taskState(taskID: taskID)
        logActionTraces(for: result)

        let agentVisualizationPlan = Self.agentVisualizationPlan(from: runSteps)
            ?? LocalAppTaskAgentVisualizationBuilder.plan(
                for: result,
                sourceTraceID: traceID
            ).map(groundAgentVisualizationPlan)
        let localTaskMetadata = Self.genericHarnessTaskMetadata(finalizedTask ?? runStep?.task)
            .merging(result.metadata) { current, _ in current }
            .merging([
                "appHarness.decision": AppHarnessDecisionKind.runLocalTask.rawValue,
                "appHarness.router": "modelLocalAppTask"
            ]) { current, _ in current }
            .merging(Self.genericHarnessMetadata(
                preparedTurn: genericPreparedTurn,
                runStep: runStep,
                verificationStep: finalized.verificationStep,
                recoveryStep: finalized.recoveryStep
            )) { current, _ in current }
        let handlingResult = UserQueryCommandHandlingResult(
            status: result.status,
            threadStatus: Self.userQueryStatus(for: finalizedTask)
                ?? threadStatus(for: result, runStep: runStep),
            decision: decision,
            summary: summary(for: result, task: finalizedTask, runStep: runStep),
            traceID: traceID,
            metadata: localTaskMetadata,
            taskLabel: taskLabel(for: result),
            documentReviewRequest: documentReviewRequest(
                traceID: traceID,
                result: result
            ),
            agentVisualizationPlan: agentVisualizationPlan,
            cursorOverlayRequest: agentVisualizationPlan?.cursorOverlayRequest()
        )
        await coordinatorRegistry.finish(taskID: taskID)
        logHandlingResult(
            handlingResult,
            stage: "localTask",
            hint: runHint(for: result)
        )
        return handlingResult
    }

    func pauseCommand(taskID: String) async -> Bool {
        await genericHarnessLifecycle.pauseTask(
            taskID: taskID,
            reason: "User query paused task"
        ) != nil
    }

    func resumeCommand(taskID: String) async -> Bool {
        await genericHarnessLifecycle.resumeTask(
            taskID: taskID,
            reason: "User query resumed task"
        ) != nil
    }

    func approvePermissionGate(taskID: String) async -> Bool {
        await genericHarnessLifecycle.approvePermissionGate(
            taskID: taskID,
            reason: "User query approved pending permissions"
        ) != nil
    }

    // MARK: - Non-Local-Task Routing

    private func handleFailSafe(
        resolution: LocalAppTaskCatalogResolution,
        traceID: String,
        taskID: String,
        modelMetadata: [String: String]
    ) async -> UserQueryCommandHandlingResult {
        let response = Self.modelUnavailableResponse(for: resolution)
        let decision = AppHarnessDecision(
            kind: .respond,
            message: response,
            traceID: traceID,
            metadata: [
                "structuredDecision": "true",
                "router": "modelUnavailable",
                "resolution.status": resolution.status.rawValue
            ]
        )
        let result = UserQueryCommandHandlingResult(
            status: .failedSafe,
            threadStatus: .failed,
            decision: decision,
            summary: response,
            traceID: traceID,
            metadata: modelMetadata.merging([
                "appHarness.decision": AppHarnessDecisionKind.respond.rawValue,
                "router": "modelUnavailable",
                "resolution.status": resolution.status.rawValue,
                "resolution.reason": resolution.metadata["reason"] ?? ""
            ]) { _, new in new }
        )
        _ = await genericHarnessLifecycle.coordinator.failSafe(
            taskID: taskID,
            reason: "Hosted command parser did not produce a safe action plan"
        )
        await coordinatorRegistry.finish(taskID: taskID)
        logHandlingResult(
            result,
            stage: "modelUnavailable",
            hint: "The hosted planner failed before producing executable intent; no local task was run."
        )
        return result
    }

    private func handleClarification(
        resolution: LocalAppTaskCatalogResolution,
        traceID: String,
        taskID: String,
        modelMetadata: [String: String]
    ) async -> UserQueryCommandHandlingResult {
        let question = Self.clarificationQuestion(for: resolution)
        let decision = AppHarnessDecision(
            kind: .askClarification,
            message: question,
            missingDetail: resolution.metadata["reason"],
            traceID: traceID,
            metadata: [
                "structuredDecision": "true",
                "router": "modelClarification",
                "resolution.status": resolution.status.rawValue
            ]
        )
        let result = UserQueryCommandHandlingResult(
            status: .needsConfirmation,
            threadStatus: .waitingForClarification,
            decision: decision,
            summary: question,
            traceID: traceID,
            metadata: modelMetadata.merging([
                "appHarness.decision": AppHarnessDecisionKind.askClarification.rawValue,
                "router": "modelClarification",
                "resolution.status": resolution.status.rawValue,
                "resolution.reason": resolution.metadata["reason"] ?? ""
            ]) { _, new in new }
        )
        _ = await genericHarnessLifecycle.coordinator.waitForUser(
            taskID: taskID,
            question: question,
            reason: "Generic harness planner requested clarification"
        )
        await coordinatorRegistry.finish(taskID: taskID)
        logHandlingResult(
            result,
            stage: "clarification",
            hint: "The harness planner asked for a missing detail before selecting an action tool."
        )
        return result
    }

    private func handleConversation(
        resolution: LocalAppTaskCatalogResolution,
        traceID: String,
        taskID: String,
        modelMetadata: [String: String]
    ) async -> UserQueryCommandHandlingResult {
        let response = Self.conversationResponse(for: resolution)
        let decision = AppHarnessDecision(
            kind: .respond,
            message: response,
            traceID: traceID,
            metadata: [
                "structuredDecision": "true",
                "router": "modelConversation",
                "resolution.status": resolution.status.rawValue
            ]
        )
        let result = UserQueryCommandHandlingResult(
            status: .completed,
            threadStatus: .chatting,
            decision: decision,
            summary: response,
            traceID: traceID,
            metadata: modelMetadata.merging([
                "appHarness.decision": AppHarnessDecisionKind.respond.rawValue,
                "router": "modelConversation",
                "resolution.status": resolution.status.rawValue,
                "resolution.reason": resolution.metadata["reason"] ?? ""
            ]) { _, new in new }
        )
        _ = await genericHarnessLifecycle.coordinator.complete(
            taskID: taskID,
            reason: "User query conversation response"
        )
        await coordinatorRegistry.finish(taskID: taskID)
        logHandlingResult(
            result,
            stage: "conversation",
            hint: "No local task intent was produced; responded in the thread."
        )
        return result
    }

    /// Guidance route: show the user where something is by grounding the requested controls in the
    /// target app's accessibility tree and presenting a cursor overlay. Visualization only — no
    /// input, no app state change. Works for any app with an accessibility tree (native or Electron).
    private func handleGuidance(
        trace: AIModelCallTrace,
        traceID: String,
        taskID: String,
        modelMetadata: [String: String]
    ) async -> UserQueryCommandHandlingResult {
        let appName = trace.metadata["genericHarness.intent.targetApp"].flatMap { $0.isEmpty ? nil : $0 }
        let targets = Self.guidanceTargets(from: trace.metadata["guidanceTargets"] ?? "")
        let title = trace.metadata["genericHarness.intent.goal"].flatMap { $0.isEmpty ? nil : $0 } ?? "Here you go"
        let outcome = await MainActor.run {
            GuidanceOverlayFlow.cursorGuide(
                appName: appName,
                bundleIdentifier: nil,
                targets: targets,
                title: title,
                traceID: traceID
            )
        }
        let located = outcome.request != nil
        // Prefer the model's own narration; fall back only when it didn't provide one (or when we
        // couldn't actually ground the control at runtime, which the planner can't know up front).
        let modelResponse = trace.metadata["assistantResponse"].flatMap { $0.isEmpty ? nil : $0 }
        let response = located
            ? (modelResponse ?? "Here it is — follow the pointer.")
            : "I couldn't locate that on screen right now."
        let decision = AppHarnessDecision(
            kind: .respond,
            message: response,
            traceID: traceID,
            metadata: [
                "structuredDecision": "true",
                "router": "modelGuidance",
                "guidance.reason": outcome.reason
            ]
        )
        let result = UserQueryCommandHandlingResult(
            status: .completed,
            threadStatus: .chatting,
            decision: decision,
            summary: response,
            traceID: traceID,
            metadata: modelMetadata.merging([
                "appHarness.decision": AppHarnessDecisionKind.respond.rawValue,
                "router": "modelGuidance",
                "guidance.reason": outcome.reason,
                "guidance.targetCount": String(targets.count),
                "guidance.resolvedApp": outcome.resolvedAppName ?? ""
            ]) { _, new in new },
            cursorOverlayRequest: outcome.request
        )
        _ = await genericHarnessLifecycle.coordinator.complete(
            taskID: taskID,
            reason: "User query guidance overlay"
        )
        await coordinatorRegistry.finish(taskID: taskID)
        logHandlingResult(
            result,
            stage: "guidance",
            hint: located ? "Guided with a pointer overlay." : "No grounded control to point at."
        )
        return result
    }

    /// Parses planner `guidanceTargets` into ordered path targets. The planner emits a JSON array of
    /// `{label, query}` objects — robust to labels/queries that contain punctuation (`:`, `;`, …),
    /// which a delimiter-based format would mis-split. A legacy `"Label::query; …"` string is still
    /// accepted as a fallback for older planner output.
    private static func guidanceTargets(from raw: String) -> [AccessibilityCursorPathTarget] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([GuidanceTargetWire].self, from: data) {
            return decoded.compactMap(\.pathTarget)
        }

        return trimmed.components(separatedBy: ";").compactMap { entry in
            let parts = entry.components(separatedBy: "::")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let query = (parts.count > 1 ? parts[1] : parts.first ?? "")
            guard !query.isEmpty else { return nil }
            let label = (parts.count > 1 && !parts[0].isEmpty) ? parts[0] : query
            return AccessibilityCursorPathTarget(query: query, label: label, kind: .targetControl)
        }
    }

    private struct GuidanceTargetWire: Decodable {
        var label: String?
        var query: String

        var pathTarget: AccessibilityCursorPathTarget? {
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedQuery.isEmpty else { return nil }
            let trimmedLabel = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return AccessibilityCursorPathTarget(
                query: trimmedQuery,
                label: trimmedLabel.isEmpty ? trimmedQuery : trimmedLabel,
                kind: .targetControl
            )
        }
    }

    // MARK: - Vision Action Route (non-scriptable apps)

    /// If the resolved target app genuinely can't be driven by AppleScript/keystrokes — an Electron app,
    /// or one this machine has LEARNED fails AppleScript — drive it by vision via the shared
    /// `VisionActionDriver`. Returns nil (use the normal AppleScript/keystroke path) when the app is
    /// scriptable, when it merely lacks a dictionary (System-Events keystrokes still work), when input
    /// isn't permitted, or when the hosted backend can't be reached. Honors the planner's confirm
    /// request: an action flagged `needsConfirmation` asks the user first rather than auto-driving.
    private func handleVisionActionIfNonScriptable(
        resolution: LocalAppTaskCatalogResolution,
        trace: AIModelCallTrace,
        command: String,
        traceID: String,
        taskID: String,
        modelMetadata: [String: String]
    ) async -> UserQueryCommandHandlingResult? {
        guard permissionPolicy.allowedCapabilities.contains(.input) else { return nil }
        guard let intent = resolution.intent else { return nil }
        let appName = intent.targetApp.appName
        guard !appName.isEmpty, appName.lowercased() != "none" else { return nil }
        let bundleIdentifier = intent.targetApp.bundleIdentifier

        let scriptability = AppCapabilityService.shared.scriptability(
            bundleIdentifier: bundleIdentifier,
            appName: appName
        )
        guard ExecutionStrategySelector.strategy(scriptability: scriptability) == .accessibilityUI else {
            return nil
        }
        // Only pre-empt the AppleScript/keystroke path for apps that truly can't use it: Electron
        // (Chromium-rendered, no usable dictionary/keystroke automation) or apps that have actually
        // failed AppleScript here. A native app that merely lacks a scripting dictionary can still be
        // driven by System-Events keystrokes, so leave it on the existing path.
        let isElectron = MacAppScriptabilityProbe().facts(
            bundleIdentifier: bundleIdentifier,
            appName: appName
        ).isElectron
        let learnedFailure = AppCapabilityService.shared.hasLearnedAppleScriptFailure(bundleIdentifier: bundleIdentifier)
        guard isElectron || learnedFailure else { return nil }

        guard let configuration = try? DonkeyBackendInferenceConfiguration.fromEnvironment() else {
            return nil
        }

        // Never auto-drive the real pointer/keyboard for an action the planner asked to confirm; ask.
        if intent.needsConfirmation {
            return await confirmVisionAction(
                appName: appName,
                trace: trace,
                traceID: traceID,
                taskID: taskID,
                modelMetadata: modelMetadata
            )
        }

        let backend = DonkeyBackendInferenceClient(configuration: configuration)
        let goal = trace.metadata["genericHarness.intent.goal"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? command
        let appGuidance = BuiltInLocalAppSkillPacks.appOperatingGuidance(
            forApp: appName,
            bundleIdentifier: bundleIdentifier
        )

        let outcome = await VisionActionDriver.drive(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            goal: goal,
            appGuidance: appGuidance,
            backend: backend
        )

        let response = outcome.completed
            ? (outcome.lastNarration ?? "Done.")
            : "I tried operating \(appName) but couldn't confirm the goal was finished."
        let decision = AppHarnessDecision(
            kind: .respond,
            message: response,
            traceID: traceID,
            metadata: [
                "structuredDecision": "true",
                "router": "modelVisionAction",
                "visionAction.completed": String(outcome.completed)
            ]
        )
        let result = UserQueryCommandHandlingResult(
            status: outcome.completed ? .completed : .failedSafe,
            threadStatus: outcome.completed ? .completed : .failed,
            decision: decision,
            summary: response,
            traceID: traceID,
            metadata: modelMetadata.merging([
                "appHarness.decision": AppHarnessDecisionKind.respond.rawValue,
                "appHarness.router": "modelVisionAction",
                "visionAction.app": appName,
                "visionAction.completed": String(outcome.completed),
                "visionAction.turns": String(outcome.turns),
                "visionAction.reason": outcome.reason
            ]) { _, new in new }
        )
        if outcome.completed {
            _ = await genericHarnessLifecycle.coordinator.complete(
                taskID: taskID,
                reason: "User query vision action completed"
            )
        } else {
            _ = await genericHarnessLifecycle.coordinator.failSafe(
                taskID: taskID,
                reason: "User query vision action did not confirm completion"
            )
        }
        await coordinatorRegistry.finish(taskID: taskID)
        logHandlingResult(
            result,
            stage: "visionAction",
            hint: outcome.completed ? "Drove \(appName) by vision." : "Vision action stopped: \(outcome.reason)."
        )
        return result
    }

    /// Asks the user before driving an app by vision, when the planner flagged the action for
    /// confirmation. Mirrors the clarification route — no input is performed.
    private func confirmVisionAction(
        appName: String,
        trace: AIModelCallTrace,
        traceID: String,
        taskID: String,
        modelMetadata: [String: String]
    ) async -> UserQueryCommandHandlingResult {
        let goal = trace.metadata["genericHarness.intent.goal"].flatMap { $0.isEmpty ? nil : $0 }
        let question = goal.map { "I can do that in \(appName) by controlling it directly (\($0)). Want me to go ahead?" }
            ?? "I can do that in \(appName) by controlling it directly. Want me to go ahead?"
        let decision = AppHarnessDecision(
            kind: .askClarification,
            message: question,
            traceID: traceID,
            metadata: [
                "structuredDecision": "true",
                "router": "modelVisionActionConfirm"
            ]
        )
        let result = UserQueryCommandHandlingResult(
            status: .needsConfirmation,
            threadStatus: .waitingForClarification,
            decision: decision,
            summary: question,
            traceID: traceID,
            metadata: modelMetadata.merging([
                "appHarness.decision": AppHarnessDecisionKind.askClarification.rawValue,
                "appHarness.router": "modelVisionActionConfirm",
                "visionAction.app": appName
            ]) { _, new in new }
        )
        _ = await genericHarnessLifecycle.coordinator.waitForUser(
            taskID: taskID,
            question: question,
            reason: "Vision action requires confirmation before driving the app"
        )
        await coordinatorRegistry.finish(taskID: taskID)
        logHandlingResult(
            result,
            stage: "visionActionConfirm",
            hint: "Asked before driving \(appName) by vision."
        )
        return result
    }

    // MARK: - Vision Navigation Route (frontmost app, env-gated)

    /// Drives the FRONTMOST user app by vision to satisfy the typed query, end to end: resolve the
    /// frontmost window, ground the query into a screenshot→action loop with `VisionActionDriver`,
    /// and console-log the grounding latency (time-to-first-action and total) for telemetry.
    ///
    /// `@MainActor` because window resolution, the driver, and the per-turn timing closure all run on
    /// the main actor — keeping it isolated lets the timing accumulators stay plain locals.
    @MainActor
    private func handleVisionNavigation(
        command: String,
        traceID: String,
        taskID: String,
        preparedTurnMetadata: [String: String]
    ) async -> UserQueryCommandHandlingResult {
        guard permissionPolicy.allowedCapabilities.contains(.input) else {
            return await failVisionNavigation(
                response: "Vision navigation needs input permission, which isn't granted.",
                reason: "inputNotPermitted",
                appName: "",
                traceID: traceID,
                taskID: taskID,
                preparedTurnMetadata: preparedTurnMetadata
            )
        }
        guard let target = Self.frontmostUserAppTarget() else {
            return await failVisionNavigation(
                response: "I couldn't find a frontmost app window to navigate. Focus the app you want, then type your request.",
                reason: "noFrontmostApp",
                appName: "",
                traceID: traceID,
                taskID: taskID,
                preparedTurnMetadata: preparedTurnMetadata
            )
        }
        let appName = target.appName ?? "the frontmost app"
        let bundleIdentifier = target.bundleIdentifier

        guard let configuration = try? DonkeyBackendInferenceConfiguration.fromEnvironment() else {
            return await failVisionNavigation(
                response: "The vision backend isn't configured (set DONKEY_WEB_BASE_URL), so I couldn't navigate by vision.",
                reason: "visionBackendUnavailable",
                appName: appName,
                traceID: traceID,
                taskID: taskID,
                preparedTurnMetadata: preparedTurnMetadata
            )
        }
        let backend = DonkeyBackendInferenceClient(configuration: configuration)
        let appGuidance = BuiltInLocalAppSkillPacks.appOperatingGuidance(
            forApp: appName,
            bundleIdentifier: bundleIdentifier
        )

        VisionGroundingLog.emit(
            "start traceID=\(traceID) app=\(appName) goal=\"\(command)\""
        )
        let e2eStartMS = Self.uptimeMilliseconds()
        var timeToFirstActionMS: Double?
        let outcome = await VisionActionDriver.drive(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            goal: command,
            appGuidance: appGuidance,
            backend: backend,
            onTurn: { info in
                // Time-to-first-grounded-action: from query submit to the first on-screen action the
                // model grounded from the screenshot + query. This is the headline grounding number.
                guard timeToFirstActionMS == nil else { return }
                let elapsed = Self.uptimeMilliseconds() - e2eStartMS
                timeToFirstActionMS = elapsed
                VisionGroundingLog.emit(
                    "time-to-first-action traceID=\(traceID) app=\(appName) ms=\(Self.formatLatency(elapsed)) action=\(info.action.action)"
                )
            }
        )
        let e2eTotalMS = Self.uptimeMilliseconds() - e2eStartMS
        let averagePerTurnMS = outcome.turns > 0 ? e2eTotalMS / Double(outcome.turns) : 0
        VisionGroundingLog.emit(
            "complete traceID=\(traceID) app=\(appName) completed=\(outcome.completed) reason=\(outcome.reason) turns=\(outcome.turns) e2eTotalMS=\(Self.formatLatency(e2eTotalMS)) timeToFirstActionMS=\(Self.formatLatency(timeToFirstActionMS ?? 0)) avgPerTurnMS=\(Self.formatLatency(averagePerTurnMS))"
        )

        let response = outcome.completed
            ? (outcome.lastNarration ?? "Done.")
            : "I tried navigating \(appName) by vision but couldn't confirm the goal was finished."
        let decision = AppHarnessDecision(
            kind: .respond,
            message: response,
            traceID: traceID,
            metadata: [
                "structuredDecision": "true",
                "router": "visionNavigation",
                "visionNavigation.completed": String(outcome.completed)
            ]
        )
        let result = UserQueryCommandHandlingResult(
            status: outcome.completed ? .completed : .failedSafe,
            threadStatus: outcome.completed ? .completed : .failed,
            decision: decision,
            summary: response,
            traceID: traceID,
            metadata: preparedTurnMetadata.merging([
                "appHarness.decision": AppHarnessDecisionKind.respond.rawValue,
                "appHarness.router": "visionNavigation",
                "visionNavigation.app": appName,
                "visionNavigation.completed": String(outcome.completed),
                "visionNavigation.turns": String(outcome.turns),
                "visionNavigation.reason": outcome.reason,
                "grounding.e2eTotalMS": Self.formatLatency(e2eTotalMS),
                "grounding.timeToFirstActionMS": Self.formatLatency(timeToFirstActionMS ?? 0),
                "grounding.avgPerTurnMS": Self.formatLatency(averagePerTurnMS)
            ]) { _, new in new }
        )
        if outcome.completed {
            _ = await genericHarnessLifecycle.coordinator.complete(
                taskID: taskID,
                reason: "User query vision navigation completed"
            )
        } else {
            _ = await genericHarnessLifecycle.coordinator.failSafe(
                taskID: taskID,
                reason: "User query vision navigation did not confirm completion"
            )
        }
        await coordinatorRegistry.finish(taskID: taskID)
        logHandlingResult(
            result,
            stage: "visionNavigation",
            hint: outcome.completed ? "Navigated \(appName) by vision." : "Vision navigation stopped: \(outcome.reason)."
        )
        return result
    }

    /// Fail-safe exit for the vision-navigation route when it can't even start (no frontmost app,
    /// backend unconfigured, input not permitted). Mirrors the other non-local routes' lifecycle.
    private func failVisionNavigation(
        response: String,
        reason: String,
        appName: String,
        traceID: String,
        taskID: String,
        preparedTurnMetadata: [String: String]
    ) async -> UserQueryCommandHandlingResult {
        VisionGroundingLog.emit("aborted traceID=\(traceID) reason=\(reason) app=\(appName)")
        let decision = AppHarnessDecision(
            kind: .respond,
            message: response,
            traceID: traceID,
            metadata: [
                "structuredDecision": "true",
                "router": "visionNavigation",
                "visionNavigation.abortReason": reason
            ]
        )
        let result = UserQueryCommandHandlingResult(
            status: .failedSafe,
            threadStatus: .failed,
            decision: decision,
            summary: response,
            traceID: traceID,
            metadata: preparedTurnMetadata.merging([
                "appHarness.decision": AppHarnessDecisionKind.respond.rawValue,
                "appHarness.router": "visionNavigation",
                "visionNavigation.abortReason": reason
            ]) { _, new in new }
        )
        _ = await genericHarnessLifecycle.coordinator.failSafe(
            taskID: taskID,
            reason: "User query vision navigation could not start: \(reason)"
        )
        await coordinatorRegistry.finish(taskID: taskID)
        logHandlingResult(result, stage: "visionNavigation", hint: response)
        return result
    }

    /// Resolves the user's frontmost real window for vision navigation. Donkey's own overlay panels
    /// float above layer 0 and are already excluded by the window enumerator, but we also skip our
    /// own process so we never drive Donkey's UI. Candidates come back in front-to-back z-order, so
    /// the first match is the app the user was last working in.
    @MainActor
    private static func frontmostUserAppTarget() -> MacWindowTargetCandidate? {
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        let ownBundleID = Bundle.main.bundleIdentifier
        return MacWindowResolver().enumerateCandidates().first { candidate in
            if candidate.processID == ownProcessID { return false }
            if let ownBundleID, let candidateBundle = candidate.bundleIdentifier,
               candidateBundle.caseInsensitiveCompare(ownBundleID) == .orderedSame {
                return false
            }
            return true
        }
    }

    /// Records whether the AppleScript path actually worked for the target app, so the strategy router
    /// learns per machine: repeated failures flip an app to the accessibility/vision path, a success
    /// keeps it on AppleScript. Best-effort — only fires when the run executed an AppleScript action
    /// and we know the app's bundle identifier.
    private static func recordAppleScriptScriptability(
        resolution: LocalAppTaskCatalogResolution,
        runSteps: [HarnessStepExecutionResult]
    ) {
        guard let bundleIdentifier = (resolution.definition?.targetApp.bundleIdentifier
            ?? resolution.intent?.targetApp.bundleIdentifier),
            !bundleIdentifier.isEmpty
        else {
            return
        }
        let appName = resolution.definition?.targetApp.appName ?? resolution.intent?.targetApp.appName

        var sawAppleScript = false
        var anySucceeded = false
        for step in runSteps {
            guard let toolResult = step.toolResult else { continue }
            let isAppleScript = toolResult.metadata["liveInputBackend"] == "mac-apple-script"
                || toolResult.metadata["appleScript.output"] != nil
                || toolResult.toolName == "automation.applescript.execute"
            guard isAppleScript else { continue }
            sawAppleScript = true
            if toolResult.status == .succeeded { anySucceeded = true }
        }
        guard sawAppleScript else { return }
        AppCapabilityService.shared.recordAppleScriptOutcome(
            bundleIdentifier: bundleIdentifier,
            appName: appName,
            succeeded: anySucceeded
        )
    }

    // MARK: - Generic Harness Task Execution

    private func finalizeGenericHarnessTask(
        taskID: String,
        result: LocalAppTaskLiveRunResult,
        runStep: HarnessStepExecutionResult?,
        verificationStep: HarnessStepExecutionResult?,
        runtime: GenericHarnessRuntime
    ) async -> UserQueryGenericFinalizeResult {
        switch result.status {
        case .completed:
            if verificationStep?.toolResult?.status == .failed {
                let recoveryStep = await recoverGenericHarnessTask(
                    taskID: taskID,
                    reason: verificationStep?.toolResult?.summary ?? "Verification failed",
                    traceID: result.traceID,
                    runtime: runtime
                )
                _ = await genericHarnessLifecycle.coordinator.failSafe(
                    taskID: taskID,
                    reason: "User query verification failed"
                )
                return UserQueryGenericFinalizeResult(
                    verificationStep: verificationStep,
                    recoveryStep: recoveryStep
                )
            }

            _ = await genericHarnessLifecycle.coordinator.complete(
                taskID: taskID,
                reason: "User query local task completed"
            )
            return UserQueryGenericFinalizeResult(verificationStep: verificationStep)
        case .needsUserReview:
            _ = await genericHarnessLifecycle.coordinator.waitForUser(
                taskID: taskID,
                question: "Review the local app result before I continue.",
                reason: "User query local app verification needs review"
            )
            return UserQueryGenericFinalizeResult(verificationStep: verificationStep)
        case .needsConfirmation, .unsupportedCommand:
            _ = await genericHarnessLifecycle.coordinator.waitForUser(
                taskID: taskID,
                question: summary(for: result, task: runStep?.task, runStep: runStep),
                reason: "User query local app task needs clarification"
            )
            return UserQueryGenericFinalizeResult()
        case .appUnavailable, .failedSafe:
            let recoveryStep = await recoverGenericHarnessTask(
                taskID: taskID,
                reason: summary(for: result, task: runStep?.task, runStep: runStep),
                traceID: result.traceID,
                runtime: runtime
            )
            _ = await genericHarnessLifecycle.coordinator.failSafe(
                taskID: taskID,
                reason: summary(for: result, task: runStep?.task, runStep: runStep)
            )
            return UserQueryGenericFinalizeResult(
                recoveryStep: recoveryStep
            )
        }
    }

    private func recoverGenericHarnessTask(
        taskID: String,
        reason: String,
        traceID: String,
        runtime: GenericHarnessRuntime
    ) async -> HarnessStepExecutionResult? {
        _ = await genericHarnessLifecycle.planRecovery(
            taskID: taskID,
            reason: reason,
            traceID: traceID
        )
        return await runtime.executeNextPlannedStep(taskID: taskID)
    }

    private func executeGenericHarnessLoop(
        taskID: String,
        runtime: GenericHarnessRuntime,
        maxSteps: Int = 16
    ) async -> [HarnessStepExecutionResult] {
        var results: [HarnessStepExecutionResult] = []
        for _ in 0..<maxSteps {
            guard let result = await runtime.executeNextPlannedStep(taskID: taskID) else {
                break
            }
            results.append(result)
            if result.stoppedForGate || Self.shouldStopHarnessLoop(after: result.toolResult) {
                break
            }
        }
        return results
    }

    private static func shouldStopHarnessLoop(after result: HarnessToolResult?) -> Bool {
        switch result?.status {
        case .failed, .unknownTool, .invalidInput, .permissionDenied, .waitingForUser, .waitingForPermission:
            return true
        case .succeeded, nil:
            return false
        }
    }

    private static func integratingGenericToolOutcome(
        into result: LocalAppTaskLiveRunResult,
        runSteps: [HarnessStepExecutionResult]
    ) -> LocalAppTaskLiveRunResult {
        guard result.actionTraces.isEmpty,
              result.status == .failedSafe
        else {
            return result
        }

        let toolResults = runSteps.compactMap(\.toolResult)
        guard let toolResult = toolResults.last else {
            return result
        }
        let completedGenericAction = toolResults.last { result in
            result.status == .succeeded
                && (
                    result.toolName == "skill.script.execute"
                        || result.toolName == "automation.applescript.execute"
                )
        }

        switch toolResult.status {
        case .succeeded where completedGenericAction != nil:
            var completed = result
            let actionResult = completedGenericAction ?? toolResult
            completed.status = .completed
            completed.metadata = result.metadata
                .merging(actionResult.metadata) { current, _ in current }
                .merging(toolResult.metadata) { current, _ in current }
            completed.metadata["reason"] = "genericToolCompleted"
            completed.metadata["genericTool.completed"] = actionResult.toolName
            return completed
        case .waitingForUser:
            var waiting = result
            waiting.status = .needsConfirmation
            waiting.metadata = result.metadata.merging(toolResult.metadata) { current, _ in current }
            waiting.metadata["reason"] = "genericToolNeedsUser"
            waiting.metadata["genericTool.waiting"] = toolResult.toolName
            return waiting
        default:
            return result
        }
    }

    private static func agentVisualizationPlan(
        from runSteps: [HarnessStepExecutionResult]
    ) -> AgentVisualizationPlan? {
        for step in runSteps.reversed() {
            guard step.toolResult?.toolName == AppHarnessGenericLifecycleToolNames.agentPathVisualize,
                  let text = step.toolResult?.metadata["agentVisualization.planJSON"],
                  let data = text.data(using: .utf8),
                  let plan = try? JSONDecoder().decode(AgentVisualizationPlan.self, from: data)
            else {
                continue
            }
            return plan
        }
        return nil
    }

    private func groundAgentVisualizationPlan(_ plan: AgentVisualizationPlan) -> AgentVisualizationPlan {
        let candidates = MacWindowResolver().enumerateCandidates()
        guard !candidates.isEmpty else { return plan }

        return AgentVisualizationGrounder().ground(
            plan: plan,
            targetAppName: plan.metadata["targetApp"],
            candidates: candidates
        )
    }

    private func logSubmittedCommand(
        _ command: String,
        traceID: String,
        taskID: String,
        context: UserQueryCommandContext?
    ) {
        guard UserQueryLog.isEnabled else { return }

        let source = context?.turnSource.rawValue ?? AppHarnessTurnSource.typedPrompt.rawValue
        let isFollowUp = context?.isFollowUp ?? false
        UserQueryLog.commands.notice(
            "command submitted traceID=\(traceID, privacy: .public) taskID=\(taskID, privacy: .public) source=\(source, privacy: .public) followUp=\(String(isFollowUp), privacy: .public) command=\(command, privacy: .public)"
        )
    }

    private func resolveTaskIntent(
        command: String,
        contextSnippets: [String],
        availableToolNames: [String],
        sourceTraceID: String
    ) async -> (resolution: LocalAppTaskCatalogResolution, trace: AIModelCallTrace) {
        let request = TaskIntentAdapterRequest(
            command: command,
            taskDefinitions: catalog.taskDefinitions,
            contextSnippets: contextSnippets,
            appFinderCatalog: catalog.appFinderCatalogEntries(),
            availableToolNames: availableToolNames,
            sourceTraceID: sourceTraceID
        )
        let result = await taskIntentAdapter.parseTaskIntent(request)

        guard let intent = result.intent else {
            var metadata = [
                "reason": "hostedModelIntentUnavailable",
                "modelCallStatus": result.trace.status.rawValue,
                "modelValidationStatus": result.trace.validationStatus
            ]
            if result.trace.validationStatus == "noTaskIntent" {
                metadata["reason"] = "noSupportedTaskIntent"
                metadata["responseMode"] = "conversation"
                metadata["assistantResponse"] = "I'm here. What would you like to work on?"
            }
            Self.mergeNonEmpty(
                from: result.trace.metadata,
                keys: ["responseMode", "assistantResponse"],
                into: &metadata
            )
            Self.mergeNonEmpty(
                from: result.trace.metadata,
                keys: [
                    "reason", "detail", "error", "backend.provider",
                    "http.status", "http.bodyPreview",
                    "modelOutput.empty", "modelOutput.preview",
                    "fallback.status", "fallback.validation", "fallback.reason",
                    "fallback.http.status", "fallback.http.bodyPreview",
                    "provider", "privacy.store"
                ],
                into: &metadata,
                keyPrefix: "model."
            )
            return (
                LocalAppTaskCatalogResolution(
                    status: .needsConfirmation,
                    metadata: metadata
                ),
                result.trace
            )
        }

        return (catalog.resolve(intent: intent), result.trace)
    }

    private func logModelResolution(
        command: String,
        traceID: String,
        resolution: LocalAppTaskCatalogResolution,
        trace: AIModelCallTrace,
        latencyMS: Double
    ) {
        guard UserQueryLog.isEnabled else { return }

        let taskType = resolution.definition?.taskType ?? resolution.intent?.taskType ?? ""
        let reason = resolution.metadata["reason"] ?? ""
        let modelReason = Self.metadataValue(
            in: resolution.metadata,
            keys: ["model.reason", "model.fallback.reason"]
        )
            ?? Self.metadataValue(
                in: trace.metadata,
                keys: ["reason", "fallback.reason"]
            )
            ?? ""
        let modelDetail = Self.metadataValue(
            in: resolution.metadata,
            keys: [
                "model.detail",
                "model.error",
                "model.http.bodyPreview",
                "model.fallback.http.bodyPreview",
                "model.sidecar.outputPreview"
            ]
        )
            ?? Self.metadataValue(
                in: trace.metadata,
                keys: [
                    "detail",
                    "error",
                    "http.bodyPreview",
                    "fallback.http.bodyPreview",
                    "sidecar.outputPreview"
                ]
            )
            ?? ""
        let fallbackStatus = trace.metadata["fallback.status"] ?? ""
        let latency = Self.formatLatency(latencyMS)
        UserQueryLog.commands.notice(
            "intent resolved traceID=\(traceID, privacy: .public) resolution=\(resolution.status.rawValue, privacy: .public) taskType=\(taskType, privacy: .public) reason=\(reason, privacy: .public) modelStatus=\(trace.status.rawValue, privacy: .public) validation=\(trace.validationStatus, privacy: .public) modelReason=\(modelReason, privacy: .public) modelDetail=\(modelDetail, privacy: .public) fallbackStatus=\(fallbackStatus, privacy: .public) latencyMS=\(latency, privacy: .public) command=\(command, privacy: .public)"
        )
    }

    private func logHandlingResult(
        _ result: UserQueryCommandHandlingResult,
        stage: String,
        hint: String
    ) {
        guard UserQueryLog.isEnabled else { return }

        let taskLabel = result.taskLabel ?? ""
        UserQueryLog.commands.notice(
            "command finished traceID=\(result.traceID, privacy: .public) stage=\(stage, privacy: .public) status=\(result.status.rawValue, privacy: .public) threadStatus=\(result.threadStatus.rawValue, privacy: .public) summary=\(result.summary, privacy: .public) taskLabel=\(taskLabel, privacy: .public) hint=\(hint, privacy: .public)"
        )
    }

    private func logActionTraces(for result: LocalAppTaskLiveRunResult) {
        guard UserQueryLog.isEnabled else { return }

        for trace in result.actionTraces {
            let command = trace.command
            let backend = trace.metadata["liveInputBackend"] ?? "unknown"
            let inputMode = trace.metadata["inputMode"] ?? inputModeDescription(
                backend: backend,
                commandKind: command.kind
            )
            let workflowStepID = command.metadata["workflowStepID"] ?? ""
            let controlID = command.metadata["controlID"] ?? ""
            let target = actionTargetDescription(for: command)
            let elementClick = isElementClick(command)
            let appleScriptAction = trace.metadata["appleScript.action"] ?? command.metadata["appleScript.action"] ?? ""
            let appleScriptOutput = trace.metadata["appleScript.output"] ?? ""
            let accessibilityResult = trace.metadata["accessibility.result"] ?? ""
            let overlayPointer = backend == "mac-apple-script" ? "fallbackOnly" : "visualOnly"

            UserQueryLog.commands.notice(
                "local action traceID=\(result.traceID, privacy: .public) commandID=\(command.id, privacy: .public) workflowStepID=\(workflowStepID, privacy: .public) kind=\(command.kind.rawValue, privacy: .public) backend=\(backend, privacy: .public) inputMode=\(inputMode, privacy: .public) executed=\(String(trace.executed), privacy: .public) decision=\(decisionDescription(trace.decision), privacy: .public) elementClick=\(String(elementClick), privacy: .public) controlID=\(controlID, privacy: .public) target=\(target, privacy: .public) overlayPointer=\(overlayPointer, privacy: .public) appleScriptAction=\(appleScriptAction, privacy: .public) appleScriptOutput=\(appleScriptOutput, privacy: .public) accessibilityResult=\(accessibilityResult, privacy: .public)"
            )
        }
    }

    private static func metadataValue(in metadata: [String: String], keys: [String]) -> String? {
        for key in keys {
            if let value = metadata[key] {
                return value
            }
        }
        return nil
    }

    private static func mergeNonEmpty(
        from source: [String: String],
        keys: [String],
        into target: inout [String: String],
        keyPrefix: String = ""
    ) {
        for key in keys {
            if let value = source[key], !value.isEmpty {
                target["\(keyPrefix)\(key)"] = value
            }
        }
    }

    private func runHint(for result: LocalAppTaskLiveRunResult) -> String {
        if let reason = result.metadata["reason"], !reason.isEmpty {
            if reason == "missingModelPlannedCommand",
               let missingTool = result.metadata["missingTool"],
               !missingTool.isEmpty {
                return "Run reason: \(reason) at \(missingTool)."
            }
            return "Run reason: \(reason)."
        }
        if let automationBackend = result.metadata["automation.backend"],
           !automationBackend.isEmpty {
            let automationAction = result.metadata["automation.action"] ?? ""
            return "Automation \(automationBackend) \(automationAction) finished with status \(result.status.rawValue)."
        }
        if let verificationStatus = result.metadata["verification.status"],
           let verificationSummary = result.metadata["verification.summary"] {
            return "Verification \(verificationStatus): \(verificationSummary)."
        }
        return "Local app workflow finished with status \(result.status.rawValue)."
    }

    private func inputModeDescription(
        backend: String,
        commandKind: ActionEngineCommandKind
    ) -> String {
        if backend.contains("apple-script") { return "appAutomation" }
        if backend.contains("accessibility") { return "accessibilityElement" }
        if backend.contains("keyboard") { return "keyboard" }
        return commandKind.rawValue
    }

    private func actionTargetDescription(for command: ActionEngineCommand) -> String {
        if let controlID = command.metadata["controlID"],
           !controlID.isEmpty {
            return "control:\(controlID)"
        }

        guard let bounds = command.targetBounds else {
            return "none"
        }
        return String(
            format: "bounds:x=%.3f,y=%.3f,w=%.3f,h=%.3f,space=%@",
            bounds.origin.x,
            bounds.origin.y,
            bounds.size.width,
            bounds.size.height,
            bounds.space.rawValue
        )
    }

    private func isElementClick(_ command: ActionEngineCommand) -> Bool {
        (command.kind == .tap || command.kind == .mouse) &&
            (command.targetBounds != nil || command.metadata["controlID"]?.isEmpty == false)
    }

    private func decisionDescription(_ decision: ActionEngineCommandDecision) -> String {
        switch decision {
        case .skippedNoLiveInput:
            return "skippedNoLiveInput"
        case .executedLive:
            return "executedLive"
        case .denied(let reason):
            return "denied:\(reason)"
        }
    }

    private static func shouldRespondWithoutLocalTask(_ resolution: LocalAppTaskCatalogResolution) -> Bool {
        guard resolution.status == .needsConfirmation else { return false }
        if resolution.metadata["responseMode"] == "conversation",
           resolution.metadata["assistantResponse"]?.isEmpty == false {
            return true
        }
        return resolution.metadata["reason"] == "lowConfidenceIntent"
            && resolution.metadata["assistantResponse"]?.isEmpty == false
    }

    private static func shouldFailSafelyWithoutLocalTask(_ resolution: LocalAppTaskCatalogResolution) -> Bool {
        guard resolution.status == .needsConfirmation,
              resolution.intent == nil,
              resolution.metadata["reason"] == "hostedModelIntentUnavailable"
        else {
            return false
        }
        return resolution.metadata["responseMode"] != "conversation"
    }

    private static func shouldAskClarificationBeforeLocalTask(_ resolution: LocalAppTaskCatalogResolution) -> Bool {
        guard resolution.status == .needsConfirmation,
              shouldRespondWithoutLocalTask(resolution) == false
        else {
            return false
        }
        return resolution.intent == nil
            || resolution.intent?.needsConfirmation == true
            || resolution.metadata["responseMode"] == "clarification"
    }

    private static func clarificationQuestion(for resolution: LocalAppTaskCatalogResolution) -> String {
        if let assistantResponse = resolution.metadata["assistantResponse"],
           !assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return assistantResponse
        }
        if let reason = resolution.metadata["reason"],
           !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let readableDetail = reason
                .split(separator: "_")
                .joined(separator: " ")
            return "What \(readableDetail) should I use?"
        }
        return "What detail should I use?"
    }

    private static func conversationResponse(for resolution: LocalAppTaskCatalogResolution) -> String {
        if let assistantResponse = resolution.metadata["assistantResponse"],
           !assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return assistantResponse
        }
        if resolution.metadata["reason"] == "hostedModelIntentUnavailable" {
            let modelStatus = resolution.metadata["modelCallStatus"] ?? ""
            if modelStatus == AIModelCallStatus.missingCredentials.rawValue {
                return "The hosted command parser is not configured yet, so I couldn't safely run that action."
            }
            if modelStatus == AIModelCallStatus.providerOutage.rawValue
                || modelStatus == AIModelCallStatus.timeout.rawValue {
                return "The hosted command parser is not available right now, so I couldn't safely run that action."
            }
        }
        return "I can help, but I need a clearer request before opening an app."
    }

    private static func modelUnavailableResponse(for resolution: LocalAppTaskCatalogResolution) -> String {
        let modelStatus = resolution.metadata["modelCallStatus"] ?? ""
        if modelStatus == AIModelCallStatus.missingCredentials.rawValue {
            return "The hosted command parser is not configured yet, so I couldn't safely run that action."
        }
        if modelStatus == AIModelCallStatus.providerOutage.rawValue
            || modelStatus == AIModelCallStatus.timeout.rawValue
            || modelStatus == AIModelCallStatus.rateLimited.rawValue {
            return "The hosted command parser is not available right now, so I couldn't safely run that action."
        }
        return "The hosted command parser failed before it produced a safe action plan, so I didn't run anything."
    }

    private func retrieveSemanticMemory(
        command: String,
        resolution: LocalAppTaskCatalogResolution
    ) async -> [RunMemorySemanticResult] {
        guard let memoryStore,
              let targetID = semanticMemoryTargetID(for: resolution)
        else {
            return []
        }

        return (try? memoryStore.search(query: AgentMemoryQuery(
                text: command,
                targetID: targetID,
                scope: .target,
                kinds: [.targetFact, .workflowMemory, .userInstruction],
                budget: RunMemoryRetrievalBudget(maxRecords: 3, maxPromptCharacters: 800)
        ))) ?? []
    }

    private func semanticMemoryTargetID(
        for resolution: LocalAppTaskCatalogResolution
    ) -> String? {
        guard let definition = resolution.definition else { return nil }
        return LocalAppTaskAdapter(definition: definition).targetID
    }

    private func documentReviewRequest(
        traceID: String,
        result: LocalAppTaskLiveRunResult
    ) -> DocumentFormFillReviewRequest? {
        guard result.status == .needsUserReview,
              let plan = result.documentFormFillPlan,
              let definition = result.resolution.definition
        else {
            return nil
        }

        return DocumentFormFillReviewRequest(
            plan: plan,
            definition: definition,
            traceID: traceID
        )
    }

    private func statusSummary(for result: LocalAppTaskLiveRunResult) -> String {
        switch result.status {
        case .completed:
            return "Done"
        case .needsUserReview:
            if let proposalCount = result.documentFormFillPlan?.proposals.count,
               proposalCount > 0 {
                return "Review \(proposalCount) fields"
            }
            return "Needs review"
        case .needsConfirmation:
            if let reason = result.resolution.metadata["reason"] {
                guard reason != "hostedModelIntentUnavailable",
                      reason != "needsConfirmation"
                else {
                    return "Need more detail"
                }
                return "Need \(reason)"
            }
            return "Need more detail"
        case .appUnavailable:
            if let appName = result.resolution.metadata["targetApp"] ?? result.resolution.availability?.target.appName {
                return "\(appName) not found"
            }
            return "App not found"
        case .unsupportedCommand:
            return "Need more detail"
        case .failedSafe:
            return "Stopped safely"
        }
    }

    private func summary(
        for result: LocalAppTaskLiveRunResult,
        task: HarnessTaskState?,
        runStep: HarnessStepExecutionResult?
    ) -> String {
        if let task,
           task.status == .waitingForPermission {
            return Self.permissionGateSummary(for: task)
        }

        if let task,
           task.status == .interrupted {
            return Self.interruptionSummary(for: task)
        }

        if let question = task?.pendingContinuation?.question,
           !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return question
        }

        if let task = runStep?.task,
           task.status == .waitingForPermission {
            return Self.permissionGateSummary(for: task)
        }

        if let task = runStep?.task,
           task.status == .interrupted {
            return Self.interruptionSummary(for: task)
        }

        if let question = runStep?.task.pendingContinuation?.question,
           !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return question
        }

        return statusSummary(for: result)
    }

    private func threadStatus(
        for result: LocalAppTaskLiveRunResult,
        runStep: HarnessStepExecutionResult? = nil
    ) -> UserQueryTaskStatus {
        if let status = Self.userQueryStatus(for: runStep?.task) {
            return status
        }

        switch result.status {
        case .completed:
            return .completed
        case .needsUserReview:
            return .waitingForReview
        case .needsConfirmation, .unsupportedCommand:
            return .waitingForClarification
        case .appUnavailable, .failedSafe:
            return .failed
        }
    }

    private func taskLabel(for result: LocalAppTaskLiveRunResult) -> String? {
        guard result.status == .completed || result.status == .needsUserReview,
              let definition = result.resolution.definition
        else {
            return nil
        }

        let entities = result.resolution.intent?.normalizedEntities ?? [:]
        if let template = definition.metadata["taskLabelTemplate"],
           let label = Self.renderTemplate(template, entities: entities),
           !label.isEmpty {
            return label
        }

        return Self.displayTitle(for: definition)
    }

    private static func displayTitle(for definition: LocalAppTaskDefinition) -> String {
        if let displayTitle = definition.metadata["displayTitle"], !displayTitle.isEmpty {
            return displayTitle
                .split(separator: " ")
                .map { word in word.prefix(1).uppercased() + word.dropFirst() }
                .joined(separator: " ")
        }

        return definition.taskType
            .split(separator: "_")
            .map { word in word.prefix(1).uppercased() + word.dropFirst() }
            .joined(separator: " ")
    }

    private static func renderTemplate(
        _ template: String,
        entities: [String: String]
    ) -> String? {
        var rendered = template
        for (name, value) in entities {
            rendered = rendered.replacingOccurrences(of: "{\(name)}", with: value)
        }
        guard !rendered.contains("{") else { return nil }
        return rendered.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func uptimeMilliseconds() -> Double {
        ProcessInfo.processInfo.systemUptime * 1_000
    }

    private static func formatLatency(_ milliseconds: Double) -> String {
        String(format: "%.3f", max(0, milliseconds))
    }

    private static func now() -> RunTraceTimestamp {
        RunTraceTimestamp(
            wallClock: Date(),
            monotonicUptimeNanoseconds: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        )
    }

    private static func modelInput(
        for command: String,
        context: UserQueryCommandContext?,
        compactedContext: HarnessCompactedThreadContext
    ) -> UserQueryModelIntentInput {
        let modelCommand = compactedContext.currentTurn?.text ?? command
        let compactedPrompt = compactedContext.promptText
        guard let context, context.isFollowUp else {
            return UserQueryModelIntentInput(
                command: modelCommand,
                contextSnippets: [compactedPrompt].filter { !$0.isEmpty }
            )
        }

        let taskContext = [
            "Existing task title: \(context.task.title)",
            "Existing task original request: \(context.task.commandText)",
            "Existing task status: \(context.task.status.rawValue)"
        ]
        .compactMap(\.self)
        .joined(separator: "\n\n")

        return UserQueryModelIntentInput(
            command: modelCommand,
            contextSnippets: [
                taskContext,
                compactedPrompt
            ].filter { !$0.isEmpty }
        )
    }

    private static func runtimeCapabilities(for catalog: LocalAppTaskCatalog) -> [String] {
        catalog.taskDefinitions
            .map { definition in
                let title = displayTitle(for: definition)
                let entities = definition.entityRules.map(\.name).joined(separator: ",")
                return "\(definition.taskType): \(title) app=\(definition.targetApp.appName) entities=\(entities)"
            }
            .sorted()
    }

    private static var userQueryGrantedPermissions: Set<HarnessPermission> {
        [
            .conversation,
            .userPrompt,
            .verification,
            .lifecycle,
            .appLookup,
            .appControl,
            .skillLookup,
            .screenCapture,
            .accessibility,
            .input
        ]
    }

    static func genericHarnessToolNames() -> [String] {
        let allowedSensitiveTools: Set<String> = [
            "automation.applescript.generate"
        ]
        return Array(Set(
            BuiltInHarnessToolCatalog.descriptors
                .filter { descriptor in
                    (
                        descriptor.safetyClass != .destructive
                            && descriptor.safetyClass != .sensitive
                    )
                        || allowedSensitiveTools.contains(descriptor.name)
                }
                .map(\.name)
                + LocalAppHarnessStepExecutor.descriptors.map(\.name)
        )).sorted()
    }

    private static func userQueryStatus(for task: HarnessTaskState?) -> UserQueryTaskStatus? {
        guard let task else { return nil }

        switch task.status {
        case .running, .resuming:
            return nil
        case .paused:
            return .paused
        case .waitingForUser:
            return .waitingForClarification
        case .waitingForPermission:
            return .waitingForPermission
        case .interrupted:
            return .interrupted
        case .completed:
            return .completed
        case .failedSafe, .cancelled:
            return .failed
        }
    }

    private static func genericHarnessTaskMetadata(_ task: HarnessTaskState?) -> [String: String] {
        guard let task else { return [:] }

        var metadata: [String: String] = [
            "genericHarness.taskStatus": task.status.rawValue
        ]
        if let continuation = task.pendingContinuation {
            metadata["genericHarness.pendingReason"] = continuation.reason
            metadata["genericHarness.pendingStage"] = continuation.stage.rawValue
            metadata["genericHarness.pendingToolName"] = continuation.pendingToolCall?.name ?? ""
            metadata["genericHarness.pendingToolCallID"] = continuation.pendingToolCall?.id ?? ""
            metadata["genericHarness.pendingQuestion"] = continuation.question ?? ""
            metadata["genericHarness.missingPermissions"] = continuation.missingPermissions
                .map(\.rawValue)
                .joined(separator: ",")
            metadata["genericHarness.newGoal"] = continuation.metadata["newGoal"] ?? ""
        }
        return metadata
    }

    private static func permissionGateSummary(for task: HarnessTaskState) -> String {
        let permissions = task.pendingContinuation?.missingPermissions ?? []
        let permissionText = permissions.isEmpty
            ? "permission"
            : permissions.map(\.rawValue).joined(separator: ", ")
        let pendingTool = task.pendingContinuation?.pendingToolCall?.name
        if let pendingTool, !pendingTool.isEmpty {
            return "Approve \(permissionText) for \(pendingTool)"
        }

        return "Approve \(permissionText)"
    }

    private static func interruptionSummary(for task: HarnessTaskState) -> String {
        if let newGoal = task.pendingContinuation?.metadata["newGoal"],
           !newGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Changed course: \(newGoal)"
        }

        return "Changed course"
    }

    private static func harnessRequest(
        command: String,
        context: UserQueryCommandContext?
    ) -> AppHarnessTurnRequest {
        AppHarnessTurnRequest(
            turn: AppHarnessTurn(
                text: command,
                source: context?.isFollowUp == true ? .followUp : context?.turnSource ?? .typedPrompt,
                taskID: context?.task.id,
                isFollowUp: context?.isFollowUp ?? false
            ),
            recentEvents: context?.recentEvents ?? [],
            assets: context?.assets ?? [],
            memory: [],
            policy: ["localInput": "guarded"]
        )
    }

    private static func genericHarnessMetadata(
        preparedTurn: AppHarnessGenericLifecyclePreparedTurn,
        runStep: HarnessStepExecutionResult? = nil,
        verificationStep: HarnessStepExecutionResult? = nil,
        recoveryStep: HarnessStepExecutionResult? = nil
    ) -> [String: String] {
        [
            "genericHarness.threadID": preparedTurn.thread.id,
            "genericHarness.taskID": preparedTurn.task.id,
            "genericHarness.taskStatus": (runStep?.task.status ?? preparedTurn.task.status).rawValue,
            "genericHarness.context.promptCharacters": String(preparedTurn.compactedContext.promptText.count),
            "genericHarness.context.eventCount": String(preparedTurn.compactedContext.events.count),
            "genericHarness.context.assetCount": String(preparedTurn.compactedContext.assets.count),
            "genericHarness.context.activeTaskCount": String(preparedTurn.compactedContext.activeTasks.count),
            "genericHarness.context.compactionRecordCount": String(preparedTurn.compactedContext.compactionRecords.count),
            "genericHarness.runToolStatus": runStep?.toolResult?.status.rawValue ?? "",
            "genericHarness.runStoppedForGate": runStep.map { String($0.stoppedForGate) } ?? "",
            "genericHarness.verificationToolStatus": verificationStep?.toolResult?.status.rawValue ?? "",
            "genericHarness.recoveryToolStatus": recoveryStep?.toolResult?.status.rawValue ?? "",
            "genericHarness.pendingQuestion": runStep?.task.pendingContinuation?.question ?? ""
        ]
    }

    private static func contextMetadata(_ context: UserQueryCommandContext?) -> [String: String] {
        guard let context else { return [:] }

        return [
            "taskContext.taskID": context.task.id,
            "taskContext.isFollowUp": String(context.isFollowUp),
            "taskContext.eventCount": String(context.recentEvents.count),
            "taskContext.assetCount": String(context.assets.count)
        ]
    }
}

private struct UserQueryGenericFinalizeResult: Equatable, Sendable {
    var verificationStep: HarnessStepExecutionResult?
    var recoveryStep: HarnessStepExecutionResult?

    init(
        verificationStep: HarnessStepExecutionResult? = nil,
        recoveryStep: HarnessStepExecutionResult? = nil
    ) {
        self.verificationStep = verificationStep
        self.recoveryStep = recoveryStep
    }
}

actor UserQueryRunCoordinatorRegistry {
    private var coordinators: [String: RunCoordinator] = [:]

    func coordinator(for taskID: String) -> RunCoordinator {
        if let coordinator = coordinators[taskID] {
            return coordinator
        }

        let coordinator = RunCoordinator()
        coordinators[taskID] = coordinator
        return coordinator
    }

    func pause(taskID: String, reason: String) async -> Bool {
        guard let coordinator = coordinators[taskID] else { return false }

        await coordinator.pause(reason: reason)
        return true
    }

    func resume(taskID: String, reason: String) async -> Bool {
        guard let coordinator = coordinators[taskID] else { return false }

        await coordinator.resume(reason: reason)
        return true
    }

    func finish(taskID: String) {
        coordinators[taskID] = nil
    }
}
