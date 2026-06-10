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
    var agentVisualizationPresenter: ((PointerCoachCursorGuideRequest, String?) -> Void)?
    /// Fired when the Live session's optional audio streaming should start/stop,
    /// so the mic owner can keep the engine running continuously.
    var onLiveAudioStreamingChanged: ((Bool) -> Void)?

    private let commandHandler: any UserQueryCommandHandling
    private let taskStore: any UserQueryTaskStoring
    private let followUpResolver: any UserQueryFollowUpResolving
    private let voiceTranscriber: LocalVoiceTranscriptionAdapter
    private let liveController: GeminiLiveVoiceController
    private var updateChecker: any DonkeyUpdateChecking
    private let appCatalogRefreshLoop: LocalAppDynamicCatalogRefreshLoop
    private var activeTaskIDs: Set<String> = []
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
        voiceTranscriber: LocalVoiceTranscriptionAdapter = LocalVoiceTranscriptionAdapter(
            runtime: ProcessBackedParakeetTranscriptionRuntime()
        ),
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
        let restoredTasks = Self.restoredTasks(from: taskStore.loadRecentTasks(limit: Self.notchTaskDisplayLimit))
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
    }

    /// Bring up the always-on Gemini Live session. It self-gates on configuration
    /// and only becomes `isConnected` if it can authenticate, so when it is not
    /// configured the existing command pipeline is used unchanged.
    private func startLiveSessionIfEnabled() {
        guard liveController.isEnabled else { return }
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
        // Gemini Live is the always-on brain when connected: text always goes to
        // it (tool-first). When audio is streaming, a batch voice transcript is
        // redundant — the model already heard it — so drop it.
        if liveController.isConnected {
            if source == .voiceTranscript, liveController.isAudioEnabled {
                clearSubmissionInputs()
                promptState.isActive = false
                promptState.isVoiceInputActive = false
                return
            }
            routeToLiveSession(text)
            return
        }
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
            reservedAccentIndex: spawn(withID: spawnID)?.accentIndex
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
        let spawnID: String?
        if let promptFollowUpTarget {
            updateSpawn(
                id: promptFollowUpTarget.spawnID,
                commandText: text,
                label: Self.collapsedDisplayText(for: text),
                phase: .holding
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
            if let taskID = promptFollowUpTarget?.taskID {
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
            phase: .holding
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
        appendTaskEvent(taskID: task.id, role: .user, text: text)
        messageText = ""
        inputTextHeight = UserQueryLayout.composerInputTextMinimumHeight
        isInputExpanded = false
        notchCommandText = ""
        notchCommandInputTextHeight = UserQueryLayout.composerInputTextMinimumHeight
        isNotchCommandInputExpanded = true
        promptState.isActive = false
        promptState.isVoiceInputActive = false
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
    }

    func pauseTask(id taskID: String) {
        guard task(withID: taskID)?.status == .running else { return }

        activeTaskIDs.insert(taskID)
        lastActiveTaskID = taskID
        updateTask(id: taskID, detail: "Paused", status: .paused)
        appendTaskEvent(taskID: taskID, role: .system, text: "Paused")
        syncPrimaryTaskPausedFlag()
        Task { [commandHandler] in
            _ = await commandHandler.pauseCommand(taskID: taskID)
        }
    }

    func resumeTask(id taskID: String) {
        guard let task = task(withID: taskID),
              task.status == .paused || task.status == .interrupted else {
            return
        }

        activeTaskIDs.insert(taskID)
        lastActiveTaskID = taskID
        updateTask(id: taskID, detail: "Running", status: .running)
        appendTaskEvent(taskID: taskID, role: .system, text: "Resumed")
        promptState.leadingSignalLevel = .thinking
        promptState.promptText = task.title
        syncPrimaryTaskPausedFlag()
        Task { [weak self, commandHandler] in
            let resumedInMemory = await commandHandler.resumeCommand(taskID: taskID)
            guard !resumedInMemory else { return }

            await MainActor.run {
                self?.startCommandRun(text: "Continue", matchedTaskID: taskID)
            }
        }
    }

    func approvePermissionGate(id taskID: String, alwaysAllow: Bool = false) {
        guard let task = task(withID: taskID),
              task.status == .waitingForPermission else {
            return
        }

        // A Live-path shell consent resolves through the Live controller, which
        // re-executes the held command and reports back via onActed/onResponse.
        if task.metadata["live.shellConsent"] == "true" {
            updateTask(id: taskID, detail: "Approved — running", status: .running, metadata: [:])
            if let turn = liveTurn, turn.taskID == taskID {
                updateSpawn(id: turn.spawnID, label: "Approved — running")
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
        let detail = Self.permissionApprovalDetail(for: task)
        updateTask(id: taskID, detail: detail, status: .running)
        appendTaskEvent(taskID: taskID, role: .system, text: detail)
        promptState.leadingSignalLevel = .thinking
        promptState.promptText = task.title
        syncPrimaryTaskPausedFlag()
        let spawnID = spawnStates.first { $0.taskID == taskID }?.id
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
        max(92, notchCommandInputTextHeight + 60)
    }

    private func beginSpawn(
        for text: String,
        label: String? = nil,
        taskID: String? = nil,
        accentIndex: Int? = nil
    ) -> String {
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
        phase: UserQuerySpawnPhase? = nil
    ) {
        guard let spawnID,
              let index = spawnIndex(id: spawnID) else {
            return
        }

        var spawnState = spawnStates[index]
        if let taskID {
            spawnState.taskID = taskID
        }
        if let commandText {
            spawnState.commandText = commandText
        }
        if let label,
           !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            spawnState.label = label
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

    private func promptSubmissionFollowUpTarget() -> (spawnID: String, taskID: String)? {
        if let selectedSpawnID,
           let taskID = taskIDForInteractableSpawn(id: selectedSpawnID) {
            return (selectedSpawnID, taskID)
        }

        guard let spawnID = latestInteractableSpawnID(),
              let taskID = taskIDForInteractableSpawn(id: spawnID) else {
            return nil
        }

        return (spawnID, taskID)
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
            if Self.shouldShowChangedCourseState(for: task) {
                task.detail = "Changed course: \(Self.collapsedDisplayText(for: text))"
                task.status = .interrupted
                task.metadata["genericHarness.taskStatus"] = "interrupted"
                task.metadata["genericHarness.newGoal"] = text
            } else {
                task.detail = "Running"
                task.status = .running
            }
            task.updatedAt = Date()
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
            detail: "Running",
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
            spawnProgressChanged: spawnProgressHandler(for: spawnID),
            agentVisualizationChanged: agentVisualizationHandler(for: spawnID)
        )
    }

    private func spawnProgressHandler(
        for spawnID: String?
    ) -> (@MainActor @Sendable (UserQuerySpawnProgressUpdate) -> Void)? {
        guard let spawnID else { return nil }

        return { [weak self] update in
            self?.updateSpawn(
                id: spawnID,
                label: update.label,
                targetHint: update.targetHint,
                phase: update.phase
            )
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

    private func updateTask(
        id: String,
        title: String? = nil,
        detail: String? = nil,
        status: UserQueryTaskStatus? = nil,
        metadata: [String: String]? = nil
    ) {
        guard let index = notchTasks.firstIndex(where: { $0.id == id }) else { return }

        var task = notchTasks[index]
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
        task.updatedAt = Date()
        notchTasks[index] = task
        taskStore.upsertTask(task)
        syncPrimaryTaskPausedFlag()
    }

    private static func restoredTasks(from tasks: [UserQueryNotchTask]) -> [UserQueryNotchTask] {
        tasks.map { task in
            guard task.status == .running else { return task }

            var restoredTask = task
            restoredTask.status = .needsAttention
            restoredTask.detail = "Interrupted"
            restoredTask.updatedAt = Date()
            return restoredTask
        }
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
            return "Working"
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
        }
    }

    private func nextRoundRobinAccentIndex() -> Int {
        guard let mostRecentAccentIndex = spawnStates.last?.accentIndex ?? notchTasks.first?.accentIndex else {
            return UserQueryAccentPalette.firstIndex
        }

        return UserQueryAccentPalette.index(after: mostRecentAccentIndex)
    }

    private static func taskLabel(for text: String) -> String {
        let collapsed = collapsedDisplayText(for: text)
        guard !collapsed.isEmpty else { return "New task" }

        let maxLength = 44
        guard collapsed.count > maxLength else { return collapsed }

        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: maxLength)
        return String(collapsed[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func collapsedDisplayText(for text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func assetUploadEventText(_ assetNames: [String]) -> String {
        let displayNames = assetNames
            .map { truncated($0, maxLength: 80) }
            .joined(separator: ", ")
        guard !displayNames.isEmpty else { return "Uploaded assets" }

        return "Uploaded assets: \(displayNames)"
    }

    private static func permissionApprovalDetail(for task: UserQueryNotchTask) -> String {
        let permissions = task.metadata["genericHarness.missingPermissions"]?
            .split(separator: ",")
            .map(String.init)
            .filter { !$0.isEmpty } ?? []
        guard !permissions.isEmpty else {
            return "Approving permission"
        }

        return "Approving \(permissions.joined(separator: ", "))"
    }

    private static func shouldShowChangedCourseState(for task: UserQueryNotchTask) -> Bool {
        switch task.status {
        case .running, .interrupted:
            return true
        case .chatting,
             .paused,
             .completed,
             .waitingForClarification,
             .waitingForPermission,
             .waitingForReview,
             .needsAttention,
             .failed:
            return false
        }
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
