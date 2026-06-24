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

/// Serializes FOREGROUND harness runs so only one holds window focus at a time. Background runs route
/// input by pid and never raise an app, so they parallelize freely and never touch this gate; two
/// foreground runs, by contrast, would fight over the frontmost app, so they queue here and run their
/// visible work one at a time (FIFO). A run still does all its planning/observation concurrently — it
/// only waits for the token around the loop that actually drives the GUI.
actor ForegroundFocusGate {
    private var locked = false
    private var waiters: [(id: Int, continuation: CheckedContinuation<Bool, Never>)] = []
    private var nextWaiterID = 0

    /// Returns true if the caller now holds the token (and must `release()`), false if it was cancelled
    /// while waiting (and must NOT release — it never held the token).
    func acquire() async -> Bool {
        if !locked {
            locked = true
            return true
        }
        let id = nextWaiterID
        nextWaiterID += 1
        // Cancellation removes and resumes the waiter rather than leaving it parked forever; a cancelled
        // waiter never held the token, so it returns false and `locked` (held by the active run) is
        // untouched. Without this, release() would hand the token to a dead continuation and deadlock
        // every later foreground run.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            // Hand the token directly to the next waiter; ownership transfers, so `locked` stays true.
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }
}

struct UserQueryCommandHandlingResult: Equatable, Sendable {
    var status: LocalAppTaskLiveRunStatus
    var threadStatus: UserQueryConversationStatus
    var decision: AppHarnessDecision
    var summary: String
    var conversationLabel: String?
    var traceID: String
    var metadata: [String: String]
    var agentVisualizationPlan: AgentVisualizationPlan?
    var cursorOverlayRequest: PointerCoachCursorGuideRequest?

    init(
        status: LocalAppTaskLiveRunStatus,
        threadStatus: UserQueryConversationStatus,
        decision: AppHarnessDecision,
        summary: String,
        traceID: String,
        metadata: [String: String],
        conversationLabel: String? = nil,
        agentVisualizationPlan: AgentVisualizationPlan? = nil,
        cursorOverlayRequest: PointerCoachCursorGuideRequest? = nil
    ) {
        self.status = status
        self.threadStatus = threadStatus
        self.decision = decision
        self.summary = summary
        self.conversationLabel = conversationLabel
        self.traceID = traceID
        self.metadata = metadata
        self.agentVisualizationPlan = agentVisualizationPlan
        self.cursorOverlayRequest = cursorOverlayRequest
    }
}

struct UserQueryCommandContext: Sendable {
    var conversation: UserQueryConversation
    var recentEvents: [UserQueryConversationEvent]
    var assets: [UserQueryConversationAsset]
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
    func pauseCommand(conversationID: String) async -> Bool
    func approvePermissionGate(conversationID: String, alwaysAllow: Bool) async -> Bool
    /// Re-run the harness loop for a task whose permission gate was just
    /// approved, so the granted command actually executes. Returns nil when the
    /// task is unknown.
    func continueApprovedCommand(
        conversationID: String,
        context: UserQueryCommandContext?
    ) async -> UserQueryCommandHandlingResult?
    /// Queue a follow-up instruction onto a task whose loop is still running so it folds it in at its
    /// next step. Returns true when the task is live (a loop will pick it up); false means the caller
    /// should fall back to resuming the task with the instruction as a fresh turn.
    func injectFollowUp(conversationID: String, text: String) async -> Bool
    /// Re-run a previously-interrupted task in the BACKGROUND (no focus steal), for unattended
    /// auto-resume on relaunch. Returns nil when the task is unknown or has no goal to resume.
    func autoResumeCommand(
        conversationID: String,
        context: UserQueryCommandContext?
    ) async -> UserQueryCommandHandlingResult?
    /// Set by the overlay so a mid-run hosted 401 (an expired session) surfaces re-login. The inference
    /// client fires it off the main actor, so the hook hops back to the main actor itself.
    var onAuthenticationRequired: (@MainActor @Sendable () -> Void)? { get set }
}

extension UserQueryCommandHandling {
    func handleSubmittedCommand(_ command: String) async -> UserQueryCommandHandlingResult {
        await handleSubmittedCommand(command, context: nil)
    }

    func continueApprovedCommand(
        conversationID: String,
        context: UserQueryCommandContext?
    ) async -> UserQueryCommandHandlingResult? {
        nil
    }

    func injectFollowUp(conversationID: String, text: String) async -> Bool {
        false
    }

    func autoResumeCommand(
        conversationID: String,
        context: UserQueryCommandContext?
    ) async -> UserQueryCommandHandlingResult? {
        nil
    }
}

struct LocalAppUserQueryCommandHandler: UserQueryCommandHandling {
    var permissionPolicy: ToolCallPolicy
    var coordinatorRegistry: UserQueryRunCoordinatorRegistry
    var genericHarnessLifecycle: AppHarnessGenericLifecycle
    /// Shared across every run (the actor is a reference, so struct copies captured into run Tasks share
    /// one gate): only one foreground run drives the GUI at a time. See `ForegroundFocusGate`.
    let foregroundFocusGate = ForegroundFocusGate()
    /// Set by the overlay model; fired when any hosted request in a turn returns 401 so the app can
    /// surface re-login. Optional, so existing construction sites are unaffected.
    var onAuthenticationRequired: (@MainActor @Sendable () -> Void)?

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

    /// Bridges the struct's main-actor auth-expiry hook to the inference client's off-actor callback,
    /// hopping back to the main actor. Nil when no hook is set, so the client stays silent.
    private func backendAuthExpiryHook() -> (@Sendable () -> Void)? {
        guard let onAuthenticationRequired else { return nil }
        return { Task { @MainActor in onAuthenticationRequired() } }
    }

    func handleSubmittedCommand(
        _ command: String,
        context: UserQueryCommandContext?
    ) async -> UserQueryCommandHandlingResult {
        let traceID = "user-query-\(UUID().uuidString)"
        let conversationID = context?.conversation.id ?? traceID
        logSubmittedCommand(command, traceID: traceID, conversationID: conversationID, context: context)
        return await continueHandlingNonVisualizationCommand(
            command: command,
            context: context,
            traceID: traceID,
            conversationID: conversationID
        )
    }

    private func continueHandlingNonVisualizationCommand(
        command: String,
        context: UserQueryCommandContext?,
        traceID: String,
        conversationID: String
    ) async -> UserQueryCommandHandlingResult {
        // Redact PII/secrets before the command becomes the task goal: the hosted planner forwards the
        // goal to the backend on every step, and the goal is the only user text this route sends to a
        // model, so redacting here keeps secrets on-device without touching the planner.
        let redactedCommand = AIHarnessRedactor().redact(command, surface: .modelContext).redactedText
        let harnessRequest = Self.harnessRequest(command: redactedCommand, context: context)
        let genericPreparedTurn = await genericHarnessLifecycle.prepareUserQueryTurn(
            request: harnessRequest,
            pointerTask: context?.conversation,
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
                agentID: genericPreparedTurn.agent.id,
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
            conversationID: genericPreparedTurn.conversation.id,
            agentID: genericPreparedTurn.agent.id,
            preparedTurnMetadata: Self.genericHarnessMetadata(preparedTurn: genericPreparedTurn),
            visualize: context?.agentVisualizationChanged,
            progress: Self.progressLabeler(context?.spawnProgressChanged),
            answerStream: Self.answerDeltaSink(context?.spawnProgressChanged)
        )
    }

