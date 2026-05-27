import DonkeyAI
import DonkeyContracts
import DonkeyHarness
import DonkeyRuntime
import Foundation
import OSLog

private enum PointerPromptLog {
    #if DEBUG
    static let isEnabled = true
    #else
    static let isEnabled = false
    #endif

    static let commands = Logger(subsystem: "com.donkey.app", category: "pointer-prompt")
}

struct PointerPromptCommandHandlingResult: Equatable, Sendable {
    var status: LocalAppTaskLiveRunStatus
    var threadStatus: PointerPromptTaskStatus
    var decision: AppHarnessDecision
    var summary: String
    var taskLabel: String?
    var traceID: String
    var metadata: [String: String]
    var documentReviewRequest: DocumentFormFillReviewRequest?
    var agentVisualizationPlan: AgentVisualizationPlan?
    var cursorOverlayRequest: PointerCoachCursorGuideRequest?
}

struct DocumentFormFillReviewRequest: Equatable, Sendable {
    var plan: DocumentFormFillPlan
    var definition: LocalAppTaskDefinition
    var traceID: String
}

private struct PointerPromptModelIntentInput: Equatable, Sendable {
    var command: String
    var contextSnippets: [String]
}

struct PointerPromptCommandContext: Sendable {
    var task: PointerPromptNotchTask
    var recentEvents: [PointerPromptTaskEvent]
    var assets: [PointerPromptTaskAsset]
    var isFollowUp: Bool
    var turnSource: AppHarnessTurnSource = .typedPrompt
    var spawnProgressChanged: (@MainActor @Sendable (PointerPromptSpawnProgressUpdate) -> Void)?
    var agentVisualizationChanged: (@MainActor @Sendable (AgentVisualizationPlan) -> Void)?
}

protocol PointerPromptCommandHandling: Sendable {
    func handleSubmittedCommand(
        _ command: String,
        context: PointerPromptCommandContext?
    ) async -> PointerPromptCommandHandlingResult
    func pauseCommand(taskID: String) async -> Bool
    func resumeCommand(taskID: String) async -> Bool
}

extension PointerPromptCommandHandling {
    func handleSubmittedCommand(_ command: String) async -> PointerPromptCommandHandlingResult {
        await handleSubmittedCommand(command, context: nil)
    }
}

struct LocalAppPointerPromptCommandHandler: PointerPromptCommandHandling {
    var catalog: LocalAppTaskCatalog
    var appHarnessRouter: AppHarnessTurnRouter
    var localModelResolver: LocalModelTaskIntentResolver
    var liveRunner: LocalAppTaskLiveRunner
    var redactor: AIHarnessRedactor
    var memoryRetriever: SemanticRunMemoryRetriever
    var coordinatorRegistry: PointerPromptRunCoordinatorRegistry
    var genericHarnessLifecycle: AppHarnessGenericLifecycle
    var memoryStore: SQLiteAgentMemoryStore?
    var agentVisualizationPlanResolver: any AgentVisualizationPlanResolving

    init(
        catalog: LocalAppTaskCatalog = .defaultLocal(),
        localModelResolver: LocalModelTaskIntentResolver? = nil,
        liveRunner: LocalAppTaskLiveRunner? = nil,
        redactor: AIHarnessRedactor = AIHarnessRedactor(),
        memoryRetriever: SemanticRunMemoryRetriever = SemanticRunMemoryRetriever(),
        coordinatorRegistry: PointerPromptRunCoordinatorRegistry = PointerPromptRunCoordinatorRegistry(),
        genericHarnessLifecycle: AppHarnessGenericLifecycle = AppHarnessGenericLifecycle(),
        memoryStore: SQLiteAgentMemoryStore? = .shared,
        agentVisualizationPlanResolver: any AgentVisualizationPlanResolving = DisabledAgentVisualizationPlanResolver()
    ) {
        self.catalog = catalog
        self.appHarnessRouter = AppHarnessTurnRouter(catalog: catalog)
        self.coordinatorRegistry = coordinatorRegistry
        self.localModelResolver = localModelResolver ?? LocalModelTaskIntentResolver(catalog: catalog)
        self.liveRunner = liveRunner ?? LocalAppTaskLiveRunner(
            catalog: catalog,
            appController: MacLocalAppTaskController(
                uiUnderstandingRunner: DonkeyUIUnderstandingRunnerFactory.defaultRunner()
            )
        )
        self.redactor = redactor
        self.memoryRetriever = memoryRetriever
        self.genericHarnessLifecycle = genericHarnessLifecycle
        self.memoryStore = memoryStore
        self.agentVisualizationPlanResolver = agentVisualizationPlanResolver
    }

