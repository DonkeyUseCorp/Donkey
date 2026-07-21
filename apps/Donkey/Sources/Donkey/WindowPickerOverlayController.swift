import AppKit
import Carbon.HIToolbox
import CoreGraphics
import ScreenCaptureKit

/// One selectable on-screen window, in CoreGraphics global coordinates (points, top-left origin) —
/// the space `SCWindow.frame` reports.
private struct PickWindowInfo {
    let windowID: CGWindowID
    let cgFrame: CGRect
}

/// The "record a window" picker. Dims every display, highlights the window under the cursor, and
/// selects it on click — the Cmd+Shift+5 window mode. Windows come from ScreenCaptureKit so the chosen
/// `windowID` matches what the recorder captures. Escape cancels.
@MainActor
final class WindowPickerOverlayController {
    var onSelect: ((CGWindowID) -> Void)?
    var onCancel: (() -> Void)?

    private var panels: [NSPanel] = []
    private var windows: [PickWindowInfo] = []
    /// Height of the primary display, the anchor for flipping between Cocoa (bottom-left) and
    /// CoreGraphics (top-left) global coordinates.
    private var primaryHeight: CGFloat = 0

    func begin() {
        close()
        Task { [weak self] in
            guard let self else { return }
            let windows = await Self.pickableWindows()
            self.presentOverlays(windows: windows)
        }
    }

    func close() {
        for panel in panels { panel.close() }
        panels.removeAll()
        windows = []
    }

    private func presentOverlays(windows: [PickWindowInfo]) {
        self.windows = windows
        primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first)?.frame.height ?? 0

        for screen in NSScreen.screens {
            let view = WindowPickerView()
            view.screenFrame = screen.frame
            view.primaryHeight = primaryHeight
            view.windowProvider = { [weak self] cgCursor in self?.window(atGlobalCGPoint: cgCursor) }
            view.onSelect = { [weak self] windowID in self?.onSelect?(windowID) }
            view.onCancel = { [weak self] in self?.onCancel?() }

            let panel = WindowPickerPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.escapeHandler = { [weak self] in self?.onCancel?() }
            panel.contentView = view
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.ignoresMouseEvents = false
            panel.acceptsMouseMovedEvents = true
            panel.level = DonkeyOverlayWindowLevel.regionSelection
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        NSApp.activate(ignoringOtherApps: true)
        panels.first?.makeKey()
    }

    /// The frontmost pickable window containing the cursor. ScreenCaptureKit returns windows
    /// front-to-back, so the first hit is the topmost.
    private func window(atGlobalCGPoint point: CGPoint) -> PickWindowInfo? {
        windows.first { $0.cgFrame.contains(point) }
    }

    private static func pickableWindows() async -> [PickWindowInfo] {
        // Only visible windows: ask ScreenCaptureKit for on-screen, non-desktop windows, then keep
        // normal app windows (layer 0) that aren't our own and are large enough to aim at.
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(
                  true,
                  onScreenWindowsOnly: true
              ) else {
            return []
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.compactMap { window in
            guard window.isOnScreen,
                  window.windowLayer == 0,
                  window.frame.width >= 40,
                  window.frame.height >= 40,
                  window.owningApplication?.processID != ownPID else {
                return nil
            }
            return PickWindowInfo(windowID: window.windowID, cgFrame: window.frame)
        }
    }
}

private final class WindowPickerPanel: NSPanel {
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

/// Dims one display and highlights the hovered window. The controller resolves the window under the
/// cursor from the shared window list; this view only converts coordinates and paints.
private final class WindowPickerView: NSView {
    var screenFrame: CGRect = .zero
    var primaryHeight: CGFloat = 0
    var windowProvider: ((CGPoint) -> PickWindowInfo?)?
    var onSelect: ((CGWindowID) -> Void)?
    var onCancel: (() -> Void)?

    private var highlightRect: CGRect?
    private var hoveredWindowID: CGWindowID?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover()
    }

    override func mouseDown(with event: NSEvent) {
        updateHover()
        if let hoveredWindowID {
            onSelect?(hoveredWindowID)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    private func updateHover() {
        let cursorCocoa = NSEvent.mouseLocation
        let cursorCG = CGPoint(x: cursorCocoa.x, y: primaryHeight - cursorCocoa.y)
        if let window = windowProvider?(cursorCG) {
            hoveredWindowID = window.windowID
            highlightRect = localRect(forGlobalCG: window.cgFrame)
        } else {
            hoveredWindowID = nil
            highlightRect = nil
        }
        needsDisplay = true
    }

    /// CG global (top-left) rect → this view's local coords (bottom-left), via Cocoa global.
    private func localRect(forGlobalCG cgFrame: CGRect) -> CGRect {
        let cocoaGlobalY = primaryHeight - cgFrame.maxY
        return CGRect(
            x: cgFrame.minX - screenFrame.minX,
            y: cocoaGlobalY - screenFrame.minY,
            width: cgFrame.width,
            height: cgFrame.height
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard let highlightRect else { return }
        let clipped = highlightRect.intersection(bounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return }

        NSColor.clear.set()
        clipped.fill(using: .copy)
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: clipped.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()
    }
}
