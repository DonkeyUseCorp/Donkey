import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation
import SwiftUI

@MainActor
final class PointerPromptOverlayModel: ObservableObject, PointerPromptIntentSink {
    @Published private(set) var promptState: PointerPromptState
    @Published var messageText = ""
    @Published var placement: PointerPromptPlacement = .bottomRight
    @Published var inputTextHeight = PointerPromptLayout.composerInputTextMinimumHeight
    @Published var isInputExpanded = false
    @Published var notchCommandText = ""
    @Published private(set) var notchCommandInputTextHeight = PointerPromptLayout.composerInputTextMinimumHeight
    @Published private(set) var isNotchCommandInputExpanded = true
    @Published private(set) var notchAccentIndex = 0
    @Published private(set) var isCurrentTaskPaused = false
    @Published private(set) var updateState: PointerPromptUpdateState
    @Published private(set) var notchTasks: [PointerPromptNotchTask]
    @Published private(set) var spawnStates: [PointerPromptSpawnState] = []
    @Published private(set) var selectedSpawnID: String?
    var agentVisualizationPresenter: ((PointerCoachCursorGuideRequest) -> Void)?

    private let commandHandler: any PointerPromptCommandHandling
    private let taskStore: any PointerPromptTaskStoring
    private let followUpResolver: any PointerPromptFollowUpResolving
    private let voiceTranscriber: LocalVoiceTranscriptionAdapter
    private var updateChecker: any DonkeyUpdateChecking
    private let documentReviewController: DocumentFormFillReviewWindowController
    private var activeTaskIDs: Set<String> = []
    private var lastActiveTaskID: String?
    private static let notchTaskDisplayLimit = 12
    private static let followUpCandidateLimit = 8
    private static let followUpMatchConfidenceThreshold = 0.62

