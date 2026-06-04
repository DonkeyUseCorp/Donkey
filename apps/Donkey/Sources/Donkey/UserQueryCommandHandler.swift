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
    var permissionPolicy: ToolCallPolicy
    var coordinatorRegistry: UserQueryRunCoordinatorRegistry
    var genericHarnessLifecycle: AppHarnessGenericLifecycle

    init(
        permissionPolicy: ToolCallPolicy = ToolCallPolicy(
            allowedCapabilities: ToolCallPolicy.defaultAllowedCapabilities.union([.input]),
            deniedCapabilities: []
        ),
        coordinatorRegistry: UserQueryRunCoordinatorRegistry = UserQueryRunCoordinatorRegistry(),
        genericHarnessLifecycle: AppHarnessGenericLifecycle = AppHarnessGenericLifecycle()
    ) {
        self.permissionPolicy = permissionPolicy
        self.coordinatorRegistry = coordinatorRegistry
        self.genericHarnessLifecycle = genericHarnessLifecycle
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
        // Redact PII/secrets before the command becomes the task goal: the hosted planner forwards the
        // goal to the backend on every step, and the goal is the only user text this route sends to a
        // model, so redacting here keeps secrets on-device without touching the planner.
        let redactedCommand = AIHarnessRedactor().redact(command, surface: .modelContext).redactedText
        let harnessRequest = Self.harnessRequest(command: redactedCommand, context: context)
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

        // Every typed query runs the generic harness loop against the frontmost app: the planner
        // re-plans per observation and picks AX/vision to see and AX/vision/scripts to act.
        return await runHarnessLoop(
            command: redactedCommand,
            traceID: traceID,
            taskID: taskID,
            preparedTurnMetadata: Self.genericHarnessMetadata(preparedTurn: genericPreparedTurn)
        )
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

    // MARK: - Harness Run (frontmost app)

    /// The only route: satisfies the typed query by running the generic harness loop
    /// (`GenericHarnessRuntime.run`) against the frontmost app. The loop re-plans after every
    /// observation via `HostedHarnessStepPlanner`, which picks the next tool — AX or vision to see,
    /// AX/vision/keyboard/AppleScript to act — and console-logs the grounding latency for telemetry.
    ///
    /// `@MainActor` because window resolution, the tools, and the timing accumulators all run on the
    /// main actor.
    @MainActor
    private func runHarnessLoop(
        command: String,
        traceID: String,
        taskID: String,
        preparedTurnMetadata: [String: String]
    ) async -> UserQueryCommandHandlingResult {
        guard permissionPolicy.allowedCapabilities.contains(.input) else {
            return await failHarnessRun(
                response: "Vision navigation needs input permission, which isn't granted.",
                reason: "inputNotPermitted",
                appName: "",
                traceID: traceID,
                taskID: taskID,
                preparedTurnMetadata: preparedTurnMetadata
            )
        }
        guard let target = MacWindowResolver().frontmostUserAppTarget() else {
            return await failHarnessRun(
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
            return await failHarnessRun(
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

        // Drive the frontmost app through the GENERIC HARNESS LOOP: the harness re-plans after every
        // observation, consulting `HostedHarnessStepPlanner` (the model boundary) to pick the next
        // tool. The planner chooses how to SEE (ax.observe vs. vision.capture) and how to ACT (ax.click,
        // vision.click, keyboard/text input, generated AppleScript), or `run.complete` when done —
        // vision is just one tool among many. The always-on warm-cache monitor is suspended for the
        // duration so it never races us on a parse.
        let analyzer = HostedDebugUIInspectionAnalyzer(backend: backend)
        let appKey = (bundleIdentifier?.isEmpty == false ? bundleIdentifier! : appName)

        // Built-in action/lifecycle/skill tools, minus the placeholder see/act tools that the real AX +
        // vision tools below replace, and restricted to what this turn is permitted to run.
        var harnessServices = LocalAppUserQueryHarnessServices.builtInSkillBackedServices()
        let appleScriptGenerationAdapter = HostedAppleScriptGenerationAdapter()
        harnessServices.appleScriptGenerator = { request in
            await appleScriptGenerationAdapter.generateAppleScript(request)
        }
        let granted = Self.userQueryGrantedPermissions
        let replacedBuiltIns: Set<String> = ["screen.observe", "elements.get", "element.perform", "text.enter", "keyboard.press"]
        let builtInDescriptors = BuiltInHarnessToolCatalog.descriptors.filter { descriptor in
            !replacedBuiltIns.contains(descriptor.name)
                && Set(descriptor.requiredPermissions).isSubset(of: granted)
        }
        let registry = HarnessToolRegistry(
            tools: BuiltInHarnessToolExecutors.tools(descriptors: builtInDescriptors, services: harnessServices)
        )
        let axProvider = AXComputerUseToolProvider(appName: appName, bundleIdentifier: bundleIdentifier)
        let visionProvider = VisionComputerUseToolProvider(
            appName: appName,
            appKey: appKey,
            bundleIdentifier: bundleIdentifier,
            analyzer: analyzer
        )
        // Register the AX/vision see/act tools only when this turn holds their permissions, mirroring
        // the built-in descriptor filter so the planner is never offered a tool it can't run.
        for tool in axProvider.makeTools() + visionProvider.makeTools()
        where Set(tool.descriptor.requiredPermissions).isSubset(of: granted) {
            await registry.register(tool)
        }
        let runtime = GenericHarnessRuntime(
            coordinator: genericHarnessLifecycle.coordinator,
            registry: registry
        )
        let plannerDescriptors = await registry.descriptors()
        let planner = HostedHarnessStepPlanner(
            backend: backend,
            descriptors: plannerDescriptors,
            appName: appName,
            appGuidance: appGuidance
        )
        _ = await genericHarnessLifecycle.coordinator.startRunning(
            taskID: taskID,
            reason: "User query harness run"
        )

        VisionGroundingLog.emit(
            "start traceID=\(traceID) app=\(appName) goal=\"\(command)\""
        )
        let e2eStartMS = Self.uptimeMilliseconds()
        // Suspend the warm-cache monitor for the whole drive so it never races us writing the same
        // app's parse. The run between these calls has no early exit, so resume always pairs with it.
        VisionWarmCacheActivity.shared.suspend()
        let runSteps = await runtime.run(taskID: taskID, planner: planner, maxSteps: 8)
        VisionWarmCacheActivity.shared.resume()

        let finalTask = await genericHarnessLifecycle.coordinator.task(id: taskID)
        let finalStatus = finalTask?.status
        let completed = finalStatus == .completed
        let awaitingUser = finalStatus == .waitingForUser
        let outcomeReason = completed ? "ok"
            : (awaitingUser ? "awaitingUser"
            : (finalStatus == .failedSafe ? "failedSafe" : "maxStepsReached"))
        let turns = runSteps.count
        let anyTurnUsedCache = runSteps.contains { $0.toolResult?.metadata["usedCache"] == "true" }
        let totalParseMS = runSteps.reduce(0.0) { $0 + ($1.toolResult?.metadata["parseMS"].flatMap(Double.init) ?? 0) }
        let timeToFirstActionMS = planner.firstActionUptimeMS.map { $0 - e2eStartMS }
        let e2eTotalMS = Self.uptimeMilliseconds() - e2eStartMS
        let averagePerTurnMS = turns > 0 ? e2eTotalMS / Double(turns) : 0
        if let timeToFirstActionMS {
            VisionGroundingLog.emit(
                "time-to-first-action traceID=\(traceID) app=\(appName) ms=\(Self.formatLatency(timeToFirstActionMS))"
            )
        }
        VisionGroundingLog.emit(
            "complete traceID=\(traceID) app=\(appName) completed=\(completed) reason=\(outcomeReason) turns=\(turns) usedCache=\(anyTurnUsedCache) parseMS=\(Self.formatLatency(totalParseMS)) e2eTotalMS=\(Self.formatLatency(e2eTotalMS)) timeToFirstActionMS=\(Self.formatLatency(timeToFirstActionMS ?? 0)) avgPerTurnMS=\(Self.formatLatency(averagePerTurnMS))"
        )

        let baseMetadata = preparedTurnMetadata.merging([
            "appHarness.router": "harness",
            "harness.app": appName,
            "harness.completed": String(completed),
            "harness.turns": String(turns),
            "harness.reason": outcomeReason,
            "grounding.e2eTotalMS": Self.formatLatency(e2eTotalMS),
            "grounding.timeToFirstActionMS": Self.formatLatency(timeToFirstActionMS ?? 0),
            "grounding.avgPerTurnMS": Self.formatLatency(averagePerTurnMS),
            "grounding.usedCache": String(anyTurnUsedCache),
            "grounding.parseMS": Self.formatLatency(totalParseMS)
        ]) { _, new in new }

        // The planner can end a turn three ways: ask the user (user.clarify → waitingForUser), answer
        // conversationally (conversation.respond), or finish an action (run.complete). Surface whichever
        // happened rather than always reporting "Done".
        if awaitingUser {
            let question = finalTask?.pendingContinuation?.question.flatMap { $0.isEmpty ? nil : $0 }
                ?? "Could you clarify what you'd like me to do?"
            let decision = AppHarnessDecision(
                kind: .askClarification,
                message: question,
                traceID: traceID,
                metadata: ["structuredDecision": "true", "router": "harness"]
            )
            let result = UserQueryCommandHandlingResult(
                status: .needsConfirmation,
                threadStatus: .waitingForClarification,
                decision: decision,
                summary: question,
                traceID: traceID,
                metadata: baseMetadata.merging([
                    "appHarness.decision": AppHarnessDecisionKind.askClarification.rawValue
                ]) { _, new in new }
            )
            await coordinatorRegistry.finish(taskID: taskID)
            logHandlingResult(result, stage: "harness", hint: "Asked the user to clarify.")
            return result
        }

        let conversationMessage = finalTask?.toolHistory.last { $0.call.name == "conversation.respond" }
            .flatMap { $0.call.input["response"] ?? $0.call.input["message"] }
            .flatMap { $0.isEmpty ? nil : $0 }
        let response = conversationMessage
            ?? planner.lastNarration
            ?? (completed ? "Done." : "I tried operating \(appName) but couldn't confirm the goal was finished.")
        let decision = AppHarnessDecision(
            kind: .respond,
            message: response,
            traceID: traceID,
            metadata: ["structuredDecision": "true", "router": "harness", "harness.completed": String(completed)]
        )
        let result = UserQueryCommandHandlingResult(
            status: completed ? .completed : .failedSafe,
            threadStatus: completed ? .completed : .failed,
            decision: decision,
            summary: response,
            traceID: traceID,
            metadata: baseMetadata.merging([
                "appHarness.decision": AppHarnessDecisionKind.respond.rawValue
            ]) { _, new in new }
        )
        // The planner ends the run via run.complete/run.failSafe, so the task status is usually already
        // terminal; finalize defensively for the maxSteps-reached case.
        if completed {
            _ = await genericHarnessLifecycle.coordinator.complete(
                taskID: taskID,
                reason: "User query harness run completed"
            )
        } else {
            _ = await genericHarnessLifecycle.coordinator.failSafe(
                taskID: taskID,
                reason: "User query harness run did not confirm completion"
            )
        }
        await coordinatorRegistry.finish(taskID: taskID)
        logHandlingResult(
            result,
            stage: "harness",
            hint: completed ? "Operated \(appName)." : "Harness run stopped: \(outcomeReason)."
        )
        return result
    }

    /// Fail-safe exit for the vision-navigation route when it can't even start (no frontmost app,
    /// backend unconfigured, input not permitted). Mirrors the other non-local routes' lifecycle.
    private func failHarnessRun(
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
                "router": "harness",
                "harness.abortReason": reason
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
                "appHarness.router": "harness",
                "harness.abortReason": reason
            ]) { _, new in new }
        )
        _ = await genericHarnessLifecycle.coordinator.failSafe(
            taskID: taskID,
            reason: "User query harness run could not start: \(reason)"
        )
        await coordinatorRegistry.finish(taskID: taskID)
        logHandlingResult(result, stage: "harness", hint: response)
        return result
    }

    // MARK: - Generic Harness Task Execution

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

    private static func uptimeMilliseconds() -> Double {
        ProcessInfo.processInfo.systemUptime * 1_000
    }

    private static func formatLatency(_ milliseconds: Double) -> String {
        String(format: "%.3f", max(0, milliseconds))
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
