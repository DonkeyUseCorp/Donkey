import AppKit
import DonkeyContracts
import DonkeyRuntime
import QuartzCore

@MainActor
final class DebugUIInspectionOverlayController {
    private var surfaces: [UInt32: DebugUIInspectionSurface] = [:]

    func render(
        frame: DebugUIInspectionFrame,
        snapshot: DebugUIScreenCaptureSnapshot
    ) {
        let surface = surfaces[snapshot.screenID] ?? makeSurface(for: snapshot)
        surfaces[snapshot.screenID] = surface
        surface.render(frame: frame, snapshot: snapshot)
    }

    func closeScreens(except activeScreenIDs: Set<UInt32>) {
        for (screenID, surface) in surfaces where !activeScreenIDs.contains(screenID) {
            surface.close()
            surfaces.removeValue(forKey: screenID)
        }
    }

    func setHidden(_ hidden: Bool) {
        for surface in surfaces.values {
            surface.setHidden(hidden)
        }
    }

    func close() {
        for surface in surfaces.values {
            surface.close()
        }
        surfaces.removeAll()
    }

    private func makeSurface(
        for snapshot: DebugUIScreenCaptureSnapshot
    ) -> DebugUIInspectionSurface {
        let frame = CGRect(
            x: snapshot.screenFrame.origin.x,
            y: snapshot.screenFrame.origin.y,
            width: snapshot.screenFrame.size.width,
            height: snapshot.screenFrame.size.height
        )
        let rootView = DebugUIInspectionRootView(frame: CGRect(origin: .zero, size: frame.size))
        rootView.wantsLayer = true
        rootView.layer = CALayer()
        rootView.layer?.frame = rootView.bounds
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.layer?.isGeometryFlipped = true

        let panel = DebugUIInspectionPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Donkey Debug UI Inspection"
        panel.contentView = rootView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.level = DonkeyOverlayWindowLevel.debugInspection
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .stationary
        ]
        panel.sharingType = .readOnly
        panel.orderFrontRegardless()

        return DebugUIInspectionSurface(panel: panel, rootView: rootView)
    }
}

@MainActor
private final class DebugUIInspectionSurface {
    private let panel: NSPanel
    private let rootView: NSView
    private var elementLayers: [String: DebugUIInspectionElementLayers] = [:]

    init(panel: NSPanel, rootView: NSView) {
        self.panel = panel
        self.rootView = rootView
    }