    init(
        aiProvider: any AIHarnessSnapshotProviding = AIHarnessBoundary(),
        commandHandler: any PointerPromptCommandHandling = LocalAppPointerPromptCommandHandler(),
        taskStore: any PointerPromptTaskStoring = CoreDataPointerPromptTaskStore(),
        followUpResolver: any PointerPromptFollowUpResolving = HostedTaskFollowUpResolver(),
        voiceTranscriber: LocalVoiceTranscriptionAdapter = LocalVoiceTranscriptionAdapter(
            runtime: ProcessBackedParakeetTranscriptionRuntime()
        ),
        updateChecker: any DonkeyUpdateChecking = SparkleUpdateController(),
        documentReviewController: DocumentFormFillReviewWindowController = DocumentFormFillReviewWindowController(),
        theme: PointerPromptTheme = PointerPromptOverlayModel.bundledTheme()
    ) {
        self.commandHandler = commandHandler
        self.taskStore = taskStore
        self.followUpResolver = followUpResolver
        self.voiceTranscriber = voiceTranscriber
        self.updateChecker = updateChecker
        self.documentReviewController = documentReviewController
        let restoredTasks = Self.restoredTasks(from: taskStore.loadRecentTasks(limit: Self.notchTaskDisplayLimit))
        notchTasks = restoredTasks
        notchAccentIndex = restoredTasks.first.map { PointerPromptAccentPalette.normalizedIndex($0.accentIndex) }
            ?? PointerPromptAccentPalette.firstIndex
        isCurrentTaskPaused = restoredTasks.first?.status == .paused
        updateState = PointerPromptUpdateState(
            currentVersion: updateChecker.currentVersion
        )
        let aiSnapshot = aiProvider.snapshot()
        promptState = PointerPromptState(
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
        checkForUpdates()
    }

    func activate() {
        promptState.isActive = true
        promptState.isPrimaryActionEnabled = true
        promptState.isVoiceInputActive = false
        promptState.leadingSignalLevel = .ready
        promptState.promptText = PointerPromptCopy.defaultPromptPlaceholder
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

    func handle(_ intent: PointerPromptIntent) {
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
            let clampedHeight = PointerPromptLayout.clampedComposerInputTextHeight(height)
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

        let sourceTraceID = "pointer-prompt-voice-\(UUID().uuidString)"
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
        let sourceTraceID = "pointer-prompt-followup-\(UUID().uuidString)"
        let confidenceThreshold = Self.followUpMatchConfidenceThreshold
        Task { [weak self, followUpResolver] in
            let matchedTaskID: String?
            if let taskID = promptFollowUpTarget?.taskID {
                matchedTaskID = taskID
            } else if candidates.isEmpty {
                matchedTaskID = nil
            } else {
                let resolution = await followUpResolver.resolveFollowUp(
                    PointerPromptFollowUpResolverRequest(
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

    func handleDroppedAssets(_ drafts: [PointerPromptTaskAssetDraft]) {
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
        inputTextHeight = PointerPromptLayout.composerInputTextMinimumHeight
        isInputExpanded = false
        notchCommandText = ""
        notchCommandInputTextHeight = PointerPromptLayout.composerInputTextMinimumHeight
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
                guard let self else { return }
                self.updateTask(
                    id: task.id,
                    title: isFollowUp ? nil : result.taskLabel,
                    detail: result.summary,
                    status: Self.taskStatus(for: result)
                )
                self.appendTaskEvent(taskID: task.id, role: .assistant, text: result.summary)
                self.activeTaskIDs.remove(task.id)
                self.refreshPromptStateAfterRunResult(
                    taskID: task.id,
                    result: result
                )
                if let documentReviewRequest = result.documentReviewRequest {
                    self.documentReviewController.show(request: documentReviewRequest)
                }
                if let cursorOverlayRequest = result.cursorOverlayRequest {
                    self.agentVisualizationPresenter?(cursorOverlayRequest)
                }
                self.finishSpawn(id: spawnID, result: result)
            }
        }
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
        guard task(withID: taskID)?.status == .paused else { return }

        activeTaskIDs.insert(taskID)
        lastActiveTaskID = taskID
        updateTask(id: taskID, detail: "Running", status: .running)
        appendTaskEvent(taskID: taskID, role: .system, text: "Resumed")
        promptState.leadingSignalLevel = .thinking
        promptState.promptText = task(withID: taskID)?.title ?? "Working"
        syncPrimaryTaskPausedFlag()
        Task { [weak self, commandHandler] in
            let resumedInMemory = await commandHandler.resumeCommand(taskID: taskID)
            guard !resumedInMemory else { return }

            await MainActor.run {
                self?.startCommandRun(text: "Continue", matchedTaskID: taskID)
            }
        }
    }

    func updateNotchCommandInputTextHeight(_ height: CGFloat) {
        let clampedHeight = PointerPromptLayout.clampedComposerInputTextHeight(height)
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
            spawnAccentIndex = PointerPromptAccentPalette.normalizedIndex(accentIndex)
        } else {
            spawnAccentIndex = nextRoundRobinAccentIndex()
        }
        notchAccentIndex = spawnAccentIndex
        let spawnState = PointerPromptSpawnState(
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
        targetHint: PointerPromptSpawnTargetHint? = nil,
        phase: PointerPromptSpawnPhase? = nil
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
        result: PointerPromptCommandHandlingResult
    ) {
        guard let spawnID,
              let index = spawnIndex(id: spawnID) else {
            return
        }

        var spawnState = spawnStates[index]
        spawnState.label = Self.spawnCompletionLabel(for: result)
        spawnState.updatedAt = Date()

        if PointerPromptSpawnLifecycle.keepsVisibleResult(for: result.threadStatus) {
            spawnState.phase = .holding
            spawnStates[index] = spawnState
        } else {
            spawnStates[index] = spawnState
            scheduleSpawnFade(id: spawnID)
        }
    }

    private func scheduleSpawnFade(id spawnID: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
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

    var notchSpawnCue: PointerPromptSpawnState? {
        spawnStates.last { $0.phase == .notchCue }
    }

    private func spawnIndex(id spawnID: String) -> Int? {
        spawnStates.firstIndex { $0.id == spawnID }
    }

    private func spawn(withID spawnID: String) -> PointerPromptSpawnState? {
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

    private func prependTask(_ task: PointerPromptNotchTask) {
        notchTasks.removeAll { $0.id == task.id }
        notchTasks.insert(task, at: 0)
        if notchTasks.count > Self.notchTaskDisplayLimit {
            notchTasks = Array(notchTasks.prefix(Self.notchTaskDisplayLimit))
        }
        taskStore.upsertTask(task)
    }

    private func clearSubmissionInputs() {
        messageText = ""
        inputTextHeight = PointerPromptLayout.composerInputTextMinimumHeight
        isInputExpanded = false
        notchCommandText = ""
        notchCommandInputTextHeight = PointerPromptLayout.composerInputTextMinimumHeight
        isNotchCommandInputExpanded = true
        promptState.isVoiceInputActive = false
    }

    private func taskForSubmittedCommand(
        text: String,
        matchedTaskID: String?,
        reservedAccentIndex: Int? = nil
    ) -> PointerPromptNotchTask {
        if let matchedTaskID,
           var task = task(withID: matchedTaskID) {
            task.detail = "Running"
            task.status = .running
            task.updatedAt = Date()
            notchAccentIndex = PointerPromptAccentPalette.normalizedIndex(task.accentIndex)
            prependTask(task)
            return task
        }

        let taskLabel = Self.taskLabel(for: text)
        let nextAccentIndex = reservedAccentIndex.map(PointerPromptAccentPalette.normalizedIndex)
            ?? nextRoundRobinAccentIndex()
        notchAccentIndex = nextAccentIndex
        let task = PointerPromptNotchTask(
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

    private func taskForDroppedAssets() -> PointerPromptNotchTask {
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
        let task = PointerPromptNotchTask(
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

    private func task(withID taskID: String) -> PointerPromptNotchTask? {
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
    ) -> PointerPromptCommandContext? {
        guard let task = task(withID: taskID) else { return nil }

        return PointerPromptCommandContext(
            task: task,
            recentEvents: Array(taskStore.loadEvents(taskID: taskID).suffix(10)),
            assets: taskStore.loadAssets(taskID: taskID),
            isFollowUp: isFollowUp,
            turnSource: source,
            spawnProgressChanged: spawnProgressHandler(for: spawnID),
            agentVisualizationChanged: agentVisualizationHandler()
        )
    }

    private func spawnProgressHandler(
        for spawnID: String?
    ) -> (@MainActor @Sendable (PointerPromptSpawnProgressUpdate) -> Void)? {
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

    private func agentVisualizationHandler() -> (@MainActor @Sendable (AgentVisualizationPlan) -> Void)? {
        { [weak self] plan in
            guard let request = plan.cursorOverlayRequest() else { return }
            self?.agentVisualizationPresenter?(request)
        }
    }

    private func followUpCandidates() -> [PointerPromptFollowUpCandidate] {
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
                return PointerPromptFollowUpCandidate(
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
    private func appendTaskEvent(taskID: String, role: PointerPromptTaskEventRole, text: String) -> String? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }

        let sequence = taskStore.loadEvents(taskID: taskID).count
        let eventID = UUID().uuidString
        taskStore.appendEvent(
            PointerPromptTaskEvent(
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
        status: PointerPromptTaskStatus? = nil
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
        task.updatedAt = Date()
        notchTasks[index] = task
        taskStore.upsertTask(task)
        syncPrimaryTaskPausedFlag()
    }

    private static func restoredTasks(from tasks: [PointerPromptNotchTask]) -> [PointerPromptNotchTask] {
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
        result: PointerPromptCommandHandlingResult
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

    private static func taskStatus(for result: PointerPromptCommandHandlingResult) -> PointerPromptTaskStatus {
        result.threadStatus
    }

    private static func spawnCompletionLabel(for result: PointerPromptCommandHandlingResult) -> String {
        switch result.threadStatus {
        case .waitingForClarification:
            return "Waiting for detail"
        case .waitingForReview:
            return "Waiting for your review"
        case .needsAttention:
            return "Needs your attention"
        case .running:
            return "Working"
        case .paused:
            return "Paused"
        case .chatting:
            return result.summary.isEmpty ? "Answered" : result.summary
        case .completed:
            return "Done"
        case .failed:
            return "Stopped"
        }
    }

    private func nextRoundRobinAccentIndex() -> Int {
        guard let mostRecentAccentIndex = spawnStates.last?.accentIndex ?? notchTasks.first?.accentIndex else {
            return PointerPromptAccentPalette.firstIndex
        }

        return PointerPromptAccentPalette.index(after: mostRecentAccentIndex)
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

    private static func persistedAsset(
        from draft: PointerPromptTaskAssetDraft,
        assetID: String,
        taskID: String,
        eventID: String?
    ) -> PointerPromptTaskAsset {
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

        return PointerPromptTaskAsset(
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
            .appendingPathComponent("PointerPromptAssets", isDirectory: true)
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

    private static func bundledTheme() -> PointerPromptTheme {
        guard let themeURL = Bundle.module.url(forResource: "theme", withExtension: "json"),
              let themeData = try? Data(contentsOf: themeURL),
              let themeConfig = try? JSONDecoder().decode(PointerPromptThemeConfig.self, from: themeData),
              let theme = PointerPromptTheme.fromConfig(themeConfig) else {
            return .defaultBlue
        }

        return theme
    }
}
