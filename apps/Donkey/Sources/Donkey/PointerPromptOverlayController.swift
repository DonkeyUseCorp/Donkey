import AppKit
import DonkeyContracts
import SwiftUI

@MainActor
final class PointerPromptOverlayController {
    static let contentSize = PointerPromptLayout.contentSize

    private let model: PointerPromptOverlayModel
    private let fixedPlacement: PointerPromptPlacement = .bottomRight

    private var panel: NSPanel?
    private var timer: Timer?
    private var globalCommandClickMonitor: Any?
    private var localCommandClickMonitor: Any?

    init(model: PointerPromptOverlayModel) {
        self.model = model
    }

    func show() {
        let rootView = PointerPromptOverlayRootView(model: model)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = CGRect(origin: .zero, size: Self.contentSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = PointerPromptPanel(
            contentRect: CGRect(origin: .zero, size: Self.contentSize),
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
        startCommandClickMonitoring()
        positionAtCurrentMouseLocation()
        panel.orderFrontRegardless()
        startTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stopCommandClickMonitoring()
        panel?.close()
        panel = nil
    }

    private func startCommandClickMonitoring() {
        stopCommandClickMonitoring()

        globalCommandClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard event.modifierFlags.contains(.command) else { return }

            Task { @MainActor in
                self?.activateAtCurrentMouseLocation()
            }
        }

        localCommandClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            if event.modifierFlags.contains(.command) {
                Task { @MainActor in
                    self?.activateAtCurrentMouseLocation()
                }
            }

            return event
        }
    }

    private func stopCommandClickMonitoring() {
        if let globalCommandClickMonitor {
            NSEvent.removeMonitor(globalCommandClickMonitor)
            self.globalCommandClickMonitor = nil
        }

        if let localCommandClickMonitor {
            NSEvent.removeMonitor(localCommandClickMonitor)
            self.localCommandClickMonitor = nil
        }
    }

    private func activateAtCurrentMouseLocation() {
        activate(at: NSEvent.mouseLocation)
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

        updateMouseEventPassthrough(for: panel)
        if model.promptState.isActive, explicitMouseLocation == nil {
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
        let size = Self.contentSize
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
                PointerPromptLayout.composerSize.width +
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
            y: Self.contentSize.height - pointerTipYFromTop
        )
    }

    private func pointerVisualInsetX(for placement: PointerPromptPlacement) -> CGFloat {
        placement.placesContentOnLeft ? 0 :
            PointerPromptLayout.pointerSlotSize.width - PointerPromptLayout.pointerVisualSize.width
    }

    private var stageHorizontalInset: CGFloat {
        (Self.contentSize.width - stageContentWidth) / 2
    }

    private var stageVerticalInset: CGFloat {
        (Self.contentSize.height - stageContentHeight) / 2
    }

    private var stageContentWidth: CGFloat {
        PointerPromptLayout.stageHorizontalPadding * 2 +
            PointerPromptLayout.pointerSlotSize.width +
            PointerPromptLayout.pointerComposerSpacing +
            PointerPromptLayout.composerSize.width
    }

    private var stageContentHeight: CGFloat {
        PointerPromptLayout.stageVerticalPadding * 2 +
            PointerPromptLayout.composerSize.height
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
        let dragThickness = PointerPromptLayout.composerDragBorderThickness
        let closeButtonClearance = PointerPromptLayout.closeButtonInset * 2 +
            PointerPromptLayout.closeButtonSize

        return [
            CGRect(
                x: composerFrame.minX + closeButtonClearance,
                y: composerFrame.maxY - dragThickness,
                width: composerFrame.width - closeButtonClearance,
                height: dragThickness
            ),
            CGRect(
                x: composerFrame.minX,
                y: composerFrame.minY,
                width: composerFrame.width,
                height: dragThickness
            ),
            CGRect(
                x: composerFrame.minX,
                y: composerFrame.minY + dragThickness,
                width: dragThickness,
                height: composerFrame.height - dragThickness - closeButtonClearance
            ),
            CGRect(
                x: composerFrame.maxX - dragThickness,
                y: composerFrame.minY + dragThickness,
                width: dragThickness,
                height: composerFrame.height - dragThickness * 2
            )
        ]
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
            y: Self.contentSize.height - composerTopFromPanelTop - PointerPromptLayout.composerSize.height,
            width: PointerPromptLayout.composerSize.width,
            height: PointerPromptLayout.composerSize.height
        )
    }

    private var composerTopFromPanelTop: CGFloat {
        stageVerticalInset + PointerPromptLayout.stageVerticalPadding
    }

    private func updateMouseEventPassthrough(for panel: NSPanel) {
        guard model.promptState.isActive else {
            panel.ignoresMouseEvents = true
            return
        }

        let mouseLocationInPanel = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        panel.ignoresMouseEvents = !composerFrame(for: fixedPlacement).contains(mouseLocationInPanel)
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
