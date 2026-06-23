import AppKit
import Carbon.HIToolbox
import DonkeyContracts
import DonkeyUI
import QuartzCore
import SwiftUI

@MainActor
final class UserQueryOverlayController {
    private let model: UserQueryOverlayModel
    private let fixedPlacement: UserQueryPlacement = .bottomRight
    private let activationShortcut: UserQueryActivationShortcut
    private let microphoneWaveformMeter = MicrophoneWaveformMeter()
    private let agentVisualizationCursorController = PointerCoachCursorOverlayController()
    private let spawnOverlayController = UserQuerySpawnOverlayController()

    private var statusPanel: NSPanel?
    private var statusHostingView: UserQueryHostingView<UserQueryNotchStatusView>?
    private var inputPanel: NSPanel?
    private var timer: Timer?
    private let missionControlMonitor = MissionControlMonitor()
    private var isMissionControlActive = false
    /// 0 = the notch rests at the top of the screen, 1 = it has slid fully up and off-screen.
    /// The 60 Hz tick eases this toward its target so the slide reads as a smooth animation
    /// even though the panel is repositioned by direct per-frame `setFrame` calls.
    private var missionControlHideProgress: CGFloat = 0
    private var globalActivationMonitor: Any?
    private var localActivationMonitor: Any?
    private var appDeactivationObserver: Any?
    private var activationTapStartedAt: Date?
    private var activationTapIsClean = false
    private var completedActivationTapCount = 0
    private var lastActivationTapCompletedAt: Date?
    private var activationHoldStartedAt: Date?
    private var isVoiceInputActive = false
    private var isStatusExpanded = false
    private var isStatusHostExpanded = false
    // Hover can produce enter/exit samples faster than SwiftUI's spring can settle.
    // Track the lifecycle explicitly so pending host resizes, opens, and closes
    // are cancelled in order instead of racing into a stale animation origin.
    private var statusHoverPhase: StatusHoverPhase = .collapsed
    private var statusCollapseWorkItem: DispatchWorkItem?
    private var statusHostShrinkWorkItem: DispatchWorkItem?
    private var spawnDesktopEmergeWorkItems: [String: DispatchWorkItem] = [:]
    private var hasPrewarmedInputPanel = false
    private var lastStatusViewSnapshot: StatusPanelViewSnapshot?
    /// Memoizes the measured chin-band height by (chin text + width) so the per-frame `notchMetrics()`
    /// doesn't redo Core Text layout when the surfaced chin text hasn't changed.
    private var chinHeightCache: (key: String, height: CGFloat)?

    init(
        model: UserQueryOverlayModel,
        activationShortcut: UserQueryActivationShortcut = .doubleCommand
    ) {
        self.model = model
        self.activationShortcut = activationShortcut
        model.agentVisualizationPresenter = { [weak self] request, preferredSpawnID in
            self?.presentAgentVisualization(
                request: request,
                preferredSpawnID: preferredSpawnID
            )
        }
        spawnOverlayController.followUpSubmitted = { [weak self] spawnID, conversationID, text in
            self?.model.submitSpawnFollowUp(spawnID: spawnID, conversationID: conversationID, text: text)
        }
        spawnOverlayController.selected = { [weak self] spawnID in
            self?.model.selectSpawn(id: spawnID)
        }
        microphoneWaveformMeter.onLevelsChanged = { [weak model] levels in
            model?.updateVoiceWaveformLevels(levels)
        }
        microphoneWaveformMeter.onAudioFrames = { [weak model] samples, sampleRate in
            model?.streamLiveAudioFrames(samples, sampleRate: sampleRate)
        }
        model.onLiveAudioStreamingChanged = { [weak self] isStreaming in
            if isStreaming {
                self?.microphoneWaveformMeter.startContinuousListening()
            } else {
                self?.microphoneWaveformMeter.stopContinuousListening()
            }
        }
    }

    func show() {
        let initialInputSize = currentContentSize
        let inputHostingView = makeInputHostingView(size: initialInputSize)
        let inputPanel = makeInputPanel(size: initialInputSize, hostingView: inputHostingView)
        let statusPanel = makeStatusPanel()

        self.inputPanel = inputPanel
        self.statusPanel = statusPanel
        prewarmInputPanel()
        startActivationMonitoring()
        startAppDeactivationMonitoring()
        startMissionControlMonitoring()
        positionStatusPanel()
        centerInputPanel()
        inputPanel.orderOut(nil)
        statusPanel.orderFrontRegardless()
        startTimer()
    }

    private func makeInputHostingView(size: CGSize) -> NSHostingView<UserQueryOverlayRootView> {
        let hostingView = NSHostingView(
            rootView: UserQueryOverlayRootView(
                model: model,
                voiceInputRequested: { [weak self] in
                    self?.activateVoiceInputAtScreenCenter()
                },
                voiceInputFinished: { [weak self] in
                    self?.finishVoiceInput()
                }
            )
        )
        // The controller positions and sizes this panel itself; stop the hosting view from also bridging
        // its SwiftUI content size to the window, which re-enters layout mid display-cycle and throws an
        // uncaught AppKit exception (see the spawn overlay).
        hostingView.sizingOptions = []
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        return hostingView
    }

    private func makeInputPanel(
        size: CGSize,
        hostingView: NSHostingView<UserQueryOverlayRootView>
    ) -> UserQueryPanel {
        let panel = UserQueryPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        panel.title = "Donkey"
        panel.contentView = hostingView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.ignoresMouseEvents = false
        panel.dragRegionProvider = { [weak self] in
            self?.composerDragRegions() ?? []
        }
        panel.escapeKeyHandler = { [weak self] in
            self?.dismissActivePromptFromKeyboard()
        }
        panel.level = DonkeyOverlayWindowLevel.userQuery
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary
        ]

