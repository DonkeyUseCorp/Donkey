import AppKit
import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation
import SwiftUI

/// Direction the keyboard arrows move the expanded-notch row highlight.
enum NotchArrowDirection {
    case up
    case down
}

@MainActor
final class UserQueryOverlayModel: ObservableObject, UserQueryIntentSink {
    @Published private(set) var promptState: UserQueryState
    @Published var messageText = ""
    @Published var placement: UserQueryPlacement = .bottomRight
    @Published var inputTextHeight = UserQueryLayout.composerInputTextMinimumHeight
    @Published var isInputExpanded = false
    @Published var notchCommandText = "" {
        didSet {
            // Starting a draft hands the arrows back to the composer for text editing; the row
            // highlight re-engages when the user clicks or arrows onto a row (see `focusNotchRow`).
            if !notchCommandText.isEmpty { selectedConversationID = nil }
        }
    }
    @Published private(set) var notchCommandInputTextHeight = UserQueryLayout.composerInputTextMinimumHeight
    @Published private(set) var isNotchCommandInputExpanded = true
    @Published private(set) var notchAccentIndex = 0
    @Published private(set) var isCurrentConversationPaused = false
    @Published private(set) var updateState: UserQueryUpdateState
    @Published private(set) var notchConversations: [UserQueryConversation]
    @Published private(set) var spawnStates: [UserQuerySpawnState] = []
    @Published private(set) var selectedSpawnID: String?
    /// Files dropped on the notch, staged as removable preview chips above the composer. They are
    /// committed to a conversation — and onto its workspace, where the planner reads them — only when
    /// the next message is submitted; the chip's ✕ takes a drop back before then.
    @Published private(set) var stagedNotchAssets: [UserQueryStagedAsset] = []
    /// The files the user attached to each displayed conversation (keyed by conversation id), rendered
    /// as clickable pills in the conversation's row. Loaded when a conversation enters the rail and
    /// appended to as staged drops commit.
    @Published private(set) var notchConversationAssets: [String: [UserQueryConversationAsset]] = [:]
    /// The files each conversation's runs produced (keyed by conversation id), rendered as output pills
    /// in the row — one file as its own pill, several as one folder pill. Refreshed when a run finishes
    /// and once at launch for restored conversations.
    @Published private(set) var notchConversationOutputs: [String: UserQueryWorkspaceOutputs] = [:]
    /// Logged out: the notch renders a login call-to-action instead of the conversation surface. The app
    /// delegate pushes this from the auth coordinator's session state (true while signed out after a
    /// prior sign-in, i.e. an expired session) and clears it once sign-in completes.
    @Published private(set) var needsLogin = false
    /// Presents the agent's pointer playback for a conversation. The conversation ID binds the pointer's
    /// lifetime to its row: the controller remembers which conversation a standalone pointer belongs to so
    /// `agentVisualizationDismisser` can tear it down when that row is deleted.
    var agentVisualizationPresenter: ((PointerCoachCursorGuideRequest, _ conversationID: String, _ preferredSpawnID: String?) -> Void)?
    /// Clears any pointer playback still on screen for a conversation. Fired when a row is dismissed so a
    /// standalone pointer never outlives the row it was narrating.
    var agentVisualizationDismisser: ((_ conversationID: String) -> Void)?
    /// Fired when the notch Login button is tapped, so the app delegate can start the real sign-in
    /// (the Google browser flow). The model never opens browsers or windows itself.
    var loginActionRequested: (() -> Void)?
    /// Fired when a hosted request fails authentication mid-run (an expired session). The app delegate
    /// wires this to sign out, which flips the notch into login mode while the running conversations stay put.
    var sessionExpired: (() -> Void)?
    /// Fired when the Live session's optional audio streaming should start/stop,
    /// so the mic owner can keep the engine running continuously.
    var onLiveAudioStreamingChanged: ((Bool) -> Void)?

    private var commandHandler: any UserQueryCommandHandling
    private let conversationStore: any UserQueryConversationStoring
    private let followUpResolver: any UserQueryFollowUpResolving
    private let voiceTranscriber: LocalVoiceTranscriptionAdapter
    private let liveController: GeminiLiveVoiceController
    private var updateChecker: any DonkeyUpdateChecking
    private let appCatalogRefreshLoop: LocalAppDynamicCatalogRefreshLoop
    private var activeAgentIDs: Set<String> = []
    /// Resume requests made while a conversation's previous loop was still winding down (e.g. a quick Stop→Resume).
    /// The resume is deferred here and fired by `handleCommandRunResult` once that loop ends, so two loops
    /// never run on one conversation and the tap is never silently dropped.
    private var pendingResumeConversationIDs: Set<String> = []
    /// The conversation an explicit Reply tap pinned the next submission to (a conversation waiting on the user — a
    /// clarification or review). It routes the answer straight to that conversation instead of leaving the
    /// follow-up resolver to guess, and the expanded panel dims every other row while it is set so the
    /// user sees which thread their reply continues. Consumed by the next submission.
    @Published private(set) var replyTargetConversationID: String?
    /// The conversation row the keyboard arrows currently highlight in the expanded notch, or nil when the
    /// composer holds the focus. Distinct from `replyTargetConversationID`: arrowing only moves this highlight;
    /// pressing Return on it begins a reply (like clicking the row). Typing into the composer clears it
    /// so the arrows return to editing the draft; clicking a row re-engages it.
    @Published private(set) var selectedConversationID: String?
    /// Metadata flag marking a terminal conversation (completed or failed) as seen — set when the user expands
    /// the notch. It lives on the conversation (and so is persisted through the conversation store) rather than in memory,
    /// so an acknowledged failure stays dismissed across relaunches instead of re-surfacing every launch.
    private static let seenMetadataKey = "notch.seen"

    /// Clear the "seen" dismissal a conversation carries into a fresh running run, so its next terminal state
    /// re-surfaces in the collapsed notch. Applied at every stopped→running transition — both the in-place
    /// resume (`updateConversation`) and the matched-resume seed (`conversationForSubmittedCommand`), which bypasses
    /// `updateConversation`. The same transitions also reset `conversationsStreamingAnswer`.
    private static func clearRunMetadata(_ metadata: inout [String: String]) {
        metadata[seenMetadataKey] = nil
        // A fresh run attempt drops the stale out-of-credits CTA; if the new run hits 402 again the harness
        // re-sets the flag. (The balance poll is the other clear path — see `clearPendingCreditReload`.)
        metadata[UserQueryConversationMetadataKey.creditReloadRequired] = nil
    }

    /// Conversation IDs whose final answer is mid-stream. Tracks first-vs-subsequent answer chunk so the
    /// first chunk replaces the last step narration and the rest accumulate onto it. In-memory only —
    /// streaming is a live-render concern, not durable conversation state — and reset alongside
    /// `clearRunMetadata` at every stopped→running transition so a new run's reply replaces the old one.
    private var conversationsStreamingAnswer: Set<String> = []

    private var lastActiveConversationID: String?
    /// The conversation/spawn the in-flight Gemini Live turn reports into, so the user
    /// sees the same cursor-and-conversation feedback as a local pipeline run.
    private var liveTurn: (conversationID: String, spawnID: String?)?
    private var liveTurnWatchdog: Task<Void, Never>?
    private static let notchConversationDisplayLimit = 12
    private static let followUpCandidateLimit = 8
    /// Stable id for the app-managed tool-setup conversation, so a relaunch (or re-download for a new
    /// version) reuses the one row instead of stacking a fresh one each time. See `startSystemToolsSetupIfNeeded`.
    private static let toolsSetupConversationID = "system.tools-setup"
    private static let followUpMatchConfidenceThreshold = 0.62
    /// How long a Live turn may stay silent (no tool, no answer) before the conversation
    /// is failed instead of spinning forever.
    private static let liveTurnSilenceLimitSeconds: TimeInterval = 75