    func render(
        frame: DebugUIInspectionFrame,
        snapshot: DebugUIScreenCaptureSnapshot
    ) {
        let panelFrame = CGRect(
            x: snapshot.screenFrame.origin.x,
            y: snapshot.screenFrame.origin.y,
            width: snapshot.screenFrame.size.width,
            height: snapshot.screenFrame.size.height
        )
        if panel.frame != panelFrame {
            panel.setFrame(panelFrame, display: true)
            rootView.frame = CGRect(origin: .zero, size: panelFrame.size)
            rootView.layer?.frame = rootView.bounds
        }

        let activeIDs = Set(frame.elements.map(\.id))
        for (id, layers) in elementLayers where !activeIDs.contains(id) {
            fadeOutAndRemove(layers)
            elementLayers.removeValue(forKey: id)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for element in frame.elements {
            let layers = elementLayers[element.id] ?? makeLayers(for: element)
            elementLayers[element.id] = layers
            update(layers: layers, element: element, snapshot: snapshot)
        }
        CATransaction.commit()

        panel.orderFrontRegardless()
    }

    func close() {
        panel.close()
        elementLayers.removeAll()
    }

    func setHidden(_ hidden: Bool) {
        if hidden {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func makeLayers(for element: DebugUIElement) -> DebugUIInspectionElementLayers {
        let boxLayer = CAShapeLayer()
        boxLayer.name = "debug-ui-box-\(element.id)"
        boxLayer.fillColor = fillColor(for: element)
        boxLayer.strokeColor = strokeColor(for: element)
        boxLayer.lineWidth = 2
        boxLayer.opacity = 0

        let textLayer = CATextLayer()
        textLayer.name = "debug-ui-label-\(element.id)"
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        textLayer.alignmentMode = .left
        textLayer.fontSize = 11
        textLayer.truncationMode = .end
        textLayer.isWrapped = false
        textLayer.opacity = 0

        rootView.layer?.addSublayer(boxLayer)
        rootView.layer?.addSublayer(textLayer)

        let layers = DebugUIInspectionElementLayers(box: boxLayer, label: textLayer)
        fadeIn(layers)
        return layers
    }

    private func update(
        layers: DebugUIInspectionElementLayers,
        element: DebugUIElement,
        snapshot: DebugUIScreenCaptureSnapshot
    ) {
        let screenPointSize = HotLoopSize(
            width: snapshot.screenFrame.size.width,
            height: snapshot.screenFrame.size.height,
            space: .screen
        )
        let boxFrame = DebugUIOverlayGeometry.localLayerFrame(
            for: element.bbox,
            screenshotPixelSize: snapshot.pixelSize,
            screenPointSize: screenPointSize
        ).integral
        let path = CGPath(rect: CGRect(origin: .zero, size: boxFrame.size), transform: nil)
        layers.box.frame = boxFrame
        layers.box.path = path
        layers.box.fillColor = fillColor(for: element)
        layers.box.strokeColor = strokeColor(for: element)
        layers.box.lineDashPattern = lineDashPattern(for: element)
        layers.box.lineWidth = lineWidth(for: element)

        let title = labelText(for: element)
        let labelFrame = DebugUIOverlayGeometry.stableLabelFrame(
            for: title,
            boxFrame: boxFrame,
            containerSize: rootView.bounds.size
        )
        layers.label.string = title
        layers.label.foregroundColor = nsColor(hex: element.visualStyle.labelColor, alpha: 1).cgColor
        layers.label.backgroundColor = labelBackgroundColor(for: element)
        layers.label.frame = labelFrame
    }

    private func labelText(for element: DebugUIElement) -> String {
        let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = label.isEmpty
            ? element.type.rawValue.replacingOccurrences(of: "_", with: " ")
            : label
        if let badge = sourceBadge(for: element) {
            return "\(badge) \(base)"
        }
        return base
    }

    private func fillColor(for element: DebugUIElement) -> CGColor {
        if element.id.hasPrefix("window-") {
            return NSColor.clear.cgColor
        }
        if sourceKind(for: element) == .ai {
            return nsColor(hex: "#FF2D55", alpha: 0.16).cgColor
        }
        if sourceKind(for: element) == .nativeVisual {
            return nsColor(hex: "#00C7BE", alpha: 0.13).cgColor
        }
        return nsColor(hex: element.visualStyle.overlayColor, alpha: 0.14).cgColor
    }

    private func strokeColor(for element: DebugUIElement) -> CGColor {
        switch sourceKind(for: element) {
        case .ai:
            return nsColor(hex: "#FF2D55", alpha: 0.98).cgColor
        case .nativeVisual:
            return nsColor(hex: "#00C7BE", alpha: 0.95).cgColor
        case .accessibility:
            return nsColor(hex: "#34D399", alpha: 0.95).cgColor
        case .other:
            return nsColor(hex: element.visualStyle.borderColor, alpha: 0.95).cgColor
        }
    }

    private func labelBackgroundColor(for element: DebugUIElement) -> CGColor {
        switch sourceKind(for: element) {
        case .ai:
            return nsColor(hex: "#FF2D55", alpha: 0.94).cgColor
        case .nativeVisual:
            return nsColor(hex: "#00C7BE", alpha: 0.92).cgColor
        case .accessibility:
            return nsColor(hex: "#34D399", alpha: 0.92).cgColor
        case .other:
            return nsColor(hex: element.visualStyle.overlayColor, alpha: 0.92).cgColor
        }
    }

    private func lineDashPattern(for element: DebugUIElement) -> [NSNumber]? {
        sourceKind(for: element) == .ai ? [6, 4] : nil
    }

    private func lineWidth(for element: DebugUIElement) -> CGFloat {
        sourceKind(for: element) == .ai ? 2.5 : 2
    }

    private func sourceBadge(for element: DebugUIElement) -> String? {
        switch sourceKind(for: element) {
        case .ai:
            return "AI"
        case .nativeVisual:
            return "CV"
        case .accessibility:
            return "AX"
        case .other:
            return nil
        }
    }

    private func sourceKind(for element: DebugUIElement) -> DebugUIInspectionSourceKind {
        let fusionSource = element.metadata["debugUIFusion.source"] ?? ""
        let sources = element.metadata["localUIElement.sources"] ?? ""
        if fusionSource == "gemini" || sources.contains("gemini") || element.id.hasPrefix("gemini-") {
            return .ai
        }
        if fusionSource == "native-visual" || sources.contains("shape") || sources.contains("ocr") || sources.contains("layout") || element.id.hasPrefix("native-visual-") {
            return .nativeVisual
        }
        if sources.contains("accessibility") || element.id.hasPrefix("ax-") || sources.contains("window-chrome-geometry") {
            return .accessibility
        }
        return .other
    }

    private func fadeIn(_ layers: DebugUIInspectionElementLayers) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = 0.16
        layers.box.opacity = 1
        layers.label.opacity = 1
        layers.box.add(animation, forKey: "fade-in")
        layers.label.add(animation, forKey: "fade-in")
    }

    private func fadeOutAndRemove(_ layers: DebugUIInspectionElementLayers) {
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            layers.box.removeFromSuperlayer()
            layers.label.removeFromSuperlayer()
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = layers.box.opacity
        animation.toValue = 0
        animation.duration = 0.14
        layers.box.opacity = 0
        layers.label.opacity = 0
        layers.box.add(animation, forKey: "fade-out")
        layers.label.add(animation, forKey: "fade-out")
        CATransaction.commit()
    }

    private func nsColor(hex: String, alpha: CGFloat) -> NSColor {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6,
              let value = UInt32(trimmed, radix: 16) else {
            return NSColor.white.withAlphaComponent(alpha)
        }

        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        return NSColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

private struct DebugUIInspectionElementLayers {
    var box: CAShapeLayer
    var label: CATextLayer
}

private enum DebugUIInspectionSourceKind {
    case accessibility
    case nativeVisual
    case ai
    case other
}

private final class DebugUIInspectionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class DebugUIInspectionRootView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
