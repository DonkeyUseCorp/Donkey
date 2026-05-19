import AppKit
import Carbon.HIToolbox
import DonkeyContracts
import DonkeyUI
import QuartzCore
import SwiftUI

@MainActor
final class PointerPromptOverlayController {
    private let model: PointerPromptOverlayModel
    private let fixedPlacement: PointerPromptPlacement = .bottomRight
    private let activationShortcut: PointerPromptActivationShortcut
    private let microphoneWaveformMeter = MicrophoneWaveformMeter()

    private var statusPanel: NSPanel?
    private var statusHostingView: NSHostingView<PointerPromptNotchStatusView>?
    private var inputPanel: NSPanel?
    private var timer: Timer?
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
    private var statusExpansionWorkItem: DispatchWorkItem?
    private var statusHostShrinkWorkItem: DispatchWorkItem?
    private var lastStatusViewSnapshot: StatusPanelViewSnapshot?

    init(
        model: PointerPromptOverlayModel,
        activationShortcut: PointerPromptActivationShortcut = .doubleCommand
    ) {
        self.model = model
        self.activationShortcut = activationShortcut
        microphoneWaveformMeter.onLevelsChanged = { [weak model] levels in
            model?.updateVoiceWaveformLevels(levels)
        }
    }

    func show() {
        let initialInputSize = currentContentSize
        let inputHostingView = makeInputHostingView(size: initialInputSize)
        let inputPanel = makeInputPanel(size: initialInputSize, hostingView: inputHostingView)
        let statusPanel = makeStatusPanel()

        self.inputPanel = inputPanel
        self.statusPanel = statusPanel
        startActivationMonitoring()
        startAppDeactivationMonitoring()
        positionStatusPanel()
        centerInputPanel()
        inputPanel.orderOut(nil)
        statusPanel.orderFrontRegardless()
        startTimer()
    }

    private func makeInputHostingView(size: CGSize) -> NSHostingView<PointerPromptOverlayRootView> {
        let hostingView = NSHostingView(rootView: PointerPromptOverlayRootView(model: model))
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        return hostingView
    }