        return panel
    }

    private func makeStatusPanel() -> NSPanel {
        let metrics = notchMetrics()
        let hostingView = UserQueryHostingView(rootView: notchStatusView(metrics: metrics))
        // The notch status panel is resized explicitly on every step (narration updates, expand/collapse
        // animations). Letting the hosting view ALSO animate the window size from content re-enters layout
        // during the display cycle and crashes the app (uncaught AppKit exception) — the exact failure seen
        // while driving a vision step. Empty sizingOptions makes our explicit frame the only sizing path.
        hostingView.sizingOptions = []
        hostingView.frame = CGRect(origin: .zero, size: metrics.surfaceSize)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        configureStatusHostingLayer(hostingView, metrics: metrics)
        hostingView.hitTestRegionProvider = { [weak self] in
            self?.statusHitTestRegions() ?? []
        }
        statusHostingView = hostingView
        lastStatusViewSnapshot = statusViewSnapshot(metrics: metrics)

        let panel = UserQueryPanel(
            contentRect: CGRect(origin: .zero, size: metrics.surfaceSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        panel.title = "Donkey Status"
        panel.contentView = hostingView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = false
        panel.mouseDownHandler = { [weak self] in
            self?.focusStatusComposerTextInputIfAvailable()
        }
        panel.escapeKeyHandler = { [weak self] in
            // Esc leaves the focused row the same way clicking bare chrome does: highlight and reply clear.
            self?.model.focusNotchRow(nil)
        }
        panel.arrowKeyHandler = { [weak self] direction in
            self?.handleNotchArrowKey(direction) ?? false
        }
        panel.level = DonkeyOverlayWindowLevel.userQuery
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary
        ]

        return panel
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        statusCollapseWorkItem?.cancel()
        statusCollapseWorkItem = nil
        statusHostShrinkWorkItem?.cancel()
        statusHostShrinkWorkItem = nil
        cancelSpawnDesktopEmergeWorkItems()
        statusHoverPhase = .collapsed
        stopActivationMonitoring()
        stopAppDeactivationMonitoring()
        stopMissionControlMonitoring()
        microphoneWaveformMeter.stop()
        agentVisualizationCursorController.close()
        spawnOverlayController.close()
        inputPanel?.close()
        inputPanel = nil
        statusPanel?.close()
        statusPanel = nil
        statusHostingView = nil
        hasPrewarmedInputPanel = false
        lastStatusViewSnapshot = nil
    }

    private func startActivationMonitoring() {
        stopActivationMonitoring()

        let activationEventMask: NSEvent.EventTypeMask = [
            .flagsChanged,
            .keyDown,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown
        ]
        globalActivationMonitor = NSEvent.addGlobalMonitorForEvents(matching: activationEventMask) { [weak self] event in
            Task { @MainActor in
                self?.handleActivationEvent(event)
            }
        }

        localActivationMonitor = NSEvent.addLocalMonitorForEvents(matching: activationEventMask) { [weak self] event in
            Task { @MainActor in
                self?.handleActivationEvent(event)
            }
            return event
        }
    }

    private func stopActivationMonitoring() {
        if let globalActivationMonitor {
            NSEvent.removeMonitor(globalActivationMonitor)
            self.globalActivationMonitor = nil
        }

        if let localActivationMonitor {
            NSEvent.removeMonitor(localActivationMonitor)
            self.localActivationMonitor = nil
        }
    }

    private func startAppDeactivationMonitoring() {
        stopAppDeactivationMonitoring()

        appDeactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.dismissActivePromptFromAppDeactivation()
            }
        }
    }

    private func stopAppDeactivationMonitoring() {
        if let appDeactivationObserver {
            NotificationCenter.default.removeObserver(appDeactivationObserver)
            self.appDeactivationObserver = nil
        }
    }

    private func startMissionControlMonitoring() {
        missionControlMonitor.onChange = { [weak self] isActive in
            Task { @MainActor in
                self?.isMissionControlActive = isActive
            }
        }
        missionControlMonitor.start()
    }

    private func stopMissionControlMonitoring() {
        missionControlMonitor.onChange = nil
        missionControlMonitor.stop()
        isMissionControlActive = false
    }

    private func handleActivationEvent(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            handleModifierFlagsChanged(event.modifierFlags)
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if event.type == .keyDown, dismissActivePromptIfEscape(event) {
                resetActivationTapSequence()
                return
            }

            if event.type != .keyDown, dismissActivePromptIfClickIsOutside() {
                resetActivationTapSequence()
                return
            }

            resetActivationTapSequence()
        default:
            break
        }
    }

    private func handleModifierFlagsChanged(_ modifierFlags: NSEvent.ModifierFlags) {
        let flags = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        let activationModifierFlag = activationShortcut.modifier.eventModifierFlag
        let isActivationModifierDown = flags.contains(activationModifierFlag)
        let isCleanActivationModifierOnly = flags == activationModifierFlag

        if isVoiceInputActive, !isActivationModifierDown {
            finishVoiceInput()
            resetActivationTapSequence()
            return
        }

        if isCleanActivationModifierOnly {
            if activationTapStartedAt == nil {
                let now = Date()
                activationTapStartedAt = now
                activationTapIsClean = true
                if shouldStartVoiceHoldCandidate(at: now) {
                    activationHoldStartedAt = now
                }
            }
            return
        }

        if isActivationModifierDown {
            if activationTapStartedAt == nil {
                activationTapStartedAt = Date()
            }
            activationTapIsClean = false
            completedActivationTapCount = 0
            lastActivationTapCompletedAt = nil
            activationHoldStartedAt = nil
            return
        }

        guard flags.isEmpty else {
            resetActivationTapSequence()
            return
        }

        guard let activationTapStartedAt else { return }

        let now = Date()
        let tapDuration = now.timeIntervalSince(activationTapStartedAt)
        let completedCleanTap = activationTapIsClean &&
            tapDuration <= activationShortcut.maximumTapDuration
        self.activationTapStartedAt = nil
        activationTapIsClean = false

        guard completedCleanTap else {
            resetActivationTapSequence()
            return
        }

        registerCompletedActivationTap(at: now)
    }

    private func registerCompletedActivationTap(at now: Date) {
        if let lastActivationTapCompletedAt,
           now.timeIntervalSince(lastActivationTapCompletedAt) <= activationShortcut.maximumTapInterval {
            completedActivationTapCount += 1
        } else {
            completedActivationTapCount = 1
        }

        lastActivationTapCompletedAt = now
        activationHoldStartedAt = nil

        guard completedActivationTapCount >= activationShortcut.tapCount else {
            return
        }

        resetActivationTapSequence()
        activateInputAtScreenCenter()
    }

    private func resetActivationTapSequence() {
        activationTapStartedAt = nil
        activationTapIsClean = false
        completedActivationTapCount = 0
        lastActivationTapCompletedAt = nil
        activationHoldStartedAt = nil
    }

    private func shouldStartVoiceHoldCandidate(at now: Date) -> Bool {
        guard activationShortcut.holdToVoiceInputDuration != nil,
              completedActivationTapCount == activationShortcut.tapCount - 1,
              let lastActivationTapCompletedAt else {
            return false
        }

        return now.timeIntervalSince(lastActivationTapCompletedAt) <=
            activationShortcut.maximumTapInterval
    }

    private func activateVoiceInputIfNeeded() {
        _ = activatePromptVoiceInputIfNeeded()
    }

    private func activatePromptVoiceInputIfNeeded() -> Bool {
        guard let holdToVoiceInputDuration = activationShortcut.holdToVoiceInputDuration,
              let activationHoldStartedAt,
              activationTapIsClean,
              Date().timeIntervalSince(activationHoldStartedAt) >= holdToVoiceInputDuration else {
            return false
        }

        resetActivationTapSequence()
        activateVoiceInputAtScreenCenter()
        return true
    }

    private func activateInputAtScreenCenter() {
        guard !model.promptState.isActive else {
            if let inputPanel {
                centerInputPanel()
                activateForKeyboardInput(inputPanel)
            }
            focusComposerTextInput()
            return
        }

        activateInput()
    }

    private func activateVoiceInputAtScreenCenter() {
        activateInputAtScreenCenter()
        isVoiceInputActive = true
        microphoneWaveformMeter.startAudioCapture()
        model.handle(.voiceInputRequested)
    }

    private func finishVoiceInput() {
        guard isVoiceInputActive else { return }

        isVoiceInputActive = false
        let audio = microphoneWaveformMeter.finishAudioCapture()
        model.submitVoiceAudio(audio)
    }

    private func activateInput() {
        guard let inputPanel else { return }

        model.activate()
        centerInputPanel()

        activateForKeyboardInput(inputPanel)
        focusComposerTextInput()
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let inputPanel else { return }

        if !model.promptState.isActive {
            microphoneWaveformMeter.stop()
            inputPanel.orderOut(nil)
        }

        activateVoiceInputIfNeeded()
        advanceMissionControlHideProgress()
        // Build the notch metrics once per frame (the chin sizing does Core Text measurement) and feed
        // both the panel position and the view update from it, instead of recomputing it for each.
        let metrics = notchMetrics()
        positionStatusPanel(metrics: metrics)
        updateStatusHoverExpansion()
        updateStatusPanelView(metrics: metrics)
        updateSpawnOverlay()
        resizeActivePanelIfNeeded(inputPanel)
        updateMouseEventPassthrough(for: inputPanel)

        if model.placement != fixedPlacement {
            model.placement = fixedPlacement
        }
    }

    private func centerInputPanel() {
        guard let inputPanel,
              let screen = activeScreen() else {
            return
        }

        let size = currentContentSize
        inputPanel.setFrame(
            CGRect(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.midY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            display: true
        )
    }

    /// Extra travel beyond the surface height so the notch fully clears the screen edge
    /// (the expanded chin can hang below the collapsed surface).
    private static let missionControlHideClearance: CGFloat = 24

    /// Eases `missionControlHideProgress` toward its target each frame. A per-frame
    /// fraction gives an ease-out slide (~0.2s) that the 60 Hz tick renders by
    /// repositioning the panel; snap to the endpoint to stop sub-pixel drift.
    private func advanceMissionControlHideProgress() {
        let target: CGFloat = isMissionControlActive ? 1 : 0
        let delta = target - missionControlHideProgress
        if abs(delta) < 0.001 {
            missionControlHideProgress = target
            return
        }
        missionControlHideProgress += delta * 0.22
    }

    private func positionStatusPanel(metrics: NotchMetrics? = nil, disableAnimations: Bool = true) {
        guard let statusPanel,
              let screen = activeScreen() else {
            return
        }

        let metrics = metrics ?? notchMetrics(for: screen)
        // While Mission Control is up, slide the notch past the top edge so it doesn't float
        // over the Spaces/window thumbnails. The eased progress (driven by the tick) makes the
        // extra Y offset animate the donkey up and off-screen, then back down when it closes.
        let hideOffset = (metrics.surfaceSize.height + Self.missionControlHideClearance) * missionControlHideProgress
        let frame = CGRect(
            x: screen.frame.midX - metrics.surfaceSize.width / 2,
            y: screen.frame.maxY - metrics.surfaceSize.height + hideOffset,
            width: metrics.surfaceSize.width,
            height: metrics.surfaceSize.height
        )

        guard disableAnimations else {
            statusPanel.setFrame(frame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            // The NSPanel is just the render host. It must jump to its target rect
            // before SwiftUI animates the visible notch, otherwise AppKit's frame
            // animation can combine with the SwiftUI spring and look corner-born.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if statusPanel.frame.size != metrics.surfaceSize {
                statusHostingView?.frame = CGRect(origin: .zero, size: metrics.surfaceSize)
            }
            statusPanel.setFrame(frame, display: true)
            CATransaction.commit()
        }
    }

    private func updateStatusPanelView(metrics: NotchMetrics? = nil) {
        let metrics = metrics ?? notchMetrics()
        let snapshot = statusViewSnapshot(metrics: metrics)
        let previousSnapshot = lastStatusViewSnapshot
        guard snapshot != previousSnapshot else { return }

        if snapshot.surfaceSize != previousSnapshot?.surfaceSize {
            positionStatusPanel(metrics: metrics)
        }

        lastStatusViewSnapshot = snapshot
        if let statusHostingView {
            configureStatusHostingLayer(statusHostingView, metrics: metrics)
        }
        statusHostingView?.rootView = notchStatusView(metrics: metrics)
    }

    private func configureStatusHostingLayer(
        _ hostingView: UserQueryHostingView<UserQueryNotchStatusView>,
        metrics: NotchMetrics
    ) {
        hostingView.layer?.cornerRadius = metrics.hostCornerRadius
        hostingView.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        hostingView.layer?.masksToBounds = true
    }

    private func statusViewSnapshot(metrics: NotchMetrics) -> StatusPanelViewSnapshot {
        let spawnCue = notchSpawnCue(metrics: metrics)
        return StatusPanelViewSnapshot(
            state: model.promptState,
            updateState: model.updateState,
            layout: metrics.layout,
            surfaceSize: metrics.surfaceSize,
            isExpanded: isStatusExpanded,
            isHostExpanded: isStatusHostExpanded,
            isCurrentConversationPaused: model.isCurrentConversationPaused,
            notchCommandText: model.notchCommandText,
            notchCommandInputTextHeight: model.notchCommandInputTextHeight,
            isNotchCommandInputExpanded: model.isNotchCommandInputExpanded,
            notchConversations: model.notchConversations,
            notchSurfacedConversations: model.notchSurfacedConversations,
            accentIndex: model.notchAccentIndex,
            spawnState: spawnCue,
            spawnStates: model.spawnStates,
            selectedSpawnID: model.selectedSpawnID,
            replyTargetConversationID: model.replyTargetConversationID,
            selectedConversationID: model.selectedConversationID,
            needsLogin: model.needsLogin
        )
    }

    private func notchStatusView(metrics: NotchMetrics) -> UserQueryNotchStatusView {
        let spawnCue = notchSpawnCue(metrics: metrics)
        return UserQueryNotchStatusView(
            state: model.promptState,
            updateState: model.updateState,
            layout: metrics.layout,
            surfaceWidth: metrics.surfaceSize.width,
            surfaceHeight: metrics.surfaceSize.height,
            isHostExpanded: isStatusHostExpanded,
            isExpanded: isStatusExpanded,
            isCurrentConversationPaused: model.isCurrentConversationPaused,
            commandText: Binding(
                get: { [weak self] in
                    self?.model.notchCommandText ?? ""
                },
                set: { [weak self] text in
                    self?.model.notchCommandText = text
                }
            ),
            commandInputTextHeight: model.notchCommandInputTextHeight,
            isCommandInputExpanded: model.isNotchCommandInputExpanded,
            conversations: model.notchConversations,
            surfacedConversations: model.notchSurfacedConversations,
            replyTargetConversationID: model.replyTargetConversationID,
            selectedConversationID: model.selectedConversationID,
            accentIndex: model.notchAccentIndex,
            spawnState: spawnCue,
            commandSubmitted: { [weak self] text in
                self?.model.handle(.messageSubmitted(text: text))
            },
            commandInputTextHeightChanged: { [weak self] height in
                self?.model.updateNotchCommandInputTextHeight(height)
            },
            commandInputExpansionChanged: { [weak self] isExpanded in
                self?.model.updateNotchCommandInputExpansion(isExpanded)
            },
            assetsDropped: { [weak self] drafts in
                self?.model.handleDroppedAssets(drafts)
            },
            pauseRequested: { [weak self] conversationID in
                self?.model.pauseAgent(id: conversationID)
            },
            resumeRequested: { [weak self] conversationID in
                self?.model.resumeAgent(id: conversationID)
            },
            dismissRequested: { [weak self] conversationID in
                self?.model.dismissConversation(id: conversationID)
            },
            conversationSelected: { [weak self] conversationID in
                self?.restoreSpawnPointer(forConversationID: conversationID)
            },
            replyRequested: { [weak self] conversationID in
                guard let self else { return }
                // A click focuses the row exactly as arrowing onto it does: highlight + pinned reply.
                self.model.focusNotchRow(conversationID)
                self.focusStatusComposerTextInputIfAvailable()
            },
            replyModeExited: { [weak self] in
                self?.model.focusNotchRow(nil)
            },
            approvePermissionRequested: { [weak self] conversationID, alwaysAllow in
                self?.model.approvePermissionGate(id: conversationID, alwaysAllow: alwaysAllow)
            },
            denyPermissionRequested: { [weak self] conversationID in
                self?.model.denyPermissionGate(id: conversationID)
            },
            updateRequested: { [weak self] in
                self?.openAvailableUpdate()
            },
            needsLogin: model.needsLogin,
            loginRequested: { [weak self] in
                self?.model.requestLogin()
            },
            reloadCreditsRequested: { [weak self] conversationID in
                self?.model.reloadCredits(id: conversationID)
            }
        )
    }

    /// Up/Down moves the expanded-notch focus, landing on each row exactly as a click would (highlight +
    /// pinned reply, other rows dimmed). Consumed (returns true) only while the notch is open and the
    /// model actually moved the focus; otherwise the arrows fall through to the composer to edit the draft.
    private func handleNotchArrowKey(_ direction: NotchArrowDirection) -> Bool {
        guard isStatusExpanded else { return false }
        let moved = model.moveNotchSelection(direction)
        if moved { updateStatusPanelView() }
        return moved
    }

    private func notchSpawnCue(metrics: NotchMetrics) -> UserQuerySpawnState? {
        spawnOverlayController.cueState(
            for: model.notchSpawnCue,
            screen: activeScreen(),
            notchMetrics: metrics
        )
    }

    private func openAvailableUpdate() {
        model.showUpdateUI()
    }

    /// Brings back a pointer the user dismissed when its conversation is clicked in
    /// the notch; the surface re-emerges and travels to its target again.
    private func restoreSpawnPointer(forConversationID conversationID: String) {
        guard let spawnID = model.spawnStates.first(where: { $0.conversationID == conversationID })?.id else {
            return
        }

        spawnOverlayController.restoreSpawn(id: spawnID)
        model.selectSpawn(id: spawnID)
        updateSpawnOverlay()
    }

    private func presentAgentVisualization(
        request: PointerCoachCursorGuideRequest,
        preferredSpawnID: String?
    ) {
        if spawnOverlayController.playGuide(
            request: request,
            on: preferredSpawnID,
            screen: activeScreen()
        ) {
            agentVisualizationCursorController.close()
            return
        }

        agentVisualizationCursorController.show(request: request)
    }

    private func updateSpawnOverlay() {
        let screen = activeScreen()
        let metrics = notchMetrics(for: screen)
        scheduleSpawnDesktopEmergeIfNeeded()
        spawnOverlayController.update(
            spawnStates: model.spawnStates,
            selectedSpawnID: model.selectedSpawnID,
            screen: screen,
            notchMetrics: metrics
        )
    }

    private func scheduleSpawnDesktopEmergeIfNeeded() {
        let cueStates = model.spawnStates.filter { $0.phase == .notchCue }
        let cueIDs = Set(cueStates.map(\.id))
        for (spawnID, workItem) in spawnDesktopEmergeWorkItems where !cueIDs.contains(spawnID) {
            workItem.cancel()
            spawnDesktopEmergeWorkItems[spawnID] = nil
        }

        for (index, spawnState) in cueStates.enumerated()
            where spawnDesktopEmergeWorkItems[spawnState.id] == nil {
            let workItem = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self else { return }

                    self.model.markSpawnDesktopEmerged(id: spawnState.id)
                    self.spawnDesktopEmergeWorkItems[spawnState.id] = nil
                }
            }
            spawnDesktopEmergeWorkItems[spawnState.id] = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.24 + Double(index) * 0.05,
                execute: workItem
            )
        }
    }

    private func cancelSpawnDesktopEmergeWorkItems() {
        for workItem in spawnDesktopEmergeWorkItems.values {
            workItem.cancel()
        }
        spawnDesktopEmergeWorkItems = [:]
    }

    private func updateStatusHoverExpansion() {
        guard let statusPanel else { return }

        let metrics = notchMetrics(for: statusPanel.screen)
        let mouseLocationInPanel = statusPanel.convertPoint(fromScreen: NSEvent.mouseLocation)

        if metrics.hoverFramesInPanel.contains(where: { $0.contains(mouseLocationInPanel) }) {
            setStatusExpanded(true)
        } else if statusHoverPhase != .collapsed,
                  statusHoverPhase != .closing,
                  statusCollapseWorkItem == nil {
            scheduleStatusCollapse()
        }
    }

    private func statusHitTestRegions() -> [CGRect] {
        guard let statusPanel else { return [] }

        let metrics = notchMetrics(for: statusPanel.screen)
        return [metrics.visibleSurfaceFrameInPanel]
    }

    private func setStatusExpanded(_ isExpanded: Bool) {
        if isExpanded {
            statusCollapseWorkItem?.cancel()
            statusCollapseWorkItem = nil
            statusHostShrinkWorkItem?.cancel()
            statusHostShrinkWorkItem = nil
            guard statusHoverPhase != .expanded else { return }
            applyStatusExpanded(true)
            return
        }

        scheduleStatusCollapse()
    }

    private func applyStatusExpanded(_ isExpanded: Bool) {
        if isExpanded {
            guard statusHoverPhase != .expanded else { return }

            // Mouse enter: jump the host window to its expanded size instantly (no animation) so there
            // is room, then let the visible black surface grow into it. The host resize happens inside
            // updateStatusPanelView; the surface size, corner radius, and content all animate off the
            // `isStatusExpanded` change in SwiftUI. The host is already full size, so nothing races.
            statusHoverPhase = .expanded
            isStatusHostExpanded = true
            isStatusExpanded = true
            // Opening the notch dismisses the surfaced terminal conversations (completed pointers and any held
            // error chin) piled up in the collapsed surface.
            model.acknowledgeSurfacedConversations()
            updateStatusPanelView()
            focusStatusComposerTextInputIfAvailable()
            return
        }

        guard statusHoverPhase != .collapsed else { return }
        guard statusHoverPhase != .closing else {
            if statusHostShrinkWorkItem == nil {
                scheduleStatusHostShrink()
            }
            return
        }

        if isStatusExpanded {
            // Mouse exit is the reverse: collapse the surface (and fade the content out) first. The
            // host stays expanded so it keeps containing the shrinking surface; it snaps to the notch
            // size once the surface has finished collapsing, when the host shrink fires below.
            isStatusExpanded = false
            model.clearNotchSelection()
            updateStatusPanelView()
        }

        statusHoverPhase = .closing
        scheduleStatusHostShrink()
    }

    private func prewarmInputPanel() {
        guard !hasPrewarmedInputPanel,
              let inputPanel else { return }
        hasPrewarmedInputPanel = true

        flushPanelLayout(inputPanel)
    }

    private func flushPanelLayout(_ panel: NSPanel) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.contentView?.displayIfNeeded()
            panel.displayIfNeeded()
            CATransaction.commit()
        }
    }

    private func scheduleStatusCollapse() {
        statusCollapseWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.collapseStatusIfPointerIsOutside()
            }
        }
        statusCollapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func collapseStatusIfPointerIsOutside() {
        statusCollapseWorkItem = nil

        guard let statusPanel else {
            applyStatusExpanded(false)
            return
        }

        let metrics = notchMetrics(for: statusPanel.screen)
        let mouseLocationInPanel = statusPanel.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard !metrics.hoverFramesInPanel.contains(where: { $0.contains(mouseLocationInPanel) }) else { return }

        applyStatusExpanded(false)
    }

    private func scheduleStatusHostShrink() {
        guard statusHostShrinkWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.shrinkStatusHostIfCollapsed()
            }
        }
        statusHostShrinkWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchMetrics.closeAnimationDuration, execute: workItem)
    }

    private func shrinkStatusHostIfCollapsed() {
        statusHostShrinkWorkItem = nil
        guard !isStatusExpanded, isStatusHostExpanded, statusHoverPhase == .closing else { return }

        isStatusHostExpanded = false
        statusHoverPhase = .collapsed
        positionStatusPanel()
        updateStatusPanelView()
    }

    private func activeScreen() -> NSScreen? {
        inputPanel?.screen ?? statusPanel?.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func notchMetrics(for screen: NSScreen? = nil) -> NotchMetrics {
        let screen = screen ?? activeScreen()
        guard let screen else {
            return NotchMetrics(
                voidWidth: NotchMetrics.fallbackVoidWidth,
                voidHeight: NotchMetrics.fallbackVoidHeight,
                expandedContentHeight: statusExpandedContentHeight,
                isExpanded: isStatusExpanded,
                isHostExpanded: isStatusHostExpanded,
                screenWidth: NotchMetrics.defaultScreenWidth,
                needsLogin: model.needsLogin
            )
        }

        let safeTop = max(0, screen.safeAreaInsets.top)
        let measuredVoidWidth: CGFloat
        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea {
            measuredVoidWidth = max(
                0,
                screen.frame.width - leftArea.width - rightArea.width
            )
        } else {
            measuredVoidWidth = 0
        }
        let hasNotch = measuredVoidWidth > 0 || safeTop >= NotchMetrics.minimumPhysicalVoidHeight
        let voidHeight = hasNotch ? max(safeTop, NotchMetrics.fallbackVoidHeight) : 0
        let voidWidth = hasNotch ? max(measuredVoidWidth, inferredVoidWidth(for: screen, safeTop: safeTop)) : 0

        // The chin band has to know its height before the surface frame is built, but that height
        // depends on the collapsed width (how wide the chin text can wrap). Resolve the width from a
        // zero-chin probe first, then size the band to the surfaced conversations' wrapped line count.
        let widthProbe = NotchMetrics(
            voidWidth: voidWidth,
            voidHeight: voidHeight,
            expandedContentHeight: statusExpandedContentHeight,
            isExpanded: isStatusExpanded,
            isHostExpanded: isStatusHostExpanded,
            screenWidth: screen.frame.width,
            chinHeight: 0,
            needsLogin: model.needsLogin
        )
        let collapsedWidth = widthProbe.layout.collapsedSurfaceFrame.width
        let chinTextWidth = collapsedWidth - Self.statusChinHorizontalInset

        return NotchMetrics(
            voidWidth: voidWidth,
            voidHeight: voidHeight,
            expandedContentHeight: statusExpandedContentHeight,
            isExpanded: isStatusExpanded,
            isHostExpanded: isStatusHostExpanded,
            screenWidth: screen.frame.width,
            chinHeight: statusChinHeight(textWidth: chinTextWidth),
            collapsedTopRowExtraHeight: statusCollapsedTopRowExtraHeight(
                collapsedWidth: collapsedWidth,
                hasNotch: hasNotch
            ),
            needsLogin: model.needsLogin
        )
    }

    /// On a no-notch display the collapsed line renders inline in the top row (a real notch routes it into
    /// the chin band instead). It shows the same rotating surfaced-conversation line the chin does, so size the
    /// pill to the tallest surfaced line that can rotate through — the max wrapped-line count across the
    /// surfaced (active or unacknowledged) conversations — and grow by one line-height when that is two lines.
    /// The idle headline, shown when nothing is surfaced, always reads on one row, so the resting pill never
    /// grows. The text width subtracts the pill's pointer lane and gutter, measured narrow so the
    /// prediction never under-counts and clips. A real notch returns 0 — its second line lives in
    /// `statusChinHeight`.
    private func statusCollapsedTopRowExtraHeight(collapsedWidth: CGFloat, hasNotch: Bool) -> CGFloat {
        guard !hasNotch else { return 0 }
        let textWidth = collapsedWidth - Self.statusCollapsedTopRowHorizontalReserve
        // A surfaced conversation — active or unacknowledged — can grow the row to a second line; the idle
        // headline (shown when nothing is surfaced) always reads on one, so the resting pill stays a single row.
        let lines = model.notchSurfacedConversations.reduce(1) { partial, conversation in
            max(partial, Self.chinLineCount(for: conversation.chinDisplayText, width: textWidth))
        }
        return lines >= 2 ? Self.statusChinLineHeight : 0
    }

    /// The collapsed chin hangs below the notch whenever a conversation is surfaced — running, a completion, or
    /// a failure the user hasn't dismissed yet. The notch view rotates which one's line it shows. The
    /// band fits one line by default and grows by a line-height to seat a wrapped second line (capped
    /// there), keeping the bottom margin constant. Real notch only.
    private func statusChinHeight(textWidth: CGFloat) -> CGFloat {
        let surfaced = model.notchSurfacedConversations
        // A surfaced conversation is active or unacknowledged (running, waiting, or a terminal line the
        // user hasn't dismissed); those get up to two lines. An idle notch has nothing surfaced, so the
        // chin collapses to no line at all.
        guard !surfaced.isEmpty else { return 0 }
        // Cache by the surfaced chin text + width: `notchMetrics()` runs every frame, but the wrapped-line
        // Core Text measurement only needs to rerun when the text or available width actually changes.
        let key = "\(Int(textWidth))|" + surfaced.map(\.chinDisplayText).joined(separator: "\u{1}")
        if let cache = chinHeightCache, cache.key == key { return cache.height }
        let lines = surfaced.reduce(1) { partial, conversation in
            return max(partial, Self.chinLineCount(for: conversation.chinDisplayText, width: textWidth))
        }
        let height = CGFloat(lines) * Self.statusChinLineHeight + Self.statusChinBottomMargin
        chinHeightCache = (key, height)
        return height
    }

    /// Approximate how many lines (1 or 2) the chin text wraps to at `width`, by comparing its wrapped
    /// height to a single line's height in the chin font. Used to grow the band for a second line.
    private static func chinLineCount(for text: String, width: CGFloat) -> Int {
        guard width > 0, !text.isEmpty, chinFontLineHeight > 0 else { return 1 }
        let wrappedHeight = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: statusChinFontSize)]
        ).height
        let lines = Int((wrappedHeight / chinFontLineHeight).rounded())
        return min(2, max(1, lines))
    }

    /// A single line's height in the chin font — constant, so measure it once instead of per call.
    private static let chinFontLineHeight: CGFloat = ("Ag" as NSString).boundingRect(
        with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: NSFont.systemFont(ofSize: statusChinFontSize)]
    ).height

    /// Chin band geometry, mirroring the prototype: a `statusChinFontSize` line on a `…LineHeight`
    /// leading, with a constant `…BottomMargin` below the last line. One line totals 23pt (15 + 8);
    /// a second line adds another 15pt. `…HorizontalInset` is the chin's total left+right text inset.
    private static let statusChinFontSize: CGFloat = 12
    private static let statusChinLineHeight: CGFloat = 15
    private static let statusChinBottomMargin: CGFloat = 8
    private static let statusChinHorizontalInset: CGFloat = 24
    /// Horizontal chrome the no-notch collapsed top row spends before its text: the 14pt side paddings
    /// (28), the three 7pt HStack gaps (21), the 14pt pointer, and the widest gutter slot — the running
    /// clock (~46). Subtracting all of it leaves the narrowest width the text ever gets, so a wrap
    /// predicted here always holds when the gutter is smaller, never clipping the grown second line.
    private static let statusCollapsedTopRowHorizontalReserve: CGFloat = 109

    private var statusExpandedContentHeight: CGFloat {
        // Logged out: the expanded login is a short wide bar (label + Login button), not the full panel.
        if model.needsLogin {
            return NotchMetrics.loginExpandedContentHeight
        }

        if hasStatusConversationDisplayText || !model.notchConversations.isEmpty || model.updateState.headerButtonTitle != nil {
            return NotchMetrics.expandedConversationContentHeight
        }

        return model.notchCommandInputSurfaceHeight + NotchMetrics.compactCommandContentVerticalPadding
    }

    private var hasStatusConversationDisplayText: Bool {
        UserQueryCopy.isConversationDisplayText(model.promptState.promptText)
    }

    private func inferredVoidWidth(for screen: NSScreen, safeTop: CGFloat) -> CGFloat {
        guard safeTop > 0 else { return 0 }

        return min(
            max(NotchMetrics.fallbackVoidWidth, screen.frame.width * 0.095),
            NotchMetrics.maximumInferredVoidWidth
        )
    }

    private var stageHorizontalInset: CGFloat {
        (currentContentSize.width - stageContentWidth) / 2
    }

    private var stageVerticalInset: CGFloat {
        (currentContentSize.height - stageContentHeight) / 2
    }

    private var stageContentWidth: CGFloat {
        UserQueryLayout.stageHorizontalPadding * 2 +
            UserQueryLayout.composerWidth
    }

    private var stageContentHeight: CGFloat {
        UserQueryLayout.stageVerticalPadding * 2 +
            currentComposerHeight
    }

    private func composerDragRegions() -> [CGRect] {
        guard model.promptState.isActive else { return [] }

        let composerFrame = composerFrame(for: fixedPlacement)
        let inputSurfaceFrame = composerInputSurfaceFrame(in: composerFrame)
        var regions = [inputSurfaceFrame]
        for frame in composerInteractiveFrames(in: inputSurfaceFrame) {
            regions = regions.flatMap { Self.subtract(frame, from: $0) }
        }

        regions.removeAll { $0.width <= 0 || $0.height <= 0 }
        return regions
    }

    private func composerFrame(for placement: UserQueryPlacement) -> CGRect {
        let x = stageHorizontalInset + UserQueryLayout.stageHorizontalPadding

        return CGRect(
            x: x,
            y: currentContentSize.height -
                composerTopFromPanelTop -
                currentComposerHeight,
            width: UserQueryLayout.composerWidth,
            height: currentComposerHeight
        )
    }

    private var composerTopFromPanelTop: CGFloat {
        stageVerticalInset + UserQueryLayout.stageVerticalPadding
    }

    private func composerInputSurfaceFrame(in composerFrame: CGRect) -> CGRect {
        return CGRect(
            x: composerFrame.minX,
            y: composerFrame.minY,
            width: UserQueryLayout.composerInputSurfaceWidth,
            height: UserQueryLayout.composerInputHeight(
                inputTextHeight: model.inputTextHeight,
                isExpanded: model.isInputExpanded
            )
        )
    }

    private func composerTextInputFrame(in inputSurfaceFrame: CGRect) -> CGRect {
        if model.isInputExpanded {
            return CGRect(
                x: inputSurfaceFrame.minX +
                    UserQueryLayout.composerExpandedTextHorizontalPadding,
                y: inputSurfaceFrame.maxY -
                    UserQueryLayout.composerExpandedTextTopPadding -
                    model.inputTextHeight,
                width: UserQueryLayout.composerExpandedTextWidth,
                height: model.inputTextHeight
            )
        }

        let x = inputSurfaceFrame.minX + UserQueryLayout.composerInputLeadingContentPadding
        let width = UserQueryLayout.composerWrappingTextWidth
        let height = model.inputTextHeight

        return CGRect(
            x: x,
            y: inputSurfaceFrame.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func composerInteractiveFrames(in inputSurfaceFrame: CGRect) -> [CGRect] {
        [
            composerTextInputFrame(in: inputSurfaceFrame).insetBy(dx: -4, dy: -6),
            composerTrailingControlsFrame(in: inputSurfaceFrame).insetBy(dx: -6, dy: -6)
        ]
    }

    private func composerTrailingControlsFrame(in inputSurfaceFrame: CGRect) -> CGRect {
        if model.isInputExpanded {
            return CGRect(
                x: inputSurfaceFrame.maxX -
                    UserQueryLayout.composerExpandedTextHorizontalPadding -
                    UserQueryLayout.composerTrailingControlsWidth,
                y: inputSurfaceFrame.minY,
                width: UserQueryLayout.composerTrailingControlsWidth,
                height: UserQueryLayout.composerExpandedToolbarHeight
            )
        }

        return CGRect(
            x: inputSurfaceFrame.maxX -
                UserQueryLayout.composerInputTrailingContentPadding -
                UserQueryLayout.composerTrailingControlsWidth,
            y: inputSurfaceFrame.minY,
            width: UserQueryLayout.composerTrailingControlsWidth,
            height: inputSurfaceFrame.height
        )
    }

    private static func subtract(_ excludedFrame: CGRect, from frame: CGRect) -> [CGRect] {
        let excludedFrame = excludedFrame.intersection(frame)
        guard !excludedFrame.isNull, !excludedFrame.isEmpty else { return [frame] }

        var regions: [CGRect] = []
        if excludedFrame.minY > frame.minY {
            regions.append(CGRect(
                x: frame.minX,
                y: frame.minY,
                width: frame.width,
                height: excludedFrame.minY - frame.minY
            ))
        }
        if excludedFrame.maxY < frame.maxY {
            regions.append(CGRect(
                x: frame.minX,
                y: excludedFrame.maxY,
                width: frame.width,
                height: frame.maxY - excludedFrame.maxY
            ))
        }
        if excludedFrame.minX > frame.minX {
            regions.append(CGRect(
                x: frame.minX,
                y: excludedFrame.minY,
                width: excludedFrame.minX - frame.minX,
                height: excludedFrame.height
            ))
        }
        if excludedFrame.maxX < frame.maxX {
            regions.append(CGRect(
                x: excludedFrame.maxX,
                y: excludedFrame.minY,
                width: frame.maxX - excludedFrame.maxX,
                height: excludedFrame.height
            ))
        }

        return regions.filter { $0.width > 0 && $0.height > 0 }
    }

    private func updateMouseEventPassthrough(for panel: NSPanel) {
        guard model.promptState.isActive else {
            panel.ignoresMouseEvents = true
            isVoiceInputActive = false
            return
        }

        if isComposerTextInputFocused(in: panel) {
            panel.ignoresMouseEvents = false
            return
        }

        let mouseLocationInPanel = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !composerFrame(for: fixedPlacement).contains(mouseLocationInPanel)
    }

    private func dismissActivePromptIfClickIsOutside() -> Bool {
        guard model.promptState.isActive,
              let inputPanel else {
            return false
        }

        let mouseLocationInPanel = inputPanel.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard !composerFrame(for: fixedPlacement).contains(mouseLocationInPanel) else {
            return false
        }

        model.handle(.dismissed)
        isVoiceInputActive = false
        microphoneWaveformMeter.stop()
        return true
    }

    private func dismissActivePromptIfEscape(_ event: NSEvent) -> Bool {
        guard model.promptState.isActive,
              event.keyCode == UInt16(kVK_Escape) else { return false }

        dismissActivePromptFromKeyboard()
        return true
    }

    private func dismissActivePromptFromKeyboard() {
        dismissActivePrompt()
    }

    private func dismissActivePromptFromAppDeactivation() {
        resetActivationTapSequence()
        dismissActivePrompt()
        inputPanel?.orderOut(nil)
    }

    private func dismissActivePrompt() {
        guard model.promptState.isActive else { return }

        model.handle(.dismissed)
        isVoiceInputActive = false
        microphoneWaveformMeter.stop()
    }

    private var currentContentSize: CGSize {
        UserQueryLayout.contentSize(
            inputTextHeight: model.inputTextHeight,
            isExpanded: model.isInputExpanded
        )
    }

    private var currentComposerHeight: CGFloat {
        UserQueryLayout.composerHeight(
            inputTextHeight: model.inputTextHeight,
            isExpanded: model.isInputExpanded
        )
    }

    private func resizeActivePanelIfNeeded(_ panel: NSPanel) {
        let size = currentContentSize
        let frame = panel.frame
        guard abs(frame.width - size.width) > 0.5 ||
            abs(frame.height - size.height) > 0.5 else {
            return
        }

        panel.setFrame(
            CGRect(
                x: frame.midX - size.width / 2,
                y: frame.midY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            display: true
        )
    }

    private func focusComposerTextInput(attempt: Int = 0) {
        guard let panel = inputPanel else { return }

        activateForKeyboardInput(panel)

        guard let textView = firstComposerTextView(in: panel.contentView) else {
            guard attempt < 8 else { return }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
                self.focusComposerTextInput(attempt: attempt + 1)
            }
            return
        }

        panel.makeFirstResponder(textView)
        textView.window?.makeFirstResponder(textView)

        guard attempt < 8,
              (!NSApp.isActive ||
               !panel.isKeyWindow ||
               !isComposerTextInputFocused(in: panel)) else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
            self.focusComposerTextInput(attempt: attempt + 1)
        }
    }

    private func activateForKeyboardInput(_ panel: NSPanel) {
        panel.ignoresMouseEvents = false
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
    }

    private func firstComposerTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }

        if let textView = view as? NSTextView {
            return textView
        }

        for subview in view.subviews {
            if let textView = firstComposerTextView(in: subview) {
                return textView
            }
        }

        return nil
    }

    private func isComposerTextInputFocused(in panel: NSPanel) -> Bool {
        guard let textView = firstComposerTextView(in: panel.contentView) else {
            return false
        }

        return panel.firstResponder === textView ||
            textView.window?.firstResponder === textView
    }

    private func focusStatusComposerTextInput(attempt: Int = 0) {
        guard isStatusExpanded,
              let statusPanel,
              let textView = firstComposerTextView(in: statusPanel.contentView) else {
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        statusPanel.orderFrontRegardless()
        statusPanel.makeKeyAndOrderFront(nil)
        statusPanel.makeFirstResponder(textView)
        textView.window?.makeFirstResponder(textView)

        guard attempt < 8,
              (!NSApp.isActive ||
               !statusPanel.isKeyWindow ||
               !isComposerTextInputFocused(in: statusPanel)) else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
            self.focusStatusComposerTextInput(attempt: attempt + 1)
        }
    }

    private func focusStatusComposerTextInputIfAvailable() {
        focusStatusComposerTextInput()
    }
}