    func continueApprovedCommand(
        conversationID: String,
        context: UserQueryCommandContext?
    ) async -> UserQueryCommandHandlingResult? {
        // Interactive resume (gate approval, tap Resume): let the understanding boundary pick foreground
        // vs. background as it would for any turn.
        await resumeExistingTask(conversationID: conversationID, context: context, tracePrefix: "user-query-resume")
    }

    /// Conversation-level controls — pause, gate approval, follow-up, resume — act on the conversation's
    /// root agent, the parent that manages any subagents (a subagent's gate or follow-up is the parent's to
    /// handle). For a single-agent conversation the root agent's id equals the conversation id; resolving
    /// it explicitly keeps these correct once subagents exist.
    private func managingAgentID(forConversation conversationID: String) async -> String {
        await genericHarnessLifecycle.coordinator.rootAgents(conversationID: conversationID).first?.id ?? conversationID
    }

    func injectFollowUp(conversationID: String, text: String) async -> Bool {
        let agentID = await managingAgentID(forConversation: conversationID)
        guard let task = await genericHarnessLifecycle.agentState(agentID: agentID) else { return false }
        switch task.status {
        case .running, .resuming:
            // A live loop drains the queue. The returned flag is authoritative — false means the loop
            // ended in the meantime, so the caller resumes the task instead (which drains it on start).
            return await genericHarnessLifecycle.coordinator.enqueueUserMessage(agentID: agentID, text: text)
        case .waitingForPermission:
            // Blocked on the user at a permission gate. Queue the follow-up WITHOUT resuming, so the gate
            // is preserved; it drains when the user approves and the loop resumes. Report accepted so the
            // caller does not start a competing run that would clear the pending gate.
            _ = await genericHarnessLifecycle.coordinator.enqueueUserMessage(agentID: agentID, text: text)
            return true
        default:
            // No live or gated loop (paused, timedOut, completed, failedSafe, interrupted, cancelled, or a
            // clarification awaiting an answer): the caller resumes/answers, and that run drains the queue.
            return false
        }
    }

    func autoResumeCommand(
        conversationID: String,
        context: UserQueryCommandContext?
    ) async -> UserQueryCommandHandlingResult? {
        // Unattended relaunch resume: force background so it never raises an app or moves the cursor.
        await resumeExistingTask(
            conversationID: conversationID,
            context: context,
            tracePrefix: "user-query-autoresume",
            forcedExecutionPreference: .background
        )
    }

    /// Task metadata keys for the drive target resolved on the first run, so a resume drives the same app.
    static let driveTargetAppMetadataKey = "harness.driveTargetApp"
    static let driveTargetBundleMetadataKey = "harness.driveTargetBundleID"

    /// Shared resume path: re-run an existing task's persisted goal as a fresh loop (its stored world
    /// model and history carry the work forward), pinned to the target the task resolved on its first run.
    /// Returns nil when the task is unknown or has no goal.
    private func resumeExistingTask(
        conversationID: String,
        context: UserQueryCommandContext?,
        tracePrefix: String,
        forcedExecutionPreference: ExecutionPreference? = nil
    ) async -> UserQueryCommandHandlingResult? {
        let agentID = await managingAgentID(forConversation: conversationID)
        guard let task = await genericHarnessLifecycle.agentState(agentID: agentID),
              !task.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        var forcedDriveTarget: (appName: String, bundleIdentifier: String?)?
        if let app = task.metadata[Self.driveTargetAppMetadataKey], !app.isEmpty {
            let bundle = task.metadata[Self.driveTargetBundleMetadataKey]
            forcedDriveTarget = (app, (bundle?.isEmpty == false) ? bundle : nil)
        }
        return await runHarnessLoop(
            command: task.goal,
            traceID: "\(tracePrefix)-\(UUID().uuidString)",
            conversationID: task.conversationID,
            agentID: task.id,
            preparedTurnMetadata: [:],
            forcedExecutionPreference: forcedExecutionPreference,
            forcedDriveTarget: forcedDriveTarget,
            visualize: context?.agentVisualizationChanged,
            progress: Self.progressLabeler(context?.spawnProgressChanged),
            answerStream: Self.answerDeltaSink(context?.spawnProgressChanged)
        )
    }