    init(
        aiProvider: any AIHarnessSnapshotProviding = AIHarnessBoundary(),
        commandHandler: any UserQueryCommandHandling = LocalAppUserQueryCommandHandler(),
        conversationStore: any UserQueryConversationStoring = CoreDataUserQueryConversationStore(),
        followUpResolver: any UserQueryFollowUpResolving = HostedConversationFollowUpResolver(),
        voiceTranscriber: LocalVoiceTranscriptionAdapter = LocalVoiceTranscriptionAdapter(),
        updateChecker: any DonkeyUpdateChecking = SparkleUpdateController(),
        liveController: GeminiLiveVoiceController = GeminiLiveVoiceController(),
        theme: UserQueryTheme = UserQueryOverlayModel.bundledTheme()
    ) {
        self.commandHandler = commandHandler
        self.conversationStore = conversationStore
        self.followUpResolver = followUpResolver
        self.voiceTranscriber = voiceTranscriber
        self.liveController = liveController
        self.updateChecker = updateChecker
        self.appCatalogRefreshLoop = LocalAppDynamicCatalogRefreshLoop(
            profileGenerator: HostedLocalAppCatalogProfileGenerator()
        )
        let restoration = Self.restoredConversations(
            from: conversationStore.loadRecentConversations(limit: Self.notchConversationDisplayLimit),
            now: Date()
        )
        let restoredConversations = restoration.conversations
        notchConversations = restoredConversations
        var restoredAssets: [String: [UserQueryConversationAsset]] = [:]
        for conversation in restoredConversations {
            restoredAssets[conversation.id] = conversationStore
                .loadAssets(conversationID: conversation.id)
                .filter { $0.source == .userUploaded }
        }
        notchConversationAssets = restoredAssets
        notchAccentIndex = restoredConversations.first.map { UserQueryAccentPalette.normalizedIndex($0.accentIndex) }
            ?? UserQueryAccentPalette.firstIndex
        isCurrentConversationPaused = restoredConversations.first?.status == .paused
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
        // Staged drops never outlive the session that staged them; clear leftovers from a prior run.
        Self.purgeStagedAssets()
        SQLiteAgentMemoryStore.shared?.prewarmDefaultLocalItemsInBackground()
        appCatalogRefreshLoop.start()
        checkForUpdates()
        startLiveSessionIfEnabled()
        // A mid-run 401 from the hosted backend means the session expired: surface login (the app
        // delegate wires `sessionExpired` to the auth coordinator) while the running conversations stay put.
        self.commandHandler.onAuthenticationRequired = { [weak self] in
            self?.handleSessionExpired()
        }
        autoResumeInterruptedConversations(restoration.autoResumeIDs)
        for conversation in restoredConversations {
            refreshConversationOutputs(conversationID: conversation.id)
        }
    }

    /// Resume conversations that were actively running when the app last quit (see `restoredConversations`). Each runs as
    /// an unattended BACKGROUND turn — the user may not be present — so it never raises an app or moves
    /// the cursor; progress narrates into the conversation's own row. Fires once, at launch.
    private func autoResumeInterruptedConversations(_ conversationIDs: [String]) {
        guard !conversationIDs.isEmpty else { return }
        // Don't drive the harness while signed out — every planner step would 401. The interrupted
        // conversations stay retryable and resume on the next launch (or manual retry) once signed in.
        guard BackendSessionGate.shared.isAuthenticated else { return }
        for conversationID in conversationIDs {
            guard let context = commandContext(conversationID: conversationID, isFollowUp: false, source: .followUp, spawnID: nil) else {
                continue
            }
            activeAgentIDs.insert(conversationID)
            Task { [weak self, commandHandler] in
                let result = await commandHandler.autoResumeCommand(conversationID: conversationID, context: context)
                await MainActor.run {
                    guard let self else { return }
                    // No goal to resume, or the unattended run couldn't even start (no frontmost app,
                    // backend off): keep the conversation retryable rather than failing it, so the user can resume
                    // it later. Only a run that actually executed reports its real outcome.
                    if result == nil || result?.metadata["harness.abortReason"] != nil {
                        self.activeAgentIDs.remove(conversationID)
                        self.updateConversation(id: conversationID, detail: "Interrupted — resume", status: .timedOut)
                        return
                    }
                    self.handleCommandRunResult(conversationID: conversationID, spawnID: nil, isFollowUp: false, result: result!)
                }
            }
        }
    }

    // MARK: - System tool setup (first-run bundle download)

    /// Begin the app-managed download of the bundled CLI tools, surfaced as a normal-looking conversation
    /// the user can watch but never stop, resume, reply to, or dismiss (it is `origin == .system`; every
    /// control gates on `isUserControllable`). The app delegate calls this once the notch surfaces are up.
    /// The installer no-ops when the bundle is already current or nothing is published, so it is cheap to
    /// call on every launch and sign-in, and it handles its own retries — the row just narrates them.
    func startSystemToolsSetupIfNeeded() {
        reconcileInterruptedSystemSetup()
        Task { [weak self] in
            await BundledToolsInstaller.shared.installIfNeeded(onEvent: { event in
                Task { @MainActor in self?.applyToolsSetupEvent(event) }
            })
        }
    }

    /// A relaunch tears down the install loop, so a setup row persisted mid-run can't keep advancing on its
    /// own. Settle it before the fresh install run (which reconciles it for real): if the tools are present
    /// it reads as ready; otherwise drop the stale row so the run below re-creates it only if work remains.
    private func reconcileInterruptedSystemSetup() {
        let id = Self.toolsSetupConversationID
        guard let conversation = conversation(withID: id),
              conversation.origin == .system,
              conversation.status != .completed,
              conversation.status != .failed else {
            return
        }
        if BundledTools.isCurrentVersionReady {
            updateConversation(id: id, detail: "Tools ready", status: .completed)
        } else {
            notchConversations.removeAll { $0.id == id }
            conversationStore.deleteConversation(id: id)
        }
    }

    /// Map one installer event onto the setup conversation. Discrete transitions announce through the
    /// lifecycle path (event log + thread record); the download's percent stream is a detail-only update so
    /// it doesn't spam an event per percent. The conversation stays `.running` through retries — the user
    /// can't act on it, so a momentary "failed" would only alarm; only a final give-up reads as `.failed`.
    private func applyToolsSetupEvent(_ event: BundledToolsSetupEvent) {
        let id = Self.toolsSetupConversationID
        switch event {
        case .started:
            ensureSystemSetupConversation()
            announceLifecycle(
                conversationID: id,
                UserQueryActivity(kind: .working, summary: "Setting up Donkey’s tools"),
                status: .running
            )
        case .downloading(let fraction):
            ensureSystemSetupConversation()
            let line = fraction.map { "Downloading tools — \(Int(($0 * 100).rounded()))%" } ?? "Downloading tools…"
            if conversation(withID: id)?.detail != line {
                updateConversation(id: id, detail: line, status: .running)
            }
        case .verifying:
            updateConversation(id: id, detail: "Verifying tools…", status: .running)
        case .installing:
            updateConversation(id: id, detail: "Installing tools…", status: .running)
        case .retrying(let attempt, let maxAttempts):
            updateConversation(
                id: id,
                detail: "Download interrupted — retrying (\(attempt)/\(maxAttempts))…",
                status: .running
            )
        case .completed:
            announceLifecycle(
                conversationID: id,
                UserQueryActivity(kind: .completed, summary: "Tools ready"),
                status: .completed
            )
            scheduleSystemSetupAutoAcknowledge(id: id)
        case .failed:
            // The row carries a Retry action while failed (see `retrySystemToolsSetup`), so the message
            // states the outcome plainly rather than promising an automatic retry the user can't see.
            announceLifecycle(
                conversationID: id,
                UserQueryActivity(kind: .failed, summary: "Couldn’t finish setting up tools"),
                status: .failed
            )
            scheduleSystemSetupAutoAcknowledge(id: id)
        }
    }

    /// Re-run the bundled-tools install for a setup row the user tapped Retry on. The launch-time run gives
    /// up after a few attempts and parks the row at `.failed`; this lets the user drive a fresh attempt then
    /// and there — no relaunch. Re-open the row to running immediately so the tap registers and the
    /// `status == .failed` guard makes a second tap a no-op (no double-launch). The installer's own events
    /// then drive the row to completed/failed; if it returns having done nothing (tools already current, so
    /// no events fired) the result settles the optimistic row so it never spins forever.
    func retrySystemToolsSetup(id: String) {
        guard let conversation = conversation(withID: id),
              conversation.origin == .system,
              conversation.status == .failed else {
            return
        }
        updateConversation(id: id, detail: "Retrying…", status: .running)
        Task { [weak self] in
            let installed = await BundledToolsInstaller.shared.installIfNeeded(onEvent: { event in
                Task { @MainActor in self?.applyToolsSetupEvent(event) }
            })
            await MainActor.run {
                guard let self,
                      self.conversation(withID: id)?.status == .running else { return }
                self.applyToolsSetupEvent(installed ? .completed : .failed)
            }
        }
    }

    /// Create the setup row on the first event of a fresh run, or re-open the persisted one to running for a
    /// new version's download (which clears its "seen" flag so it resurfaces). Reuses the stable id.
    private func ensureSystemSetupConversation() {
        let id = Self.toolsSetupConversationID
        if let existing = conversation(withID: id) {
            if existing.status != .running {
                updateConversation(id: id, status: .running)
            }
            return
        }
        let conversation = UserQueryConversation(
            id: id,
            title: "Setting up Donkey’s tools",
            detail: "Preparing…",
            commandText: "",
            status: .running,
            accentIndex: nextRoundRobinAccentIndex(),
            origin: .system
        )
        prependConversation(conversation)
    }