private final class UserQueryPanel: NSPanel {
    var dragRegionProvider: (() -> [CGRect])?
    var escapeKeyHandler: (() -> Void)?
    var mouseDownHandler: (() -> Void)?
    /// Up/Down arrow handler for the expanded notch. Returns whether it consumed the key; when it does
    /// not (the composer owns the arrows for text editing), the event falls through to the field.
    var arrowKeyHandler: ((NotchArrowDirection) -> Bool)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    /// Make the standard editing shortcuts work in the composer. It's an NSTextView inside an
    /// NSScrollView, and NSScrollView doesn't forward `performKeyEquivalent` to its document view, so
    /// Cmd+V/C/X/A/Z never reach the field on their own — the user can type but not paste. The window
    /// always receives `performKeyEquivalent` for a key equivalent (before the main menu), so route the
    /// shortcut to the focused text here. Returns true to consume it so nothing else double-handles it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let text = firstResponder as? NSText,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return false
        }
        switch key {
        case "v": text.paste(nil); return true
        case "c": text.copy(nil); return true
        case "x": text.cut(nil); return true
        case "a": text.selectAll(nil); return true
        case "z":
            if event.modifierFlags.contains(.shift) { text.undoManager?.redo() } else { text.undoManager?.undo() }
            return true
        default: return false
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            switch Int(event.keyCode) {
            case kVK_UpArrow:
                if arrowKeyHandler?(.up) == true { return }
            case kVK_DownArrow:
                if arrowKeyHandler?(.down) == true { return }
            default:
                break
            }
        }

        if event.type == .keyDown,
           event.keyCode == UInt16(kVK_Escape) {
            escapeKeyHandler?()
            return
        }

        if event.type == .leftMouseDown,
           dragRegionProvider?().contains(where: { $0.contains(event.locationInWindow) }) == true {
            performDrag(with: event)
            return
        }

        if event.type == .leftMouseDown {
            mouseDownHandler?()
        }

        super.sendEvent(event)
    }
}

