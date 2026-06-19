import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation
import SwiftUI

@MainActor
final class UserQueryOverlayModel: ObservableObject, UserQueryIntentSink {
    @Published private(set) var promptState: UserQueryState
    @Published var messageText = ""
    @Published var placement: UserQueryPlacement = .bottomRight
    @Published var inputTextHeight = UserQueryLayout.composerInputTextMinimumHeight
    @Published var isInputExpanded = false
    @Published var notchCommandText = ""
    @Published private(set) var notchCommandInputTextHeight = UserQueryLayout.composerInputTextMinimumHeight
    @Published private(set) var isNotchCommandInputExpanded = true
    @Published private(set) var notchAccentIndex = 0
    @Published private(set) var isCurrentTaskPaused = false
    @Published private(set) var updateState: UserQueryUpdateState
    @Published private(set) var notchTasks: [UserQueryNotchTask]
    @Published private(set) var spawnStates: [UserQuerySpawnState] = []
    @Published private(set) var selectedSpawnID: String?
    /// Logged out: the notch renders a login call-to-action instead of the task surface. The app
    /// delegate pushes this from the auth coordinator's session state (true while signed out after a
    /// prior sign-in, i.e. an expired session) and clears it once sign-in completes.
    @Published private(set) var needsLogin = false
    var agentVisualizationPresenter: ((PointerCoachCursorGuideRequest, String?) -> Void)?
    /// Fired when the notch Login button is tapped, so the app delegate can start the real sign-in
    /// (the Google browser flow). The model never opens browsers or windows itself.
    var loginActionRequested: (() -> Void)?
    /// Fired when a hosted request fails authentication mid-run (an expired session). The app delegate
    /// wires this to sign out, which flips the notch into login mode while the running tasks stay put.
    var sessionExpired: (() -> Void)?
    /// Fired when the Live session's optional audio streaming should start/stop,
    /// so the mic owner can keep the engine running continuously.
    var onLiveAudioStreamingChanged: ((Bool) -> Void)?

    private var commandHandler: any UserQueryCommandHandling
    private let taskStore: any UserQueryTaskStoring
    private let followUpResolver: any UserQueryFollowUpResolving
    private let voiceTranscriber: LocalVoiceTranscriptionAdapter
    private let liveController: GeminiLiveVoiceController
    private var updateChecker: any DonkeyUpdateChecking
    private let appCatalogRefreshLoop: LocalAppDynamicCatalogRefreshLoop
    private var activeTaskIDs: Set<String> = []
    /// Resume requests made while a task's previous loop was still winding down (e.g. a quick Stop→Resume).
    /// The resume is deferred here and fired by `handleCommandRunResult` once that loop ends, so two loops
    /// never run on one task and the tap is never silently dropped.
    private var pendingResumeTaskIDs: Set<String> = []
    /// The task an explicit Reply tap pinned the next submission to (a task waiting on the user — a
    /// clarification or review). It routes the answer straight to that task instead of leaving the
    /// follow-up resolver to guess, and the expanded panel dims every other row while it is set so the
    /// user sees which thread their reply continues. Consumed by the next submission.
    @Published private(set) var replyTargetTaskID: String?
    /// Metadata flag marking a terminal task (completed or failed) as seen — set when the user expands
    /// the notch. It lives on the task (and so is persisted through the task store) rather than in memory,
    /// so an acknowledged failure stays dismissed across relaunches instead of re-surfacing every launch.
    private static let seenMetadataKey = "notch.seen"

    /// Clear the per-run metadata flags a task carries into a fresh running run: the "seen" dismissal (so
    /// its next terminal state re-surfaces in the collapsed notch) and the streaming-answer flag (so a
    /// streamed reply on the new run replaces the previous answer instead of appending to it). Applied at
    /// every stopped→running transition — both the in-place resume (`updateTask`) and the matched-resume
    /// seed (`taskForSubmittedCommand`), which bypasses `updateTask`.
    private static func clearRunMetadata(_ metadata: inout [String: String]) {
        metadata[seenMetadataKey] = nil
        metadata[UserQueryNotchTask.streamingAnswerMetadataKey] = nil
    }

    private var lastActiveTaskID: String?
    /// The task/spawn the in-flight Gemini Live turn reports into, so the user
    /// sees the same cursor-and-task feedback as a local pipeline run.
    private var liveTurn: (taskID: String, spawnID: String?)?
    private var liveTurnWatchdog: Task<Void, Never>?
    private static let notchTaskDisplayLimit = 12
    private static let followUpCandidateLimit = 8
    private static let followUpMatchConfidenceThreshold = 0.62
    /// How long a Live turn may stay silent (no tool, no answer) before the task
    /// is failed instead of spinning forever.
    private static let liveTurnSilenceLimitSeconds: TimeInterval = 75

    init(
        aiProvider: any AIHarnessSnapshotProviding = AIHarnessBoundary(),
        commandHandler: any UserQueryCommandHandling = LocalAppUserQueryCommandHandler(),
        taskStore: any UserQueryTaskStoring = CoreDataUserQueryTaskStore(),
        followUpResolver: any UserQueryFollowUpResolving = HostedTaskFollowUpResolver(),
        voiceTranscriber: LocalVoiceTranscriptionAdapter = LocalVoiceTranscriptionAdapter(),
        updateChecker: any DonkeyUpdateChecking = SparkleUpdateController(),
        liveController: GeminiLiveVoiceController = GeminiLiveVoiceController(),
        theme: UserQueryTheme = UserQueryOverlayModel.bundledTheme()
    ) {
        self.commandHandler = commandHandler
        self.taskStore = taskStore
        self.followUpResolver = followUpResolver
        self.voiceTranscriber = voiceTranscriber
        self.liveController = liveController
        self.updateChecker = updateChecker
        self.appCatalogRefreshLoop = LocalAppDynamicCatalogRefreshLoop(
            profileGenerator: HostedLocalAppCatalogProfileGenerator()
        )
        let restoration = Self.restoredTasks(
            from: taskStore.loadRecentTasks(limit: Self.notchTaskDisplayLimit),
            now: Date()
        )
        let restoredTasks = restoration.tasks
        notchTasks = restoredTasks
        notchAccentIndex = restoredTasks.first.map { UserQueryAccentPalette.normalizedIndex($0.accentIndex) }
            ?? UserQueryAccentPalette.firstIndex
        isCurrentTaskPaused = restoredTasks.first?.status == .paused
        updateState = UserQueryUpdateState(
            currentVersion: updateChecker.currentVersion
        )
        let aiSnapshot = aiProvider.snapshot()
        promptState = UserQueryState(
            promptText: aiSnapshot.suggestedPromptText,
            isPrimaryActionEnabled: true,
            leadingSignalLevel: .idle,
            isActive: false,
            theme: theme
        )
        self.updateChecker.updateStateChanged = { [weak self] state in
            self?.updateState = state
        }
        updateChecker.start()
        SQLiteAgentMemoryStore.shared?.prewarmDefaultLocalItemsInBackground()
        appCatalogRefreshLoop.start()
        checkForUpdates()
        startLiveSessionIfEnabled()
        // A mid-run 401 from the hosted backend means the session expired: surface login (the app
        // delegate wires `sessionExpired` to the auth coordinator) while the running tasks stay put.
        self.commandHandler.onAuthenticationRequired = { [weak self] in
            self?.handleSessionExpired()
        }
        autoResumeInterruptedTasks(restoration.autoResumeIDs)
    }

    /// Resume tasks that were actively running when the app last quit (see `restoredTasks`). Each runs as
    /// an unattended BACKGROUND turn — the user may not be present — so it never raises an app or moves
    /// the cursor; progress narrates into the task's own row. Fires once, at launch.
    private func autoResumeInterruptedTasks(_ taskIDs: [String]) {
        guard !taskIDs.isEmpty else { return }
        // Don't drive the harness while signed out — every planner step would 401. The interrupted
        // tasks stay retryable and resume on the next launch (or manual retry) once signed in.
        guard BackendSessionGate.shared.isAuthenticated else { return }
        for taskID in taskIDs {
            guard let context = commandContext(taskID: taskID, isFollowUp: false, source: .followUp, spawnID: nil) else {
                continue
            }
            activeTaskIDs.insert(taskID)
            Task { [weak self, commandHandler] in
                let result = await commandHandler.autoResumeCommand(taskID: taskID, context: context)
                await MainActor.run {
                    guard let self else { return }
                    // No goal to resume, or the unattended run couldn't even start (no frontmost app,
                    // backend off): keep the task retryable rather than failing it, so the user can resume
                    // it later. Only a run that actually executed reports its real outcome.
                    if result == nil || result?.metadata["harness.abortReason"] != nil {
                        self.activeTaskIDs.remove(taskID)
                        self.updateTask(id: taskID, detail: "Interrupted — resume", status: .timedOut)
                        return
                    }
                    self.handleCommandRunResult(taskID: taskID, spawnID: nil, isFollowUp: false, result: result!)
                }
            }
        }
    }