    /// The user can't dismiss a system row, so a finished one would otherwise pin the collapsed chin
    /// forever. Mark it seen after a short read so the chin settles on its own; the row stays in the list
    /// (and history) like any other completed conversation.
    private func scheduleSystemSetupAutoAcknowledge(id: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self,
                  let index = self.notchConversations.firstIndex(where: { $0.id == id }),
                  Self.isSurfacedTerminalStatus(self.notchConversations[index].status) else {
                return
            }
            var conversation = self.notchConversations[index]
            conversation.metadata[Self.seenMetadataKey] = "true"
            self.notchConversations[index] = conversation
            self.conversationStore.upsertConversation(conversation)
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
            // through Live — no loop). The pipeline has its own conversation/spawn UI.
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
            self.updateConversation(id: liveTurn.conversationID, detail: summary, status: .running)
            self.appendAgentEvent(conversationID: liveTurn.conversationID, role: .system, text: summary)
            self.restartLiveTurnWatchdog()
        }
        liveController.onResponse = { [weak self] answer in
            guard let self else { return }
            self.promptState.leadingSignalLevel = .ready
            self.promptState.promptText = answer
            guard let liveTurn = self.liveTurn else { return }
            self.appendAgentEvent(conversationID: liveTurn.conversationID, role: .assistant, text: answer)
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

    func installAvailableUpdate() {
        updateChecker.installAvailableUpdate()
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

    /// The notch "Reload credits" CTA was tapped on a credit-exhausted conversation. Open the billing page in
    /// the browser (donkeyuse.com in prod, localhost in dev — the configured web base URL) so the user
    /// can top up; the conversation stays on the row so it can be re-run once credits land.
    func reloadCredits(id conversationID: String) {
        let billingURL = DonkeyAuthConfiguration.current().webBaseURL
            .appendingPathComponent("app/settings")
        NSWorkspace.shared.open(billingURL)
    }

    /// Whether any task still carries the out-of-credits reload CTA. The app delegate's reconciler reads this
    /// to decide whether to spend a balance poll at all — with nothing flagged, the periodic tick is a free
    /// no-op and never touches the network.
    var hasPendingCreditReload: Bool {
        notchConversations.contains {
            $0.metadata[UserQueryConversationMetadataKey.creditReloadRequired] == "true"
        }
    }

    /// Drop the out-of-credits reload CTA from every task that carries it, in the notch and in storage. Called
    /// once the balance poll confirms the account has credits again (see the app delegate's reconciler), so the
    /// CTA disappears the moment a top-up lands rather than lingering until the next launch. The balance is
    /// account-wide, so a positive balance clears every credit-blocked task at once.
    func clearPendingCreditReload() {
        for index in notchConversations.indices
        where notchConversations[index].metadata[UserQueryConversationMetadataKey.creditReloadRequired] == "true" {
            var conversation = notchConversations[index]
            conversation.metadata[UserQueryConversationMetadataKey.creditReloadRequired] = nil
            conversation.updatedAt = Date()
            notchConversations[index] = conversation
            conversationStore.upsertConversation(conversation)
        }
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
    /// local run: a conversation in the rail and a spawn cursor that narrates tool
    /// activity, consent gates, and the final answer.
    private func routeToLiveSession(_ text: String) {
        if liveTurn != nil {
            finishLiveTurn(detail: "Changed course", status: .interrupted)
        }
        let spawnID = beginSpawn(for: text)
        let conversation = conversationForSubmittedCommand(
            text: text,
            matchedConversationID: nil,
            reservedAccentIndex: spawnID.flatMap { spawn(withID: $0)?.accentIndex }
        )
        updateSpawn(id: spawnID, conversationID: conversation.id, accentIndex: conversation.accentIndex)
        activeAgentIDs.insert(conversation.id)
        lastActiveConversationID = conversation.id
        appendAgentEvent(conversationID: conversation.id, role: .user, text: text)
        clearSubmissionInputs()
        promptState.isActive = false
        promptState.isVoiceInputActive = false
        promptState.leadingSignalLevel = .thinking
        promptState.promptText = conversation.title
        liveTurn = (conversation.id, spawnID)
        restartLiveTurnWatchdog()
        Task { [liveController] in await liveController.sendText(text) }
    }

    /// Close out the in-flight Live turn's conversation and spawn.
    private func finishLiveTurn(detail: String?, status: UserQueryConversationStatus) {
        liveTurnWatchdog?.cancel()
        liveTurnWatchdog = nil
        guard let turn = liveTurn else { return }
        liveTurn = nil
        updateConversation(id: turn.conversationID, detail: detail, status: status)
        activeAgentIDs.remove(turn.conversationID)
        syncPrimaryConversationPausedFlag()
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
    /// past the limit, instead of leaving the conversation spinning.
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

    /// Surface a Live-path shell consent in the notch using the same conversation
    /// metadata the harness consent UI reads, marked so approval routes back to
    /// the Live controller instead of the harness lifecycle.
    private func presentLiveShellConsent(_ request: GeminiLiveShellConsentRequest) {
        guard let turn = liveTurn else { return }
        liveTurnWatchdog?.cancel()
        updateSpawn(id: turn.spawnID, label: "Waiting for approval", phase: .holding)
        updateConversation(
            id: turn.conversationID,
            detail: request.summary,
            status: .waitingForPermission,
            metadata: [
                "genericHarness.shellConsent.command": request.command,
                "genericHarness.shellConsent.tier": request.tier,
                "genericHarness.shellConsent.allowAlways": request.allowAlways ? "true" : "false",
                "live.shellConsent": "true"
            ]
        )
        appendAgentEvent(conversationID: turn.conversationID, role: .system, text: request.summary)
        promptState.leadingSignalLevel = .ready
        promptState.promptText = request.summary
        syncPrimaryConversationPausedFlag()
    }

    private func runLocalCommand(_ text: String, source: AppHarnessTurnSource = .typedPrompt) {
        // The submitted message takes the staged drops with it: drained here, committed onto whichever
        // conversation the turn resolves to, so the chips clear the moment the message leaves.
        let stagedAssets = stagedNotchAssets
        stagedNotchAssets = []
        let candidates = followUpCandidates()
        let promptFollowUpTarget = promptSubmissionFollowUpTarget()
        let replyTargetConversationID = consumePendingReplyTarget()
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
            let matchedConversationID: String?
            if let replyTargetConversationID {
                // An explicit Reply pins the answer to that conversation — never re-routed by the resolver.
                matchedConversationID = replyTargetConversationID
            } else if let conversationID = promptFollowUpTarget?.conversationID {
                matchedConversationID = conversationID
            } else if candidates.isEmpty {
                matchedConversationID = nil
            } else {
                let resolution = await followUpResolver.resolveFollowUp(
                    UserQueryFollowUpResolverRequest(
                        text: text,
                        candidates: candidates,
                        sourceTraceID: sourceTraceID
                    )
                )
                if let conversationID = resolution.conversationID,
                   resolution.confidence >= confidenceThreshold {
                    matchedConversationID = conversationID
                } else {
                    matchedConversationID = nil
                }
            }

            await MainActor.run {
                self?.startCommandRun(
                    text: text,
                    matchedConversationID: matchedConversationID,
                    source: source,
                    spawnID: spawnID,
                    stagedAssets: stagedAssets
                )
            }
        }
    }

    /// Stage dropped files as chips above the composer. Each file is copied into a staging directory
    /// immediately — drags out of browsers and mail hand over temporary files that can vanish before the
    /// user submits — so the chip and the eventual commit always read from a stable copy.
    func handleDroppedAssets(_ drafts: [UserQueryConversationAssetDraft]) {
        for draft in drafts {
            let stagedID = UUID().uuidString
            var stagedDraft = draft
            if let sourceURL = URL(string: draft.urlString),
               sourceURL.isFileURL,
               let stagedURL = Self.copyAssetToStaging(
                sourceURL: sourceURL,
                stagedID: stagedID,
                displayName: draft.displayName
               ) {
                stagedDraft.urlString = stagedURL.absoluteString
            }
            stagedNotchAssets.append(UserQueryStagedAsset(id: stagedID, draft: stagedDraft))
        }
    }

    func removeStagedAsset(id: String) {
        guard let index = stagedNotchAssets.firstIndex(where: { $0.id == id }) else { return }

        Self.deleteStagedAssetFile(urlString: stagedNotchAssets[index].draft.urlString)
        stagedNotchAssets.remove(at: index)
    }

    /// Re-read what the conversation's runs have produced and publish it for the row's output pills.
    /// Fired when a run finishes and once per restored conversation at launch.
    private func refreshConversationOutputs(conversationID: String) {
        Task { [weak self, commandHandler] in
            let outputs = await commandHandler.workspaceOutputs(conversationID: conversationID)
            await MainActor.run {
                guard let self else { return }
                if let outputs {
                    self.notchConversationOutputs[conversationID] = outputs
                } else {
                    self.notchConversationOutputs.removeValue(forKey: conversationID)
                }
            }
        }
    }

    /// Move staged drops onto the conversation the submitted turn resolved to: each becomes a persisted
    /// user-uploaded asset (copied into the conversation's asset directory) and its staging copy is
    /// deleted. Returns the persisted assets so a live loop can register them onto its workspace.
    @discardableResult
    private func commitStagedAssets(
        _ stagedAssets: [UserQueryStagedAsset],
        conversationID: String,
        eventID: String?
    ) -> [UserQueryConversationAsset] {
        let committedAssets = stagedAssets.map { staged in
            let asset = Self.persistedAsset(
                from: staged.draft,
                assetID: staged.id,
                conversationID: conversationID,
                eventID: eventID
            )
            conversationStore.appendAsset(asset)
            Self.deleteStagedAssetFile(urlString: staged.draft.urlString)
            return asset
        }
        if !committedAssets.isEmpty {
            notchConversationAssets[conversationID, default: []].append(contentsOf: committedAssets)
        }
        return committedAssets
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

    func submitSpawnFollowUp(spawnID: String, conversationID: String, text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty,
              conversationIDForInteractableSpawn(id: spawnID) == conversationID else {
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
            matchedConversationID: conversationID,
            source: .followUp,
            spawnID: spawnID
        )
    }

    private func startCommandRun(
        text: String,
        matchedConversationID: String?,
        source: AppHarnessTurnSource = .typedPrompt,
        spawnID: String? = nil,
        stagedAssets: [UserQueryStagedAsset] = []
    ) {
        // A follow-up to a conversation whose loop is still running — or one blocked at a permission gate — is
        // queued into that conversation: the running loop folds it in at its next step, and a gated conversation keeps its
        // gate and drains the follow-up when the user approves. Either way it must NOT start a second run
        // or clear the gate. Everything else (a brand-new command, or a follow-up to a stopped conversation) takes
        // the fresh/resume path below, which runs concurrently with any other in-flight conversation.
        let matchedStatus = matchedConversationID.flatMap { conversation(withID: $0)?.status }
        if let matchedConversationID, matchedStatus == .running || matchedStatus == .waitingForPermission {
            queueFollowUpIntoRunningConversation(
                text: text,
                conversationID: matchedConversationID,
                source: source,
                spawnID: spawnID,
                stagedAssets: stagedAssets
            )
            return
        }
        runFreshOrResumedCommand(
            text: text,
            matchedConversationID: matchedConversationID,
            source: source,
            spawnID: spawnID,
            stagedAssets: stagedAssets
        )
    }

    /// Queue a follow-up onto a conversation whose loop is still running. The live loop picks it up at its next
    /// step; if the loop happens to finish first, fall back to resuming the conversation with the instruction.
    private func queueFollowUpIntoRunningConversation(
        text: String,
        conversationID: String,
        source: AppHarnessTurnSource,
        spawnID: String?,
        stagedAssets: [UserQueryStagedAsset] = []
    ) {
        let eventID = appendAgentEvent(conversationID: conversationID, role: .user, text: text)
        // Commit the drops now and hand them to the live loop, which registers them onto the running
        // conversation's workspace so the planner sees the new inputs at its next step.
        let committedAssets = commitStagedAssets(stagedAssets, conversationID: conversationID, eventID: eventID)
        updateSpawn(id: spawnID, conversationID: conversationID)
        clearSubmissionInputs()
        lastActiveConversationID = conversationID
        promptState.isActive = false
        promptState.isVoiceInputActive = false
        promptState.leadingSignalLevel = .thinking
        promptState.promptText = conversation(withID: conversationID)?.title ?? Self.collapsedDisplayText(for: text)
        syncPrimaryConversationPausedFlag()
        Task { [weak self, commandHandler] in
            let injected = await commandHandler.injectFollowUp(
                conversationID: conversationID,
                text: text,
                assets: committedAssets
            )
            guard !injected else { return }
            // Race: the loop finished between the live check and the enqueue. Resume the conversation with the
            // instruction instead. The user event and assets are already recorded, so neither is added again;
            // the resumed run picks the assets up from the conversation store.
            await MainActor.run {
                self?.runFreshOrResumedCommand(
                    text: text,
                    matchedConversationID: conversationID,
                    source: source,
                    spawnID: spawnID,
                    appendUserEvent: false
                )
            }
        }
    }

    private func runFreshOrResumedCommand(
        text: String,
        matchedConversationID: String?,
        source: AppHarnessTurnSource = .typedPrompt,
        spawnID: String? = nil,
        appendUserEvent: Bool = true,
        stagedAssets: [UserQueryStagedAsset] = []
    ) {
        let isFollowUp = matchedConversationID != nil
        let reservedAccentIndex = spawnID.flatMap { spawn(withID: $0)?.accentIndex }
        let conversation = conversationForSubmittedCommand(
            text: text,
            matchedConversationID: matchedConversationID,
            reservedAccentIndex: reservedAccentIndex
        )
        updateSpawn(
            id: spawnID,
            conversationID: conversation.id,
            accentIndex: conversation.accentIndex
        )
        activeAgentIDs.insert(conversation.id)
        lastActiveConversationID = conversation.id
        var userEventID: String?
        if appendUserEvent {
            userEventID = appendAgentEvent(conversationID: conversation.id, role: .user, text: text)
        }
        // Committed before the run context is built below, so the turn's asset load already includes
        // the drops and the harness registers them onto the conversation workspace for the planner.
        commitStagedAssets(stagedAssets, conversationID: conversation.id, eventID: userEventID)
        clearSubmissionInputs()
        promptState.isActive = false
        promptState.leadingSignalLevel = .thinking
        promptState.promptText = conversation.title
        syncPrimaryConversationPausedFlag()
        let context = commandContext(
            conversationID: conversation.id,
            isFollowUp: isFollowUp,
            source: source,
            spawnID: spawnID
        )
        Task { [weak self, commandHandler] in
            let result = await commandHandler.handleSubmittedCommand(text, context: context)
            await MainActor.run {
                self?.handleCommandRunResult(
                    conversationID: conversation.id,
                    spawnID: spawnID,
                    isFollowUp: isFollowUp,
                    result: result
                )
            }
        }
    }

    /// Apply a finished pipeline run to the conversation rail, prompt pill, cursor
    /// replay, and spawn — shared by fresh submissions and post-approval resumes.
    private func handleCommandRunResult(
        conversationID: String,
        spawnID: String?,
        isFollowUp: Bool,
        result: UserQueryCommandHandlingResult
    ) {
        updateConversation(
            id: conversationID,
            title: isFollowUp ? nil : result.conversationLabel,
            detail: result.summary,
            status: Self.conversationStatus(for: result),
            metadata: result.metadata
        )
        appendAgentEvent(conversationID: conversationID, role: .assistant, text: result.summary)
        activeAgentIDs.remove(conversationID)
        refreshConversationOutputs(conversationID: conversationID)
        refreshPromptStateAfterRunResult(conversationID: conversationID, result: result)
        let cursorOverlayRequest = result.cursorOverlayRequest
        if let cursorOverlayRequest {
            agentVisualizationPresenter?(cursorOverlayRequest, conversationID, spawnID)
        }
        finishSpawn(
            id: spawnID,
            result: result,
            minimumFadeDelay: cursorOverlayRequest.map(Self.visualizationPlaybackDuration)
        )
        // Honor a resume requested while this loop was still winding down (e.g. Stop→Resume): now that the
        // loop has ended and the conversation left activeAgentIDs, the resume can start without racing a live loop.
        if pendingResumeConversationIDs.remove(conversationID) != nil {
            resumeAgent(id: conversationID)
        }
    }

    /// Move the expanded-notch focus with the arrows. With a row already focused, Up/Down step through the
    /// rows and clamp at the ends — reaching the top or bottom holds that row rather than dropping back to
    /// the composer — so the selection is never lost mid-navigation. With nothing focused the arrows enter
    /// the list (Up at the bottom row nearest the composer, Down at the top); landing on a row does exactly
    /// what clicking it does (highlight + pinned reply, other rows dim). Returns whether the key was
    /// consumed; at the composer with a draft already typed, the arrows fall through to edit the text.
    @discardableResult
    func moveNotchSelection(_ direction: NotchArrowDirection) -> Bool {
        guard !notchConversations.isEmpty else { return false }
        let lastIndex = notchConversations.count - 1
        guard let current = selectedConversationID.flatMap({ id in notchConversations.firstIndex { $0.id == id } }) else {
            // No row focused yet: enter the list, but only when the composer isn't holding a draft.
            if !notchCommandText.isEmpty { return false }
            let entry = direction == .up ? lastIndex : 0
            focusNotchRow(notchConversations[entry].id)
            return true
        }
        let next: Int
        switch direction {
        case .up: next = max(0, current - 1)
        case .down: next = min(lastIndex, current + 1)
        }
        focusNotchRow(notchConversations[next].id)
        return true
    }

    /// Make `conversationID` the focused thread — the shared effect of clicking a row and of arrowing onto it: it
    /// becomes the keyboard highlight and the reply target (its pointer lights, the composer takes its
    /// accent, and the other rows dim). Passing nil (Escape, or leaving reply) clears both, the same as
    /// clicking bare chrome.
    func focusNotchRow(_ conversationID: String?) {
        selectedConversationID = conversationID
        guard let conversationID, let conversation = conversation(withID: conversationID) else {
            replyTargetConversationID = nil
            return
        }
        // A system-driven row (tool setup) can be highlighted, but the user can't reply to it, so it never
        // becomes the reply target — a Return on it is inert rather than pinning the composer to it.
        guard conversation.isUserControllable else {
            replyTargetConversationID = nil
            return
        }
        replyTargetConversationID = conversationID
        lastActiveConversationID = conversationID
    }

    func clearNotchSelection() {
        selectedConversationID = nil
    }

    /// Submit a generative options form (user.choose) for a conversation waiting on the user. The picks are
    /// encoded into the one response line the planner reads back ("Selected options: id=value, …") and
    /// routed as that conversation's reply — the exact path a typed clarification answer takes — so the
    /// harness resumes the task with the choices. No-op if the conversation isn't actually awaiting a form.
    func submitChoiceForm(conversationID: String, selection: [String: String]) {
        guard let conversation = conversation(withID: conversationID),
              conversation.status == .waitingForClarification else {
            return
        }
        let response: String
        if let json = conversation.metadata["genericHarness.choiceForm"],
           let form = HarnessChoiceForm.decode(fromJSON: json) {
            response = form.encodeSelectionResponse(selection)
        } else {
            response = "Selected options: "
                + selection.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
        }
        // Pin the answer to the waiting conversation so it resumes that thread rather than starting a new one.
        replyTargetConversationID = conversationID
        runLocalCommand(response)
    }

    /// Take the pinned Reply target, if any, for the submission about to run. Cleared on read so it only
    /// applies to the one answer (which also un-dims the rows), and dropped if the conversation is no longer
    /// around (fall back to normal routing).
    private func consumePendingReplyTarget() -> String? {
        guard let conversationID = replyTargetConversationID else { return nil }
        replyTargetConversationID = nil
        // Drop the pin only if the conversation vanished between the tap and the submit (e.g. it was closed);
        // otherwise the message is pinned to it whatever its current state (`startCommandRun` routes a
        // running/permission-gated target into a queued follow-up, a stopped/terminal one resumes).
        return conversation(withID: conversationID) != nil ? conversationID : nil
    }

    func pauseAgent(id conversationID: String) {
        guard let conversation = conversation(withID: conversationID),
              conversation.isUserControllable,
              conversation.status == .running else { return }

        activeAgentIDs.insert(conversationID)
        lastActiveConversationID = conversationID
        announceLifecycle(conversationID: conversationID, UserQueryActivity(kind: .paused), status: .paused)
        syncPrimaryConversationPausedFlag()
        Task { [commandHandler] in
            _ = await commandHandler.pauseCommand(conversationID: conversationID)
        }
    }

    func resumeAgent(id conversationID: String) {
        guard let conversation = conversation(withID: conversationID),
              conversation.isUserControllable,
              [.paused, .interrupted, .timedOut, .needsAttention].contains(conversation.status) else {
            return
        }
        // Only run a conversation with real work behind it; an info-only row (e.g. an asset drop) has no goal, so
        // resuming would dead-end. Such rows shouldn't offer Resume, but guard here too.
        guard !conversation.commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // If the conversation's previous loop is still winding down (e.g. just Stopped), defer the resume until it
        // ends so two loops never run on one conversation; handleCommandRunResult fires the deferred resume.
        guard !activeAgentIDs.contains(conversationID) else {
            pendingResumeConversationIDs.insert(conversationID)
            return
        }

        activeAgentIDs.insert(conversationID)
        lastActiveConversationID = conversationID
        // Show the live "Resuming" line until the first step narrates; an empty detail would let the chin
        // fall back to the title (the original prompt), which is the stale line a resume must not resurface.
        announceLifecycle(conversationID: conversationID, UserQueryActivity(kind: .resumed), status: .running)
        updateSpawn(id: spawnStates.first { $0.conversationID == conversationID }?.id, resumesWork: true)
        promptState.leadingSignalLevel = .thinking
        promptState.promptText = conversation.title
        syncPrimaryConversationPausedFlag()
        // Pausing or a relaunch tears the loop down, so there is no suspended loop to continue in memory:
        // re-run the conversation's existing goal as a fresh loop. The persisted world model and history carry the
        // context forward, so it continues the work rather than starting over.
        let context = commandContext(conversationID: conversationID, isFollowUp: false, source: .followUp, spawnID: nil)
        Task { [weak self, commandHandler] in
            guard let result = await commandHandler.continueApprovedCommand(conversationID: conversationID, context: context) else {
                // Nothing to resume (e.g. the harness snapshot is gone): restore a retryable row rather
                // than leaving it stuck on the optimistic "running" with no loop behind it.
                await MainActor.run {
                    self?.activeAgentIDs.remove(conversationID)
                    self?.updateConversation(id: conversationID, detail: "Couldn’t resume — tap to retry", status: .timedOut)
                }
                return
            }
            await MainActor.run {
                self?.handleCommandRunResult(conversationID: conversationID, spawnID: nil, isFollowUp: false, result: result)
            }
        }
    }

    /// The conversations the collapsed notch keeps surfaced as floating pointers: anything running, anything
    /// blocked on the user (a clarification, a review, or a permission), plus terminal conversations (a finished
    /// action, a conversational reply, or a failure) the user hasn't dismissed yet by expanding the notch.
    /// A failure — like an auth error —
    /// holds the chin until acknowledged just as a completion does; a waiting conversation keeps its pointer lit
    /// and pulsing (and its question in the chin) until the user answers.
    var notchSurfacedConversations: [UserQueryConversation] {
        notchConversations.filter { conversation in
            conversation.status == .running ||
                Self.isWaitingOnUserStatus(conversation.status) ||
                (Self.isSurfacedTerminalStatus(conversation.status) && !Self.isSeen(conversation))
        }
    }

    /// Whether a status is blocked waiting on the user — a clarification or review to answer, or a
    /// permission to approve. Mirrors the notch view's `isWaitingOnUser`.
    private static func isWaitingOnUserStatus(_ status: UserQueryConversationStatus) -> Bool {
        status.isAwaitingUserResponse || status == .waitingForPermission
    }

    /// Marks every currently-terminal conversation (a finished action, a conversational reply, or a failure) as
    /// seen so it stops surfacing in the
    /// collapsed notch. Called when the notch expands — the user is now looking at the full list. The
    /// flag is written to the conversation store, so the dismissal sticks across relaunches.
    func acknowledgeSurfacedConversations() {
        for index in notchConversations.indices where Self.isSurfacedTerminalStatus(notchConversations[index].status) && !Self.isSeen(notchConversations[index]) {
            var conversation = notchConversations[index]
            conversation.metadata[Self.seenMetadataKey] = "true"
            notchConversations[index] = conversation
            conversationStore.upsertConversation(conversation)
        }
    }

    private static func isSurfacedTerminalStatus(_ status: UserQueryConversationStatus) -> Bool {
        // A conversational reply (`.chatting`) surfaces like a completion: the back-and-forth has to land
        // in the chin until the user acknowledges it by expanding, the same as a finished action.
        status == .completed || status == .chatting || status == .failed
    }

    private static func isSeen(_ conversation: UserQueryConversation) -> Bool {
        conversation.metadata[seenMetadataKey] == "true"
    }

    /// Closes a conversation: removes it from the notch list and tears down its pointer.
    /// Offered only for stopped (paused/interrupted/failed) and completed conversations —
    /// the same affordance the prototype calls "close".
    func dismissConversation(id conversationID: String) {
        guard let conversation = conversation(withID: conversationID) else { return }
        // A system-driven conversation (tool setup) is the app's to run while it works, but once it has
        // finished it is just a notice the user can clear — so a completed/failed system row is dismissible
        // too (see `isUserDismissible`). A still-running one stays the app's.
        guard conversation.isUserDismissible else { return }
        guard conversation.status != .running else { return }

        notchConversations.removeAll { $0.id == conversationID }
        activeAgentIDs.remove(conversationID)
        notchConversationAssets.removeValue(forKey: conversationID)
        notchConversationOutputs.removeValue(forKey: conversationID)
        // Closing the targeted conversation ends reply mode so the remaining rows don't stay dimmed.
        if replyTargetConversationID == conversationID {
            replyTargetConversationID = nil
        }
        if selectedConversationID == conversationID {
            selectedConversationID = nil
        }
        if lastActiveConversationID == conversationID {
            lastActiveConversationID = notchConversations.first?.id
        }
        if let spawnID = spawnStates.first(where: { $0.conversationID == conversationID })?.id {
            removeSpawn(id: spawnID)
        }
        // Tear down any pointer playback still narrating this row. Spawn cursors are removed above; this
        // covers the standalone pointer overlay, which is keyed by conversation rather than spawn and would
        // otherwise linger after the row is gone.
        agentVisualizationDismisser?(conversationID)
        // Drop the persisted row (and its events/assets) too, so the conversation does not
        // reappear when the notch reloads recent conversations on the next launch.
        conversationStore.deleteConversation(id: conversationID)
        syncPrimaryConversationPausedFlag()
        // Return the free-floating prompt line to rest once this was the last row. The collapsed notch
        // reads `promptState` only when no conversation row exists, so a dismissed conversation's summary
        // left stranded in `promptText` kept rendering — the row read as "still listed" (with a generic
        // "Needs attention") even though it was gone. Resetting once the list empties is what actually
        // makes the X clear the notch.
        resetPromptLineIfNotchEmptied()
    }

    /// The prompt line the collapsed notch falls back to after a dismissal. Empty list → the resting
    /// placeholder, never the dismissed conversation's stranded summary; with rows remaining the collapsed
    /// notch reads them directly, so the line is left as the live flows set it (nil = leave untouched).
    static func restingPromptText(forRemainingConversations conversations: [UserQueryConversation]) -> String? {
        conversations.isEmpty ? UserQueryCopy.defaultPromptPlaceholder : nil
    }

    /// Apply `restingPromptText` to the live prompt state after the notch list changes. Skipped while the
    /// composer is active so it never clobbers what the user is typing into.
    private func resetPromptLineIfNotchEmptied() {
        guard !promptState.isActive,
              let restingText = Self.restingPromptText(forRemainingConversations: notchConversations) else { return }
        promptState.promptText = restingText
        promptState.leadingSignalLevel = .ready
    }

    func approvePermissionGate(id conversationID: String, alwaysAllow: Bool = false) {
        guard let conversation = conversation(withID: conversationID),
              conversation.status == .waitingForPermission else {
            return
        }

        // A Live-path shell consent resolves through the Live controller, which
        // re-executes the held command and reports back via onActed/onResponse.
        if conversation.metadata["live.shellConsent"] == "true" {
            announceLifecycle(
                conversationID: conversationID,
                UserQueryActivity(kind: .resumed),
                status: .running,
                metadata: [:]
            )
            if let turn = liveTurn, turn.conversationID == conversationID {
                updateSpawn(id: turn.spawnID, label: UserQueryActivity.Kind.resumed.label, resumesWork: true)
                restartLiveTurnWatchdog()
            }
            syncPrimaryConversationPausedFlag()
            Task { [liveController] in
                await liveController.resolvePendingConsent(approved: true, alwaysAllow: alwaysAllow)
            }
            return
        }

        activeAgentIDs.insert(conversationID)
        lastActiveConversationID = conversationID
        // After approval the conversation resumes on the live "Resuming" line until the first step narrates;
        // an empty detail would let the chin fall back to the title (the original prompt), the stale line the
        // user sees "reappear" after granting a gate.
        announceLifecycle(conversationID: conversationID, UserQueryActivity(kind: .resumed), status: .running)
        promptState.leadingSignalLevel = .thinking
        promptState.promptText = conversation.title
        syncPrimaryConversationPausedFlag()
        let spawnID = spawnStates.first { $0.conversationID == conversationID }?.id
        updateSpawn(id: spawnID, resumesWork: true)
        let context = commandContext(conversationID: conversationID, isFollowUp: true, spawnID: spawnID)
        Task { [weak self, commandHandler] in
            let approved = await commandHandler.approvePermissionGate(conversationID: conversationID, alwaysAllow: alwaysAllow)
            guard approved else {
                await MainActor.run {
                    guard let self else { return }
                    self.updateConversation(id: conversationID, detail: "Approval unavailable", status: .needsAttention)
                    self.activeAgentIDs.remove(conversationID)
                    self.syncPrimaryConversationPausedFlag()
                }
                return
            }
            // The grant only recorded consent; the loop already exited at the
            // gate. Re-run it so the approved command actually executes.
            let result = await commandHandler.continueApprovedCommand(conversationID: conversationID, context: context)
            await MainActor.run {
                guard let self else { return }
                guard let result else {
                    self.updateConversation(id: conversationID, detail: "Could not resume the task", status: .needsAttention)
                    self.activeAgentIDs.remove(conversationID)
                    self.syncPrimaryConversationPausedFlag()
                    return
                }
                self.handleCommandRunResult(
                    conversationID: conversationID,
                    spawnID: spawnID,
                    isFollowUp: true,
                    result: result
                )
            }
        }
    }

    /// User denied a pending permission. The harness loop already exited at the consent gate, so this
    /// stops the conversation into a resumable (paused) state — resuming re-runs it and asks again. A Live-path
    /// consent is also told "no" so it stops re-trying.
    func denyPermissionGate(id conversationID: String) {
        guard let conversation = conversation(withID: conversationID),
              conversation.status == .waitingForPermission else {
            return
        }

        if conversation.metadata["live.shellConsent"] == "true" {
            Task { [liveController] in
                await liveController.resolvePendingConsent(approved: false, alwaysAllow: false)
            }
            if liveTurn?.conversationID == conversationID {
                finishLiveTurn(detail: "Permission denied", status: .paused)
                return
            }
        }

        announceLifecycle(
            conversationID: conversationID,
            UserQueryActivity(kind: .paused, summary: "Permission denied"),
            status: .paused
        )
        activeAgentIDs.remove(conversationID)
        syncPrimaryConversationPausedFlag()
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
    /// traveling cursor; accent assignment and conversation tracking continue without one. Flip to re-enable.
    private static let spawnPointersEnabled = false

    private func beginSpawn(
        for text: String,
        label: String? = nil,
        conversationID: String? = nil,
        accentIndex: Int? = nil
    ) -> String? {
        guard Self.spawnPointersEnabled else { return nil }

        let spawnID = UUID().uuidString
        let displayText = Self.conversationLabel(for: text)
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
            conversationID: conversationID,
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
        conversationID: String? = nil,
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
        if let conversationID {
            spawnState.conversationID = conversationID
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
        // failure, OR a completed conversation that produced a summary (e.g. "Now playing …"). Only a
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
                $0.conversationID != nil && ($0.phase == .holding || $0.phase == .traveling)
            }?
            .id
    }

    /// Only an EXPLICIT spawn selection force-targets an existing conversation. A bare new prompt is never
    /// auto-attached to the latest conversation just because it is the most recent — that route is what made a
    /// new command hijack a running conversation. Implicit follow-up matching is left entirely to the typed
    /// follow-up resolver, which decides against conversation content rather than recency.
    private func promptSubmissionFollowUpTarget() -> (spawnID: String, conversationID: String)? {
        guard let selectedSpawnID,
              let conversationID = conversationIDForInteractableSpawn(id: selectedSpawnID) else {
            return nil
        }
        return (selectedSpawnID, conversationID)
    }

    private func conversationIDForInteractableSpawn(id spawnID: String) -> String? {
        guard let spawn = spawn(withID: spawnID),
              let conversationID = spawn.conversationID,
              spawn.phase == .holding || spawn.phase == .traveling else {
            return nil
        }

        return conversationID
    }

    private func removeSpawn(id spawnID: String) {
        spawnStates.removeAll { $0.id == spawnID }
        if selectedSpawnID == spawnID {
            selectedSpawnID = latestInteractableSpawnID()
        }
    }

    private func prependConversation(_ conversation: UserQueryConversation) {
        notchConversations.removeAll { $0.id == conversation.id }
        notchConversations.insert(conversation, at: 0)
        if notchConversations.count > Self.notchConversationDisplayLimit {
            notchConversations = Array(notchConversations.prefix(Self.notchConversationDisplayLimit))
        }
        // An older conversation re-entering the rail (a matched follow-up) brings its attached files
        // back with it; a brand-new conversation just seeds an empty entry.
        if notchConversationAssets[conversation.id] == nil {
            notchConversationAssets[conversation.id] = conversationStore
                .loadAssets(conversationID: conversation.id)
                .filter { $0.source == .userUploaded }
        }
        conversationStore.upsertConversation(conversation)
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

    private func conversationForSubmittedCommand(
        text: String,
        matchedConversationID: String?,
        reservedAccentIndex: Int? = nil
    ) -> UserQueryConversation {
        if let matchedConversationID,
           var conversation = conversation(withID: matchedConversationID) {
            if let reservedAccentIndex {
                conversation.accentIndex = UserQueryAccentPalette.normalizedIndex(reservedAccentIndex)
            }
            // A follow-up to a conversation whose loop is still running is queued into it upstream (it never
            // reaches here). A matched conversation that reaches this point has a stopped loop, so a new turn
            // resumes it: seed it back to running rather than restarting it under a replaced goal.
            //
            // The chin shows the conversation's latest line (`detail`), so seed both the command and that
            // line with what the user just sent; the agent's narration and reply overwrite `detail` from
            // there. (`appendAgentEvent` also writes these for the resume path, but the inject path seeds
            // straight here, so set them at the source too.)
            conversation.commandText = text
            conversation.detail = text
            conversation.status = .running
            conversation.updatedAt = Date()
            // Resume the clock. If the conversation already stopped (the normal case) this opens a fresh
            // stretch as of now, so the idle gap since it stopped isn't counted; if it somehow reaches here
            // still running (the queue-path race) the open is a no-op and the live stretch keeps counting.
            // Either way cumulative time is preserved — opening can't drop or restart it.
            conversation.openRunningStretch(asOf: Date())
            // This branch seeds the conversation straight to running without going through `updateConversation`, so it
            // must apply the same fresh-run metadata reset (see `clearRunMetadata`): otherwise a replied-to
            // thread keeps its stale "seen" (its next terminal state never re-surfaces) and "streaming
            // answer" flag (the new streamed reply appends onto the old answer).
            Self.clearRunMetadata(&conversation.metadata)
            conversationsStreamingAnswer.remove(conversation.id)
            notchAccentIndex = UserQueryAccentPalette.normalizedIndex(conversation.accentIndex)
            prependConversation(conversation)
            return conversation
        }

        let conversationLabel = Self.conversationLabel(for: text)
        let nextAccentIndex = reservedAccentIndex.map(UserQueryAccentPalette.normalizedIndex)
            ?? nextRoundRobinAccentIndex()
        notchAccentIndex = nextAccentIndex
        let conversation = UserQueryConversation(
            id: UUID().uuidString,
            title: conversationLabel,
            detail: text,
            commandText: text,
            status: .running,
            accentIndex: nextAccentIndex
        )
        prependConversation(conversation)
        return conversation
    }

    private func conversation(withID conversationID: String) -> UserQueryConversation? {
        if let conversation = notchConversations.first(where: { $0.id == conversationID }) {
            return conversation
        }

        return conversationStore
            .loadRecentConversations(limit: max(Self.notchConversationDisplayLimit, Self.followUpCandidateLimit) * 2)
            .first { $0.id == conversationID }
    }

    private func commandContext(
        conversationID: String,
        isFollowUp: Bool,
        source: AppHarnessTurnSource = .typedPrompt,
        spawnID: String? = nil
    ) -> UserQueryCommandContext? {
        guard let conversation = conversation(withID: conversationID) else { return nil }

        return UserQueryCommandContext(
            conversation: conversation,
            recentEvents: Array(conversationStore.loadEvents(conversationID: conversationID).suffix(10)),
            assets: conversationStore.loadAssets(conversationID: conversationID),
            isFollowUp: isFollowUp,
            turnSource: source,
            spawnProgressChanged: runProgressHandler(conversationID: conversationID, spawnID: spawnID),
            agentVisualizationChanged: agentVisualizationHandler(conversationID: conversationID, spawnID: spawnID)
        )
    }

    /// Streams the agent's live narration into the running conversation's status line — the planner's per-step
    /// reason as it works ("Working out what you need", the restated goal, each tool's one-line summary)
    /// — so the notch shows what the model is doing now instead of a static seed. The conversation title keeps
    /// showing the user's prompt; only the status subtext advances. When a spawn pointer is present its
    /// cursor label follows the same narration. Returned unconditionally (even with pointers disabled)
    /// so the status line always advances past its "Thinking" seed.
    private func runProgressHandler(
        conversationID: String,
        spawnID: String?
    ) -> (@MainActor @Sendable (UserQuerySpawnProgressUpdate) -> Void)? {
        return { [weak self] update in
            guard let self else { return }

            // A streamed answer chunk accumulates onto the conversation's detail (the chin and the open row both
            // read it), so the reply types itself out. It bypasses the label path below, which replaces.
            if let answerDelta = update.answerDelta {
                self.appendStreamedAnswer(conversationID: conversationID, delta: answerDelta, spawnID: spawnID)
                return
            }

            let label = update.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !label.isEmpty, self.conversation(withID: conversationID)?.status == .running {
                self.updateConversation(id: conversationID, detail: label)
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

    /// Append one streamed chunk of the assistant's final reply to the running conversation's detail. The first
    /// chunk clears the per-step "Thinking" status and flips the streaming flag so the chin shows the
    /// growing answer instead of the prompt; later chunks accumulate onto it. No-op once the conversation has
    /// left the running state (a late chunk after completion must not reopen the row's status line).
    private func appendStreamedAnswer(conversationID: String, delta: String, spawnID: String?) {
        guard let conversation = conversation(withID: conversationID), conversation.status == .running else { return }
        let isStreaming = conversationsStreamingAnswer.contains(conversationID)
        let newDetail = isStreaming ? conversation.detail + delta : delta
        conversationsStreamingAnswer.insert(conversationID)
        updateConversation(id: conversationID, detail: newDetail)
        if let spawnID {
            updateSpawn(id: spawnID, label: newDetail)
        }
    }

    private func agentVisualizationHandler(
        conversationID: String,
        spawnID: String?
    ) -> (@MainActor @Sendable (AgentVisualizationPlan) -> Void)? {
        { [weak self] plan in
            guard let request = plan.cursorOverlayRequest() else { return }
            self?.agentVisualizationPresenter?(request, conversationID, spawnID)
        }
    }

    private func followUpCandidates() -> [UserQueryFollowUpCandidate] {
        let recent = conversationStore.loadRecentConversations(limit: Self.followUpCandidateLimit)
        // The follow-up resolver only ever continues one of the user's own conversations: a system-driven
        // row (tool setup) is never a target for the user's next message.
        return Self.activeFollowUpCandidates(from: recent, now: Date())
            .filter { $0.isUserControllable }
            .map { conversation in
                let recentEvents = conversationStore
                    .loadEvents(conversationID: conversation.id)
                    .suffix(6)
                    .map { event in
                        Self.truncated("\(event.role.rawValue): \(event.text)", maxLength: 220)
                    }
                let assetNames = conversationStore
                    .loadAssets(conversationID: conversation.id)
                    .suffix(8)
                    .map(\.displayName)
                return UserQueryFollowUpCandidate(
                    conversationID: conversation.id,
                    title: conversation.title,
                    detail: conversation.detail,
                    commandText: conversation.commandText,
                    status: conversation.status,
                    updatedAt: conversation.updatedAt,
                    recentEvents: recentEvents,
                    assetNames: assetNames
                )
            }
    }

    @discardableResult
    private func appendAgentEvent(conversationID: String, role: UserQueryConversationEventRole, text: String) -> String? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }

        let sequence = conversationStore.loadEvents(conversationID: conversationID).count
        let eventID = UUID().uuidString
        conversationStore.appendEvent(
            UserQueryConversationEvent(
                id: eventID,
                conversationID: conversationID,
                role: role,
                text: trimmedText,
                sequence: sequence
            )
        )
        // The chin shows the latest line of the conversation, and `detail` holds it. A user message is the
        // newest line the instant it is sent, so write it here — the one chokepoint every user turn crosses
        // (fresh, follow-up, resumed, or folded into a still-running conversation via the inject path) — rather than
        // at each call site, where a path that forgets leaves the chin reading back an older line. Clear any
        // in-flight streamed answer so the agent's next reply replaces this message instead of appending to
        // it; keep `commandText` in sync for the other surfaces (prompt pill, follow-up matching).
        if role == .user {
            conversationsStreamingAnswer.remove(conversationID)
            updateConversation(id: conversationID, commandText: trimmedText, detail: trimmedText)
        }
        return eventID
    }

    /// The single place a lifecycle transition announces itself. It sets the conversation's live status line
    /// from the typed activity, records the event in the in-app conversation store, and appends the
    /// same line to `thread.md` — so the conversation record stays the complete history we can render
    /// back to the user. New transitions pass a different `UserQueryActivity` kind; nothing else moves.
    private func announceLifecycle(
        conversationID: String,
        _ activity: UserQueryActivity,
        status: UserQueryConversationStatus,
        liveDetail: String? = nil,
        metadata: [String: String]? = nil
    ) {
        updateConversation(id: conversationID, detail: liveDetail ?? activity.displayText, status: status, metadata: metadata)
        // In-app event store keeps plain text (structured data for the conversation view); thread.md
        // gets the icon-prefixed markdown line.
        _ = appendAgentEvent(conversationID: conversationID, role: .system, text: activity.displayText)
        recordThreadActivity(conversationID: conversationID, activity)
    }

    /// Appends a typed activity line to the conversation's `thread.md` conversation record. The thread file
    /// already exists from the run, so this only ever appends (off the main thread — small file IO).
    private func recordThreadActivity(conversationID: String, _ activity: UserQueryActivity) {
        let line = activity.transcriptLine
        Task.detached {
            ConversationTranscript(id: conversationID).systemEvent(line)
        }
    }

    private func updateConversation(
        id: String,
        title: String? = nil,
        commandText: String? = nil,
        detail: String? = nil,
        status: UserQueryConversationStatus? = nil,
        metadata: [String: String]? = nil
    ) {
        guard let index = notchConversations.firstIndex(where: { $0.id == id }) else { return }

        var conversation = notchConversations[index]
        let wasRunning = conversation.status == .running
        if let title {
            conversation.title = title
        }
        if let commandText {
            conversation.commandText = commandText
        }
        if let detail {
            conversation.detail = detail
        }
        if let status {
            conversation.status = status
        }
        if let metadata {
            conversation.metadata = metadata
        }
        // Drive the elapsed clock off the status change. Opening/closing a stretch is the ONLY way to move
        // the timer, and both are no-ops in the wrong state (open while already running, close while already
        // stopped), so a per-step "still running" update or a repeated terminal write can neither restart the
        // clock nor double-count. The clock is monotonic across gates and resumes by construction.
        let now = Date()
        if let status {
            if status == .running {
                // A genuine (re)entry from stopped starts a fresh run: clear per-run metadata flags too. A
                // per-step update where it was already running skips this (and the open is a no-op).
                if !wasRunning {
                    Self.clearRunMetadata(&conversation.metadata)
                    conversationsStreamingAnswer.remove(id)
                }
                conversation.openRunningStretch(asOf: now)
            } else {
                conversation.closeRunningStretch(asOf: now)
            }
        }
        conversation.updatedAt = now
        notchConversations[index] = conversation
        conversationStore.upsertConversation(conversation)
        syncPrimaryConversationPausedFlag()
    }

    /// How recently a running conversation must have last advanced to auto-resume itself on relaunch. Inside the
    /// window the work was clearly in progress and should pick back up; outside it, resuming unattended
    /// work the user likely moved on from (and spending credits while they're away) is the wrong default.
    private static let autoResumeStalenessWindow: TimeInterval = 30 * 60

    /// How recently a conversation must have been active to stay eligible as a follow-up target. Implicit
    /// follow-up routing runs through the typed resolver, but only over conversations touched within this
    /// window: one left idle longer is treated as closed, so an unrelated later turn starts a fresh
    /// conversation instead of folding into stale work (observed live: "hi" folding into a day-old
    /// video-clip conversation that had never reached a terminal state). This gates eligibility, not selection —
    /// among eligible candidates the resolver still decides by content, never by recency. An explicit
    /// Reply or spawn selection bypasses this entirely; the user can always continue an old thread on purpose.
    private static let followUpStalenessWindow: TimeInterval = 30 * 60

    /// Conversations recent enough to continue with a new turn. Sorted-by-recency input is filtered to the
    /// staleness window; everything older is considered closed and dropped from the follow-up pool.
    static func activeFollowUpCandidates(
        from conversations: [UserQueryConversation],
        now: Date
    ) -> [UserQueryConversation] {
        conversations.filter { now.timeIntervalSince($0.updatedAt) <= followUpStalenessWindow }
    }

    /// Maps persisted conversations into their post-relaunch state and collects the IDs to auto-resume. A relaunch
    /// tears down every live loop, so an in-flight conversation can't simply keep running — but one that was
    /// actively working moments ago resumes on its own, while staler or user-blocked work comes back as a
    /// row the user can resume with a tap. The persisted `updatedAt` is preserved throughout so a row's
    /// elapsed time stays the real run duration rather than the gap until the app was reopened.
    static func restoredConversations(
        from conversations: [UserQueryConversation],
        now: Date
    ) -> (conversations: [UserQueryConversation], autoResumeIDs: [String]) {
        var autoResumeIDs: [String] = []
        let restored = conversations.map { conversation -> UserQueryConversation in
            // A system-driven row (tool setup) has no harness loop behind it, so it is never auto-resumed
            // through the command handler. The install run reconciles it on launch (see
            // `reconcileInterruptedSystemSetup`); here it just carries through untouched.
            guard conversation.isUserControllable else { return conversation }
            switch conversation.status {
            case .running:
                // Running when the app quit, so the stretch never closed. Close it at `updatedAt` — the last
                // time the loop actually advanced — so its REAL duration is banked and the app-closed gap is
                // never counted.
                var restored = conversation
                restored.closeRunningStretch(asOf: conversation.updatedAt)
                // Actively running when the app quit. Resume on its own only if that was recent;
                // otherwise it becomes a retryable row instead of running stale work unattended.
                if now.timeIntervalSince(conversation.updatedAt) <= autoResumeStalenessWindow {
                    // Reopen the stretch at relaunch so the live timer continues on top of the banked total
                    // rather than restarting at zero.
                    restored.openRunningStretch(asOf: now)
                    autoResumeIDs.append(restored.id)
                    return restored
                }
                restored.status = .timedOut
                restored.detail = "Timed out — resume"
                return restored
            case .waitingForClarification, .waitingForReview, .waitingForPermission:
                // The loop that was blocked on the user is gone, but the gate still stands — the question or
                // the pending approval is persisted in the conversation's continuation (and shown in its `detail`).
                // Keep it in that same waiting state rather than collapsing it to paused: pausing is a
                // deliberate user action (Stop on a running conversation), never something a relaunch does on the
                // user's behalf. A waiting-on-user row keeps its Reply button (and the attention glyph); a
                // permission row keeps its Approve / Deny banner, and approving re-runs the persisted call
                // with consent granted. Answering or approving continues the conversation with the context intact.
                return conversation
            default:
                // paused, completed, failed, timedOut, interrupted, needsAttention, chatting: unchanged.
                return conversation
            }
        }
        return (restored, autoResumeIDs)
    }

    private func refreshPromptStateAfterRunResult(
        conversationID: String,
        result: UserQueryCommandHandlingResult
    ) {
        syncPrimaryConversationPausedFlag()
        if promptState.isActive {
            if lastActiveConversationID == conversationID {
                lastActiveConversationID = notchConversations.first?.id
            }
            return
        }

        if let runningConversation = notchConversations.first(where: { activeAgentIDs.contains($0.id) && $0.status == .running }) {
            promptState.leadingSignalLevel = .thinking
            promptState.promptText = runningConversation.title
            return
        }

        if let pausedConversation = notchConversations.first(where: { activeAgentIDs.contains($0.id) && $0.status == .paused }) {
            promptState.leadingSignalLevel = .idle
            promptState.promptText = pausedConversation.title
            return
        }

        promptState.leadingSignalLevel = result.status == .completed ? .ready : .idle
        promptState.promptText = result.conversationLabel ?? result.summary
        if lastActiveConversationID == conversationID {
            lastActiveConversationID = notchConversations.first?.id
        }
    }

    private func syncPrimaryConversationPausedFlag() {
        isCurrentConversationPaused = notchConversations.first?.status == .paused
    }

    private static func conversationStatus(for result: UserQueryCommandHandlingResult) -> UserQueryConversationStatus {
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
        guard let mostRecentAccentIndex = spawnStates.last?.accentIndex ?? notchConversations.first?.accentIndex else {
            return UserQueryAccentPalette.firstIndex
        }

        return UserQueryAccentPalette.index(after: mostRecentAccentIndex)
    }

    /// The conversation's title is the user's prompt, whitespace-collapsed. It is NOT hard-truncated here: every
    /// place that shows it (the collapsed bar, the prompt pill, each expanded row) renders it on a single
    /// line and tail-truncates to its own available width, so the expanded row title spans the full row
    /// rather than being clipped to a fixed character budget. Capped only by `collapsedDisplayText` so a
    /// runaway prompt can't blob through the store.
    private static func conversationLabel(for text: String) -> String {
        let collapsed = collapsedDisplayText(for: text)
        return collapsed.isEmpty ? "New conversation" : collapsed
    }

    /// A cursor label stays a short status line; cap it so a long tool result never blobs over the
    /// screen. The overlay wraps within this, and the full text is always in the notch conversation list.
    private static let maxSpawnLabelLength = 200

    private static func collapsedDisplayText(for text: String) -> String {
        let collapsed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return truncated(collapsed, maxLength: maxSpawnLabelLength)
    }

    private static func persistedAsset(
        from draft: UserQueryConversationAssetDraft,
        assetID: String,
        conversationID: String,
        eventID: String?
    ) -> UserQueryConversationAsset {
        var storedURLString = draft.urlString
        if let sourceURL = URL(string: draft.urlString),
           sourceURL.isFileURL,
           let destinationURL = copyAssetToApplicationSupport(
            sourceURL: sourceURL,
            conversationID: conversationID,
            assetID: assetID,
            displayName: draft.displayName
           ) {
            storedURLString = destinationURL.absoluteString
        }

        return UserQueryConversationAsset(
            id: assetID,
            conversationID: conversationID,
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
        conversationID: String,
        assetID: String,
        displayName: String
    ) -> URL? {
        guard let assetsDirectory = conversationAssetDirectory(conversationID: conversationID) else { return nil }

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

    /// Where drops wait between the drag and the submit. Distinct from any conversation's asset
    /// directory (those are keyed by conversation UUID) and purged on launch, since staged chips
    /// don't survive a restart.
    private static func stagedAssetsDirectory() -> URL? {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("Donkey", isDirectory: true)
            .appendingPathComponent("UserQueryAssets", isDirectory: true)
            .appendingPathComponent("Staged", isDirectory: true)
    }

    private static func copyAssetToStaging(
        sourceURL: URL,
        stagedID: String,
        displayName: String
    ) -> URL? {
        guard let stagingDirectory = stagedAssetsDirectory() else { return nil }

        do {
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )
            let fileName = "\(stagedID)-\(safeAssetFileName(displayName))"
            let destinationURL = stagingDirectory.appendingPathComponent(fileName, isDirectory: false)
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

    /// Deletes a staged file. Guarded to the staging directory: when the copy-to-staging failed, the
    /// chip still points at the user's original file, which must never be touched.
    private static func deleteStagedAssetFile(urlString: String) {
        guard let url = URL(string: urlString),
              url.isFileURL,
              let stagingDirectory = stagedAssetsDirectory(),
              url.standardizedFileURL.path.hasPrefix(stagingDirectory.standardizedFileURL.path + "/") else {
            return
        }

        try? FileManager.default.removeItem(at: url)
    }

    static func purgeStagedAssets() {
        guard let stagingDirectory = stagedAssetsDirectory() else { return }

        try? FileManager.default.removeItem(at: stagingDirectory)
    }

    private static func conversationAssetDirectory(conversationID: String) -> URL? {
        guard let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        return applicationSupportURL
            .appendingPathComponent("Donkey", isDirectory: true)
            .appendingPathComponent("UserQueryAssets", isDirectory: true)
            .appendingPathComponent(safeAssetFileName(conversationID), isDirectory: true)
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
        guard let themeURL = DonkeyResourceBundle.app?.url(forResource: "theme", withExtension: "json"),
              let themeData = try? Data(contentsOf: themeURL),
              let themeConfig = try? JSONDecoder().decode(UserQueryThemeConfig.self, from: themeData),
              let theme = UserQueryTheme.fromConfig(themeConfig) else {
            return .defaultBlue
        }

        return theme
    }
}