private final class UserQueryHostingView<Content: View>: NSHostingView<Content> {
    var hitTestRegionProvider: (() -> [CGRect])?

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hitTestRegionProvider,
           !hitTestRegionProvider().contains(where: { $0.contains(point) }) {
            return nil
        }

        return super.hitTest(point)
    }
}

private typealias NotchMetrics = UserQueryNotchMetrics

private struct StatusPanelViewSnapshot: Equatable {
    var state: UserQueryState
    var updateState: UserQueryUpdateState
    var layout: UserQueryNotchLayout
    var surfaceSize: CGSize
    var isExpanded: Bool
    var isHostExpanded: Bool
    var isCurrentConversationPaused: Bool
    var notchCommandText: String
    var notchCommandInputTextHeight: CGFloat
    var isNotchCommandInputExpanded: Bool
    var notchConversations: [UserQueryConversation]
    var notchSurfacedConversations: [UserQueryConversation]
    var accentIndex: Int
    var spawnState: UserQuerySpawnState?
    var spawnStates: [UserQuerySpawnState]
    var selectedSpawnID: String?
    var replyTargetConversationID: String?
    var selectedConversationID: String?
    var needsLogin: Bool
}

private enum StatusHoverPhase {
    // The status panel has two layers of state: an invisible AppKit host rect and
    // the SwiftUI notch surface. These phases keep quick hover churn from leaving
    // one layer expanded while the other is still opening or closing.
    case collapsed
    case expanded
    case closing
}

private extension UserQueryActivationModifier {
    var eventModifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .command:
            .command
        }
    }
}
