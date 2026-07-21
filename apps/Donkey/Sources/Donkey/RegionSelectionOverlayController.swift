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
/// drags a rectangle on one of them, then resizes or repositions it in place before recording. The
/// controller reports the current rect in display-local, top-left points — the coordinate space
/// `SCStreamConfiguration.sourceRect` expects — after every edit. Escape cancels. v1 keeps a
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

/// The dim that stays up while a region is recording. It darkens the display and cuts the recorded rect
/// back to full brightness so the user can see exactly what is being captured. Mouse events pass through
/// (the user keeps working), and the panel is handed to the recorder as an excluded window via its
/// `windowNumber`, so the dim itself never lands in the recording. Region mode only.
@MainActor
final class RecordingRegionDimOverlayController {
    private var panel: NSPanel?

    /// The overlay window's number, for `SCStreamConfiguration` capture exclusion. `nil` while hidden.
    var windowNumber: Int? { panel?.windowNumber }

    /// Show the dim over `displayID`, leaving `region` (display-local, top-left points) clear.
    func show(region: CGRect, displayID: CGDirectDisplayID) {
        close()
        guard let screen = NSScreen.screens.first(where: { $0.donkeyDisplayID == displayID }) else { return }
        let view = RecordingRegionDimView()
        // Flip the top-left region back into the view's bottom-left space.
        view.hole = CGRect(
            x: region.minX,
            y: screen.frame.height - region.maxY,
            width: region.width,
            height: region.height
        )

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = view
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.level = DonkeyOverlayWindowLevel.regionSelection
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

/// Dims its display and cuts the recorded region clear, with a thin frame so the boundary reads.
private final class RecordingRegionDimView: NSView {
    var hole: CGRect = .zero { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard hole.width > 0, hole.height > 0 else { return }
        NSColor.clear.set()
        hole.fill(using: .copy)
        NSColor.white.withAlphaComponent(0.5).setStroke()
        let framePath = NSBezierPath(rect: hole.insetBy(dx: 0.5, dy: 0.5))
        framePath.lineWidth = 1
        framePath.stroke()
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

/// Dims its display and tracks the selection rectangle: the first drag rubber-bands a new box, then the
/// box stays live so it can be resized from any of eight grips or dragged bodily. Paints the clear
/// cut-out, a dashed marquee, corner/edge handles, and a live pixel readout. Reports the current rect
/// (view coords, bottom-left) after every edit so the controller's Record button always reflects it.
private final class RegionSelectionView: NSView {
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    /// The eight resize grips: four corners and four edge midpoints.
    private enum Grip: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    /// What the current mouse-down is doing.
    private enum DragKind {
        case none
        case creating(anchor: CGPoint)
        case moving(original: CGRect, start: CGPoint)
        case resizing(grip: Grip, original: CGRect)
    }

    private var selection: CGRect?
    private var drag: DragKind = .none

    private let minSize: CGFloat = 16
    private let handleSize: CGFloat = 9      // drawn edge length of a grip
    private let handleHitInset: CGFloat = 11 // half the square hit-target around a grip

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let selection {
            if let grip = grip(at: point, in: selection) {
                drag = .resizing(grip: grip, original: selection)
                return
            }
            if selection.contains(point) {
                drag = .moving(original: selection, start: point)
                return
            }
        }
        // Empty space: start a fresh box.
        drag = .creating(anchor: point)
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none:
            return
        case .creating(let anchor):
            selection = CGRect(
                x: min(anchor.x, point.x),
                y: min(anchor.y, point.y),
                width: abs(point.x - anchor.x),
                height: abs(point.y - anchor.y)
            ).intersection(bounds)
        case .moving(let original, let start):
            selection = moved(original, by: CGPoint(x: point.x - start.x, y: point.y - start.y))
        case .resizing(let grip, let original):
            selection = resized(original, grip: grip, to: point)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = .none }
        guard let selection, selection.width >= minSize, selection.height >= minSize else {
            self.selection = nil
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            return
        }
        onComplete?(selection)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Geometry

    private func gripCenters(in rect: CGRect) -> [Grip: CGPoint] {
        [
            .topLeft: CGPoint(x: rect.minX, y: rect.maxY),
            .top: CGPoint(x: rect.midX, y: rect.maxY),
            .topRight: CGPoint(x: rect.maxX, y: rect.maxY),
            .right: CGPoint(x: rect.maxX, y: rect.midY),
            .bottomRight: CGPoint(x: rect.maxX, y: rect.minY),
            .bottom: CGPoint(x: rect.midX, y: rect.minY),
            .bottomLeft: CGPoint(x: rect.minX, y: rect.minY),
            .left: CGPoint(x: rect.minX, y: rect.midY)
        ]
    }

    private func grip(at point: CGPoint, in rect: CGRect) -> Grip? {
        for (grip, center) in gripCenters(in: rect) {
            let hit = CGRect(
                x: center.x - handleHitInset,
                y: center.y - handleHitInset,
                width: handleHitInset * 2,
                height: handleHitInset * 2
            )
            if hit.contains(point) { return grip }
        }
        return nil
    }

    /// Translate the box, clamped so it stays fully on the display.
    private func moved(_ rect: CGRect, by delta: CGPoint) -> CGRect {
        var origin = CGPoint(x: rect.minX + delta.x, y: rect.minY + delta.y)
        origin.x = max(0, min(origin.x, bounds.width - rect.width))
        origin.y = max(0, min(origin.y, bounds.height - rect.height))
        return CGRect(origin: origin, size: rect.size)
    }

    /// Move the grip's edge(s) to the mouse, clamped to the display and never past the minimum size.
    private func resized(_ rect: CGRect, grip: Grip, to point: CGPoint) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX
        var minY = rect.minY, maxY = rect.maxY
        let movesLeft = grip == .topLeft || grip == .left || grip == .bottomLeft
        let movesRight = grip == .topRight || grip == .right || grip == .bottomRight
        let movesTop = grip == .topLeft || grip == .top || grip == .topRight
        let movesBottom = grip == .bottomLeft || grip == .bottom || grip == .bottomRight
        if movesLeft { minX = max(0, min(point.x, maxX - minSize)) }
        if movesRight { maxX = min(bounds.width, max(point.x, minX + minSize)) }
        if movesBottom { minY = max(0, min(point.y, maxY - minSize)) }
        if movesTop { maxY = min(bounds.height, max(point.y, minY + minSize)) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Cursors

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair) // empty space draws a new box
        guard let selection else { return }
        addCursorRect(selection, cursor: .openHand) // body moves the box
        for (grip, center) in gripCenters(in: selection) {
            let rect = CGRect(
                x: center.x - handleHitInset,
                y: center.y - handleHitInset,
                width: handleHitInset * 2,
                height: handleHitInset * 2
            )
            addCursorRect(rect, cursor: cursor(for: grip))
        }
    }

    private func cursor(for grip: Grip) -> NSCursor {
        switch grip {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return .crosshair
        }
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard let selection, selection.width > 0, selection.height > 0 else { return }

        // Punch the selection back out of the dim, then frame it with a dashed marquee.
        NSColor.clear.set()
        selection.fill(using: .copy)
        let framePath = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        framePath.lineWidth = 1
        framePath.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.95).setStroke()
        framePath.stroke()

        drawHandles(for: selection)
        drawReadout(for: selection)
    }

    private func drawHandles(for rect: CGRect) {
        for center in gripCenters(in: rect).values {
            let box = CGRect(
                x: center.x - handleSize / 2,
                y: center.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            let path = NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            path.fill()
            NSColor.black.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
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
