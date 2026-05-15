import AppKit
import DonkeyContracts
import SwiftUI

@MainActor
final class PointerPromptOverlayController {
    static let contentSize = PointerPromptLayout.contentSize

    private let model: PointerPromptOverlayModel
    private let fixedPlacement: PointerPromptPlacement = .bottomRight
    private let activationShortcut: PointerPromptActivationShortcut

    private var panel: NSPanel?
    private var timer: Timer?
    private var globalActivationMonitor: Any?
    private var localActivationMonitor: Any?
    private var activationTapStartedAt: Date?
    private var activationTapIsClean = false
    private var completedActivationTapCount = 0
    private var lastActivationTapCompletedAt: Date?
    private var activationHoldStartedAt: Date?

    init(
        model: PointerPromptOverlayModel,
        activationShortcut: PointerPromptActivationShortcut = .doubleCommand
    ) {
        self.model = model
        self.activationShortcut = activationShortcut
    }

    func show() {
        let rootView = PointerPromptOverlayRootView(model: model)
        let initialContentSize = currentContentSize
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = CGRect(origin: .zero, size: initialContentSize)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = PointerPromptPanel(
            contentRect: CGRect(origin: .zero, size: initialContentSize),
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
        panel.ignoresMouseEvents = true
        panel.dragRegionProvider = { [weak self] in
            self?.composerDragRegions() ?? []
        }
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary
        ]

        self.panel = panel
        startActivationMonitoring()
        positionAtCurrentMouseLocation()
        panel.orderFrontRegardless()
        startTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stopActivationMonitoring()
        panel?.close()
        panel = nil
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
            let eventType = event.type
            let modifierFlags = event.modifierFlags
            Task { @MainActor in
                self?.handleActivationEvent(type: eventType, modifierFlags: modifierFlags)
            }
        }

