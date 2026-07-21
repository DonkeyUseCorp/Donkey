import AppKit
import Carbon.HIToolbox
import CoreGraphics

extension NSScreen {
    /// The CoreGraphics display ID backing this screen, for matching against `SCDisplay`/`SCStream`.
    var donkeyDisplayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

/// The drag-to-select region picker. Puts a dimmed, key-capable panel over every display; the user
/// drags a rectangle on one of them and the controller reports it in display-local, top-left points —
/// the coordinate space `SCStreamConfiguration.sourceRect` expects. Escape cancels. v1 keeps a
/// selection within the single display it started on.
@MainActor
final class RegionSelectionOverlayController {
    /// `(region in display-local top-left points, the display it belongs to)`.
    var onSelect: ((CGRect, CGDirectDisplayID) -> Void)?
    var onCancel: (() -> Void)?

    private var panels: [NSPanel] = []

    func begin() {
        close()
        for screen in NSScreen.screens {
            guard let displayID = screen.donkeyDisplayID else { continue }
            let view = RegionSelectionView()
            view.onComplete = { [weak self] rectInView in
                self?.handleComplete(rectInView: rectInView, screenHeight: screen.frame.height, displayID: displayID)
            }
            view.onCancel = { [weak self] in self?.handleCancel() }

            let panel = RegionSelectionPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.escapeHandler = { [weak self] in self?.handleCancel() }
            panel.contentView = view
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.ignoresMouseEvents = false
            panel.level = DonkeyOverlayWindowLevel.regionSelection
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        // Become active so the picker receives mouse + Escape even when another app was frontmost.
        NSApp.activate(ignoringOtherApps: true)
        panels.first?.makeKey()
    }

    func close() {
        for panel in panels { panel.close() }
        panels.removeAll()
    }

    private func handleComplete(rectInView: CGRect, screenHeight: CGFloat, displayID: CGDirectDisplayID) {
        // View coords are bottom-left; flip to display-local top-left for SCStreamConfiguration.sourceRect.
        let region = CGRect(
            x: rectInView.minX,
            y: screenHeight - rectInView.maxY,
            width: rectInView.width,
            height: rectInView.height
        )
        onSelect?(region, displayID)
    }

    private func handleCancel() {
        onCancel?()
    }
}

/// A borderless panel that can become key (so it receives `keyDown`) and routes Escape to a handler,
/// mirroring the `UserQueryPanel` pattern used elsewhere.
private final class RegionSelectionPanel: NSPanel {
    var escapeHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape) {
            escapeHandler?()
            return
        }
        super.sendEvent(event)
    }
}

/// Dims its display and tracks a single drag into a selection rectangle, painting the clear cut-out,
/// a 1px frame, and a live pixel readout. Reports the rect (view coords, bottom-left) on mouse-up.
private final class RegionSelectionView: NSView {
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var anchor: CGPoint?
    private var selection: CGRect?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let current = convert(event.locationInWindow, from: nil)
        selection = CGRect(
            x: min(anchor.x, current.x),
            y: min(anchor.y, current.y),
            width: abs(current.x - anchor.x),
            height: abs(current.y - anchor.y)
        ).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { anchor = nil }
        guard let selection, selection.width >= 16, selection.height >= 16 else {
            self.selection = nil
            needsDisplay = true
            return
        }
        onComplete?(selection)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard let selection, selection.width > 0, selection.height > 0 else { return }

        // Punch the selection back out of the dim, then frame it.
        NSColor.clear.set()
        selection.fill(using: .copy)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let framePath = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        framePath.lineWidth = 1
        framePath.stroke()

        drawReadout(for: selection)
    }

    private func drawReadout(for rect: CGRect) {
        let scale = window?.backingScaleFactor ?? 2
        let widthPx = Int((rect.width * scale).rounded())
        let heightPx = Int((rect.height * scale).rounded())
        let text = "\(widthPx) × \(heightPx)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 6
        let boxWidth = size.width + padding * 2
        let boxHeight = size.height + padding
        var boxX = rect.midX - boxWidth / 2
        var boxY = rect.minY - boxHeight - 6
        boxX = max(4, min(boxX, bounds.width - boxWidth - 4))
        if boxY < 4 { boxY = rect.maxY + 6 }
        let box = CGRect(x: boxX, y: boxY, width: boxWidth, height: boxHeight)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(
            at: CGPoint(x: box.minX + padding, y: box.minY + padding / 2),
            withAttributes: attributes
        )
    }
}