    /// Bring up the always-on Gemini Live session. It self-gates on configuration
    /// and only becomes `isConnected` if it can authenticate, so when it is not
    /// configured the existing command pipeline is used unchanged.
    private func startLiveSessionIfEnabled() {
        // Self-gates on configuration AND on being signed in: the session mints a backend token to
        // connect, which 401s while logged out. The app delegate calls `resumeLiveSession()` once the
        // session is restored, so the always-on session comes back without a relaunch.
        guard liveController.isEnabled, BackendSessionGate.shared.isAuthenticated else { return }
        liveController.onComplexRequest = { [weak self] goal in
            // The model explicitly delegated via agent_run: close out the Live
            // turn and run the goal through the full local pipeline (never back
            // through Live — no loop). The pipeline has its own task/spawn UI.
            guard let self else { return }
            self.finishLiveTurn(detail: "Handed off to the desktop agent", status: .completed)
            self.runLocalCommand(goal, source: .typedPrompt)
        }
        liveController.onActed = { [weak self] summary in
            guard let self else { return }
            self.promptState.leadingSignalLevel = .ready
            self.promptState.promptText = summary
            guard let liveTurn = self.liveTurn else { return }
            self.updateSpawn(id: liveTurn.spawnID, label: Self.collapsedDisplayText(for: summary), phase: .holding)
            self.updateTask(id: liveTurn.taskID, detail: summary, status: .running)
            self.appendTaskEvent(taskID: liveTurn.taskID, role: .system, text: summary)
            self.restartLiveTurnWatchdog()
        }
        liveController.onResponse = { [weak self] answer in
            guard let self else { return }
            self.promptState.leadingSignalLevel = .ready
            self.promptState.promptText = answer
            guard let liveTurn = self.liveTurn else { return }
            self.appendTaskEvent(taskID: liveTurn.taskID, role: .assistant, text: answer)
            self.finishLiveTurn(detail: answer, status: .completed)
        }
        liveController.onConsentNeeded = { [weak self] request in
            self?.presentLiveShellConsent(request)
        }
        // Forward start/stop of optional audio streaming to the mic owner. The
        // controller emits a paired false on disconnect/stop, so continuous
        // listening is always torn down.
        liveController.onAudioStreamingChanged = { [weak self] active in
            self?.onLiveAudioStreamingChanged?(active)
        }
        Task { [liveController] in await liveController.start() }
    }

    /// Tear down the always-on Live session when the session signs out. The app delegate drives this
    /// from the auth phase so a logged-out app stops reconnecting (each reconnect re-mints a token and
    /// 401s). Paired with `resumeLiveSession()` on sign-in.
    func suspendLiveSession() {
        Task { [liveController] in await liveController.stop() }
    }

    /// Bring the Live session back after sign-in. `start()` self-guards on an existing session, so a
    /// redundant call is a no-op.
    func resumeLiveSession() {
        startLiveSessionIfEnabled()
    }

    /// Stream optional microphone audio into the Live session (no-op unless audio
    /// is enabled and the session is connected).
    func streamLiveAudioFrames(_ samples: [Float], sampleRate: Double) {
        Task { [liveController] in
            await liveController.sendAudioFrames(samples, sampleRate: sampleRate)
        }
    }

    func activate() {
        promptState.isActive = true
        promptState.isPrimaryActionEnabled = true
        promptState.isVoiceInputActive = false
        promptState.leadingSignalLevel = .ready
        promptState.promptText = UserQueryCopy.defaultPromptPlaceholder
    }

    func updateVoiceWaveformLevels(_ levels: [Double]) {
        let normalizedLevels = levels.map { min(max($0, 0), 1) }
        guard promptState.voiceWaveformLevels != normalizedLevels else { return }

        promptState.voiceWaveformLevels = normalizedLevels
    }

    func checkForUpdates() {
        updateChecker.checkForUpdatesInBackground()
    }

    func showUpdateUI() {
        updateChecker.showUpdateUI()
    }

    /// Push the logged-out state into the notch. The app delegate drives this from the auth
    /// coordinator's session phase.
    func updateNeedsLogin(_ value: Bool) {
        guard needsLogin != value else { return }
        needsLogin = value
    }

    /// The notch Login button was tapped; hand off to the app delegate to start the sign-in flow.
    func requestLogin() {
        loginActionRequested?()
    }

    /// A hosted request returned 401 mid-run. Surface login once — ignored if already logged out, so a
    /// burst of retrying calls doesn't re-fire — and let the app delegate sign out.
    func handleSessionExpired() {
        guard !needsLogin else { return }
        sessionExpired?()
    }

    func handle(_ intent: UserQueryIntent) {
        switch intent {
        case .addContextRequested:
            promptState.leadingSignalLevel = .ready
        case .voiceInputRequested:
            promptState.leadingSignalLevel = .ready
            promptState.isVoiceInputActive = true
            promptState.promptText = "Listening..."
        case .primaryActionRequested(let promptText):
            let trimmedText = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { return }

            submitCommand(trimmedText)
        case .messageSubmitted(let text):
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { return }

            submitCommand(trimmedText)
        case .inputTextHeightChanged(let height):
            let clampedHeight = UserQueryLayout.clampedComposerInputTextHeight(height)
            guard abs(inputTextHeight - clampedHeight) > 0.5 else { return }
            inputTextHeight = clampedHeight
        case .inputExpansionChanged(let isExpanded):
            let shouldExpand = !messageText.isEmpty && (isExpanded || messageText.contains("\n"))
            guard isInputExpanded != shouldExpand else { return }
            isInputExpanded = shouldExpand
        case .dismissed:
            promptState.isPrimaryActionEnabled = false
            promptState.isVoiceInputActive = false
            promptState.isActive = false
        }
    }

    func submitVoiceAudio(_ audio: LocalVoiceAudioBuffer?) {
        promptState.isVoiceInputActive = false

        guard let audio else {
            promptState.leadingSignalLevel = .idle
            promptState.promptText = "No voice captured"
            return
        }

        let sourceTraceID = "user-query-voice-\(UUID().uuidString)"
        promptState.leadingSignalLevel = .thinking
        promptState.promptText = "Transcribing..."
        Task { [weak self, voiceTranscriber] in
            let result = await voiceTranscriber.transcribe(
                LocalVoiceTranscriptionRequest(
                    audio: audio,
                    sourceTraceID: sourceTraceID
                )
            )
            await MainActor.run {
                guard let self else { return }
                guard let transcript = result.transcript,
                      !transcript.text.isEmpty else {
                    self.promptState.leadingSignalLevel = .idle
                    self.promptState.promptText = "Voice unavailable"
                    return
                }

                self.messageText = transcript.text
                self.submitCommand(transcript.text, source: .voiceTranscript)
            }
        }
    }

    private func submitCommand(_ text: String, source: AppHarnessTurnSource = .typedPrompt) {
        // A spoken turn while the mic is streaming was already heard by the Live session; running it
        // again here would double-execute it, so drop it (the Live session answers it in real time).
        if liveController.isConnected, source == .voiceTranscript, liveController.isAudioEnabled {
            clearSubmissionInputs()
            promptState.isActive = false
            promptState.isVoiceInputActive = false
            return
        }
        // Every actionable turn runs through the harness agent loop. The loop re-plans after each
        // observation, verifies before completing, and adjusts on failure, so multi-step work ("note
        // with all the album's songs", "play X and …") runs to completion instead of the one-shot Live
        // tool path that does a single step and stops. The Live session stays connected for real-time
        // voice; it is no longer the executor for typed/transcribed turns.
        runLocalCommand(text, source: source)
    }

