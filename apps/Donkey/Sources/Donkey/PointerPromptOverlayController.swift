import AppKit
import DonkeyContracts
import SwiftUI

@MainActor
final class PointerPromptOverlayController {
    static let contentSize = CGSize(width: 448, height: 166)

    private let model: PointerPromptOverlayModel
    private let pointerGap: CGFloat = 18
    private let screenPadding: CGFloat = 8
    private let routeStepInterval: TimeInterval = 0.15
    private let followSmoothing: CGFloat = 0.34
    private let flipSmoothing: CGFloat = 0.22

    private var panel: NSPanel?
    private var timer: Timer?
    private var globalCommandClickMonitor: Any?
    private var localCommandClickMonitor: Any?
    private var currentFrame: CGRect?
    private var displayPlacement: PointerPromptPlacement = .bottomRight
    private var finalPlacement: PointerPromptPlacement = .bottomRight
    private var pendingPlacements: [PointerPromptPlacement] = []
    private var lastRouteStepAt = Date.distantPast

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
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary
        ]

        self.panel = panel
        panel.orderOut(nil)
        startCommandClickMonitoring()
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

    private func activate(at mouseLocation: CGPoint) {
        guard let panel else { return }

        model.activate()
        currentFrame = nil
        displayPlacement = .bottomRight
        finalPlacement = .bottomRight
        pendingPlacements = []
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
        guard model.promptState.isActive else { return }

        let mouseLocation = explicitMouseLocation ?? NSEvent.mouseLocation
        guard let screen = screen(containing: mouseLocation) else { return }

        let now = Date()
        let targetPlacement = preferredPlacement(
            for: mouseLocation,
            visibleFrame: screen.visibleFrame
        )
        updateRoute(to: targetPlacement, now: now)
        advanceRoute(now: now)

        let targetFrame = clampedFrame(
            frame(for: displayPlacement, mouseLocation: mouseLocation),
            in: screen.visibleFrame
        )
        let nextFrame = smoothedFrame(toward: targetFrame, in: screen.visibleFrame)
        currentFrame = nextFrame
        panel.setFrame(nextFrame, display: true)

        if model.placement != displayPlacement {
            model.placement = displayPlacement
        }
    }

    private func updateRoute(to targetPlacement: PointerPromptPlacement, now: Date) {
        guard targetPlacement != finalPlacement else { return }

        finalPlacement = targetPlacement
        pendingPlacements = route(from: displayPlacement, to: targetPlacement)
        lastRouteStepAt = now.addingTimeInterval(-routeStepInterval)
    }

    private func advanceRoute(now: Date) {
        guard !pendingPlacements.isEmpty else { return }
        guard now.timeIntervalSince(lastRouteStepAt) >= routeStepInterval else { return }

        displayPlacement = pendingPlacements.removeFirst()
        lastRouteStepAt = now
    }

    private func route(
        from currentPlacement: PointerPromptPlacement,
        to targetPlacement: PointerPromptPlacement
    ) -> [PointerPromptPlacement] {
        guard currentPlacement != targetPlacement else { return [] }

        if currentPlacement.placesContentOnLeft != targetPlacement.placesContentOnLeft,
           currentPlacement.placesContentAbovePointer != targetPlacement.placesContentAbovePointer {
            let horizontalFirst = placement(
                left: targetPlacement.placesContentOnLeft,
                above: currentPlacement.placesContentAbovePointer
            )
            return [horizontalFirst, targetPlacement]
        }

        return [targetPlacement]
    }

    private func preferredPlacement(
        for mouseLocation: CGPoint,
        visibleFrame: CGRect
    ) -> PointerPromptPlacement {
        let preferredFrame = frame(for: .bottomRight, mouseLocation: mouseLocation)
        let overflowsRight = preferredFrame.maxX > visibleFrame.maxX - screenPadding
        let overflowsBottom = preferredFrame.minY < visibleFrame.minY + screenPadding

        let preferredPlacement = placement(left: overflowsRight, above: overflowsBottom)
        let candidates = [
            preferredPlacement,
            PointerPromptPlacement.bottomRight,
            .bottomLeft,
            .topRight,
            .topLeft
        ]

        for candidate in candidates where fits(
            frame(for: candidate, mouseLocation: mouseLocation),
            in: visibleFrame
        ) {
            return candidate
        }

        return preferredPlacement
    }

    private func placement(left: Bool, above: Bool) -> PointerPromptPlacement {
        switch (left, above) {
        case (false, false):
            .bottomRight
        case (true, false):
            .bottomLeft
        case (true, true):
            .topLeft
        case (false, true):
            .topRight
        }
    }

    private func frame(
        for placement: PointerPromptPlacement,
        mouseLocation: CGPoint
    ) -> CGRect {
        let size = Self.contentSize

        switch placement {
        case .bottomRight:
            return CGRect(
                x: mouseLocation.x + pointerGap,
                y: mouseLocation.y - size.height - pointerGap,
                width: size.width,
                height: size.height
            )
        case .bottomLeft:
            return CGRect(
                x: mouseLocation.x - size.width - pointerGap,
                y: mouseLocation.y - size.height - pointerGap,
                width: size.width,
                height: size.height
            )
        case .topLeft:
            return CGRect(
                x: mouseLocation.x - size.width - pointerGap,
                y: mouseLocation.y + pointerGap,
                width: size.width,
                height: size.height
            )
        case .topRight:
            return CGRect(
                x: mouseLocation.x + pointerGap,
                y: mouseLocation.y + pointerGap,
                width: size.width,
                height: size.height
            )
        }
    }

    private func fits(_ frame: CGRect, in visibleFrame: CGRect) -> Bool {
        frame.minX >= visibleFrame.minX + screenPadding &&
            frame.maxX <= visibleFrame.maxX - screenPadding &&
            frame.minY >= visibleFrame.minY + screenPadding &&
            frame.maxY <= visibleFrame.maxY - screenPadding
    }

    private func clampedFrame(_ frame: CGRect, in visibleFrame: CGRect) -> CGRect {
        var origin = frame.origin
        let size = frame.size

        let minX = visibleFrame.minX + screenPadding
        let maxX = visibleFrame.maxX - size.width - screenPadding
        let minY = visibleFrame.minY + screenPadding
        let maxY = visibleFrame.maxY - size.height - screenPadding

        if minX <= maxX {
            origin.x = min(max(origin.x, minX), maxX)
        } else {
            origin.x = visibleFrame.midX - size.width / 2
        }

        if minY <= maxY {
            origin.y = min(max(origin.y, minY), maxY)
        } else {
            origin.y = visibleFrame.midY - size.height / 2
        }

        return CGRect(origin: origin, size: size)
    }

    private func smoothedFrame(toward targetFrame: CGRect, in visibleFrame: CGRect) -> CGRect {
        guard let currentFrame else { return targetFrame }

        let smoothing = pendingPlacements.isEmpty ? followSmoothing : flipSmoothing
        let origin = CGPoint(
            x: currentFrame.origin.x + (targetFrame.origin.x - currentFrame.origin.x) * smoothing,
            y: currentFrame.origin.y + (targetFrame.origin.y - currentFrame.origin.y) * smoothing
        )
        return clampedFrame(CGRect(origin: origin, size: targetFrame.size), in: visibleFrame)
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            screen.frame.contains(point)
        } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

private final class PointerPromptPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}
