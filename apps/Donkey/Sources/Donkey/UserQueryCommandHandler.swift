import AppKit
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
        self.agentVisualizationPlan = agentVisualizationPlan
        self.cursorOverlayRequest = cursorOverlayRequest
    }
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
    func approvePermissionGate(taskID: String, alwaysAllow: Bool) async -> Bool
    /// Re-run the harness loop for a task whose permission gate was just
    /// approved, so the granted command actually executes. Returns nil when the
    /// task is unknown.
    func continueApprovedCommand(
        taskID: String,
        context: UserQueryCommandContext?
    ) async -> UserQueryCommandHandlingResult?
}

extension UserQueryCommandHandling {
    func handleSubmittedCommand(_ command: String) async -> UserQueryCommandHandlingResult {
        await handleSubmittedCommand(command, context: nil)
    }

    func continueApprovedCommand(
        taskID: String,
        context: UserQueryCommandContext?
    ) async -> UserQueryCommandHandlingResult? {
        nil
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
            preparedTurnMetadata: Self.genericHarnessMetadata(preparedTurn: genericPreparedTurn),
            visualize: context?.agentVisualizationChanged,
            progress: Self.progressLabeler(context?.spawnProgressChanged)
        )
    }

    func continueApprovedCommand(
        taskID: String,
        context: UserQueryCommandContext?
    ) async -> UserQueryCommandHandlingResult? {
        guard let task = await genericHarnessLifecycle.taskState(taskID: taskID),
              !task.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let traceID = "user-query-resume-\(UUID().uuidString)"
        return await runHarnessLoop(
            command: task.goal,
            traceID: traceID,
            taskID: taskID,
            preparedTurnMetadata: [:],
            visualize: context?.agentVisualizationChanged,
            progress: Self.progressLabeler(context?.spawnProgressChanged)
        )
    }

    /// Adapt the spawn-progress callback into a plain narration sink the run
    /// loop can feed with one-line status labels.
    private static func progressLabeler(
        _ spawnProgressChanged: (@MainActor @Sendable (UserQuerySpawnProgressUpdate) -> Void)?
    ) -> (@MainActor @Sendable (String) -> Void)? {
        guard let spawnProgressChanged else { return nil }
        return { label in
            spawnProgressChanged(UserQuerySpawnProgressUpdate(label: label))
        }
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

    func approvePermissionGate(taskID: String, alwaysAllow: Bool) async -> Bool {
        await genericHarnessLifecycle.approvePermissionGate(
            taskID: taskID,
            decision: alwaysAllow ? .allowAlways : .allow,
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
        preparedTurnMetadata: [String: String],
        visualize: (@MainActor @Sendable (AgentVisualizationPlan) -> Void)? = nil,
        progress: (@MainActor @Sendable (String) -> Void)? = nil
    ) async -> UserQueryCommandHandlingResult {
        guard permissionPolicy.allowedCapabilities.contains(.input) else {
            return await failHarnessRun(
                command: command,
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
                command: command,
                response: "I couldn't find a frontmost app window to navigate. Focus the app you want, then type your request.",
                reason: "noFrontmostApp",
                appName: "",
                traceID: traceID,
                taskID: taskID,
                preparedTurnMetadata: preparedTurnMetadata
            )
        }
        let frontmostAppName = target.appName ?? "the frontmost app"
        let frontmostBundleIdentifier = target.bundleIdentifier

        guard let configuration = try? DonkeyBackendInferenceConfiguration.fromEnvironment() else {
            return await failHarnessRun(
                command: command,
                response: "The vision backend isn't configured (set DONKEY_WEB_BASE_URL), so I couldn't navigate by vision.",
                reason: "visionBackendUnavailable",
                appName: frontmostAppName,
                traceID: traceID,
                taskID: taskID,
                preparedTurnMetadata: preparedTurnMetadata
            )
        }
        let backend = DonkeyBackendInferenceClient(configuration: configuration)

        // Understand the request ONCE before the loop: restate the goal, identify the target app,
        // extract parameters, and decide whether to clarify. Degrades to driving the raw command when
        // it returns nil — or when the call outlives its deadline — so a backend hiccup never
        // dead-ends or silently stalls the run.
        progress?("Working out what you need")
        let understandingBoundary = HostedHarnessRequestUnderstanding(backend: backend)
        let understanding = await AIDeadline.race(seconds: Self.understandingTimeoutSeconds) {
            await understandingBoundary.understand(command: command, frontmostAppName: frontmostAppName)
        }
        if let restated = understanding?.restatedGoal, !restated.isEmpty {
            progress?(restated)
        }

        // Drive the understood target app when it names one that resolves to a running window; else the
        // frontmost app. resolveTarget never falls back to an unrelated window, so a miss keeps us on
        // the frontmost app and the planner can app.openOrFocus the target itself.
        let driveTarget = Self.resolveDriveTarget(
            understanding: understanding,
            frontmostAppName: frontmostAppName,
            frontmostBundleIdentifier: frontmostBundleIdentifier
        )
        let appName = driveTarget.appName
        let bundleIdentifier = driveTarget.bundleIdentifier

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
        // Generic LLM tool: lets the planner compose/transform text mid-task (build a tracklist,
        // a clean note body, a friendly status line) through the same hosted route.
        let textGenerator = HostedTextGenerator(backend: backend)
        harnessServices.textGenerator = { prompt in
            await textGenerator.generate(prompt)
        }
        // Web research goes through the backend on the service-account credential — no key in the
        // app. Search uses Google Search grounding; fetch reads a page and returns clean markdown
        // (nav/ads/boilerplate stripped server-side) so the model gets the article, not raw HTML.
        let hostedWebSearch = HostedWebSearch(backend: backend)
        let hostedWebFetch = HostedWebFetch(backend: backend)
        harnessServices.webSearcher = { query in await hostedWebSearch.search(query) }
        harnessServices.webFetcher = { url in await hostedWebFetch.fetch(url) }
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
        let pointerProvider = PointerComputerUseToolProvider(appName: appName, bundleIdentifier: bundleIdentifier)
        // Register the AX/vision/pointer see/act tools only when this turn holds their permissions,
        // mirroring the built-in descriptor filter so the planner is never offered a tool it can't run.
        for tool in axProvider.makeTools() + visionProvider.makeTools() + pointerProvider.makeTools()
        where Set(tool.descriptor.requiredPermissions).isSubset(of: granted) {
            await registry.register(tool)
        }
        let runtime = GenericHarnessRuntime(
            coordinator: genericHarnessLifecycle.coordinator,
            registry: registry
        )
        let plannerDescriptors = await registry.descriptors()
        let environmentSummary = await SystemToolCapabilityProbe.shared.summary()
        let planner = HostedHarnessStepPlanner(
            backend: backend,
            descriptors: plannerDescriptors,
            appName: appName,
            appGuidance: appGuidance,
            understanding: understanding,
            environmentSummary: environmentSummary,
            skillCatalog: Self.installedSkillCatalog()
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
        // Realtime per-step feedback: narrate every step through the spawn cursor's label (the
        // planner's one-line reason, falling back to the tool's own summary), and after each step that
        // physically moved the pointer (a click), animate the overlay cursor traveling to that exact
        // target, so the visualization tracks what the harness is actually doing.
        // The thread: the real conversation record (like ChatGPT/Claude), written live as markdown —
        // user request, the assistant's thinking, each tool call and result, and the final answer — so
        // the full reasoning trace is readable (and renderable to the user later), and a stuck run is
        // visible instead of a mystery.
        let transcript = ThreadTranscript(id: taskID)
        transcript.begin(id: taskID, app: appName)
        transcript.userMessage(command)
        // The thread is the COMPLETE session record: the parsed understanding (or its absence) is part
        // of the conversation, not just an internal step.
        if let understanding {
            var understood = "Understood request: \(understanding.restatedGoal)"
            if let app = understanding.targetAppName, !app.isEmpty {
                understood += " · target app: \(app)"
            }
            if understanding.needsClarification, let question = understanding.clarifyingQuestion, !question.isEmpty {
                understood += " · needs clarification: \(question)"
            }
            transcript.systemEvent(understood)
        } else {
            transcript.systemEvent("Understanding was unavailable (timed out or failed); driving the raw command.")
        }
        VisionGroundingLog.emit("thread traceID=\(traceID) path=\(transcript.threadPath)")

        // Always set onStep so every turn is recorded; the overlay narration/cursor is layered on top
        // when a UI is attached.
        let onStep: (@Sendable (HarnessStepExecutionResult) async -> Void)? = { (step: HarnessStepExecutionResult) async -> Void in
            await MainActor.run {
                let narration = Self.stepNarration(for: step, planner: planner)
                // Planning failures (unusable replies, retries) are part of the session and must be
                // readable in the thread — a step that ends in run.failSafe is otherwise a mystery.
                for planningError in planner.lastPlanningErrors {
                    transcript.error(planningError)
                }
                if let result = step.toolResult {
                    // The thread file gets the model's full thought summary (when thinking is on);
                    // the overlay/progress gets only the clipped one-line narration below. The full
                    // reasoning is persisted here and nowhere else, so the planning context stays bounded.
                    transcript.thinking(planner.lastThinking ?? narration)
                    transcript.toolCall(tool: result.toolName, input: step.task.toolHistory.last?.call.input ?? [:])
                    transcript.toolResult(tool: result.toolName, status: result.status.rawValue, output: result.summary)
                }
                // Every step narrates through the spawn label (a lightweight text update), so the user
                // is kept informed even on steps that don't move the pointer — observe, shell, wait,
                // verify. The cursor itself only travels (a heavier window-animating overlay playback)
                // on steps that actually moved it; re-running that playback every step thrashes window
                // layout, so it stays gated to real pointer moves.
                if let progress, let narration {
                    progress(narration)
                }
                guard let present = visualize else { return }
                let screenSize = (NSScreen.main ?? NSScreen.screens.first)?.frame.size ?? .zero
                guard let plan = Self.cursorVisualizationPlan(
                    for: step,
                    appName: appName,
                    traceID: traceID,
                    screenSize: screenSize
                ) else { return }
                present(plan)
            }
        }
        // Step budget is progress-based, not a fixed count: the runtime keeps going while the task
        // advances and stops fast when it stalls or loops, so a long legitimate task isn't cut off.
        let runSteps = await runtime.run(taskID: taskID, planner: planner, onStep: onStep)
        VisionWarmCacheActivity.shared.resume()

        let finalTask = await genericHarnessLifecycle.coordinator.task(id: taskID)
        let finalStatus = finalTask?.status
        let completed = finalStatus == .completed
        let awaitingUser = finalStatus == .waitingForUser
        let awaitingPermission = finalStatus == .waitingForPermission
        let outcomeReason = completed ? "ok"
            : (awaitingUser ? "awaitingUser"
            : (awaitingPermission ? "awaitingPermission"
            : (finalStatus == .failedSafe ? "failedSafe" : "maxStepsReached")))
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

        // Record the assistant's final answer to close the turn, then write a compacted, structured
        // thread summary. A deterministic summary lands immediately; an LLM-written one replaces it in
        // the background so the result isn't delayed by the summary call.
        let finalDetail = runSteps.last?.toolResult?.summary ?? finalTask?.goal ?? command
        transcript.systemEvent("Run finished: \(outcomeReason) after \(turns) step(s).")
        transcript.response(finalDetail)
        transcript.writeSummary(Self.deterministicThreadSummary(
            command: command, app: appName, outcome: outcomeReason, steps: runSteps, finalDetail: finalDetail
        ))
        let threadText = (try? String(contentsOfFile: transcript.threadPath, encoding: .utf8)) ?? ""
        if !threadText.isEmpty {
            Task.detached {
                let prompt = """
                Summarize this conversation thread into a compact markdown brief with these exact \
                sections (omit a section only if truly empty): ## Goal, ## Progress, ## Key Decisions, \
                ## Next Steps, ## Critical Context. Be concrete and short.

                THREAD:
                \(threadText)
                """
                if let enhanced = await textGenerator.generate(prompt), !enhanced.isEmpty {
                    transcript.writeSummary(enhanced)
                }
            }
        }

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

        // A permission gate (e.g. shell-command consent) is a hard stop that waits for the user's
        // allow-once / always-allow decision, not a failure. Surface it with the consent metadata the
        // notch controls read; approval re-enters the loop via `continueApprovedCommand`.
        if awaitingPermission {
            let continuation = finalTask?.pendingContinuation
            let summary = runSteps.last?.toolResult?.summary
                ?? continuation?.reason
                ?? "Waiting for your approval."
            let decision = AppHarnessDecision(
                kind: .respond,
                message: summary,
                traceID: traceID,
                metadata: ["structuredDecision": "true", "router": "harness"]
            )
            let missingPermissions: String = (continuation?.missingPermissions ?? [])
                .map(\.rawValue).joined(separator: ",")
            let consentMetadata: [String: String] = [
                "appHarness.decision": AppHarnessDecisionKind.respond.rawValue,
                "genericHarness.shellConsent.command": continuation?.metadata["shell.command"] ?? "",
                "genericHarness.shellConsent.tier": continuation?.metadata["shell.tier"] ?? "",
                "genericHarness.shellConsent.reason": continuation?.metadata["shell.reason"] ?? "",
                "genericHarness.shellConsent.allowAlways": continuation?.metadata["shell.allowAlways"] ?? "",
                "genericHarness.missingPermissions": missingPermissions
            ]
            let result = UserQueryCommandHandlingResult(
                status: .needsConfirmation,
                threadStatus: .waitingForPermission,
                decision: decision,
                summary: summary,
                traceID: traceID,
                metadata: baseMetadata.merging(consentMetadata) { _, new in new }
            )
            await coordinatorRegistry.finish(taskID: taskID)
            logHandlingResult(result, stage: "harness", hint: "Stopped at a permission gate.")
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
    /// Even an aborted start gets a thread file: the thread is the session's complete record, and a
    /// turn that produced nothing on disk is indistinguishable from a turn that never happened.
    private func failHarnessRun(
        command: String,
        response: String,
        reason: String,
        appName: String,
        traceID: String,
        taskID: String,
        preparedTurnMetadata: [String: String]
    ) async -> UserQueryCommandHandlingResult {
        VisionGroundingLog.emit("aborted traceID=\(traceID) reason=\(reason) app=\(appName)")
        let transcript = ThreadTranscript(id: taskID)
        transcript.begin(id: taskID, app: appName)
        transcript.userMessage(command)
        transcript.error("Run could not start (\(reason)).")
        transcript.response(response)
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

    /// A compacted, structured thread summary built deterministically from the run — written
    /// immediately, then replaced by an LLM-written version in the background. Mirrors the Hermes
    /// compaction sections so the summary stays consistent whether or not the LLM call lands.
    static func deterministicThreadSummary(
        command: String,
        app: String,
        outcome: String,
        steps: [HarnessStepExecutionResult],
        finalDetail: String
    ) -> String {
        let keyDecisions = steps.compactMap { step -> String? in
            guard let result = step.toolResult else { return nil }
            return "- `\(result.toolName)` → \(result.status.rawValue): \(result.summary.prefix(120))"
        }.joined(separator: "\n")
        let progress = outcome == "ok" ? "Completed." : "Ended: \(outcome)."
        let nextSteps = outcome == "ok"
            ? "- None — task complete."
            : "- Resume or retry; the task did not complete."
        return """
        # Thread Summary

        ## Goal
        \(command)

        ## Progress
        \(progress) \(steps.count) step(s)\(app.isEmpty ? "" : " in \(app)").

        ## Key Decisions
        \(keyDecisions.isEmpty ? "- (none)" : keyDecisions)

        ## Next Steps
        \(nextSteps)

        ## Critical Context
        \(finalDetail)
        """
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

    /// Deadline for the one-shot understanding call; past it the run degrades to
    /// driving the raw command instead of stalling silently.
    private static let understandingTimeoutSeconds: TimeInterval = 15

    /// One short line describing the step that just ran, for the spawn cursor's
    /// label: the planner's stated reason, else the tool result's own summary.
    @MainActor
    static func stepNarration(
        for step: HarnessStepExecutionResult,
        planner: HostedHarnessStepPlanner
    ) -> String? {
        let candidate = planner.lastNarration ?? step.toolResult?.summary
        guard var narration = candidate?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first,
            !narration.isEmpty else {
            return nil
        }
        let maxLength = 90
        if narration.count > maxLength {
            narration = String(narration.prefix(maxLength)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return narration
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

    /// Picks the app the harness drive operates: the understood target app when it names one that
    /// resolves to a running window, otherwise the frontmost app. `AccessibilityObserver.resolveTarget`
    /// only ever returns the named app's window (never an unrelated frontmost one), so a non-running or
    /// misnamed target safely falls back to the frontmost app.
    @MainActor
    private static func resolveDriveTarget(
        understanding: HarnessRequestUnderstanding?,
        frontmostAppName: String,
        frontmostBundleIdentifier: String?
    ) -> (appName: String, bundleIdentifier: String?) {
        guard let requested = understanding?.targetAppName,
              !requested.isEmpty,
              requested.caseInsensitiveCompare(frontmostAppName) != .orderedSame,
              let resolved = AccessibilityObserver.resolveTarget(appName: requested, bundleIdentifier: nil)
        else {
            return (frontmostAppName, frontmostBundleIdentifier)
        }
        return (resolved.appName ?? requested, resolved.bundleIdentifier)
    }

    /// A compact, one-line-per-skill catalog of every installed app skill — id, description, the apps it
    /// covers, and any validated `skill_run` scripts — surfaced to the planner each step. App-specific
    /// guidance is only preloaded for the resolved GUI drive target, so without this the planner never
    /// learns that a script-driven skill (e.g. Music playback, Notes capture) exists when the task has no
    /// GUI target app — and it improvises fragile commands instead of running the validated script.
    /// Lists every skill unconditionally; the planner does the routing, so no intent is matched here.
    private static func installedSkillCatalog() -> String? {
        let skills = BuiltInLocalAppSkillPacks.descriptors().sorted { $0.id < $1.id }
        guard !skills.isEmpty else { return nil }
        let lines = skills.map { skill -> String in
            let apps = (skill.metadata["apps"]?.isEmpty == false) ? " · apps: \(skill.metadata["apps"]!)" : ""
            let scripts = skill.scripts.isEmpty
                ? ""
                : " · skill_run: " + skill.scripts.map { script in
                    script.purpose.isEmpty ? script.id : "\(script.id) (\(script.purpose))"
                }.joined(separator: ", ")
            return "  - \(skill.id) — \(skill.description)\(apps)\(scripts)"
        }
        return lines.joined(separator: "\n")
    }

    /// Builds a one-step cursor-path visualization toward the exact screen point a just-executed action
    /// clicked, in screen-normalized coordinates for the overlay. Returns nil for steps that did not
    /// move the pointer (observation, conversation, AXPress without a coordinate fallback).
    static func cursorVisualizationPlan(
        for step: HarnessStepExecutionResult,
        appName: String,
        traceID: String,
        screenSize: CGSize
    ) -> AgentVisualizationPlan? {
        guard let result = step.toolResult,
              result.status == .succeeded,
              let raw = result.metadata["screenPoint"],
              screenSize.width > 0, screenSize.height > 0 else {
            return nil
        }
        let parts = raw.split(separator: ",")
        guard parts.count == 2,
              let px = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let py = Double(parts[1].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        let label = result.metadata["label"].flatMap { $0.isEmpty ? nil : $0 } ?? appName
        let target = AgentVisualizationStepTarget(
            point: HotLoopPoint(
                x: px / Double(screenSize.width),
                y: py / Double(screenSize.height),
                space: .normalizedTarget
            ),
            description: label,
            source: .actionTrace,
            confidence: 0.95
        )
        return AgentVisualizationPlan(
            title: appName,
            executionMode: .live,
            sourceTraceID: traceID,
            steps: [
                AgentVisualizationStep(
                    kind: .moveToTarget,
                    label: label,
                    target: target,
                    travelDuration: 0.45,
                    holdDuration: 0.5
                )
            ],
            metadata: ["realPointerMoved": "true"]
        )
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
            "genericHarness.pendingQuestion": runStep?.task.pendingContinuation?.question ?? "",
            "genericHarness.shellConsent.command": runStep?.task.pendingContinuation?.metadata["shell.command"] ?? "",
            "genericHarness.shellConsent.tier": runStep?.task.pendingContinuation?.metadata["shell.tier"] ?? "",
            "genericHarness.shellConsent.reason": runStep?.task.pendingContinuation?.metadata["shell.reason"] ?? "",
            "genericHarness.shellConsent.allowAlways": runStep?.task.pendingContinuation?.metadata["shell.allowAlways"] ?? ""
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