    /// Send a turn to the Live session with the same visible lifecycle as a
    /// local run: a task in the rail and a spawn cursor that narrates tool
    /// activity, consent gates, and the final answer.
    private func routeToLiveSession(_ text: String) {
        if liveTurn != nil {
            finishLiveTurn(detail: "Changed course", status: .interrupted)
        }
        let spawnID = beginSpawn(for: text)
        let task = taskForSubmittedCommand(
            text: text,
            matchedTaskID: nil,
            reservedAccentIndex: spawnID.flatMap { spawn(withID: $0)?.accentIndex }
        )
        updateSpawn(id: spawnID, taskID: task.id, accentIndex: task.accentIndex)
        activeTaskIDs.insert(task.id)
        lastActiveTaskID = task.id
        appendTaskEvent(taskID: task.id, role: .user, text: text)
        clearSubmissionInputs()
        promptState.isActive = false
        promptState.isVoiceInputActive = false
        promptState.leadingSignalLevel = .thinking
        promptState.promptText = task.title
        liveTurn = (task.id, spawnID)
        restartLiveTurnWatchdog()
        Task { [liveController] in await liveController.sendText(text) }
    }

    /// Close out the in-flight Live turn's task and spawn.
    private func finishLiveTurn(detail: String?, status: UserQueryTaskStatus) {
        liveTurnWatchdog?.cancel()
        liveTurnWatchdog = nil
        guard let turn = liveTurn else { return }
        liveTurn = nil
        updateTask(id: turn.taskID, detail: detail, status: status)
        activeTaskIDs.remove(turn.taskID)
        syncPrimaryTaskPausedFlag()
        guard let spawnID = turn.spawnID, let index = spawnIndex(id: spawnID) else { return }
        var spawnState = spawnStates[index]
        switch status {
        case .completed:
            spawnState.label = detail.map(Self.collapsedDisplayText(for:)) ?? "Done"
        case .failed:
            spawnState.label = "Stopped"
        default:
            spawnState.label = Self.collapsedDisplayText(for: detail ?? spawnState.label)
        }
        spawnState.updatedAt = Date()
        spawnState.finishedAt = Date()
        spawnStates[index] = spawnState
        if !UserQuerySpawnLifecycle.keepsVisibleResult(for: status) {
            scheduleSpawnFade(id: spawnID, after: 2.0)
        }
    }