    func handleSubmittedCommand(
        _ command: String,
        context: PointerPromptCommandContext?
    ) async -> PointerPromptCommandHandlingResult {
        let traceID = "pointer-prompt-\(UUID().uuidString)"
        let taskID = context?.task.id ?? traceID
        logSubmittedCommand(command, traceID: traceID, taskID: taskID, context: context)
        let visualizationResolution = await agentVisualizationPlanResolver.resolveVisualizationPlan(
            AgentVisualizationPlanResolverRequest(
                command: command,
                runtimeCapabilities: Self.runtimeCapabilities(for: catalog),
                cacheSnippets: [],
                sourceTraceID: traceID
            )
        )
        if let resolvedVisualizationPlan = visualizationResolution.visualizationPlan {
            let visualizationPlan = groundAgentVisualizationPlan(resolvedVisualizationPlan)
            guard let cursorOverlayRequest = visualizationPlan.cursorOverlayRequest() else {
                return await continueHandlingNonVisualizationCommand(
                    command: command,
                    context: context,
                    traceID: traceID,
                    taskID: taskID
                )
            }
            let result = PointerPromptCommandHandlingResult(
                status: .completed,
                threadStatus: .chatting,
                decision: AppHarnessDecision(
                    kind: .respond,
                    message: "Showing you.",
                    traceID: traceID,
                    metadata: [
                        "structuredDecision": "true",
                        "router": "agentVisualization"
                    ]
                ),
                summary: "Showing you.",
                taskLabel: visualizationPlan.title,
                traceID: traceID,
                metadata: cursorOverlayRequest.metadata.merging([
                    "appHarness.decision": AppHarnessDecisionKind.respond.rawValue,
                    "appHarness.context.traceID": traceID,
                    "agentVisualization.modelCallID": visualizationResolution.trace.id,
                    "agentVisualization.modelStatus": visualizationResolution.trace.status.rawValue,
                    "agentVisualization.validationStatus": visualizationResolution.trace.validationStatus,
                    "agentVisualization.confidence": Self.formatLatency(visualizationResolution.confidence),
                    "agentVisualization.reason": visualizationResolution.reason,
                    "agentVisualization.stepCount": String(visualizationPlan.steps.count)
                ]) { current, _ in current },
                documentReviewRequest: nil,
                agentVisualizationPlan: visualizationPlan,
                cursorOverlayRequest: cursorOverlayRequest
            )
            logHandlingResult(result, stage: "agentVisualization", hint: "Showing a visual-only agent action visualization.")
            return result
        }

        return await continueHandlingNonVisualizationCommand(
            command: command,
            context: context,
            traceID: traceID,
            taskID: taskID
        )
    }