        localActivationMonitor = NSEvent.addLocalMonitorForEvents(matching: activationEventMask) { [weak self] event in
            let eventType = event.type
            let modifierFlags = event.modifierFlags
            Task { @MainActor in
                self?.handleActivationEvent(type: eventType, modifierFlags: modifierFlags)
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

    private func handleActivationEvent(
        type: NSEvent.EventType,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        switch type {
        case .flagsChanged:
            handleModifierFlagsChanged(modifierFlags)
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
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
        activateAtCurrentMouseLocation()
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
        activateVoiceInputAtCurrentMouseLocation()
    }

    private func activateAtCurrentMouseLocation() {
        guard !model.promptState.isActive else {
            NSApp.activate(ignoringOtherApps: true)
            panel?.makeKeyAndOrderFront(nil)
            focusComposerTextInput()
            return
        }

        activate(at: NSEvent.mouseLocation)
    }

    private func activateVoiceInputAtCurrentMouseLocation() {
        activateAtCurrentMouseLocation()
        model.handle(.voiceInputRequested)
    }

    private func positionAtCurrentMouseLocation() {
        tick(mouseLocation: NSEvent.mouseLocation)
    }

    private func activate(at mouseLocation: CGPoint) {
        guard let panel else { return }

        model.activate()
        tick(mouseLocation: mouseLocation)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
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

    private func tick(mouseLocation explicitMouseLocation: CGPoint? = nil) {
        guard let panel else { return }

        activateVoiceInputIfNeeded()
        updateMouseEventPassthrough(for: panel)
        if model.promptState.isActive, explicitMouseLocation == nil {
            resizeActivePanelIfNeeded(panel)
            updateMouseEventPassthrough(for: panel)
            return
        }

        let mouseLocation = explicitMouseLocation ?? NSEvent.mouseLocation
        let targetFrame = frame(for: fixedPlacement, mouseLocation: mouseLocation)
        panel.setFrame(targetFrame, display: true)
        updateMouseEventPassthrough(for: panel)

        if model.placement != fixedPlacement {
            model.placement = fixedPlacement
        }
    }

    private func frame(
        for placement: PointerPromptPlacement,
        mouseLocation: CGPoint
    ) -> CGRect {
        let size = currentContentSize
        let anchor = agentPointerTipAnchor(for: placement)
        let agentPointerTipLocation = agentPointerTipLocation(
            for: placement,
            mouseLocation: mouseLocation
        )

        return CGRect(
            x: agentPointerTipLocation.x - anchor.x,
            y: agentPointerTipLocation.y - anchor.y,
            width: size.width,
            height: size.height
        )
    }

    private func agentPointerTipLocation(
        for placement: PointerPromptPlacement,
        mouseLocation: CGPoint
    ) -> CGPoint {
        let xDirection: CGFloat = placement.placesContentOnLeft ? -1 : 1
        let yDirection: CGFloat = placement.placesContentAbovePointer ? 1 : -1

        return CGPoint(
            x: mouseLocation.x + PointerPromptLayout.pointerDiagonalComponent * xDirection,
            y: mouseLocation.y + PointerPromptLayout.pointerDiagonalComponent * yDirection
        )
    }

    private func agentPointerTipAnchor(for placement: PointerPromptPlacement) -> CGPoint {
        let pointerSlotX: CGFloat
        if placement.placesContentOnLeft {
            pointerSlotX = stageHorizontalInset +
                PointerPromptLayout.stageHorizontalPadding +
                PointerPromptLayout.composerWidth +
                PointerPromptLayout.pointerComposerSpacing
        } else {
            pointerSlotX = stageHorizontalInset + PointerPromptLayout.stageHorizontalPadding
        }
        let pointerVisualX = pointerSlotX + pointerVisualInsetX(for: placement)
        let pointerTipX = pointerVisualX +
            PointerPromptLayout.pointerVisualSize.width *
            PointerPromptLayout.pointerTipUnitPoint.x

        return CGPoint(
            x: pointerTipX,
            y: currentContentSize.height - pointerTipYFromTop
        )
    }

    private func pointerVisualInsetX(for placement: PointerPromptPlacement) -> CGFloat {
        placement.placesContentOnLeft ? 0 :
            PointerPromptLayout.pointerSlotSize.width - PointerPromptLayout.pointerVisualSize.width
    }

    private var stageHorizontalInset: CGFloat {
        (currentContentSize.width - stageContentWidth) / 2
    }

    private var stageVerticalInset: CGFloat {
        (currentContentSize.height - stageContentHeight) / 2
    }

    private var stageContentWidth: CGFloat {
        PointerPromptLayout.stageHorizontalPadding * 2 +
            PointerPromptLayout.pointerSlotSize.width +
            PointerPromptLayout.pointerComposerSpacing +
            PointerPromptLayout.composerWidth
    }

    private var stageContentHeight: CGFloat {
        PointerPromptLayout.stageVerticalPadding * 2 +
            currentComposerHeight
    }

    private var pointerTipYFromTop: CGFloat {
        pointerVisualTopFromPanelTop +
            PointerPromptLayout.pointerVisualSize.height *
            PointerPromptLayout.pointerTipUnitPoint.y
    }

    private var pointerVisualTopFromPanelTop: CGFloat {
        composerTopFromPanelTop
    }

    private func composerDragRegions() -> [CGRect] {
        guard model.promptState.isActive else { return [] }

        let composerFrame = composerFrame(for: fixedPlacement)
        let inputFrame = composerInputFrame(in: composerFrame)
        let closeControlFrame = CGRect(
            x: composerFrame.minX + PointerPromptLayout.closeButtonInset,
            y: composerFrame.maxY -
                PointerPromptLayout.closeButtonInset -
                PointerPromptLayout.closeButtonSize,
            width: PointerPromptLayout.closeControlWidth,
            height: PointerPromptLayout.closeButtonSize
        ).insetBy(dx: -6, dy: -6)

        var regions = [
            CGRect(
                x: closeControlFrame.maxX,
                y: inputFrame.maxY,
                width: composerFrame.maxX - closeControlFrame.maxX,
                height: composerFrame.maxY - inputFrame.maxY
            ),
            CGRect(
                x: composerFrame.minX,
                y: inputFrame.maxY,
                width: closeControlFrame.minX - composerFrame.minX,
                height: composerFrame.maxY - inputFrame.maxY
            ),
            CGRect(
                x: composerFrame.minX,
                y: inputFrame.minY,
                width: inputFrame.minX - composerFrame.minX,
                height: inputFrame.height
            ),
            CGRect(
                x: inputFrame.maxX,
                y: inputFrame.minY,
                width: composerFrame.maxX - inputFrame.maxX,
                height: inputFrame.height
            ),
            CGRect(
                x: composerFrame.minX,
                y: composerFrame.minY,
                width: composerFrame.width,
                height: inputFrame.minY - composerFrame.minY
            )
        ]

        regions.removeAll { $0.width <= 0 || $0.height <= 0 }
        return regions
    }

    private func composerFrame(for placement: PointerPromptPlacement) -> CGRect {
        let x: CGFloat
        if placement.placesContentOnLeft {
            x = stageHorizontalInset + PointerPromptLayout.stageHorizontalPadding
        } else {
            x = stageHorizontalInset +
                PointerPromptLayout.stageHorizontalPadding +
                PointerPromptLayout.pointerSlotSize.width +
                PointerPromptLayout.pointerComposerSpacing
        }

        return CGRect(
            x: x,
            y: currentContentSize.height - composerTopFromPanelTop - currentComposerHeight,
            width: PointerPromptLayout.composerWidth,
            height: currentComposerHeight
        )
    }

    private var composerTopFromPanelTop: CGFloat {
        stageVerticalInset + PointerPromptLayout.stageVerticalPadding
    }

    private func composerInputFrame(in composerFrame: CGRect) -> CGRect {
        let inputHeight = PointerPromptLayout.composerInputHeight(
            inputTextHeight: model.inputTextHeight
        )

        return CGRect(
            x: composerFrame.minX + PointerPromptLayout.composerInputHorizontalPadding,
            y: composerFrame.minY + PointerPromptLayout.composerBottomPadding,
            width: composerFrame.width - PointerPromptLayout.composerInputHorizontalPadding * 2,
            height: inputHeight
        )
    }

    private func updateMouseEventPassthrough(for panel: NSPanel) {
        guard model.promptState.isActive else {
            panel.ignoresMouseEvents = true
            return
        }

        if isComposerTextInputFocused(in: panel) {
            panel.ignoresMouseEvents = false
            return
        }

        let mouseLocationInPanel = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !composerFrame(for: fixedPlacement).contains(mouseLocationInPanel)
    }

    private var currentContentSize: CGSize {
        PointerPromptLayout.contentSize(inputTextHeight: model.inputTextHeight)
    }

    private var currentComposerHeight: CGFloat {
        PointerPromptLayout.composerHeight(inputTextHeight: model.inputTextHeight)
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
                x: frame.minX,
                y: frame.maxY - size.height,
                width: size.width,
                height: size.height
            ),
            display: true
        )
    }

    private func focusComposerTextInput(attempt: Int = 0) {
        guard let panel else { return }

        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)

        guard let textView = firstComposerTextView(in: panel.contentView) else {
            guard attempt < 8 else { return }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
                self.focusComposerTextInput(attempt: attempt + 1)
            }
            return
        }

        panel.makeFirstResponder(textView)
        textView.window?.makeFirstResponder(textView)
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
}

private final class PointerPromptPanel: NSPanel {
    var dragRegionProvider: (() -> [CGRect])?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown,
           dragRegionProvider?().contains(where: { $0.contains(event.locationInWindow) }) == true {
            performDrag(with: event)
            return
        }

        super.sendEvent(event)
    }
}

private extension PointerPromptActivationModifier {
    var eventModifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .command:
            .command
        }
    }
}