    /// Fail the Live turn if the session stays silent (no tool call, no answer)
    /// past the limit, instead of leaving the task spinning.
    private func restartLiveTurnWatchdog() {
        liveTurnWatchdog?.cancel()
        let limit = Self.liveTurnSilenceLimitSeconds
        liveTurnWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.liveTurn != nil else { return }
                self.finishLiveTurn(detail: "No response — try again or rephrase.", status: .failed)
                self.promptState.leadingSignalLevel = .idle
            }
        }
    }

    /// Surface a Live-path shell consent in the notch using the same task
    /// metadata the harness consent UI reads, marked so approval routes back to
    /// the Live controller instead of the harness lifecycle.
    private func presentLiveShellConsent(_ request: GeminiLiveShellConsentRequest) {
        guard let turn = liveTurn else { return }
        liveTurnWatchdog?.cancel()
        updateSpawn(id: turn.spawnID, label: "Waiting for approval", phase: .holding)
        updateTask(
            id: turn.taskID,
            detail: request.summary,
            status: .waitingForPermission,
            metadata: [
                "genericHarness.shellConsent.command": request.command,
                "genericHarness.shellConsent.tier": request.tier,
                "genericHarness.shellConsent.allowAlways": request.allowAlways ? "true" : "false",
                "live.shellConsent": "true"
            ]
        )
        appendTaskEvent(taskID: turn.taskID, role: .system, text: request.summary)
        promptState.leadingSignalLevel = .ready
        promptState.promptText = request.summary
        syncPrimaryTaskPausedFlag()
    }

    private func runLocalCommand(_ text: String, source: AppHarnessTurnSource = .typedPrompt) {
        let candidates = followUpCandidates()
        let promptFollowUpTarget = promptSubmissionFollowUpTarget()
        let replyTargetTaskID = consumePendingReplyTarget()
        let spawnID: String?
        if let promptFollowUpTarget {
            updateSpawn(
                id: promptFollowUpTarget.spawnID,
                commandText: text,
                label: Self.collapsedDisplayText(for: text),
                phase: .holding,
                resumesWork: true
            )
            spawnID = promptFollowUpTarget.spawnID
        } else {
            spawnID = source == .voiceTranscript ? nil : beginSpawn(for: text)
        }
        clearSubmissionInputs()
        promptState.isActive = false
        promptState.isVoiceInputActive = false
        promptState.leadingSignalLevel = .thinking
        promptState.promptText = "Routing task"
        let sourceTraceID = "user-query-followup-\(UUID().uuidString)"
        let confidenceThreshold = Self.followUpMatchConfidenceThreshold
        Task { [weak self, followUpResolver] in
            let matchedTaskID: String?
            if let replyTargetTaskID {
                // An explicit Reply pins the answer to that task — never re-routed by the resolver.
                matchedTaskID = replyTargetTaskID
            } else if let taskID = promptFollowUpTarget?.taskID {
                matchedTaskID = taskID
            } else if candidates.isEmpty {
                matchedTaskID = nil
            } else {
                let resolution = await followUpResolver.resolveFollowUp(
                    UserQueryFollowUpResolverRequest(
                        text: text,
                        candidates: candidates,
                        sourceTraceID: sourceTraceID
                    )
                )
                if let taskID = resolution.taskID,
                   resolution.confidence >= confidenceThreshold {
                    matchedTaskID = taskID
                } else {
                    matchedTaskID = nil
                }
            }

            await MainActor.run {
                self?.startCommandRun(
                    text: text,
                    matchedTaskID: matchedTaskID,
                    source: source,
                    spawnID: spawnID
                )
            }
        }
    }

    func handleDroppedAssets(_ drafts: [UserQueryTaskAssetDraft]) {
        guard !drafts.isEmpty else { return }

        let targetTask = taskForDroppedAssets()
        let assetNames = drafts.map(\.displayName)
        let eventText = Self.assetUploadEventText(assetNames)
        let eventID = appendTaskEvent(taskID: targetTask.id, role: .user, text: eventText)
        for draft in drafts {
            let assetID = UUID().uuidString
            taskStore.appendAsset(
                Self.persistedAsset(
                    from: draft,
                    assetID: assetID,
                    taskID: targetTask.id,
                    eventID: eventID
                )
            )
        }

        var updatedTask = targetTask
        updatedTask.detail = drafts.count == 1 ? "1 asset attached" : "\(drafts.count) assets attached"
        updatedTask.updatedAt = Date()
        prependTask(updatedTask)
        lastActiveTaskID = updatedTask.id
        promptState.promptText = updatedTask.title
        promptState.leadingSignalLevel = updatedTask.status == .running ? .thinking : .ready
        syncPrimaryTaskPausedFlag()
    }

    func markSpawnDesktopEmerged(id spawnID: String) {
        guard let index = spawnIndex(id: spawnID),
              spawnStates[index].phase == .notchCue else {
            return
        }

        var spawnState = spawnStates[index]
        spawnState.phase = .traveling
        spawnState.updatedAt = Date()
        spawnStates[index] = spawnState
        selectedSpawnID = spawnID
    }

    func selectSpawn(id spawnID: String) {
        guard spawnStates.contains(where: { $0.id == spawnID }) else { return }

        selectedSpawnID = spawnID
    }

    func submitSpawnFollowUp(spawnID: String, taskID: String, text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty,
              taskIDForInteractableSpawn(id: spawnID) == taskID else {
            return
        }

        selectedSpawnID = spawnID
        updateSpawn(
            id: spawnID,
            commandText: trimmedText,
            label: Self.collapsedDisplayText(for: trimmedText),
            phase: .holding,
            resumesWork: true
        )
        startCommandRun(
            text: trimmedText,
            matchedTaskID: taskID,
            source: .followUp,
            spawnID: spawnID
        )
    }

    private func startCommandRun(
        text: String,
        matchedTaskID: String?,
        source: AppHarnessTurnSource = .typedPrompt,
        spawnID: String? = nil
    ) {
        // A follow-up to a task whose loop is still running — or one blocked at a permission gate — is
        // queued into that task: the running loop folds it in at its next step, and a gated task keeps its
        // gate and drains the follow-up when the user approves. Either way it must NOT start a second run
        // or clear the gate. Everything else (a brand-new command, or a follow-up to a stopped task) takes
        // the fresh/resume path below, which runs concurrently with any other in-flight task.
        let matchedStatus = matchedTaskID.flatMap { task(withID: $0)?.status }
        if let matchedTaskID, matchedStatus == .running || matchedStatus == .waitingForPermission {
            queueFollowUpIntoRunningTask(text: text, taskID: matchedTaskID, source: source, spawnID: spawnID)
            return
        }
        runFreshOrResumedCommand(text: text, matchedTaskID: matchedTaskID, source: source, spawnID: spawnID)
    }

    /// Queue a follow-up onto a task whose loop is still running. The live loop picks it up at its next
    /// step; if the loop happens to finish first, fall back to resuming the task with the instruction.
    private func queueFollowUpIntoRunningTask(
        text: String,
        taskID: String,
        source: AppHarnessTurnSource,
        spawnID: String?
    ) {
        appendTaskEvent(taskID: taskID, role: .user, text: text)
        updateSpawn(id: spawnID, taskID: taskID)
        clearSubmissionInputs()
        lastActiveTaskID = taskID
        promptState.isActive = false
        promptState.isVoiceInputActive = false
        promptState.leadingSignalLevel = .thinking
        promptState.promptText = task(withID: taskID)?.title ?? Self.collapsedDisplayText(for: text)
        syncPrimaryTaskPausedFlag()
        Task { [weak self, commandHandler] in
            let injected = await commandHandler.injectFollowUp(taskID: taskID, text: text)
            guard !injected else { return }
            // Race: the loop finished between the live check and the enqueue. Resume the task with the
            // instruction instead. The user event is already recorded, so it is not appended again.
            await MainActor.run {
                self?.runFreshOrResumedCommand(
                    text: text,
                    matchedTaskID: taskID,
                    source: source,
                    spawnID: spawnID,
                    appendUserEvent: false
                )
            }
        }
    }

    private func runFreshOrResumedCommand(
        text: String,
        matchedTaskID: String?,
        source: AppHarnessTurnSource = .typedPrompt,
        spawnID: String? = nil,
        appendUserEvent: Bool = true
    ) {
        let isFollowUp = matchedTaskID != nil
        let reservedAccentIndex = spawnID.flatMap { spawn(withID: $0)?.accentIndex }
        let task = taskForSubmittedCommand(
            text: text,
            matchedTaskID: matchedTaskID,
            reservedAccentIndex: reservedAccentIndex
        )
        updateSpawn(
            id: spawnID,
            taskID: task.id,
            accentIndex: task.accentIndex
        )
        activeTaskIDs.insert(task.id)
        lastActiveTaskID = task.id
        if appendUserEvent {
            appendTaskEvent(taskID: task.id, role: .user, text: text)
        }
        clearSubmissionInputs()
        promptState.isActive = false
        promptState.leadingSignalLevel = .thinking
        promptState.promptText = task.title
        syncPrimaryTaskPausedFlag()
        let context = commandContext(
            taskID: task.id,
            isFollowUp: isFollowUp,
            source: source,
            spawnID: spawnID
        )
        Task { [weak self, commandHandler] in
            let result = await commandHandler.handleSubmittedCommand(text, context: context)
            await MainActor.run {
                self?.handleCommandRunResult(
                    taskID: task.id,
                    spawnID: spawnID,
                    isFollowUp: isFollowUp,
                    result: result
                )
            }
        }
    }

    /// Apply a finished pipeline run to the task rail, prompt pill, cursor
    /// replay, and spawn — shared by fresh submissions and post-approval resumes.
    private func handleCommandRunResult(
        taskID: String,
        spawnID: String?,
        isFollowUp: Bool,
        result: UserQueryCommandHandlingResult
    ) {
        updateTask(
            id: taskID,
            title: isFollowUp ? nil : result.taskLabel,
            detail: result.summary,
            status: Self.taskStatus(for: result),
            metadata: result.metadata
        )
        appendTaskEvent(taskID: taskID, role: .assistant, text: result.summary)
        activeTaskIDs.remove(taskID)
        refreshPromptStateAfterRunResult(taskID: taskID, result: result)
        let cursorOverlayRequest = result.cursorOverlayRequest
        if let cursorOverlayRequest {
            agentVisualizationPresenter?(cursorOverlayRequest, spawnID)
        }
        finishSpawn(
            id: spawnID,
            result: result,
            minimumFadeDelay: cursorOverlayRequest.map(Self.visualizationPlaybackDuration)
        )
        // Honor a resume requested while this loop was still winding down (e.g. Stop→Resume): now that the
        // loop has ended and the task left activeTaskIDs, the resume can start without racing a live loop.
        if pendingResumeTaskIDs.remove(taskID) != nil {
            resumeTask(id: taskID)
        }
    }

    /// The user tapped Reply on a task that is waiting on them (a clarification or a review). Pin the
    /// next composer submission to that task so the answer continues it rather than starting a new task
    /// or being matched elsewhere by the resolver; the controller focuses the input after this.
    func beginReply(toTaskID taskID: String) {
        // Any existing thread is repliable, whatever its state — running/permission-gated threads take
        // the message as a queued follow-up downstream, the rest resume.
        guard task(withID: taskID) != nil else {
            return
        }
        // Tapping Reply on the row already targeted cancels reply mode and un-dims the other rows, so the
        // user is never stuck in a dimmed state with no way back out short of sending a message.
        if replyTargetTaskID == taskID {
            replyTargetTaskID = nil
            return
        }
        replyTargetTaskID = taskID
        lastActiveTaskID = taskID
    }

    /// Leave reply mode without sending — the user tapped elsewhere in the notch chrome. No-op when no
    /// reply is targeted, so a stray background tap in normal use does nothing.
    func cancelReply() {
        guard replyTargetTaskID != nil else { return }
        replyTargetTaskID = nil
    }

    /// Take the pinned Reply target, if any, for the submission about to run. Cleared on read so it only
    /// applies to the one answer (which also un-dims the rows), and dropped if the task is no longer
    /// around (fall back to normal routing).
    private func consumePendingReplyTarget() -> String? {
        guard let taskID = replyTargetTaskID else { return nil }
        replyTargetTaskID = nil
        // Drop the pin only if the task vanished between the tap and the submit (e.g. it was closed);
        // otherwise the message is pinned to it whatever its current state (`startCommandRun` routes a
        // running/permission-gated target into a queued follow-up, a stopped/terminal one resumes).
        return task(withID: taskID) != nil ? taskID : nil
    }

    func pauseTask(id taskID: String) {
        guard task(withID: taskID)?.status == .running else { return }

        activeTaskIDs.insert(taskID)
        lastActiveTaskID = taskID
        announceLifecycle(taskID: taskID, UserQueryActivity(kind: .paused), status: .paused)
        syncPrimaryTaskPausedFlag()
        Task { [commandHandler] in
            _ = await commandHandler.pauseCommand(taskID: taskID)
        }
    }

    func resumeTask(id taskID: String) {
        guard let task = task(withID: taskID),
              [.paused, .interrupted, .timedOut, .needsAttention].contains(task.status) else {
            return
        }
        // Only run a task with real work behind it; an info-only row (e.g. an asset drop) has no goal, so
        // resuming would dead-end. Such rows shouldn't offer Resume, but guard here too.
        guard !task.commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // If the task's previous loop is still winding down (e.g. just Stopped), defer the resume until it
        // ends so two loops never run on one task; handleCommandRunResult fires the deferred resume.
        guard !activeTaskIDs.contains(taskID) else {
            pendingResumeTaskIDs.insert(taskID)
            return
        }

        activeTaskIDs.insert(taskID)
        lastActiveTaskID = taskID
        // The live line falls back to the running activity ("Thinking"); the record logs "Resuming".
        announceLifecycle(taskID: taskID, UserQueryActivity(kind: .resumed), status: .running, liveDetail: "")
        updateSpawn(id: spawnStates.first { $0.taskID == taskID }?.id, resumesWork: true)
        promptState.leadingSignalLevel = .thinking
        promptState.promptText = task.title
        syncPrimaryTaskPausedFlag()
        // Pausing or a relaunch tears the loop down, so there is no suspended loop to continue in memory:
        // re-run the task's existing goal as a fresh loop. The persisted world model and history carry the
        // context forward, so it continues the work rather than starting over.
        let context = commandContext(taskID: taskID, isFollowUp: false, source: .followUp, spawnID: nil)
        Task { [weak self, commandHandler] in
            guard let result = await commandHandler.continueApprovedCommand(taskID: taskID, context: context) else {
                // Nothing to resume (e.g. the harness snapshot is gone): restore a retryable row rather
                // than leaving it stuck on the optimistic "running" with no loop behind it.
                await MainActor.run {
                    self?.activeTaskIDs.remove(taskID)
                    self?.updateTask(id: taskID, detail: "Couldn’t resume — tap to retry", status: .timedOut)
                }
                return
            }
            await MainActor.run {
                self?.handleCommandRunResult(taskID: taskID, spawnID: nil, isFollowUp: false, result: result)
            }
        }
    }

    /// The tasks the collapsed notch keeps surfaced as floating pointers: anything running, plus
    /// terminal tasks (completed or failed) the user hasn't dismissed yet by expanding the notch. A
    /// failure — like an auth error — holds the chin until acknowledged just as a completion does.
    var notchSurfacedTasks: [UserQueryNotchTask] {
        notchTasks.filter { task in
            task.status == .running ||
                (Self.isSurfacedTerminalStatus(task.status) && !Self.isSeen(task))
        }
    }

    /// Marks every currently-terminal task (completed or failed) as seen so it stops surfacing in the
    /// collapsed notch. Called when the notch expands — the user is now looking at the full list. The
    /// flag is written to the task store, so the dismissal sticks across relaunches.
    func acknowledgeSurfacedTasks() {
        for index in notchTasks.indices where Self.isSurfacedTerminalStatus(notchTasks[index].status) && !Self.isSeen(notchTasks[index]) {
            var task = notchTasks[index]
            task.metadata[Self.seenMetadataKey] = "true"
            notchTasks[index] = task
            taskStore.upsertTask(task)
        }
    }

    private static func isSurfacedTerminalStatus(_ status: UserQueryTaskStatus) -> Bool {
        status == .completed || status == .failed
    }

    private static func isSeen(_ task: UserQueryNotchTask) -> Bool {
        task.metadata[seenMetadataKey] == "true"
    }

    /// Closes a task: removes it from the notch list and tears down its pointer.
    /// Offered only for stopped (paused/interrupted/failed) and completed tasks —
    /// the same affordance the prototype calls "close".
    func dismissTask(id taskID: String) {
        guard let task = task(withID: taskID) else { return }
        guard task.status != .running else { return }

        notchTasks.removeAll { $0.id == taskID }
        activeTaskIDs.remove(taskID)
        // Closing the targeted task ends reply mode so the remaining rows don't stay dimmed.
        if replyTargetTaskID == taskID {
            replyTargetTaskID = nil
        }
        if lastActiveTaskID == taskID {
            lastActiveTaskID = notchTasks.first?.id
        }
        if let spawnID = spawnStates.first(where: { $0.taskID == taskID })?.id {
            removeSpawn(id: spawnID)
        }
        // Drop the persisted row (and its events/assets) too, so the task does not
        // reappear when the notch reloads recent tasks on the next launch.
        taskStore.deleteTask(id: taskID)
        syncPrimaryTaskPausedFlag()
    }

    func approvePermissionGate(id taskID: String, alwaysAllow: Bool = false) {
        guard let task = task(withID: taskID),
              task.status == .waitingForPermission else {
            return
        }

        // A Live-path shell consent resolves through the Live controller, which
        // re-executes the held command and reports back via onActed/onResponse.
        if task.metadata["live.shellConsent"] == "true" {
            announceLifecycle(
                taskID: taskID,
                UserQueryActivity(kind: .resumed),
                status: .running,
                liveDetail: "",
                metadata: [:]
            )
            if let turn = liveTurn, turn.taskID == taskID {
                updateSpawn(id: turn.spawnID, label: UserQueryActivity.Kind.resumed.label, resumesWork: true)
                restartLiveTurnWatchdog()
            }
            syncPrimaryTaskPausedFlag()
            Task { [liveController] in
                await liveController.resolvePendingConsent(approved: true, alwaysAllow: alwaysAllow)
            }
            return
        }

        activeTaskIDs.insert(taskID)
        lastActiveTaskID = taskID
        // After approval the task simply resumes; the live line falls back to the running activity
        // ("Thinking") rather than narrating an internal "approving permission" step.
        announceLifecycle(taskID: taskID, UserQueryActivity(kind: .resumed), status: .running, liveDetail: "")
        promptState.leadingSignalLevel = .thinking
        promptState.promptText = task.title
        syncPrimaryTaskPausedFlag()
        let spawnID = spawnStates.first { $0.taskID == taskID }?.id
        updateSpawn(id: spawnID, resumesWork: true)
        let context = commandContext(taskID: taskID, isFollowUp: true, spawnID: spawnID)
        Task { [weak self, commandHandler] in
            let approved = await commandHandler.approvePermissionGate(taskID: taskID, alwaysAllow: alwaysAllow)
            guard approved else {
                await MainActor.run {
                    guard let self else { return }
                    self.updateTask(id: taskID, detail: "Approval unavailable", status: .needsAttention)
                    self.activeTaskIDs.remove(taskID)
                    self.syncPrimaryTaskPausedFlag()
                }
                return
            }
            // The grant only recorded consent; the loop already exited at the
            // gate. Re-run it so the approved command actually executes.
            let result = await commandHandler.continueApprovedCommand(taskID: taskID, context: context)
            await MainActor.run {
                guard let self else { return }
                guard let result else {
                    self.updateTask(id: taskID, detail: "Could not resume the task", status: .needsAttention)
                    self.activeTaskIDs.remove(taskID)
                    self.syncPrimaryTaskPausedFlag()
                    return
                }
                self.handleCommandRunResult(
                    taskID: taskID,
                    spawnID: spawnID,
                    isFollowUp: true,
                    result: result
                )
            }
        }
    }

    /// User denied a pending permission. The harness loop already exited at the consent gate, so this
    /// stops the task into a resumable (paused) state — resuming re-runs it and asks again. A Live-path
    /// consent is also told "no" so it stops re-trying.
    func denyPermissionGate(id taskID: String) {
        guard let task = task(withID: taskID),
              task.status == .waitingForPermission else {
            return
        }

        if task.metadata["live.shellConsent"] == "true" {
            Task { [liveController] in
                await liveController.resolvePendingConsent(approved: false, alwaysAllow: false)
            }
            if liveTurn?.taskID == taskID {
                finishLiveTurn(detail: "Permission denied", status: .paused)
                return
            }
        }

        announceLifecycle(
            taskID: taskID,
            UserQueryActivity(kind: .paused, summary: "Permission denied"),
            status: .paused
        )
        activeTaskIDs.remove(taskID)
        syncPrimaryTaskPausedFlag()
    }

    func updateNotchCommandInputTextHeight(_ height: CGFloat) {
        let clampedHeight = UserQueryLayout.clampedComposerInputTextHeight(height)
        guard abs(notchCommandInputTextHeight - clampedHeight) > 0.5 else { return }

        notchCommandInputTextHeight = clampedHeight
    }

    func updateNotchCommandInputExpansion(_ isExpanded: Bool) {
        let shouldExpand = true
        guard isNotchCommandInputExpanded != shouldExpand else { return }

        isNotchCommandInputExpanded = shouldExpand
    }

    var notchCommandInputSurfaceHeight: CGFloat {
        UserQueryLayout.followUpComposerHeight(inputTextHeight: notchCommandInputTextHeight)
    }

    /// Desktop pointer spawning is temporarily disabled. Submissions no longer launch a
    /// traveling cursor; accent assignment and task tracking continue without one. Flip to re-enable.
    private static let spawnPointersEnabled = false

    private func beginSpawn(
        for text: String,
        label: String? = nil,
        taskID: String? = nil,
        accentIndex: Int? = nil
    ) -> String? {
        guard Self.spawnPointersEnabled else { return nil }

        let spawnID = UUID().uuidString
        let displayText = Self.taskLabel(for: text)
        let labelText = label ?? Self.collapsedDisplayText(for: text)
        let spawnAccentIndex: Int
        if let accentIndex {
            spawnAccentIndex = UserQueryAccentPalette.normalizedIndex(accentIndex)
        } else {
            spawnAccentIndex = nextRoundRobinAccentIndex()
        }
        notchAccentIndex = spawnAccentIndex
        let spawnState = UserQuerySpawnState(
            id: spawnID,
            taskID: taskID,
            commandText: text,
            label: labelText,
            accentIndex: spawnAccentIndex,
            phase: .notchCue
        )
        spawnStates.append(spawnState)
        selectedSpawnID = spawnID
        promptState.promptText = displayText
        promptState.leadingSignalLevel = .thinking
        return spawnID
    }

    private func updateSpawn(
        id spawnID: String?,
        taskID: String? = nil,
        commandText: String? = nil,
        label: String? = nil,
        accentIndex: Int? = nil,
        targetHint: UserQuerySpawnTargetHint? = nil,
        phase: UserQuerySpawnPhase? = nil,
        resumesWork: Bool = false
    ) {
        guard let spawnID,
              let index = spawnIndex(id: spawnID) else {
            return
        }

        var spawnState = spawnStates[index]
        if resumesWork {
            spawnState.finishedAt = nil
        }
        if let taskID {
            spawnState.taskID = taskID
        }
        if let commandText {
            spawnState.commandText = commandText
        }
        if let label,
           !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Bound every label: a cursor label is a short status, never a tool's full output. A long
            // result (e.g. app_skill returning a whole skill's instructions) must not blob over the
            // screen — collapse whitespace and cap it.
            spawnState.label = Self.truncated(Self.collapsedDisplayText(for: label), maxLength: Self.maxSpawnLabelLength)
        }
        if let accentIndex {
            spawnState.accentIndex = accentIndex
        }
        if let targetHint {
            spawnState.targetHint = targetHint
        }
        if let phase {
            if spawnState.phase != .notchCue || phase == .fading {
                spawnState.phase = phase
            }
        }
        spawnState.updatedAt = Date()
        spawnStates[index] = spawnState
    }

    private func finishSpawn(
        id spawnID: String?,
        result: UserQueryCommandHandlingResult,
        minimumFadeDelay: TimeInterval? = nil
    ) {
        guard let spawnID,
              let index = spawnIndex(id: spawnID) else {
            return
        }

        var spawnState = spawnStates[index]
        spawnState.label = Self.spawnCompletionLabel(for: result)
        spawnState.updatedAt = Date()
        spawnState.finishedAt = Date()

        // Keep the cursor visible whenever there is a response to read — a clarification, a wait, a
        // failure, OR a completed task that produced a summary (e.g. "Now playing …"). Only a
        // completed action with no summary fades out, so the user always gets to see the result on
        // the cursor and several recent results can stay on screen at once.
        let hasReadableResult = UserQuerySpawnLifecycle.keepsVisibleResult(for: result.threadStatus)
            || !result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasReadableResult {
            spawnState.phase = .holding
            spawnStates[index] = spawnState
        } else {
            spawnStates[index] = spawnState
            scheduleSpawnFade(id: spawnID, after: minimumFadeDelay ?? 0.5)
        }
    }

    private func scheduleSpawnFade(id spawnID: String, after delay: TimeInterval = 0.5) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.5, delay)) { [weak self] in
            guard let self,
                  let index = self.spawnIndex(id: spawnID) else {
                return
            }

            var spawnState = self.spawnStates[index]
            spawnState.phase = .fading
            spawnState.updatedAt = Date()
            self.spawnStates[index] = spawnState
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.removeSpawn(id: spawnID)
            }
        }
    }

    private static func visualizationPlaybackDuration(
        for request: PointerCoachCursorGuideRequest
    ) -> TimeInterval {
        request.steps.reduce(0.5) { total, step in
            total + max(0.82, step.travelDuration) + step.holdDuration
        }
    }

    var notchSpawnCue: UserQuerySpawnState? {
        spawnStates.last { $0.phase == .notchCue }
    }

    private func spawnIndex(id spawnID: String) -> Int? {
        spawnStates.firstIndex { $0.id == spawnID }
    }

    private func spawn(withID spawnID: String) -> UserQuerySpawnState? {
        spawnStates.first { $0.id == spawnID }
    }

    private func latestInteractableSpawnID() -> String? {
        spawnStates
            .last {
                $0.taskID != nil && ($0.phase == .holding || $0.phase == .traveling)
            }?
            .id
    }

    /// Only an EXPLICIT spawn selection force-targets an existing task. A bare new prompt is never
    /// auto-attached to the latest task just because it is the most recent — that route is what made a
    /// new command hijack a running task. Implicit follow-up matching is left entirely to the typed
    /// follow-up resolver, which decides against task content rather than recency.
    private func promptSubmissionFollowUpTarget() -> (spawnID: String, taskID: String)? {
        guard let selectedSpawnID,
              let taskID = taskIDForInteractableSpawn(id: selectedSpawnID) else {
            return nil
        }
        return (selectedSpawnID, taskID)
    }

    private func taskIDForInteractableSpawn(id spawnID: String) -> String? {
        guard let spawn = spawn(withID: spawnID),
              let taskID = spawn.taskID,
              spawn.phase == .holding || spawn.phase == .traveling else {
            return nil
        }

        return taskID
    }

    private func removeSpawn(id spawnID: String) {
        spawnStates.removeAll { $0.id == spawnID }
        if selectedSpawnID == spawnID {
            selectedSpawnID = latestInteractableSpawnID()
        }
    }

    private func prependTask(_ task: UserQueryNotchTask) {
        notchTasks.removeAll { $0.id == task.id }
        notchTasks.insert(task, at: 0)
        if notchTasks.count > Self.notchTaskDisplayLimit {
            notchTasks = Array(notchTasks.prefix(Self.notchTaskDisplayLimit))
        }
        taskStore.upsertTask(task)
    }

    private func clearSubmissionInputs() {
        messageText = ""
        inputTextHeight = UserQueryLayout.composerInputTextMinimumHeight
        isInputExpanded = false
        notchCommandText = ""
        notchCommandInputTextHeight = UserQueryLayout.composerInputTextMinimumHeight
        isNotchCommandInputExpanded = true
        promptState.isVoiceInputActive = false
    }

    private func taskForSubmittedCommand(
        text: String,
        matchedTaskID: String?,
        reservedAccentIndex: Int? = nil
    ) -> UserQueryNotchTask {
        if let matchedTaskID,
           var task = task(withID: matchedTaskID) {
            if let reservedAccentIndex {
                task.accentIndex = UserQueryAccentPalette.normalizedIndex(reservedAccentIndex)
            }
            // A follow-up to a task whose loop is still running is queued into it upstream (it never
            // reaches here). A matched task that reaches this point has a stopped loop, so a new turn
            // resumes it: seed it back to running rather than restarting it under a replaced goal.
            task.detail = Self.runningSeedDetail
            task.status = .running
            task.updatedAt = Date()
            // Restamp the run-start: a resumed run's elapsed time should measure this run, not the idle
            // gap since the task was first created (e.g. a task that failed, sat for hours, then resumed).
            task.createdAt = Date()
            // This branch seeds the task straight to running without going through `updateTask`, so it
            // must apply the same fresh-run metadata reset (see `clearRunMetadata`): otherwise a replied-to
            // thread keeps its stale "seen" (its next terminal state never re-surfaces) and "streaming
            // answer" flag (the new streamed reply appends onto the old answer).
            Self.clearRunMetadata(&task.metadata)
            notchAccentIndex = UserQueryAccentPalette.normalizedIndex(task.accentIndex)
            prependTask(task)
            return task
        }

        let taskLabel = Self.taskLabel(for: text)
        let nextAccentIndex = reservedAccentIndex.map(UserQueryAccentPalette.normalizedIndex)
            ?? nextRoundRobinAccentIndex()
        notchAccentIndex = nextAccentIndex
        let task = UserQueryNotchTask(
            id: UUID().uuidString,
            title: taskLabel,
            detail: Self.runningSeedDetail,
            commandText: text,
            status: .running,
            accentIndex: nextAccentIndex
        )
        prependTask(task)
        return task
    }

    private func taskForDroppedAssets() -> UserQueryNotchTask {
        if let lastActiveTaskID,
           activeTaskIDs.contains(lastActiveTaskID),
           let task = task(withID: lastActiveTaskID) {
            return task
        }

        if let activeTask = notchTasks.first(where: { $0.status == .running || $0.status == .paused }) {
            return activeTask
        }

        if let recentTask = notchTasks.first {
            return recentTask
        }

        let nextAccentIndex = nextRoundRobinAccentIndex()
        notchAccentIndex = nextAccentIndex
        let task = UserQueryNotchTask(
            id: UUID().uuidString,
            title: "Uploaded assets",
            detail: "Assets attached",
            commandText: "",
            status: .needsAttention,
            accentIndex: nextAccentIndex
        )
        prependTask(task)
        return task
    }

    private func task(withID taskID: String) -> UserQueryNotchTask? {
        if let task = notchTasks.first(where: { $0.id == taskID }) {
            return task
        }

        return taskStore
            .loadRecentTasks(limit: max(Self.notchTaskDisplayLimit, Self.followUpCandidateLimit) * 2)
            .first { $0.id == taskID }
    }

    private func commandContext(
        taskID: String,
        isFollowUp: Bool,
        source: AppHarnessTurnSource = .typedPrompt,
        spawnID: String? = nil
    ) -> UserQueryCommandContext? {
        guard let task = task(withID: taskID) else { return nil }

        return UserQueryCommandContext(
            task: task,
            recentEvents: Array(taskStore.loadEvents(taskID: taskID).suffix(10)),
            assets: taskStore.loadAssets(taskID: taskID),
            isFollowUp: isFollowUp,
            turnSource: source,
            spawnProgressChanged: runProgressHandler(taskID: taskID, spawnID: spawnID),
            agentVisualizationChanged: agentVisualizationHandler(for: spawnID)
        )
    }

    /// Streams the agent's live narration into the running task's status line — the planner's per-step
    /// reason as it works ("Working out what you need", the restated goal, each tool's one-line summary)
    /// — so the notch shows what the model is doing now instead of a static seed. The task title keeps
    /// showing the user's prompt; only the status subtext advances. When a spawn pointer is present its
    /// cursor label follows the same narration. Returned unconditionally (even with pointers disabled)
    /// so the status line always advances past its "Thinking" seed.
    private func runProgressHandler(
        taskID: String,
        spawnID: String?
    ) -> (@MainActor @Sendable (UserQuerySpawnProgressUpdate) -> Void)? {
        return { [weak self] update in
            guard let self else { return }

            // A streamed answer chunk accumulates onto the task's detail (the chin and the open row both
            // read it), so the reply types itself out. It bypasses the label path below, which replaces.
            if let answerDelta = update.answerDelta {
                self.appendStreamedAnswer(taskID: taskID, delta: answerDelta, spawnID: spawnID)
                return
            }

            let label = update.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !label.isEmpty, self.task(withID: taskID)?.status == .running {
                self.updateTask(id: taskID, detail: label)
            }
            if let spawnID {
                self.updateSpawn(
                    id: spawnID,
                    label: update.label,
                    targetHint: update.targetHint,
                    phase: update.phase
                )
            }
        }
    }

    /// Append one streamed chunk of the assistant's final reply to the running task's detail. The first
    /// chunk clears the per-step "Thinking" status and flips the streaming flag so the chin shows the
    /// growing answer instead of the prompt; later chunks accumulate onto it. No-op once the task has
    /// left the running state (a late chunk after completion must not reopen the row's status line).
    private func appendStreamedAnswer(taskID: String, delta: String, spawnID: String?) {
        guard let task = task(withID: taskID), task.status == .running else { return }
        let isStreaming = task.metadata[UserQueryNotchTask.streamingAnswerMetadataKey] == "true"
        let newDetail = isStreaming ? task.detail + delta : delta
        var metadata = task.metadata
        metadata[UserQueryNotchTask.streamingAnswerMetadataKey] = "true"
        updateTask(id: taskID, detail: newDetail, metadata: metadata)
        if let spawnID {
            updateSpawn(id: spawnID, label: newDetail)
        }
    }

    private func agentVisualizationHandler(
        for spawnID: String?
    ) -> (@MainActor @Sendable (AgentVisualizationPlan) -> Void)? {
        { [weak self] plan in
            guard let request = plan.cursorOverlayRequest() else { return }
            self?.agentVisualizationPresenter?(request, spawnID)
        }
    }

    private func followUpCandidates() -> [UserQueryFollowUpCandidate] {
        taskStore
            .loadRecentTasks(limit: Self.followUpCandidateLimit)
            .map { task in
                let recentEvents = taskStore
                    .loadEvents(taskID: task.id)
                    .suffix(6)
                    .map { event in
                        Self.truncated("\(event.role.rawValue): \(event.text)", maxLength: 220)
                    }
                let assetNames = taskStore
                    .loadAssets(taskID: task.id)
                    .suffix(8)
                    .map(\.displayName)
                return UserQueryFollowUpCandidate(
                    taskID: task.id,
                    title: task.title,
                    detail: task.detail,
                    commandText: task.commandText,
                    status: task.status,
                    updatedAt: task.updatedAt,
                    recentEvents: recentEvents,
                    assetNames: assetNames
                )
            }
    }

    @discardableResult
    private func appendTaskEvent(taskID: String, role: UserQueryTaskEventRole, text: String) -> String? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }

        let sequence = taskStore.loadEvents(taskID: taskID).count
        let eventID = UUID().uuidString
        taskStore.appendEvent(
            UserQueryTaskEvent(
                id: eventID,
                taskID: taskID,
                role: role,
                text: trimmedText,
                sequence: sequence
            )
        )
        return eventID
    }

    /// The single place a lifecycle transition announces itself. It sets the task's live status line
    /// from the typed activity, records the event in the in-app conversation store, and appends the
    /// same line to `thread.md` — so the conversation record stays the complete history we can render
    /// back to the user. New transitions pass a different `UserQueryActivity` kind; nothing else moves.
    private func announceLifecycle(
        taskID: String,
        _ activity: UserQueryActivity,
        status: UserQueryTaskStatus,
        liveDetail: String? = nil,
        metadata: [String: String]? = nil
    ) {
        updateTask(id: taskID, detail: liveDetail ?? activity.displayText, status: status, metadata: metadata)
        // In-app event store keeps plain text (structured data for the conversation view); thread.md
        // gets the icon-prefixed markdown line.
        _ = appendTaskEvent(taskID: taskID, role: .system, text: activity.displayText)
        recordThreadActivity(taskID: taskID, activity)
    }

    /// Appends a typed activity line to the task's `thread.md` conversation record. The thread file
    /// already exists from the run, so this only ever appends (off the main thread — small file IO).
    private func recordThreadActivity(taskID: String, _ activity: UserQueryActivity) {
        let line = activity.transcriptLine
        Task.detached {
            ThreadTranscript(id: taskID).systemEvent(line)
        }
    }

    private func updateTask(
        id: String,
        title: String? = nil,
        detail: String? = nil,
        status: UserQueryTaskStatus? = nil,
        metadata: [String: String]? = nil
    ) {
        guard let index = notchTasks.firstIndex(where: { $0.id == id }) else { return }

        var task = notchTasks[index]
        let wasRunning = task.status == .running
        if let title {
            task.title = title
        }
        if let detail {
            task.detail = detail
        }
        if let status {
            task.status = status
        }
        if let metadata {
            task.metadata = metadata
        }
        // A stopped task re-entering running begins a fresh run: clear the per-run metadata flags and
        // restamp the run-start so elapsed measures this run, not the idle gap before it. Gated on the
        // prior status so the planner's per-step "still running" updates (and streamed-answer deltas,
        // which re-pass the streaming flag) don't keep resetting it mid-run.
        if status == .running, !wasRunning {
            Self.clearRunMetadata(&task.metadata)
            task.createdAt = Date()
        }
        task.updatedAt = Date()
        notchTasks[index] = task
        taskStore.upsertTask(task)
        syncPrimaryTaskPausedFlag()
    }

    /// How recently a running task must have last advanced to auto-resume itself on relaunch. Inside the
    /// window the work was clearly in progress and should pick back up; outside it, resuming unattended
    /// work the user likely moved on from (and spending credits while they're away) is the wrong default.
    private static let autoResumeStalenessWindow: TimeInterval = 30 * 60

    /// Maps persisted tasks into their post-relaunch state and collects the IDs to auto-resume. A relaunch
    /// tears down every live loop, so an in-flight task can't simply keep running — but one that was
    /// actively working moments ago resumes on its own, while staler or user-blocked work comes back as a
    /// row the user can resume with a tap. The persisted `updatedAt` is preserved throughout so a row's
    /// elapsed time stays the real run duration rather than the gap until the app was reopened.
    static func restoredTasks(
        from tasks: [UserQueryNotchTask],
        now: Date
    ) -> (tasks: [UserQueryNotchTask], autoResumeIDs: [String]) {
        var autoResumeIDs: [String] = []
        let restored = tasks.map { task -> UserQueryNotchTask in
            switch task.status {
            case .running:
                // Actively running when the app quit. Resume on its own only if that was recent;
                // otherwise it becomes a retryable row instead of running stale work unattended.
                if now.timeIntervalSince(task.updatedAt) <= autoResumeStalenessWindow {
                    autoResumeIDs.append(task.id)
                    return task
                }
                var timedOut = task
                timedOut.status = .timedOut
                timedOut.detail = "Timed out — resume"
                return timedOut
            case .waitingForClarification, .waitingForReview, .waitingForPermission:
                // Was blocked on the user; the loop that asked is gone. It comes back simply paused —
                // a clean resumable/repliable row, not an "interrupted" one, since whether the app was
                // restarted is irrelevant to the user. Paused also stays out of the collapsed attention
                // glyph.
                var restoredTask = task
                restoredTask.status = .paused
                restoredTask.detail = "Paused"
                return restoredTask
            default:
                // paused, completed, failed, timedOut, interrupted, needsAttention, chatting: unchanged.
                return task
            }
        }
        return (restored, autoResumeIDs)
    }

    private func refreshPromptStateAfterRunResult(
        taskID: String,
        result: UserQueryCommandHandlingResult
    ) {
        syncPrimaryTaskPausedFlag()
        if promptState.isActive {
            if lastActiveTaskID == taskID {
                lastActiveTaskID = notchTasks.first?.id
            }
            return
        }

        if let runningTask = notchTasks.first(where: { activeTaskIDs.contains($0.id) && $0.status == .running }) {
            promptState.leadingSignalLevel = .thinking
            promptState.promptText = runningTask.title
            return
        }

        if let pausedTask = notchTasks.first(where: { activeTaskIDs.contains($0.id) && $0.status == .paused }) {
            promptState.leadingSignalLevel = .idle
            promptState.promptText = pausedTask.title
            return
        }

        promptState.leadingSignalLevel = result.status == .completed ? .ready : .idle
        promptState.promptText = result.taskLabel ?? result.summary
        if lastActiveTaskID == taskID {
            lastActiveTaskID = notchTasks.first?.id
        }
    }

    private func syncPrimaryTaskPausedFlag() {
        isCurrentTaskPaused = notchTasks.first?.status == .paused
    }

    private static func taskStatus(for result: UserQueryCommandHandlingResult) -> UserQueryTaskStatus {
        result.threadStatus
    }

    private static func spawnCompletionLabel(for result: UserQueryCommandHandlingResult) -> String {
        switch result.threadStatus {
        case .waitingForClarification:
            return "Waiting for detail"
        case .waitingForPermission:
            return "Waiting for approval"
        case .waitingForReview:
            return "Waiting for your review"
        case .interrupted:
            return "Changed course"
        case .needsAttention:
            return "Needs your attention"
        case .running:
            return "Thinking"
        case .paused:
            return "Paused"
        case .chatting:
            return result.summary.isEmpty ? "Answered" : collapsedDisplayText(for: result.summary)
        case .completed:
            // Show what the agent actually did/answered on the cursor, not a generic "Done" — e.g.
            // "Now playing Spies — Coldplay". Falls back to "Done" only for an action with no summary.
            return result.summary.isEmpty ? "Done" : collapsedDisplayText(for: result.summary)
        case .failed:
            return result.summary.isEmpty ? "Stopped" : collapsedDisplayText(for: result.summary)
        case .timedOut:
            return "Timed out — resume"
        }
    }

    private func nextRoundRobinAccentIndex() -> Int {
        guard let mostRecentAccentIndex = spawnStates.last?.accentIndex ?? notchTasks.first?.accentIndex else {
            return UserQueryAccentPalette.firstIndex
        }

        return UserQueryAccentPalette.index(after: mostRecentAccentIndex)
    }

    /// The status line a freshly-started task shows before the agent's first narration lands. Uses the
    /// centralized activity vocabulary ("Thinking") rather than a bare "Running", and is replaced step
    /// by step as `runProgressHandler` streams the planner's narration in.
    private static let runningSeedDetail = UserQueryActivity.Kind.working.label

    /// The task's title is the user's prompt, whitespace-collapsed. It is NOT hard-truncated here: every
    /// place that shows it (the collapsed bar, the prompt pill, each expanded row) renders it on a single
    /// line and tail-truncates to its own available width, so the expanded row title spans the full row
    /// rather than being clipped to a fixed character budget. Capped only by `collapsedDisplayText` so a
    /// runaway prompt can't blob through the store.
    private static func taskLabel(for text: String) -> String {
        let collapsed = collapsedDisplayText(for: text)
        return collapsed.isEmpty ? "New task" : collapsed
    }

    /// A cursor label stays a short status line; cap it so a long tool result never blobs over the
    /// screen. The overlay wraps within this, and the full text is always in the notch task list.
    private static let maxSpawnLabelLength = 200

    private static func collapsedDisplayText(for text: String) -> String {
        let collapsed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return truncated(collapsed, maxLength: maxSpawnLabelLength)
    }

    private static func assetUploadEventText(_ assetNames: [String]) -> String {
        let displayNames = assetNames
            .map { truncated($0, maxLength: 80) }
            .joined(separator: ", ")
        guard !displayNames.isEmpty else { return "Uploaded assets" }

        return "Uploaded assets: \(displayNames)"
    }

    private static func persistedAsset(
        from draft: UserQueryTaskAssetDraft,
        assetID: String,
        taskID: String,
        eventID: String?
    ) -> UserQueryTaskAsset {
        var storedURLString = draft.urlString
        if let sourceURL = URL(string: draft.urlString),
           sourceURL.isFileURL,
           let destinationURL = copyAssetToApplicationSupport(
            sourceURL: sourceURL,
            taskID: taskID,
            assetID: assetID,
            displayName: draft.displayName
           ) {
            storedURLString = destinationURL.absoluteString
        }

        return UserQueryTaskAsset(
            id: assetID,
            taskID: taskID,
            eventID: eventID,
            source: draft.source,
            displayName: draft.displayName,
            contentType: draft.contentType,
            urlString: storedURLString,
            byteCount: draft.byteCount
        )
    }

    private static func copyAssetToApplicationSupport(
        sourceURL: URL,
        taskID: String,
        assetID: String,
        displayName: String
    ) -> URL? {
        guard let assetsDirectory = taskAssetDirectory(taskID: taskID) else { return nil }

        do {
            try FileManager.default.createDirectory(
                at: assetsDirectory,
                withIntermediateDirectories: true
            )
            let fileName = "\(assetID)-\(safeAssetFileName(displayName))"
            let destinationURL = assetsDirectory.appendingPathComponent(fileName, isDirectory: false)
            let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        } catch {
            return nil
        }
    }

    private static func taskAssetDirectory(taskID: String) -> URL? {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        return applicationSupportURL
            .appendingPathComponent("Donkey", isDirectory: true)
            .appendingPathComponent("UserQueryAssets", isDirectory: true)
            .appendingPathComponent(safeAssetFileName(taskID), isDirectory: true)
    }

    private static func safeAssetFileName(_ fileName: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let scalars = fileName.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? Character(scalar) : "-"
        }
        let sanitized = String(scalars)
            .split(separator: "-")
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return sanitized.isEmpty ? "asset" : sanitized
    }

    private static func truncated(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }

        let endIndex = text.index(text.startIndex, offsetBy: maxLength)
        return String(text[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func bundledTheme() -> UserQueryTheme {
        guard let themeURL = Bundle.module.url(forResource: "theme", withExtension: "json"),
              let themeData = try? Data(contentsOf: themeURL),
              let themeConfig = try? JSONDecoder().decode(UserQueryThemeConfig.self, from: themeData),
              let theme = UserQueryTheme.fromConfig(themeConfig) else {
            return .defaultBlue
        }

        return theme
    }
}