    private func makeInputPanel(
        size: CGSize,
        hostingView: NSHostingView<PointerPromptOverlayRootView>
    ) -> PointerPromptPanel {
        let panel = PointerPromptPanel(
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
        panel.level = .statusBar
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
        let hostingView = NSHostingView(rootView: notchStatusView(metrics: metrics))
        hostingView.frame = CGRect(origin: .zero, size: metrics.surfaceSize)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        statusHostingView = hostingView
        lastStatusViewSnapshot = statusViewSnapshot(metrics: metrics)

        let panel = PointerPromptPanel(
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
            self?.focusStatusComposerTextInputIfEmpty()
        }
        panel.level = .statusBar
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
        statusExpansionWorkItem?.cancel()
        statusExpansionWorkItem = nil
        statusHostShrinkWorkItem?.cancel()
        statusHostShrinkWorkItem = nil
        statusHoverPhase = .collapsed
        stopActivationMonitoring()
        stopAppDeactivationMonitoring()
        microphoneWaveformMeter.stop()
        inputPanel?.close()
        inputPanel = nil
        statusPanel?.close()
        statusPanel = nil
        statusHostingView = nil
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
        guard let holdToVoiceInputDuration = activationShortcut.holdToVoiceInputDuration,
              let activationHoldStartedAt,
              activationTapIsClean,
              Date().timeIntervalSince(activationHoldStartedAt) >= holdToVoiceInputDuration else {
            return
        }

        resetActivationTapSequence()
        activateVoiceInputAtScreenCenter()
    }

    private func activateInputAtScreenCenter() {
        guard !model.promptState.isActive else {
            if let inputPanel {
                centerInputPanel()
                activateForKeyboardInput(inputPanel)
            }
            focusComposerTextInput()
            microphoneWaveformMeter.start()
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
        microphoneWaveformMeter.start()
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
        positionStatusPanel()
        updateStatusHoverExpansion()
        updateStatusPanelView()
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

    private func positionStatusPanel(disableAnimations: Bool = true) {
        guard let statusPanel,
              let screen = activeScreen() else {
            return
        }

        let metrics = notchMetrics(for: screen)
        let frame = CGRect(
            x: screen.frame.midX - metrics.surfaceSize.width / 2,
            y: screen.frame.maxY - metrics.surfaceSize.height,
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

    private func updateStatusPanelView() {
        let metrics = notchMetrics()
        let snapshot = statusViewSnapshot(metrics: metrics)
        let previousSnapshot = lastStatusViewSnapshot
        guard snapshot != previousSnapshot else { return }

        if snapshot.surfaceSize != previousSnapshot?.surfaceSize {
            positionStatusPanel()
        }

        lastStatusViewSnapshot = snapshot
        statusHostingView?.rootView = notchStatusView(metrics: metrics)
    }

    private func statusViewSnapshot(metrics: NotchMetrics) -> StatusPanelViewSnapshot {
        StatusPanelViewSnapshot(
            state: model.promptState,
            updateState: model.updateState,
            layout: metrics.layout,
            surfaceSize: metrics.surfaceSize,
            isExpanded: isStatusExpanded,
            isHostExpanded: isStatusHostExpanded,
            isCurrentTaskPaused: model.isCurrentTaskPaused,
            notchCommandText: model.notchCommandText,
            notchCommandInputTextHeight: model.notchCommandInputTextHeight,
            isNotchCommandInputExpanded: model.isNotchCommandInputExpanded,
            accentIndex: model.notchAccentIndex
        )
    }

    private func notchStatusView(metrics: NotchMetrics) -> PointerPromptNotchStatusView {
        PointerPromptNotchStatusView(
            state: model.promptState,
            updateState: model.updateState,
            layout: metrics.layout,
            surfaceWidth: metrics.surfaceSize.width,
            surfaceHeight: metrics.surfaceSize.height,
            isExpanded: isStatusExpanded,
            isCurrentTaskPaused: model.isCurrentTaskPaused,
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
            accentIndex: model.notchAccentIndex,
            commandSubmitted: { [weak self] text in
                self?.model.handle(.messageSubmitted(text: text))
            },
            commandInputTextHeightChanged: { [weak self] height in
                self?.model.updateNotchCommandInputTextHeight(height)
            },
            commandInputExpansionChanged: { [weak self] isExpanded in
                self?.model.updateNotchCommandInputExpansion(isExpanded)
            },
            pauseRequested: { [weak self] in
                self?.model.pauseCurrentTask()
            },
            resumeRequested: { [weak self] in
                self?.model.resumeCurrentTask()
            },
            updateRequested: { [weak self] in
                self?.openAvailableUpdate()
            }
        )
    }

    private func openAvailableUpdate() {
        model.showUpdateUI()
    }

    private func updateStatusHoverExpansion() {
        guard let statusPanel else { return }

        let metrics = notchMetrics(for: statusPanel.screen)
        let mouseLocationInPanel = statusPanel.convertPoint(fromScreen: NSEvent.mouseLocation)

        if metrics.hoverFramesInPanel.contains(where: { $0.contains(mouseLocationInPanel) }) {
            setStatusExpanded(true)
        } else if statusHoverPhase != .collapsed, statusCollapseWorkItem == nil {
            scheduleStatusCollapse()
        }
    }

    private func setStatusExpanded(_ isExpanded: Bool) {
        if isExpanded {
            statusCollapseWorkItem?.cancel()
            statusCollapseWorkItem = nil
            statusHostShrinkWorkItem?.cancel()
            statusHostShrinkWorkItem = nil
            guard statusHoverPhase != .preparingOpen, statusHoverPhase != .expanded else { return }
            applyStatusExpanded(true)
            return
        }

        scheduleStatusCollapse()
    }

    private func applyStatusExpanded(_ isExpanded: Bool) {
        if isExpanded {
            guard statusHoverPhase != .preparingOpen, statusHoverPhase != .expanded else { return }

            statusHoverPhase = .preparingOpen
            isStatusExpanded = false
            // First render the collapsed visual notch inside the already-expanded
            // host. The delayed flip below is the only step that should animate.
            prepareStatusHostForExpansion()

            let workItem = DispatchWorkItem { [weak self] in
                guard let self,
                      self.statusHoverPhase == .preparingOpen,
                      self.isStatusHostExpanded,
                      !self.isStatusExpanded else { return }
                self.isStatusExpanded = true
                self.statusHoverPhase = .expanded
                self.statusExpansionWorkItem = nil
                self.updateStatusPanelView()
                self.focusStatusComposerTextInputIfEmpty()
            }
            statusExpansionWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + NotchMetrics.openHostPreparationDelay,
                execute: workItem
            )
            return
        }

        statusExpansionWorkItem?.cancel()
        statusExpansionWorkItem = nil

        guard statusHoverPhase != .collapsed else { return }
        guard statusHoverPhase != .closing else {
            scheduleStatusHostShrink()
            return
        }

        if isStatusExpanded {
            isStatusExpanded = false
            updateStatusPanelView()
        }

        statusHoverPhase = .closing
        scheduleStatusHostShrink()
    }

    private func prepareStatusHostForExpansion() {
        isStatusHostExpanded = true
        positionStatusPanel()
        updateStatusPanelView()
        flushStatusHostLayout()
    }

    private func flushStatusHostLayout() {
        guard let statusPanel else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            statusPanel.contentView?.layoutSubtreeIfNeeded()
            statusHostingView?.layoutSubtreeIfNeeded()
            statusHostingView?.displayIfNeeded()
            statusPanel.displayIfNeeded()
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
        statusHostShrinkWorkItem?.cancel()

        // Wait for SwiftUI's short close animation, then collapse the transparent
        // host without animation. Shrinking it earlier changes the coordinate
        // space while the visible surface is still animating.
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
                screenWidth: NotchMetrics.defaultScreenWidth
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
        let hasNotch = safeTop > 0 || measuredVoidWidth > 0
        let voidHeight = hasNotch ? max(safeTop, NotchMetrics.fallbackVoidHeight) : 0
        let voidWidth = hasNotch ? max(measuredVoidWidth, inferredVoidWidth(for: screen, safeTop: safeTop)) : 0

        return NotchMetrics(
            voidWidth: voidWidth,
            voidHeight: voidHeight,
            expandedContentHeight: statusExpandedContentHeight,
            isExpanded: isStatusExpanded,
            isHostExpanded: isStatusHostExpanded,
            screenWidth: screen.frame.width
        )
    }

    private var statusExpandedContentHeight: CGFloat {
        if hasStatusTaskDisplayText || model.updateState.headerButtonTitle != nil {
            return NotchMetrics.expandedTaskContentHeight
        }

        return model.notchCommandInputSurfaceHeight + NotchMetrics.compactCommandContentPadding
    }

    private var hasStatusTaskDisplayText: Bool {
        let text = model.promptState.promptText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        return !text.isEmpty && text != "Make this so" && text != "Resting"
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
        PointerPromptLayout.stageHorizontalPadding * 2 +
            PointerPromptLayout.composerWidth
    }

    private var stageContentHeight: CGFloat {
        PointerPromptLayout.stageVerticalPadding * 2 +
            currentComposerHeight
    }

    private func composerDragRegions() -> [CGRect] {
        guard model.promptState.isActive else { return [] }

        let composerFrame = composerFrame(for: fixedPlacement)
        let inputSurfaceFrame = composerInputSurfaceFrame(in: composerFrame)
        var regions = [inputSurfaceFrame]

        regions.removeAll { $0.width <= 0 || $0.height <= 0 }
        return regions
    }

    private func composerFrame(for placement: PointerPromptPlacement) -> CGRect {
        let x = stageHorizontalInset + PointerPromptLayout.stageHorizontalPadding

        return CGRect(
            x: x,
            y: currentContentSize.height -
                composerTopFromPanelTop -
                currentComposerHeight,
            width: PointerPromptLayout.composerWidth,
            height: currentComposerHeight
        )
    }

    private var composerTopFromPanelTop: CGFloat {
        stageVerticalInset + PointerPromptLayout.stageVerticalPadding
    }

    private func composerInputSurfaceFrame(in composerFrame: CGRect) -> CGRect {
        return CGRect(
            x: composerFrame.minX,
            y: composerFrame.minY,
            width: PointerPromptLayout.composerInputSurfaceWidth,
            height: PointerPromptLayout.composerInputHeight(
                inputTextHeight: model.inputTextHeight,
                isExpanded: model.isInputExpanded
            )
        )
    }

    private func composerTextInputFrame(in inputSurfaceFrame: CGRect) -> CGRect {
        if model.isInputExpanded {
            return CGRect(
                x: inputSurfaceFrame.minX +
                    PointerPromptLayout.composerExpandedTextHorizontalPadding,
                y: inputSurfaceFrame.maxY -
                    PointerPromptLayout.composerExpandedTextTopPadding -
                    model.inputTextHeight,
                width: PointerPromptLayout.composerExpandedTextWidth,
                height: model.inputTextHeight
            )
        }

        let x = inputSurfaceFrame.minX + PointerPromptLayout.composerInputLeadingContentPadding
        let width = PointerPromptLayout.composerWrappingTextWidth
        let height = model.inputTextHeight

        return CGRect(
            x: x,
            y: inputSurfaceFrame.midY - height / 2,
            width: width,
            height: height
        )
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
        PointerPromptLayout.contentSize(
            inputTextHeight: model.inputTextHeight,
            isExpanded: model.isInputExpanded
        )
    }

    private var currentComposerHeight: CGFloat {
        PointerPromptLayout.composerHeight(
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

    private func focusStatusComposerTextInputIfEmpty() {
        guard !hasStatusTaskDisplayText else { return }

        focusStatusComposerTextInput()
    }
}

private final class PointerPromptPanel: NSPanel {
    var dragRegionProvider: (() -> [CGRect])?
    var escapeKeyHandler: (() -> Void)?
    var mouseDownHandler: (() -> Void)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override func sendEvent(_ event: NSEvent) {
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

private struct NotchMetrics {
    static let fallbackVoidWidth: CGFloat = 180
    static let fallbackVoidHeight: CGFloat = 32
    static let maximumInferredVoidWidth: CGFloat = 220
    static let defaultScreenWidth: CGFloat = 1512

    var voidWidth: CGFloat
    var voidHeight: CGFloat
    var expandedContentHeight: CGFloat
    var isExpanded: Bool
    var isHostExpanded: Bool
    var screenWidth: CGFloat

    var surfaceSize: CGSize {
        surfaceFrame.size
    }

    var visibleSurfaceFrameInPanel: CGRect {
        frameInPanel(for: visibleSurfaceFrame)
    }

    var hoverFramesInPanel: [CGRect] {
        let tolerance: CGFloat = 2
        return [visibleSurfaceFrameInPanel.insetBy(dx: -tolerance, dy: -tolerance)]
    }

    var layout: PointerPromptNotchLayout {
        PointerPromptNotchLayout(
            voidWidth: voidWidth,
            voidHeight: voidHeight,
            collapsedVisibleHeight: collapsedVisibleHeight,
            expandedVisibleHeight: expandedVisibleHeight,
            contentHorizontalInset: 14,
            visibleHeight: visibleHeight,
            cornerRadius: isExpanded ? Self.expandedCornerRadius : Self.collapsedCornerRadius,
            collapsedSurfaceFrame: collapsedSurfaceFrame,
            expandedSurfaceFrame: expandedSurfaceFrame,
            expandedContentFrame: expandedContentFrame,
            collapsedCornerRadius: Self.collapsedCornerRadius,
            expandedCornerRadius: Self.expandedCornerRadius
        )
    }

    private var visibleHeight: CGFloat {
        visibleSurfaceFrame.height
    }

    private func frameInPanel(for frame: CGRect) -> CGRect {
        CGRect(
            x: (surfaceSize.width - frame.width) / 2,
            y: surfaceSize.height - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    private var surfaceFrame: CGRect {
        isHostExpanded ? expandedSurfaceFrame : collapsedSurfaceFrame
    }

    private var visibleSurfaceFrame: CGRect {
        isExpanded ? expandedSurfaceFrame : collapsedSurfaceFrame
    }

    private var expandedSurfaceFrame: CGRect {
        CGRect(
            x: 0,
            y: 0,
            width: Self.expandedContentDesignFrame.width,
            height: expandedSurfaceHeight
        )
    }

    private var collapsedSurfaceFrame: CGRect {
        CGRect(
            x: 0,
            y: 0,
            width: collapsedSurfaceWidth,
            height: collapsedVisibleHeight
        )
    }

    private var expandedContentFrame: CGRect {
        CGRect(
            x: Self.expandedContentDesignFrame.minX,
            y: expandedContentTopInset,
            width: Self.expandedContentDesignFrame.width,
            height: expandedContentHeight
        )
    }

    private var collapsedSurfaceWidth: CGFloat {
        min(
            Self.expandedContentDesignFrame.width,
            max(Self.minimumCollapsedSurfaceFrame.width, voidWidth + Self.collapsedSideLaneWidth * 2)
        )
    }

    private var collapsedVisibleHeight: CGFloat {
        voidHeight > 0 ? voidHeight : Self.minimumCollapsedSurfaceFrame.height
    }

    private var expandedVisibleHeight: CGFloat {
        expandedSurfaceHeight
    }

    private var expandedContentTopInset: CGFloat {
        min(max(0, voidHeight), Self.maximumExpandedContentTopInset)
    }

    private var expandedSurfaceHeight: CGFloat {
        expandedContentHeight + expandedContentTopInset
    }

    private static let minimumCollapsedSurfaceFrame = CGRect(x: 0, y: 0, width: 110, height: 28)
    private static let expandedContentDesignFrame = CGRect(
        x: 0,
        y: 0,
        width: PointerPromptLayout.composerInputSurfaceWidth + 48,
        height: 280
    )
    static let expandedTaskContentHeight: CGFloat = 280
    static let compactCommandContentPadding: CGFloat = 52
    private static let collapsedSideLaneWidth: CGFloat = 34
    private static let collapsedCornerRadius: CGFloat = 14
    private static let expandedCornerRadius: CGFloat = 26
    static let openHostPreparationDelay: TimeInterval = 1.0 / 60.0
    static let closeAnimationDuration: TimeInterval = 0.22
    private static let maximumExpandedContentTopInset: CGFloat = 44
}

private struct StatusPanelViewSnapshot: Equatable {
    var state: PointerPromptState
    var updateState: PointerPromptUpdateState
    var layout: PointerPromptNotchLayout
    var surfaceSize: CGSize
    var isExpanded: Bool
    var isHostExpanded: Bool
    var isCurrentTaskPaused: Bool
    var notchCommandText: String
    var notchCommandInputTextHeight: CGFloat
    var isNotchCommandInputExpanded: Bool
    var accentIndex: Int
}

private enum StatusHoverPhase {
    // The status panel has two layers of state: an invisible AppKit host rect and
    // the SwiftUI notch surface. These phases keep quick hover churn from leaving
    // one layer expanded while the other is still opening or closing.
    case collapsed
    case preparingOpen
    case expanded
    case closing
}

private extension PointerPromptActivationModifier {
    var eventModifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .command:
            .command
        }
    }
}
