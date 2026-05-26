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
        CATransaction.setAnimationDuration(0.18)
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

    private func makeLayers(for element: DebugUIElement) -> DebugUIInspectionElementLayers {
        let boxLayer = CAShapeLayer()
        boxLayer.name = "debug-ui-box-\(element.id)"
        boxLayer.fillColor = fillColor(for: element)
        boxLayer.strokeColor = nsColor(hex: element.visualStyle.borderColor, alpha: 0.95).cgColor
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
        layers.box.strokeColor = nsColor(hex: element.visualStyle.borderColor, alpha: 0.95).cgColor

        let title = labelText(for: element)
        let labelSize = labelFrameSize(for: title, boxFrame: boxFrame)
        let labelY = max(0, boxFrame.minY - labelSize.height - 2)
        layers.label.string = title
        layers.label.foregroundColor = nsColor(hex: element.visualStyle.labelColor, alpha: 1).cgColor
        layers.label.backgroundColor = nsColor(hex: element.visualStyle.overlayColor, alpha: 0.92).cgColor
        layers.label.frame = CGRect(
            x: max(0, min(boxFrame.minX, rootView.bounds.width - labelSize.width)),
            y: labelY,
            width: labelSize.width,
            height: labelSize.height
        ).integral
    }

    private func labelText(for element: DebugUIElement) -> String {
        let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty {
            return label
        }
        return element.type.rawValue.replacingOccurrences(of: "_", with: " ")
    }

    private func labelFrameSize(for text: String, boxFrame: CGRect) -> CGSize {
        let characterWidth = 6.5
        let width = min(
            max(48, Double(text.count) * characterWidth + 14),
            max(64, Double(rootView.bounds.width - max(0, boxFrame.minX)))
        )
        return CGSize(width: width, height: 18)
    }

    private func fillColor(for element: DebugUIElement) -> CGColor {
        if element.id.hasPrefix("window-") {
            return NSColor.clear.cgColor
        }
        return nsColor(hex: element.visualStyle.overlayColor, alpha: 0.14).cgColor
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

private final class DebugUIInspectionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class DebugUIInspectionRootView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