    private func continueHandlingNonVisualizationCommand(
        command: String,
        context: PointerPromptCommandContext?,
        traceID: String,
        taskID: String
    ) async -> PointerPromptCommandHandlingResult {
        let harnessRequest = Self.harnessRequest(command: command, context: context)
        let routing = appHarnessRouter.route(
            request: harnessRequest,
            traceID: traceID
        )
        let genericPreparedTurn = await genericHarnessLifecycle.preparePointerPromptTurn(
            request: harnessRequest,
            pointerTask: context?.task,
            traceID: traceID,
            availableToolNames: Self.genericHarnessToolNames(),
            grantedPermissions: Self.pointerPromptGrantedPermissions
        )
        logRouting(command: command, traceID: traceID, taskID: taskID, routing: routing)
        switch routing.outcome.decision.kind {
        case .respond:
            let result = PointerPromptCommandHandlingResult(
                status: .completed,
                threadStatus: .chatting,
                decision: routing.outcome.decision,
                summary: routing.outcome.assistantResponse ?? "Tell me what local app task you want to work on.",
                taskLabel: nil,
                traceID: traceID,
                metadata: Self.contextPacketMetadata(routing.contextPacket, outcome: routing.outcome)
                    .merging(Self.genericHarnessMetadata(preparedTurn: genericPreparedTurn)) { current, _ in current },
                documentReviewRequest: nil,
                agentVisualizationPlan: nil,
                cursorOverlayRequest: nil
            )
            _ = await genericHarnessLifecycle.coordinator.complete(
                taskID: genericPreparedTurn.task.id,
                reason: "Pointer prompt routed to conversation response"
            )
            logHandlingResult(result, stage: "conversation", hint: routingHint(for: routing))
            return result
        case .askClarification:
            let result = PointerPromptCommandHandlingResult(
                status: .needsConfirmation,
                threadStatus: .waitingForClarification,
                decision: routing.outcome.decision,
                summary: routing.outcome.assistantResponse ?? "What detail should I use?",
                taskLabel: nil,
                traceID: traceID,
                metadata: Self.contextPacketMetadata(routing.contextPacket, outcome: routing.outcome)
                    .merging(Self.genericHarnessMetadata(preparedTurn: genericPreparedTurn)) { current, _ in current },
                documentReviewRequest: nil,
                agentVisualizationPlan: nil,
                cursorOverlayRequest: nil
            )
            _ = await genericHarnessLifecycle.coordinator.waitForUser(
                taskID: genericPreparedTurn.task.id,
                question: result.summary,
                reason: "Pointer prompt routing needs clarification"
            )
            logHandlingResult(result, stage: "routing", hint: routingHint(for: routing))
            return result
        case .noOp:
            let result = PointerPromptCommandHandlingResult(
                status: .completed,
                threadStatus: .chatting,
                decision: routing.outcome.decision,
                summary: "",
                taskLabel: nil,
                traceID: traceID,
                metadata: Self.contextPacketMetadata(routing.contextPacket, outcome: routing.outcome)
                    .merging(Self.genericHarnessMetadata(preparedTurn: genericPreparedTurn)) { current, _ in current },
                documentReviewRequest: nil,
                agentVisualizationPlan: nil,
                cursorOverlayRequest: nil
            )
            _ = await genericHarnessLifecycle.coordinator.complete(
                taskID: genericPreparedTurn.task.id,
                reason: "Pointer prompt empty turn"
            )
            logHandlingResult(result, stage: "empty", hint: "Empty command; no action was run.")
            return result
        case .openReview, .runLocalTask:
            break
        }

        let coordinator = await coordinatorRegistry.coordinator(for: taskID)
        var taskLiveRunner = liveRunner
        taskLiveRunner.coordinator = coordinator
        let modelInput = Self.modelInput(
            for: command,
            context: context,
            contextPacket: routing.contextPacket
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
        let localModelResult = await localModelResolver.resolve(
            command: commandRedaction.redactedText,
            contextSnippets: redactedContextSnippets,
            sourceTraceID: traceID
        )
        let resolution = localModelResult.resolution
        let parseLatencyMS = Self.uptimeMilliseconds() - parseStartedAt
        logModelResolution(
            command: commandRedaction.redactedText,
            traceID: traceID,
            resolution: resolution,
            trace: localModelResult.trace,
            latencyMS: parseLatencyMS
        )
        let semanticMemoryResults = await retrieveSemanticMemory(
            command: commandRedaction.redactedText,
            resolution: resolution
        )
        let modelObservability = AIModelObservabilityReportBuilder.build(from: [localModelResult.trace])
        let modelMetadata = [
            "appHarness.decision": routing.outcome.decision.kind.rawValue,
            "appHarness.context.promptCharacters": String(routing.contextPacket.promptText.count),
            "appHarness.context.redactionCount": String(routing.contextPacket.redactionCount),
            "intentParser": "hostedModel",
            "latency.commandParseMS": Self.formatLatency(parseLatencyMS),
            "modelCallID": localModelResult.trace.id,
            "modelCallStatus": localModelResult.trace.status.rawValue,
            "modelValidationStatus": localModelResult.trace.validationStatus,
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
            toolName: "local-task-intent-parser",
            summary: "Parsed local app command",
            traceID: traceID,
            metadata: [
                "modelCallID": localModelResult.trace.id,
                "modelCallStatus": localModelResult.trace.status.rawValue,
                "modelValidationStatus": localModelResult.trace.validationStatus
            ]
        )

        if Self.shouldRespondWithoutLocalTask(resolution) {
            let response = Self.conversationResponse(for: resolution)
            let decision = AppHarnessDecision(
                kind: .respond,
                message: response,
                traceID: traceID,
                metadata: [
                    "structuredDecision": "true",
                    "router": "modelNoTaskIntent",
                    "resolution.status": resolution.status.rawValue
                ]
            )
            let handlingResult = PointerPromptCommandHandlingResult(
                status: .completed,
                threadStatus: .chatting,
                decision: decision,
                summary: response,
                taskLabel: nil,
                traceID: traceID,
                metadata: modelMetadata.merging([
                    "appHarness.decision": AppHarnessDecisionKind.respond.rawValue,
                    "router": "modelNoTaskIntent",
                    "resolution.status": resolution.status.rawValue,
                    "resolution.reason": resolution.metadata["reason"] ?? ""
                ]) { _, new in new }.merging(
                    Self.contextPacketMetadata(routing.contextPacket, outcome: routing.outcome)
                ) { current, _ in current },
                documentReviewRequest: nil,
                agentVisualizationPlan: nil,
                cursorOverlayRequest: nil
            )
            _ = await genericHarnessLifecycle.coordinator.complete(
                taskID: taskID,
                reason: "Pointer prompt conversation response"
            )
            await coordinatorRegistry.finish(taskID: taskID)
            logHandlingResult(
                handlingResult,
                stage: "conversation",
                hint: "No local task intent was produced; responded in the thread."
            )
            return handlingResult
        }

        _ = await genericHarnessLifecycle.planLocalTaskRun(
            taskID: taskID,
            resolution: resolution,
            fallbackGoal: commandRedaction.redactedText,
            traceID: traceID
        )
        let localRunResults = PointerPromptHarnessLocalRunResultStore()
        let registry = BuiltInHarnessToolCatalog.registryWithBuiltInExecutors()
        let harnessTaskLiveRunner = taskLiveRunner
        await registry.register(
            HarnessTool(
                descriptor: AppHarnessGenericLifecycle.localTaskRunDescriptor()
            ) { toolContext in
                let localResult = await harnessTaskLiveRunner.run(
                    command: commandRedaction.redactedText,
                    traceID: traceID,
                    resolution: resolution,
                    metadata: modelMetadata.merging([
                        "genericHarness.taskID": toolContext.taskID,
                        "genericHarness.toolCallID": toolContext.call.id
                    ]) { current, _ in current }
                )
                await localRunResults.store(localResult, callID: toolContext.call.id)
                return Self.harnessToolResult(
                    for: localResult,
                    call: toolContext.call
                )
            }
        )
        let genericRuntime = GenericHarnessRuntime(
            coordinator: genericHarnessLifecycle.coordinator,
            registry: registry
        )
        let runStep = await genericRuntime.executeNextPlannedStep(taskID: taskID)
        let result = await localRunResults.firstResult() ?? LocalAppTaskLiveRunResult(
            command: commandRedaction.redactedText,
            traceID: traceID,
            status: .failedSafe,
            resolution: resolution,
            metadata: [
                "reason": "genericHarnessMissingLocalRunResult",
                "genericHarness.stoppedForGate": String(runStep?.stoppedForGate ?? false)
            ]
        )
        let finalized = await finalizeGenericHarnessTask(
            taskID: taskID,
            result: result,
            runStep: runStep,
            runtime: genericRuntime
        )
        logActionTraces(for: result)

        let agentVisualizationPlan = LocalAppTaskAgentVisualizationBuilder.plan(
            for: result,
            sourceTraceID: traceID
        ).map(groundAgentVisualizationPlan)
        let handlingResult = PointerPromptCommandHandlingResult(
            status: result.status,
            threadStatus: threadStatus(for: result),
            decision: routing.outcome.decision,
            summary: summary(for: result, runStep: runStep),
            taskLabel: taskLabel(for: result),
            traceID: traceID,
            metadata: result.metadata.merging(
                Self.contextPacketMetadata(routing.contextPacket, outcome: routing.outcome)
            ) { current, _ in current }
            .merging(Self.genericHarnessMetadata(
                preparedTurn: genericPreparedTurn,
                runStep: runStep,
                verificationStep: finalized.verificationStep,
                recoveryStep: finalized.recoveryStep
            )) { current, _ in current },
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
        let genericPaused = await genericHarnessLifecycle.pauseTask(
            taskID: taskID,
            reason: "Pointer prompt paused task"
        ) != nil
        let oldRunnerPaused = await coordinatorRegistry.pause(
            taskID: taskID,
            reason: "Pointer prompt paused task"
        )
        return genericPaused || oldRunnerPaused
    }

    func resumeCommand(taskID: String) async -> Bool {
        let genericResumed = await genericHarnessLifecycle.resumeTask(
            taskID: taskID,
            reason: "Pointer prompt resumed task"
        ) != nil
        let oldRunnerResumed = await coordinatorRegistry.resume(
            taskID: taskID,
            reason: "Pointer prompt resumed task"
        )
        return genericResumed || oldRunnerResumed
    }

    private func finalizeGenericHarnessTask(
        taskID: String,
        result: LocalAppTaskLiveRunResult,
        runStep: HarnessStepExecutionResult?,
        runtime: GenericHarnessRuntime
    ) async -> PointerPromptGenericFinalizeResult {
        switch result.status {
        case .completed:
            let verificationStep = await runtime.executeNextPlannedStep(taskID: taskID)
            if verificationStep?.toolResult?.status == .failed {
                let recoveryStep = await recoverGenericHarnessTask(
                    taskID: taskID,
                    reason: verificationStep?.toolResult?.summary ?? "Verification failed",
                    traceID: result.traceID,
                    runtime: runtime
                )
                _ = await genericHarnessLifecycle.coordinator.failSafe(
                    taskID: taskID,
                    reason: "Pointer prompt verification failed"
                )
                return PointerPromptGenericFinalizeResult(
                    verificationStep: verificationStep,
                    recoveryStep: recoveryStep
                )
            }

            _ = await genericHarnessLifecycle.coordinator.complete(
                taskID: taskID,
                reason: "Pointer prompt local task completed"
            )
            return PointerPromptGenericFinalizeResult(verificationStep: verificationStep)
        case .needsUserReview, .needsConfirmation, .unsupportedCommand:
            return PointerPromptGenericFinalizeResult()
        case .appUnavailable, .failedSafe:
            let recoveryStep = await recoverGenericHarnessTask(
                taskID: taskID,
                reason: summary(for: result, runStep: runStep),
                traceID: result.traceID,
                runtime: runtime
            )
            _ = await genericHarnessLifecycle.coordinator.failSafe(
                taskID: taskID,
                reason: summary(for: result, runStep: runStep)
            )
            return PointerPromptGenericFinalizeResult(
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

    private func groundAgentVisualizationPlan(_ plan: AgentVisualizationPlan) -> AgentVisualizationPlan {
        let candidates = MacWindowResolver().enumerateCandidates()
        guard !candidates.isEmpty else { return plan }

        return AgentVisualizationGrounder().ground(
            plan: plan,
            targetAppName: plan.metadata["targetApp"],
            candidates: candidates
        )
    }

    private func logRouting(
        command: String,
        traceID: String,
        taskID: String,
        routing: AppHarnessRoutingResult
    ) {
        guard PointerPromptLog.isEnabled else { return }

        let decision = routing.outcome.decision.kind.rawValue
        let router = routing.outcome.metadata["router"] ?? "unknown"
        let resolution = routing.outcome.resolution?.status.rawValue ?? "none"
        let missingDetail = routing.outcome.missingDetail ?? ""
        let taskType = routing.outcome.resolution?.definition?.taskType ?? ""
        let hint = routingHint(for: routing)
        PointerPromptLog.commands.notice(
            "command routed traceID=\(traceID, privacy: .public) taskID=\(taskID, privacy: .public) decision=\(decision, privacy: .public) router=\(router, privacy: .public) resolution=\(resolution, privacy: .public) taskType=\(taskType, privacy: .public) missingDetail=\(missingDetail, privacy: .public) hint=\(hint, privacy: .public) command=\(command, privacy: .public)"
        )
    }

    private func logSubmittedCommand(
        _ command: String,
        traceID: String,
        taskID: String,
        context: PointerPromptCommandContext?
    ) {
        guard PointerPromptLog.isEnabled else { return }

        let source = context?.turnSource.rawValue ?? AppHarnessTurnSource.typedPrompt.rawValue
        let isFollowUp = context?.isFollowUp ?? false
        PointerPromptLog.commands.notice(
            "command submitted traceID=\(traceID, privacy: .public) taskID=\(taskID, privacy: .public) source=\(source, privacy: .public) followUp=\(String(isFollowUp), privacy: .public) command=\(command, privacy: .public)"
        )
    }

    private func logModelResolution(
        command: String,
        traceID: String,
        resolution: LocalAppTaskCatalogResolution,
        trace: AIModelCallTrace,
        latencyMS: Double
    ) {
        guard PointerPromptLog.isEnabled else { return }

        let taskType = resolution.definition?.taskType ?? resolution.intent?.taskType ?? ""
        let reason = resolution.metadata["reason"] ?? ""
        let modelReason = Self.metadataValue(
            in: resolution.metadata,
            keys: ["model.reason", "model.fallback.reason"]
        )
            ?? Self.metadataValue(
                in: trace.metadata,
                keys: ["reason", "fallback.reason", "modelFallback.reason"]
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
        PointerPromptLog.commands.notice(
            "intent resolved traceID=\(traceID, privacy: .public) resolution=\(resolution.status.rawValue, privacy: .public) taskType=\(taskType, privacy: .public) reason=\(reason, privacy: .public) modelStatus=\(trace.status.rawValue, privacy: .public) validation=\(trace.validationStatus, privacy: .public) modelReason=\(modelReason, privacy: .public) modelDetail=\(modelDetail, privacy: .public) fallbackStatus=\(fallbackStatus, privacy: .public) latencyMS=\(latency, privacy: .public) command=\(command, privacy: .public)"
        )
    }

    private func logHandlingResult(
        _ result: PointerPromptCommandHandlingResult,
        stage: String,
        hint: String
    ) {
        guard PointerPromptLog.isEnabled else { return }

        let taskLabel = result.taskLabel ?? ""
        PointerPromptLog.commands.notice(
            "command finished traceID=\(result.traceID, privacy: .public) stage=\(stage, privacy: .public) status=\(result.status.rawValue, privacy: .public) threadStatus=\(result.threadStatus.rawValue, privacy: .public) summary=\(result.summary, privacy: .public) taskLabel=\(taskLabel, privacy: .public) hint=\(hint, privacy: .public)"
        )
    }

    private func logActionTraces(for result: LocalAppTaskLiveRunResult) {
        guard PointerPromptLog.isEnabled else { return }

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

            PointerPromptLog.commands.notice(
                "local action traceID=\(result.traceID, privacy: .public) commandID=\(command.id, privacy: .public) workflowStepID=\(workflowStepID, privacy: .public) kind=\(command.kind.rawValue, privacy: .public) backend=\(backend, privacy: .public) inputMode=\(inputMode, privacy: .public) executed=\(String(trace.executed), privacy: .public) decision=\(decisionDescription(trace.decision), privacy: .public) elementClick=\(String(elementClick), privacy: .public) controlID=\(controlID, privacy: .public) target=\(target, privacy: .public) overlayPointer=visualOnly appleScriptAction=\(appleScriptAction, privacy: .public) appleScriptOutput=\(appleScriptOutput, privacy: .public) accessibilityResult=\(accessibilityResult, privacy: .public)"
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

    private func routingHint(for routing: AppHarnessRoutingResult) -> String {
        let router = routing.outcome.metadata["router"] ?? ""
        switch router {
        case "followUpActionContext":
            return "Follow-up turn is being treated as an action for the existing task."
        case "modelIntent":
            return "Using hosted model intent classification through the Donkey backend."
        default:
            return "Router path \(router.isEmpty ? "unknown" : router)."
        }
    }

    private func runHint(for result: LocalAppTaskLiveRunResult) -> String {
        if let reason = result.metadata["reason"], !reason.isEmpty {
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
        if resolution.intent == nil {
            let reason = resolution.metadata["reason"]
            if reason == "localModelIntentUnavailable"
                || reason == "hostedModelIntentUnavailable" {
                return true
            }
        }
        if resolution.metadata["responseMode"] == "conversation",
           resolution.metadata["assistantResponse"]?.isEmpty == false {
            return true
        }
        return resolution.metadata["reason"] == "lowConfidenceIntent"
            && resolution.metadata["assistantResponse"]?.isEmpty == false
    }

    private static func conversationResponse(for resolution: LocalAppTaskCatalogResolution) -> String {
        if let assistantResponse = resolution.metadata["assistantResponse"],
           !assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return assistantResponse
        }
        if resolution.metadata["reason"] == "localModelIntentUnavailable" {
            let modelStatus = resolution.metadata["modelCallStatus"] ?? ""
            if modelStatus == AIModelCallStatus.providerOutage.rawValue
                || modelStatus == AIModelCallStatus.timeout.rawValue {
                return "The local command parser is not available right now, so I couldn't safely run that local action."
            }
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

    private func summary(for result: LocalAppTaskLiveRunResult) -> String {
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
                guard reason != "localModelIntentUnavailable",
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
        runStep: HarnessStepExecutionResult?
    ) -> String {
        if let question = runStep?.task.pendingContinuation?.question,
           !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return question
        }

        return summary(for: result)
    }

    private func threadStatus(for result: LocalAppTaskLiveRunResult) -> PointerPromptTaskStatus {
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
        context: PointerPromptCommandContext?,
        contextPacket: AppHarnessContextPacket
    ) -> PointerPromptModelIntentInput {
        let modelCommand = contextPacket.currentTurn.text
        guard let context, context.isFollowUp else {
            return PointerPromptModelIntentInput(
                command: modelCommand,
                contextSnippets: []
            )
        }

        let taskContext = [
            "Existing task title: \(context.task.title)",
            "Existing task original request: \(context.task.commandText)",
            "Existing task status: \(context.task.status.rawValue)"
        ]
        .compactMap(\.self)
        .joined(separator: "\n\n")

        return PointerPromptModelIntentInput(
            command: modelCommand,
            contextSnippets: [
                taskContext,
                contextPacket.promptText
            ]
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

    private static var pointerPromptGrantedPermissions: Set<HarnessPermission> {
        [.conversation, .userPrompt, .verification, .lifecycle]
    }

    private static func genericHarnessToolNames() -> [String] {
        (BuiltInHarnessToolCatalog.descriptors.map(\.name) + [
            AppHarnessGenericLifecycleToolNames.localAppRun
        ]).sorted()
    }

    private static func harnessToolResult(
        for result: LocalAppTaskLiveRunResult,
        call: HarnessToolCall
    ) -> HarnessToolResult {
        let toolStatus: HarnessToolResultStatus
        let question: String?
        switch result.status {
        case .completed:
            toolStatus = .succeeded
            question = nil
        case .needsUserReview:
            toolStatus = .waitingForUser
            question = "Review the proposed changes before I continue."
        case .needsConfirmation:
            toolStatus = .waitingForUser
            question = "What detail should I use?"
        case .unsupportedCommand:
            toolStatus = .waitingForUser
            question = "What local app task should I run?"
        case .appUnavailable, .failedSafe:
            toolStatus = .failed
            question = nil
        }

        return HarnessToolResult(
            callID: call.id,
            toolName: call.name,
            status: toolStatus,
            summary: "Local app task \(result.status.rawValue).",
            observations: HarnessObservationDelta(
                focusedApp: result.resolution.availability?.target.appName,
                facts: [
                    "localApp.status": result.status.rawValue,
                    "localApp.resolutionStatus": result.resolution.status.rawValue,
                    "localApp.taskType": result.resolution.intent?.taskType
                        ?? result.resolution.definition?.taskType
                        ?? "",
                    "localApp.targetApp": result.resolution.intent?.targetApp.appName
                        ?? result.resolution.definition?.targetApp.appName
                        ?? result.resolution.availability?.target.appName
                        ?? ""
                ].merging(result.metadata) { current, _ in current },
                uncertainty: result.status == .completed ? [] : [result.status.rawValue]
            ),
            question: question,
            metadata: [
                "executor": "LocalAppTaskLiveRunner",
                "localApp.status": result.status.rawValue,
                "traceID": result.traceID
            ]
        )
    }

    private static func harnessRequest(
        command: String,
        context: PointerPromptCommandContext?
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

    private static func contextPacketMetadata(
        _ packet: AppHarnessContextPacket,
        outcome: AppHarnessRoutingOutcome
    ) -> [String: String] {
        [
            "appHarness.decision": outcome.decision.kind.rawValue,
            "appHarness.decision.traceID": outcome.decision.traceID,
            "appHarness.missingDetail": outcome.missingDetail ?? "",
            "appHarness.context.traceID": packet.traceID,
            "appHarness.context.eventCount": String(packet.recentEvents.count),
            "appHarness.context.assetCount": String(packet.assets.count),
            "appHarness.context.promptCharacters": String(packet.promptText.count),
            "appHarness.context.redactionCount": String(packet.redactionCount)
        ]
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

    private static func contextMetadata(_ context: PointerPromptCommandContext?) -> [String: String] {
        guard let context else { return [:] }

        return [
            "taskContext.taskID": context.task.id,
            "taskContext.isFollowUp": String(context.isFollowUp),
            "taskContext.eventCount": String(context.recentEvents.count),
            "taskContext.assetCount": String(context.assets.count)
        ]
    }
}

private struct PointerPromptGenericFinalizeResult: Equatable, Sendable {
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

private actor PointerPromptHarnessLocalRunResultStore {
    private var resultsByCallID: [String: LocalAppTaskLiveRunResult] = [:]

    func store(_ result: LocalAppTaskLiveRunResult, callID: String) {
        resultsByCallID[callID] = result
    }

    func firstResult() -> LocalAppTaskLiveRunResult? {
        resultsByCallID.values.first
    }
}

actor PointerPromptRunCoordinatorRegistry {
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
