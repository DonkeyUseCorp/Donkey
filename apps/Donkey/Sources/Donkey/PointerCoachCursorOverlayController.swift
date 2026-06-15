import AppKit
import DonkeyContracts
import DonkeyUI
import SwiftUI

@MainActor
final class PointerCoachCursorOverlayController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<PointerCoachCursorOverlayView>?
    private var viewModel: PointerCoachCursorOverlayViewModel?
    private var timer: Timer?
    private var dismissalWorkItem: DispatchWorkItem?
    private var screenFrame: CGRect = .zero

    func show(request: PointerCoachCursorGuideRequest) {
        close()

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        screenFrame = screen.frame
        let viewModel = PointerCoachCursorOverlayViewModel(
            request: request,
            screenSize: screenFrame.size
        )
        viewModel.start()
        let localFrame = viewModel.visualFrame
        viewModel.updateViewport(origin: localFrame.origin, size: localFrame.size)

        let hostingView = NSHostingView(rootView: PointerCoachCursorOverlayView(viewModel: viewModel))
        // The controller owns the panel frame; stop the hosting view from also bridging its content size
        // to the window, which re-enters layout mid display-cycle and crashes (see the spawn overlay).
        hostingView.sizingOptions = []
        hostingView.frame = CGRect(origin: .zero, size: localFrame.size)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = NSPanel(
            contentRect: panelFrame(for: localFrame, in: screenFrame),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Donkey Guide"
        panel.contentView = hostingView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.level = DonkeyOverlayWindowLevel.userQuery
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary
        ]
        panel.orderFrontRegardless()
        self.panel = panel
        self.hostingView = hostingView
        self.viewModel = viewModel
        startTimer()

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.close()
            }
        }
        dismissalWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration(for: request), execute: workItem)
    }

    func close() {
        timer?.invalidate()
        timer = nil
        dismissalWorkItem?.cancel()
        dismissalWorkItem = nil
        panel?.close()
        panel = nil
        hostingView = nil
        viewModel = nil
        screenFrame = .zero
    }

    private func duration(for request: PointerCoachCursorGuideRequest) -> TimeInterval {
        request.steps.reduce(0.6) { total, step in
            total + step.travelDuration + step.holdDuration
        }
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
        guard let panel,
              let hostingView,
              let viewModel else {
            return
        }

        viewModel.update(now: Date(), screenSize: screenFrame.size)
        let localFrame = viewModel.visualFrame
        viewModel.updateViewport(origin: localFrame.origin, size: localFrame.size)
        hostingView.frame = CGRect(origin: .zero, size: localFrame.size)
        panel.setFrame(panelFrame(for: localFrame, in: screenFrame), display: true)
    }

    private func panelFrame(
        for localFrame: CGRect,
        in screenFrame: CGRect
    ) -> CGRect {
        CGRect(
            x: screenFrame.minX + localFrame.minX,
            y: screenFrame.maxY - localFrame.maxY,
            width: localFrame.width,
            height: localFrame.height
        )
    }
}
