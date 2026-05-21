import AppKit
import DonkeyContracts
import DonkeyUI
import SwiftUI

@MainActor
final class PointerCoachCursorOverlayController {
    private var panel: NSPanel?
    private var dismissalWorkItem: DispatchWorkItem?

    func show(request: PointerCoachCursorGuideRequest) {
        close()

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let hostingView = NSHostingView(rootView: PointerCoachCursorOverlayView(request: request))
        hostingView.frame = CGRect(origin: .zero, size: screen.frame.size)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = NSPanel(
            contentRect: screen.frame,
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
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary
        ]
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.close()
            }
        }
        dismissalWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration(for: request), execute: workItem)
    }

    func close() {
        dismissalWorkItem?.cancel()
        dismissalWorkItem = nil
        panel?.close()
        panel = nil
    }

    private func duration(for request: PointerCoachCursorGuideRequest) -> TimeInterval {
        request.steps.reduce(0.6) { total, step in
            total + step.travelDuration + step.holdDuration
        }
    }
}