    /// The single bridge from the harness's lifecycle status to the notch row's status. Exhaustive on
    /// `HarnessAgentStatus` so a new harness case is a compile error here rather than silently collapsing
    /// to `.failed`. `.running`/`.resuming` only appear if a run returned still-runnable (a bug); they map
    /// to the retryable `.timedOut` so the row never looks live with no loop behind it.
    static func userQueryStatus(forHarness status: HarnessAgentStatus?) -> UserQueryConversationStatus {
        switch status {
        case .completed: return .completed
        case .paused: return .paused
        case .timedOut: return .timedOut
        case .interrupted: return .interrupted
        case .waitingForUser: return .waitingForClarification
        case .waitingForPermission: return .waitingForPermission
        case .failedSafe, .cancelled: return .failed
        case .running, .resuming, .none: return .timedOut
        }
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

    /// Adapt the spawn-progress callback into a delta sink for the streamed final answer: each chunk is
    /// forwarded as an `answerDelta` so the model accumulates it onto the task's detail (the chin and the
    /// open row stream it), rather than replacing the status line the way a `label` update does.
    private static func answerDeltaSink(
        _ spawnProgressChanged: (@MainActor @Sendable (UserQuerySpawnProgressUpdate) -> Void)?
    ) -> (@MainActor @Sendable (String) -> Void)? {
        guard let spawnProgressChanged else { return nil }
        return { delta in
            spawnProgressChanged(UserQuerySpawnProgressUpdate(answerDelta: delta))
        }
    }

    func pauseCommand(conversationID: String) async -> Bool {
        let agentID = await managingAgentID(forConversation: conversationID)
        return await genericHarnessLifecycle.pauseAgent(
            agentID: agentID,
            reason: "User query paused task"
        ) != nil
    }

    func approvePermissionGate(conversationID: String, alwaysAllow: Bool) async -> Bool {
        let agentID = await managingAgentID(forConversation: conversationID)
        return await genericHarnessLifecycle.approvePermissionGate(
            agentID: agentID,
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
        conversationID: String,
        agentID: String,
        preparedTurnMetadata: [String: String],
        forcedExecutionPreference: ExecutionPreference? = nil,
        forcedDriveTarget: (appName: String, bundleIdentifier: String?)? = nil,
        visualize: (@MainActor @Sendable (AgentVisualizationPlan) -> Void)? = nil,
        progress: (@MainActor @Sendable (String) -> Void)? = nil,
        answerStream: (@MainActor @Sendable (String) -> Void)? = nil
    ) async -> UserQueryCommandHandlingResult {
        // A resume pins the task's original target, so it can drive that app even when it (or nothing) is
        // frontmost — which is the common case right after a relaunch. Resolve the frontmost app up front
        // (no guard yet): its name feeds the understanding prompt, and neither a conversational turn nor an
        // app-less action turn needs an app at all — only a GUI-driving turn below does.
        let frontmost = MacWindowResolver().frontmostUserAppTarget()
        let frontmostAppName = frontmost?.appName ?? forcedDriveTarget?.appName ?? "the frontmost app"

        // The backend is needed by BOTH paths — the conversational responder and the action loop — so it
        // is built before the turn is classified.
        guard var configuration = try? DonkeyBackendInferenceConfiguration.fromEnvironment() else {
            return await failHarnessRun(
                command: command,
                response: "The vision backend isn't configured (set DONKEY_WEB_BASE_URL), so I couldn't navigate by vision.",
                reason: "visionBackendUnavailable",
                appName: frontmostAppName,
                traceID: traceID,
                conversationID: conversationID,
                agentID: agentID,
                preparedTurnMetadata: preparedTurnMetadata
            )
        }
        // One client serves the whole turn — understanding, planner, and hosted adapters all share it —
        // so wiring the auth-expiry hook here catches a 401 on any of those paths, even the ones that
        // swallow the thrown error. Stamping the conversation here means every billable call this turn
        // makes carries the id, so backend usage records group under the conversation.
        configuration.conversationID = conversationID
        let backend = DonkeyBackendInferenceClient(
            configuration: configuration,
            onAuthenticationRequired: backendAuthExpiryHook()
        )

        // The thread is the COMPLETE, human-readable record of the turn (like ChatGPT/Claude), written
        // live as markdown. It is opened here — before the very first model call — so the trace manager
        // can record even the pre-loop understanding decision into it. The header uses the frontmost app
        // (the app in front when the user asked); the resolved drive target is shown in the planning
        // block below.
        let transcript = ConversationTranscript(id: conversationID)
        transcript.begin(id: conversationID, app: frontmostAppName)
        transcript.userMessage(command)
        // The turn-trace manager: the single sink every model call and every executed step reports to,
        // so the whole decision path — prompts, replies, sensing modality, and per-call timing — is
        // traceable in the thread file. The model boundaries hold it as `any HarnessTurnTracing`.
        let trace = HarnessTurnTrace(transcript: transcript)

        // Understand the request ONCE before the loop: restate the goal, identify the target app,
        // extract parameters, and decide whether to clarify. Degrades to driving the raw command when
        // it returns nil — or when the call outlives its deadline — so a backend hiccup never
        // dead-ends or silently stalls the run.
        let understandingBoundary = HostedHarnessRequestUnderstanding(backend: backend, trace: trace)
        let skillSelectionCatalog = BuiltInLocalAppSkillPacks.skillSelectionCatalog()

        // A fresh turn — no assistant reply yet in this conversation — lets a `.converse` reply stream
        // straight out of the understanding boundary in ONE round trip: the same call that types the turn
        // also generates the reply, and the field extractor streams it to the chin live. A follow-up may
        // lean on earlier context the understanding boundary never sees, so it uses the non-streaming
        // understanding and routes any converse reply through the context-aware responder below.
        let priorEvents = await genericHarnessLifecycle.conversationStore.events(conversationID: conversationID)
        let isFreshTurn = !priorEvents.contains { $0.role == .assistant }
        let understanding = await AIDeadline.race(seconds: Self.understandingTimeoutSeconds) {
            if isFreshTurn {
                return await understandingBoundary.understandStreaming(
                    command: command,
                    frontmostAppName: frontmostAppName,
                    skillCatalog: skillSelectionCatalog,
                    onReplyDelta: answerStream ?? { _ in }
                )
            }
            return await understandingBoundary.understand(
                command: command,
                frontmostAppName: frontmostAppName,
                skillCatalog: skillSelectionCatalog
            )
        }

        // TWO-TIER SPLIT. A turn the understanding boundary typed `.converse` (a greeting, a thanks, a
        // question answerable in words) never touches the action machinery: it is answered by a responder
        // that holds no tools, so a misread greeting can't run a command. Gated on the typed enum, never
        // the user's words. Everything below — the input/frontmost guards and the whole guarded loop —
        // runs only for an actionable turn. (A nil understanding means the classifier was unavailable;
        // it degrades to the action path against the raw command, the conservative existing behavior.)
        if understanding?.turnKind == .converse {
            return await runConversationalReply(
                command: command,
                frontmostAppName: frontmostAppName,
                backend: backend,
                transcript: transcript,
                trace: trace,
                traceID: traceID,
                conversationID: conversationID,
                agentID: agentID,
                preparedTurnMetadata: preparedTurnMetadata,
                inlineReply: understanding?.conversationReply,
                inlineReplyAlreadyStreamed: isFreshTurn,
                answerStream: answerStream
            )
        }

        // ACTION PATH from here down — a conversational turn already returned above. Resolve which app, if
        // any, this turn drives: a resume pins its original target; otherwise the understanding boundary's
        // typed surface decides. An `.appless` turn (artifact/system work — make an image, fetch the web,
        // change a setting) and a turn with nothing in front both resolve to nil and run APP-LESS: the
        // planner works through shell/web/file/generative tools with no app to focus and no pointer to move,
        // so the run is never blocked on a missing frontmost window the way a GUI task would be.
        let driveTarget: (appName: String, bundleIdentifier: String?)?
        if let forcedDriveTarget {
            driveTarget = forcedDriveTarget
        } else {
            // A frontmost candidate with no resolvable name is no drive target — same as nothing in front.
            let frontmostTarget: (appName: String, bundleIdentifier: String?)? = frontmost.flatMap { candidate in
                candidate.appName.map { (appName: $0, bundleIdentifier: candidate.bundleIdentifier) }
            }
            driveTarget = Self.resolveDriveTarget(
                understanding: understanding,
                frontmost: frontmostTarget
            )
        }

        // Input permission gates a GUI-driving run only: that path clicks and types. An app-less run moves
        // no pointer and presses no keys, so it proceeds without the grant. Gated on the typed surface
        // (driveTarget == nil), never the user's words.
        if driveTarget != nil, !permissionPolicy.allowedCapabilities.contains(.input) {
            return await failHarnessRun(
                command: command,
                response: "Vision navigation needs input permission, which isn't granted.",
                reason: "inputNotPermitted",
                appName: frontmostAppName,
                traceID: traceID,
                conversationID: conversationID,
                agentID: agentID,
                preparedTurnMetadata: preparedTurnMetadata,
                transcript: transcript
            )
        }
        if let restated = understanding?.restatedGoal, !restated.isEmpty {
            progress?(restated)
        }

        // An app-less run carries an empty app name and no bundle id; the see/act providers below resolve
        // no window and the planner reaches for app-less tools instead.
        let appName = driveTarget?.appName ?? ""
        let bundleIdentifier = driveTarget?.bundleIdentifier
        // Pin the resolved target on the task so a later resume drives the same app (see forcedDriveTarget).
        // An app-less run records an empty name, so a resume re-derives the surface and stays app-less.
        await genericHarnessLifecycle.coordinator.recordMetadata(agentID: agentID, [
            Self.driveTargetAppMetadataKey: appName,
            Self.driveTargetBundleMetadataKey: bundleIdentifier ?? ""
        ])

        // App guidance is the drive app's own playbook; an app-less run has no app, so it loads none.
        let appGuidance = driveTarget != nil
            ? BuiltInLocalAppSkillPacks.appOperatingGuidance(
                forApp: appName,
                bundleIdentifier: bundleIdentifier
            )
            : nil

        // Preload the full guides for the capability skills the understanding boundary picked for this task
        // (`relevantSkillIDs`) — the same "preload the right playbook" treatment app skills get via
        // appGuidance, generalized so a media/pdf/data task arrives with its skill in hand instead of
        // depending on the planner to discover and load it. Skip the drive-target app's own skill (already
        // in appGuidance) and cap the count so the prompt stays bounded; anything else stays loadable from
        // the catalog via skill.load.
        let appSkillID = driveTarget != nil
            ? BuiltInLocalAppSkillPacks.appSkillDescriptor(
                forApp: appName,
                bundleIdentifier: bundleIdentifier
            )?.id.lowercased()
            : nil
        let preloadedSkillGuides: [String] = (understanding?.relevantSkillIDs ?? [])
            .filter { $0.lowercased() != appSkillID }
            .prefix(2)
            .compactMap { BuiltInLocalAppSkillPacks.skillGuidance(forID: $0) }

        // Drive the frontmost app through the GENERIC HARNESS LOOP: the harness re-plans after every
        // observation, consulting `HostedHarnessStepPlanner` (the model boundary) to pick the next
        // tool. The planner chooses how to SEE (ax.observe vs. vision.capture) and how to ACT (ax.click,
        // vision.click, keyboard/text input, generated AppleScript), or `run.complete` when done —
        // vision is just one tool among many. The always-on warm-cache monitor is suspended for the
        // duration so it never races us on a parse.
        let analyzer = HostedDebugUIInspectionAnalyzer(backend: backend)

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
        // Claude-style rolling compaction: feeds the planner a bounded conversation view each step and
        // writes a summary event back when the conversation outgrows the threshold.
        let compactionDriver = ConversationCompactionDriver(
            conversationStore: genericHarnessLifecycle.conversationStore,
            coordinator: genericHarnessLifecycle.coordinator,
            compactor: genericHarnessLifecycle.compactor,
            generate: { await textGenerator.generate($0) }
        )
        // Generative image editing/generation behind image.edit / image.generate. Provider stays
        // unset so the backend routes kind=image to its configured image model; this adapter only
        // encodes inputs and writes the returned files.
        let imageGenerator = HostedImageGenerator(backend: backend)
        harnessServices.imageGenerator = { request in
            await imageGenerator.generate(request)
        }
        // Same boundary, multimodal arm: transcribe/translate/caption a local audio or video file
        // (the media skill extracts audio and reaches for this to subtitle a clip).
        harnessServices.mediaGenerator = { prompt, fileURL, mimeType in
            await textGenerator.generate(prompt, attachmentPath: fileURL, mimeType: mimeType)
        }
        // Web research goes through the backend on the service-account credential — no key in the
        // app. Search uses Google Search grounding; fetch reads a page and returns clean markdown
        // (nav/ads/boilerplate stripped server-side) so the model gets the article, not raw HTML.
        let hostedWebSearch = HostedWebSearch(backend: backend)
        let hostedWebFetch = HostedWebFetch(backend: backend)
        let hostedWebAutomate = HostedWebAutomate(backend: backend)
        harnessServices.webSearcher = { query in await hostedWebSearch.search(query) }
        harnessServices.webFetcher = { url in await hostedWebFetch.fetch(url) }
        harnessServices.webAutomator = { request in await hostedWebAutomate.run(request) }
        // File understanding behind files.describe: OCR + dimensions for images/screenshots, text for
        // PDFs, Foundation content for text files. Cached per file so the describe pass and any later
        // operation reuse one understanding.
        harnessServices.fileUnderstanding = { url in await FileUnderstandingProvider.understand(url) }
        let granted = Self.userQueryGrantedPermissions
        let replacedBuiltIns: Set<String> = ["screen.observe", "elements.get", "element.perform", "text.enter", "keyboard.press"]
        let builtInDescriptors = BuiltInHarnessToolCatalog.descriptors.filter { descriptor in
            !replacedBuiltIns.contains(descriptor.name)
                && Set(descriptor.requiredPermissions).isSubset(of: granted)
        }
        let registry = HarnessToolRegistry(
            tools: BuiltInHarnessToolExecutors.tools(descriptors: builtInDescriptors, services: harnessServices)
        )
        // Background is the default operating mode: the agent acts on a safe, on-active-Space window
        // without raising the app or moving the cursor — the AX action lane for advertised controls, the
        // pid-routed event-post lane for coordinate/scroll/drag/keystroke input. The understanding
        // boundary flips this to foreground only when the turn's point is for the user to watch. When
        // understanding is unavailable we still default to background (each lane degrades to foreground on
        // its own when an action can't be delivered that way).
        // An unattended auto-resume forces background so it never raises an app or moves the cursor while
        // the user is away; an interactive turn lets the understanding boundary decide.
        let executionPreference = forcedExecutionPreference ?? understanding?.executionPreference ?? .background
        // One shared, mutable target the three see/act providers read per call: an observe/capture step
        // that names an `app:` retargets it, and every later act/scroll/keystroke follows to that app.
        // Seeded with the run's resolved app — empty on an app-less run, which acquires its first app the
        // moment the planner observes one by name. This is what unbinds the run from a single pinned app.
        let targetContext = HarnessTargetContext(appName: appName, bundleIdentifier: bundleIdentifier)
        let axProvider = AXComputerUseToolProvider(
            target: targetContext,
            executionPreference: executionPreference
        )
        let visionProvider = VisionComputerUseToolProvider(
            target: targetContext,
            executionPreference: executionPreference,
            analyzer: analyzer
        )
        let pointerProvider = PointerComputerUseToolProvider(
            target: targetContext,
            executionPreference: executionPreference
        )
        // Native music playback (MusicKit): search/play/transport/status with no Music-app GUI or
        // AppleScript. Declares no harness permissions — MusicKit runs its own consent flow.
        let musicProvider = MusicPlaybackToolProvider(service: MusicKitPlaybackService())
        // Register the AX/vision/pointer/music see/act tools only when this turn holds their
        // permissions, mirroring the built-in descriptor filter so the planner is never offered a
        // tool it can't run.
        for tool in axProvider.makeTools() + visionProvider.makeTools() + pointerProvider.makeTools()
            + musicProvider.makeTools()
        where Set(tool.descriptor.requiredPermissions).isSubset(of: granted) {
            await registry.register(tool)
        }
        let runtime = GenericHarnessRuntime(
            coordinator: genericHarnessLifecycle.coordinator,
            registry: registry
        )
        let plannerDescriptors = await registry.descriptors()
        // Every step, surface the other windows on screen (all apps/displays) to the planner so a
        // request that lives in a window the user isn't looking at can be found and switched to. Donkey's
        // own windows are filtered out by bundle id so the agent never targets its own overlay.
        let ownBundleID = Bundle.main.bundleIdentifier
        // Recall durable operating lessons distilled from earlier runs with a related goal, so a trap the
        // agent already hit once (a broad search that timed out, a wrong tool) steers this run from its
        // first step. Computed once here against the restated goal; nil when nothing relevant was learned.
        let restatedGoal = understanding?.restatedGoal
        let lessonGoal = (restatedGoal?.isEmpty == false ? restatedGoal : nil) ?? command
        let recalledLessons = RunLessonMemory.recall(forGoal: lessonGoal, store: .shared)
        let planner = HostedHarnessStepPlanner(
            backend: backend,
            descriptors: plannerDescriptors,
            appName: appName,
            appGuidance: appGuidance,
            understanding: understanding,
            skillCatalog: Self.installedSkillCatalog(),
            preloadedSkillGuides: preloadedSkillGuides,
            recalledLessons: recalledLessons,
            trace: trace,
            openWindows: {
                MacWindowResolver().enumerateCandidates().filter { candidate in
                    guard let ownBundleID, let candidateBundle = candidate.bundleIdentifier else { return true }
                    return candidateBundle.caseInsensitiveCompare(ownBundleID) != .orderedSame
                }
            },
            // Attach a compressed screenshot of the user's frontmost window to every step so a multimodal
            // planner always sees the screen, not just AX/vision text. Best-effort: a capture failure
            // returns nil and the step proceeds text-only, never breaking the planner.
            captureScreenshot: {
                guard let target = MacWindowResolver().frontmostUserAppTarget(),
                      let shot = try? await ScreenCaptureKitWindowScreenshotCapturer().capture(target: target) else {
                    return nil
                }
                return ScreenshotCompression.compressedForModel(shot).base64DataURL
            }
        )
        _ = await genericHarnessLifecycle.coordinator.startRunning(
            agentID: agentID,
            reason: "User query harness run"
        )

        VisionGroundingLog.emit(
            "start traceID=\(traceID) app=\(appName) goal=\"\(command)\""
        )
        let e2eStartMS = Self.uptimeMilliseconds()
        // Realtime per-step feedback: narrate every step through the spawn cursor's label (the
        // planner's one-line reason, falling back to the tool's own summary), and after each step that
        // physically moved the pointer (a click), animate the overlay cursor traveling to that exact
        // target, so the visualization tracks what the harness is actually doing.
        //
        // The thread is the COMPLETE session record: the turn's upfront planning (or its absence) is
        // part of the conversation, not just an internal step. A follow-up turn (clarification
        // answer, permission grant) appends its own planning block mid-thread.
        if let understanding {
            transcript.planning(
                goal: understanding.restatedGoal,
                targetApp: understanding.targetAppName,
                parameters: understanding.parameters,
                successCriteria: understanding.successCriteria,
                clarification: understanding.needsClarification ? understanding.clarifyingQuestion : nil
            )
        } else {
            transcript.systemEvent("Understanding was unavailable (timed out or failed); driving the raw command.")
        }
        VisionGroundingLog.emit("conversation traceID=\(traceID) path=\(transcript.conversationPath)")

        // On a background turn the agent acts without taking over the user's cursor, so the cosmetic
        // traveling cursor is suppressed and progress is narrated through the notch text only. (AX-lane
        // background actions already report no screen point, so they produce no cursor plan; this also
        // covers background coordinate/scroll/drag posts, which move no real pointer.) The overlay never
        // drives real input either way — realPointerMoved stays false.
        let suppressBackgroundCursorPlayback = executionPreference == .background

        // Always set onStep so every turn is recorded; the overlay narration/cursor is layered on top
        // when a UI is attached.
        let onStep: (@Sendable (HarnessStepExecutionResult) async -> Void)? = { (step: HarnessStepExecutionResult) async -> Void in
            await MainActor.run {
                let narration = Self.stepNarration(for: step, planner: planner)
                if let result = step.toolResult {
                    // One grouped block per step through the trace manager: the model's full thought
                    // summary (persisted here and nowhere else, so the planning context stays bounded),
                    // its warm one-line narration, the action with its input, the output, any planning retries
                    // hit while choosing this step, and the timing the manager attaches — decision time
                    // vs. tool time plus which sensing modality the step used. The overlay/progress gets
                    // only the clipped one-line narration below.
                    trace.recordStep(
                        number: step.task.toolHistory.count,
                        thought: planner.lastThinking,
                        narration: planner.lastNarration,
                        tool: result.toolName,
                        input: step.task.toolHistory.last?.call.input ?? [:],
                        status: result.status.rawValue,
                        output: result.summary,
                        planningErrors: planner.lastPlanningErrors,
                        modality: Self.sensingModality(forTool: result.toolName),
                        cacheHit: result.metadata["usedCache"].map { $0 == "true" },
                        elementCount: result.metadata["elementCount"].flatMap(Int.init)
                    )
                } else {
                    // No tool executed (the call never ran), but planning failures are still part of
                    // the session and must be readable in the thread — a step that ends in
                    // run.failSafe is otherwise a mystery.
                    for planningError in planner.lastPlanningErrors {
                        transcript.error(planningError)
                    }
                }
                // Every step narrates through the spawn label (a lightweight text update), so the user
                // is kept informed even on steps that don't move the pointer — observe, shell, wait,
                // verify. The cursor itself only travels (a heavier window-animating overlay playback)
                // on steps that actually moved it; re-running that playback every step thrashes window
                // layout, so it stays gated to real pointer moves.
                if let progress, let narration {
                    progress(narration)
                }
                // The animated cursor playback is cosmetic and separate from the real input. It animates
                // an overlay panel's window frame, which can re-enter AppKit's layout cycle on some macOS
                // builds; this escape hatch turns the playback off (text narration still updates) so a
                // run can proceed without it.
                guard !Self.cursorVisualizationDisabled else { return }
                // Background turns narrate through the notch only; no traveling cursor on a window the
                // user isn't driving. Text narration above still fires every step.
                guard !suppressBackgroundCursorPlayback else { return }
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
        // A foreground run waits its turn for window focus so concurrent foreground turns don't fight
        // over the frontmost app; background runs route by pid and never take the gate.
        let holdsForegroundFocus = executionPreference == .foreground
            ? await foregroundFocusGate.acquire()
            : false
        let runSteps = await runtime.run(agentID: agentID, planner: planner, compactor: compactionDriver, onStep: onStep)
        if holdsForegroundFocus {
            await foregroundFocusGate.release()
        }

        let finalTask = await genericHarnessLifecycle.coordinator.agent(id: agentID)
        let finalStatus = finalTask?.status
        let completed = finalStatus == .completed
        let awaitingUser = finalStatus == .waitingForUser
        let awaitingPermission = finalStatus == .waitingForPermission
        let outcomeReason = completed ? "ok"
            : (awaitingUser ? "awaitingUser"
            : (awaitingPermission ? "awaitingPermission"
            : (finalStatus == .failedSafe ? "failedSafe"
            : (finalStatus == .timedOut ? "timedOut"
            : (finalStatus == .paused ? "paused" : "stopped")))))
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

        // Close the per-step trace with a compact whole-turn timing line, so the run's total cost and
        // time-to-first-action sit at the foot of the thread next to the per-step breakdown.
        trace.recordTurnTiming(e2eTotalMS: e2eTotalMS, timeToFirstActionMS: timeToFirstActionMS, steps: turns)

        // Record the assistant's final answer to close the turn, then write a compacted, structured
        // thread summary. A deterministic summary lands immediately; an LLM-written one replaces it in
        // the background so the result isn't delayed by the summary call.
        let finalDetail = runSteps.last?.toolResult?.summary ?? finalTask?.goal ?? command
        transcript.systemEvent("Run finished: \(outcomeReason) after \(turns) step(s).")
        transcript.response(finalDetail)
        transcript.writeSummary(Self.deterministicThreadSummary(
            command: command, app: appName, outcome: outcomeReason, steps: runSteps, finalDetail: finalDetail
        ))
        let threadText = (try? String(contentsOfFile: transcript.conversationPath, encoding: .utf8)) ?? ""
        if !threadText.isEmpty {
            Task.detached {
                let prompt = """
                Summarize this conversation thread into a compact markdown brief with these exact \
                sections (omit a section only if truly empty): ## Goal, ## Progress, ## Key Decisions, \
                ## Next Steps, ## Critical Context. Be concrete and short.

                THREAD:
                \(threadText)
                """
                let summaryStartedAt = RunTraceTimestamp.now()
                let enhanced = await textGenerator.generate(prompt)
                trace.recordModelCall(TraceModelCall(
                    kind: .conversationSummary,
                    prompt: prompt,
                    response: enhanced ?? "<no output>",
                    status: (enhanced?.isEmpty == false) ? .ok : .empty,
                    startedAt: summaryStartedAt,
                    endedAt: .now()
                ))
                if let enhanced, !enhanced.isEmpty {
                    transcript.writeSummary(enhanced)
                }
            }
        }

        // Self-improving loop: distill this run into one durable, general operating lesson and store it,
        // so a future turn with a related goal recalls it (see the recall at planner construction above)
        // and avoids a trap this run already paid for. Reuses the agent-memory approval + persistence
        // path. Gated to runs that plausibly taught something — a non-clean outcome, or a run long enough
        // to have taken a wrong turn — so a short clean success doesn't spend a model call to learn
        // nothing. Detached so it never delays the user-facing result.
        let shouldDistillLesson = outcomeReason != "ok" || turns >= 4
        if shouldDistillLesson, !threadText.isEmpty {
            Task.detached {
                let prompt = DonkeyPrompts.runLessonDistillation(
                    goal: lessonGoal, outcome: outcomeReason, thread: threadText
                )
                let lessonStartedAt = RunTraceTimestamp.now()
                let raw = await textGenerator.generate(prompt) ?? ""
                trace.recordModelCall(TraceModelCall(
                    kind: .lessonDistillation,
                    prompt: prompt,
                    response: raw.isEmpty ? "<no output>" : raw,
                    status: raw.isEmpty ? .empty : .ok,
                    startedAt: lessonStartedAt,
                    endedAt: .now()
                ))
                guard let distillation = RunLessonMemory.parse(raw),
                      let proposal = RunLessonMemory.proposal(
                          for: distillation,
                          goal: lessonGoal,
                          outcome: outcomeReason,
                          traceID: traceID,
                          now: .now()
                      )
                else { return }
                _ = try? SQLiteAgentMemoryStore.shared?.appendApprovedProposal(proposal, decidedAt: .now())
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
            await coordinatorRegistry.finish(conversationID: conversationID)
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
            await coordinatorRegistry.finish(conversationID: conversationID)
            logHandlingResult(result, stage: "harness", hint: "Stopped at a permission gate.")
            return result
        }

        let conversationMessage = finalTask?.toolHistory.last { $0.call.name == "conversation.respond" }
            .flatMap { $0.call.input["response"] ?? $0.call.input["message"] }
            .flatMap { $0.isEmpty ? nil : $0 }
        var response: String
        if let conversationMessage {
            response = conversationMessage
        } else if completed {
            response = planner.lastNarration ?? "Done."
        } else {
            // The run did not complete. Echoing `planner.lastNarration` here surfaces the last
            // forward-looking "I will…" line, which reads as a silent stop — the exact "it didn't tell me
            // why" failure. Explain what actually went wrong, in plain language, from the real step errors.
            var explained: String?
            if let prompt = Self.failureExplanationPrompt(goal: command, steps: runSteps) {
                let generated = await textGenerator.generate(prompt)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let generated, !generated.isEmpty { explained = generated }
            }
            response = explained
                ?? planner.lastNarration
                ?? "I tried operating \(appName) but couldn't confirm the goal was finished."
        }

        // Stream the assistant's final reply token-by-token into the notch (the chin and the open task
        // row) whenever the turn produced a real text answer. It is re-composed from the harness's drafted
        // answer so it stays grounded; the streamed text becomes the authoritative reply, and a failed
        // or empty stream falls back to the draft already computed above. Only conversational answers
        // stream — an action that merely finished ("Done.") has no message worth typing out. A respond-only
        // turn (e.g. a plain "hi") never reaches `completed`, so gate on the answer itself, not completion.
        if let conversationMessage, let answerStream {
            let prompt = Self.finalAnswerPrompt(goal: command, draftAnswer: conversationMessage)
            if let streamed = await textGenerator.generateStreaming(prompt, onDelta: answerStream),
               !streamed.isEmpty {
                response = streamed
            }
        }
        let decision = AppHarnessDecision(
            kind: .respond,
            message: response,
            traceID: traceID,
            metadata: ["structuredDecision": "true", "router": "harness", "harness.completed": String(completed)]
        )
        // The runtime sets the task's terminal status authoritatively (run.complete, a stall fail-safe,
        // the step-ceiling timeout, a user pause, or a gate), so the row status maps straight from it.
        // Defensive only: if a run somehow returned still-runnable, mark it timed out (retryable) rather
        // than leaving a row that looks live with no loop behind it.
        await genericHarnessLifecycle.coordinator.timeOutIfRunnable(
            agentID: agentID,
            reason: "User query harness run returned without a terminal status"
        )
        // A turn whose terminal step was talking to the user (conversation.respond) is a conversational
        // back-and-forth, not an app action — surface it as `.chatting` so the reply lands in the chin and
        // reads as a message. We key off the typed tool name, never the user's words. This matters because
        // a respond-only turn (a plain "hi") leaves the agent runnable; the defensive `timeOutIfRunnable`
        // above flips it to `.timedOut`, which the chin doesn't surface — so the reply would otherwise be
        // dropped. When the run actually finished an action, keep the runtime's terminal status.
        let answeredConversationally = conversationMessage != nil
        let threadStatus: UserQueryConversationStatus = (answeredConversationally && !completed)
            ? .chatting
            : Self.userQueryStatus(forHarness: finalStatus)
        // A run that failed safe for lack of credits carries a typed flag the notch reads to show the
        // reload CTA banner (instead of inferring the credit state from the narration text).
        var responseMetadata = [
            "appHarness.decision": AppHarnessDecisionKind.respond.rawValue
        ]
        if planner.lastFailureRequiresCreditReload {
            responseMetadata[UserQueryConversationMetadataKey.creditReloadRequired] = "true"
        }
        let result = UserQueryCommandHandlingResult(
            status: (completed || answeredConversationally) ? .completed : .failedSafe,
            threadStatus: threadStatus,
            decision: decision,
            summary: response,
            traceID: traceID,
            metadata: baseMetadata.merging(responseMetadata) { _, new in new }
        )
        await coordinatorRegistry.finish(conversationID: conversationID)
        logHandlingResult(
            result,
            stage: "harness",
            hint: completed ? "Operated \(appName)." : "Harness run stopped: \(outcomeReason)."
        )
        return result
    }

    /// Build the prompt that turns a not-completed run's real step errors — which for yt-dlp/ffmpeg are
    /// buried under page-long signed URLs — into a one-or-two-sentence plain-language "why" for the user.
    /// Pure and Sendable; the caller runs the model inline so the misleading forward-looking narration the
    /// notch showed before is replaced by an actual explanation. Returns nil when no step failed.
    static func failureExplanationPrompt(goal: String, steps: [HarnessStepExecutionResult]) -> String? {
        let failures = steps.compactMap { step -> String? in
            guard let result = step.toolResult,
                  result.status == .failed || result.status == .invalidInput,
                  !result.summary.isEmpty else { return nil }
            let oneLine = result.summary.replacingOccurrences(of: "\n", with: " ")
            return "- \(result.toolName): \(String(oneLine.prefix(300)))"
        }
        guard !failures.isEmpty else { return nil }
        return """
        A macOS task did not finish. In ONE or TWO plain sentences, tell the user what was attempted and \
        why it did not finish, then the single most likely next step. Be concrete but human: no URLs, no \
        file paths, no code, no stack traces, no apology filler.

        GOAL: \(goal)
        ERRORS (most recent last):
        \(failures.suffix(4).joined(separator: "\n"))
        """
    }

    /// The conversational arm of the two-tier split: a turn typed `.converse` is answered here, with no
    /// action loop, no tools, no world model, and no permission gate. The reply streams into the notch
    /// chin token-by-token and the turn completes as a chat message. Because this path is reached only on
    /// a typed `.converse` classification and the responder holds no tools, a misread greeting can never
    /// produce a command — the safety is structural, not a matter of planner discipline.
    @MainActor
    private func runConversationalReply(
        command: String,
        frontmostAppName: String,
        backend: DonkeyBackendInferenceClient,
        transcript: ConversationTranscript,
        trace: HarnessTurnTrace,
        traceID: String,
        conversationID: String,
        agentID: String,
        preparedTurnMetadata: [String: String],
        inlineReply: String?,
        inlineReplyAlreadyStreamed: Bool,
        answerStream: (@MainActor @Sendable (String) -> Void)?
    ) async -> UserQueryCommandHandlingResult {
        transcript.systemEvent("Conversational turn — responding without driving the Mac.")
        VisionGroundingLog.emit("conversation traceID=\(traceID) kind=converse")

        // On a fresh turn the understanding boundary already generated AND streamed this reply live (one
        // round trip), so adopt it as-is — re-emitting would double it on screen. A follow-up turn falls to
        // the context-aware responder, which streams a reply that can see the earlier conversation.
        let reply: String
        if let inlineReply, !inlineReply.isEmpty, inlineReplyAlreadyStreamed {
            reply = inlineReply
        } else {
            // Carry the same bounded rolling conversation context the planner would get, so multi-turn chat
            // keeps continuity ("what did I just ask?") without ever entering the action loop.
            let textGenerator = HostedTextGenerator(backend: backend)
            let compactionDriver = ConversationCompactionDriver(
                conversationStore: genericHarnessLifecycle.conversationStore,
                coordinator: genericHarnessLifecycle.coordinator,
                compactor: genericHarnessLifecycle.compactor,
                generate: { await textGenerator.generate($0) }
            )
            let conversationContext = await compactionDriver.rollingContext(agentID: agentID)

            let responder = HostedHarnessConversationalResponder(backend: backend, trace: trace)
            let streamed = await responder.respond(
                command: command,
                frontmostAppName: frontmostAppName,
                conversationContext: conversationContext,
                onDelta: answerStream ?? { _ in }
            )
            reply = (streamed?.isEmpty == false) ? streamed! : "Hey! What can I help you with?"
        }
        transcript.response(reply)
        transcript.writeSummary(Self.deterministicThreadSummary(
            command: command, app: frontmostAppName, outcome: "ok", steps: [], finalDetail: reply
        ))

        let decision = AppHarnessDecision(
            kind: .respond,
            message: reply,
            traceID: traceID,
            metadata: ["structuredDecision": "true", "router": "conversation"]
        )
        // A conversational turn is genuinely finished — there is no pending work to resume — so the agent
        // completes. The row still surfaces as `.chatting` so the reply lands in the chin as a message
        // (the same completed + chatting pairing the empty turn uses).
        _ = await genericHarnessLifecycle.coordinator.complete(
            agentID: agentID,
            reason: "Conversational turn"
        )
        let result = UserQueryCommandHandlingResult(
            status: .completed,
            threadStatus: .chatting,
            decision: decision,
            summary: reply,
            traceID: traceID,
            metadata: preparedTurnMetadata.merging([
                "appHarness.decision": AppHarnessDecisionKind.respond.rawValue,
                "appHarness.router": "conversation"
            ]) { _, new in new }
        )
        await coordinatorRegistry.finish(conversationID: conversationID)
        logHandlingResult(result, stage: "conversation", hint: reply)
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
        conversationID: String,
        agentID: String,
        preparedTurnMetadata: [String: String],
        transcript existingTranscript: ConversationTranscript? = nil
    ) async -> UserQueryCommandHandlingResult {
        VisionGroundingLog.emit("aborted traceID=\(traceID) reason=\(reason) app=\(appName)")
        // Reuse the turn's open transcript when the abort happens after it was started (the action-only
        // guards run after the user message is already recorded); otherwise open a fresh one, since even
        // a turn that never got past its first guard must still leave a thread file on disk.
        let transcript: ConversationTranscript
        if let existingTranscript {
            transcript = existingTranscript
        } else {
            transcript = ConversationTranscript(id: conversationID)
            transcript.begin(id: conversationID, app: appName)
            transcript.userMessage(command)
        }
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
            agentID: agentID,
            reason: "User query harness run could not start: \(reason)"
        )
        await coordinatorRegistry.finish(conversationID: conversationID)
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
        conversationID: String,
        context: UserQueryCommandContext?
    ) {
        guard UserQueryLog.isEnabled else { return }

        let source = context?.turnSource.rawValue ?? AppHarnessTurnSource.typedPrompt.rawValue
        let isFollowUp = context?.isFollowUp ?? false
        UserQueryLog.commands.notice(
            "command submitted traceID=\(traceID, privacy: .public) conversationID=\(conversationID, privacy: .public) source=\(source, privacy: .public) followUp=\(String(isFollowUp), privacy: .public) command=\(command, privacy: .public)"
        )
    }

    private func logHandlingResult(
        _ result: UserQueryCommandHandlingResult,
        stage: String,
        hint: String
    ) {
        guard UserQueryLog.isEnabled else { return }

        let conversationLabel = result.conversationLabel ?? ""
        UserQueryLog.commands.notice(
            "command finished traceID=\(result.traceID, privacy: .public) stage=\(stage, privacy: .public) status=\(result.status.rawValue, privacy: .public) threadStatus=\(result.threadStatus.rawValue, privacy: .public) summary=\(result.summary, privacy: .public) conversationLabel=\(conversationLabel, privacy: .public) hint=\(hint, privacy: .public)"
        )
    }

    /// Prompt for the streamed final reply: relay the harness's drafted answer to the user, grounded
    /// strictly in that draft so the streamed message can't drift from what the run actually found.
    private static func finalAnswerPrompt(goal: String, draftAnswer: String) -> String {
        """
        Relay Donkey's reply to the user for this finished request. Base it strictly on the draft \
        below — do not add facts, steps, or speculation. Reply directly to the user in a concise, \
        friendly voice; if the draft already reads well, lightly polish it. Output only the reply \
        text, with no preamble.

        User request: \(goal)
        Draft reply: \(draftAnswer)
        """
    }

    /// Deadline for the one-shot understanding call; past it the run degrades to
    /// driving the raw command instead of stalling silently.
    private static let understandingTimeoutSeconds: TimeInterval = 15

    /// One line describing the step that just ran: the planner's stated reason, else the tool result's
    /// own summary. The conversation row owns visual truncation with a five-line tail clamp; cursor
    /// labels are bounded later in the overlay model.
    @MainActor
    static func stepNarration(
        for step: HarnessStepExecutionResult,
        planner: HostedHarnessStepPlanner
    ) -> String? {
        let candidate = planner.lastNarration ?? step.toolResult?.summary
        guard let narration = candidate?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first,
            !narration.isEmpty else {
            return nil
        }
        return narration
    }

    /// Which sensing modality a step used, matched on the executed tool's typed registry name (never on
    /// user text). Only the two observation tools sense fresh elements; everything else (clicks, input,
    /// shell, wait, verify) senses nothing, so its step shows no modality.
    private static func sensingModality(forTool toolName: String) -> TraceModality {
        switch toolName {
        case "ax.observe": return .accessibility
        case "vision.capture": return .vision
        default: return .none
        }
    }

    /// Escape hatch to suppress the cosmetic animated-cursor playback (set `DONKEY_DISABLE_CURSOR_VIZ=1`).
    /// The playback animates an overlay window's frame, which can trip a re-entrant AppKit layout crash on
    /// some macOS builds; turning it off lets a run proceed (the harness still does the real vision input
    /// and the text narration still updates).
    static var cursorVisualizationDisabled: Bool {
        ProcessInfo.processInfo.environment["DONKEY_DISABLE_CURSOR_VIZ"] == "1"
    }

    private static func uptimeMilliseconds() -> Double {
        ProcessInfo.processInfo.systemUptime * 1_000
    }

    private static func formatLatency(_ milliseconds: Double) -> String {
        String(format: "%.3f", max(0, milliseconds))
    }

    private static var userQueryGrantedPermissions: Set<HarnessPermission> {
        // Internal capabilities are always available; the macOS-backed ones (screen capture,
        // accessibility, input) are kept only when the system grants them right now. A missing one
        // drops out so the first tool that needs it stops at the notch gate and is requested in the
        // conversation — onboarding is optional, not a prerequisite.
        HarnessSystemPermissionBridge.granting([
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
        ])
    }

    /// Picks the app the harness drive operates, or nil for an app-less run. An `.appless` turn (the
    /// understanding boundary's typed signal for artifact/system work — make an image, fetch the web,
    /// change a setting) drives no app at all and returns nil, so it is never pinned to a window and never
    /// blocked on one. Otherwise the understood target app wins whenever it names a real app: a running
    /// window resolves to its exact name and bundle id, and an installed-but-not-running app is still
    /// pinned by name — the see/act providers re-resolve the target window on every call, so the target
    /// starts working the moment the planner launches it. Pinning to the frontmost app instead aims every
    /// observe/click (and the focus guard's recovery activation) at an unrelated window for the whole run,
    /// and preloads the wrong app's guidance. A name that matches nothing running and nothing installed
    /// falls back to the frontmost app, and with no frontmost app the run is app-less rather than failed.
    @MainActor
    static func resolveDriveTarget(
        understanding: HarnessRequestUnderstanding?,
        frontmost: (appName: String, bundleIdentifier: String?)?,
        resolveRunningWindow: (String) -> (appName: String?, bundleIdentifier: String?)? = { requested in
            AccessibilityObserver.resolveTarget(appName: requested, bundleIdentifier: nil)
                .map { ($0.appName, $0.bundleIdentifier) }
        },
        resolveInstalledBundle: (String) -> URL? = { requested in
            MacAppScriptabilityProbe().bundleURL(bundleIdentifier: nil, appName: requested)
        }
    ) -> (appName: String, bundleIdentifier: String?)? {
        // An app-less turn drives nothing — the planner produces the result with system/web/generative tools.
        if understanding?.actionSurface == .appless { return nil }
        guard let requested = understanding?.targetAppName,
              !requested.isEmpty,
              requested.caseInsensitiveCompare(frontmost?.appName ?? "") != .orderedSame
        else {
            // No named target (or it IS the front app): drive the front app, or run app-less when none.
            return frontmost
        }
        if let resolved = resolveRunningWindow(requested) {
            return (resolved.appName ?? requested, resolved.bundleIdentifier)
        }
        if let bundleURL = resolveInstalledBundle(requested) {
            return (requested, Bundle(url: bundleURL)?.bundleIdentifier)
        }
        return frontmost
    }

    /// A compact, one-line-per-skill catalog of every installed app skill — id, description, the apps it
    /// covers, and any validated `skill_run` scripts — surfaced to the planner each step. App-specific
    /// guidance is only preloaded for the resolved GUI drive target, so without this the planner never
    /// learns that a skill owns a domain (e.g. native music playback, Notes capture by script) when the
    /// task has no GUI target app — and it improvises fragile commands instead of following the skill.
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
            return "  - \(skill.id) — \(skill.summary)\(apps)\(scripts)"
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
                conversationID: context?.conversation.id,
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
            "genericHarness.conversationID": preparedTurn.conversation.id,
            "genericHarness.agentID": preparedTurn.agent.id,
            "genericHarness.agentStatus": (runStep?.task.status ?? preparedTurn.agent.status).rawValue,
            "genericHarness.context.promptCharacters": String(preparedTurn.compactedContext.promptText.count),
            "genericHarness.context.eventCount": String(preparedTurn.compactedContext.events.count),
            "genericHarness.context.assetCount": String(preparedTurn.compactedContext.assets.count),
            "genericHarness.context.activeTaskCount": String(preparedTurn.compactedContext.activeAgents.count),
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

    func coordinator(for conversationID: String) -> RunCoordinator {
        if let coordinator = coordinators[conversationID] {
            return coordinator
        }

        let coordinator = RunCoordinator()
        coordinators[conversationID] = coordinator
        return coordinator
    }

    func pause(conversationID: String, reason: String) async -> Bool {
        guard let coordinator = coordinators[conversationID] else { return false }

        await coordinator.pause(reason: reason)
        return true
    }

    func resume(conversationID: String, reason: String) async -> Bool {
        guard let coordinator = coordinators[conversationID] else { return false }

        await coordinator.resume(reason: reason)
        return true
    }

    func finish(conversationID: String) {
        coordinators[conversationID] = nil
    }
}
