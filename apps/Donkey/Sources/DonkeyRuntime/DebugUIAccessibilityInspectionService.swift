@preconcurrency import AppKit
import CoreGraphics
import CryptoKit
import DonkeyContracts
import Foundation

public struct DebugUIAccessibilityInspectionResult: Equatable, Sendable {
    public var snapshot: DebugUIScreenCaptureSnapshot
    public var frame: DebugUIInspectionFrame

    public init(
        snapshot: DebugUIScreenCaptureSnapshot,
        frame: DebugUIInspectionFrame
    ) {
        self.snapshot = snapshot
        self.frame = frame
    }
}

public enum DebugUIAccessibilityInspectionError: Error, Equatable, Sendable {
    case noScreenAvailable
    case missingDisplayIdentifier
    case accessibilityNotTrusted
}

struct DebugUIScreenMetadata: Equatable, Sendable {
    var screenID: UInt32
    var appKitFrame: HotLoopRect
    var captureFrame: WindowTargetBounds
}

protocol DebugUIScreenMetadataProviding: Sendable {
    func screens(scope: DebugUIInspectionScreenScope) throws -> [DebugUIScreenMetadata]
}

public struct DebugUIAccessibilityInspectionService: Sendable {
    private let windowResolver: MacWindowResolver
    private let capturer: any MacAccessibilitySnapshotCapturing
    private let controlDiscovery: LocalAppAccessibilityControlDiscovery
    private let screenProvider: any DebugUIScreenMetadataProviding
    private let currentProcessID: Int32

    public init() {
        self.init(
            windowResolver: MacWindowResolver(),
            capturer: ApplicationServicesMacAccessibilitySnapshotCapturer(),
            screenProvider: AppKitDebugUIScreenMetadataProvider(),
            currentProcessID: ProcessInfo.processInfo.processIdentifier
        )
    }

    init(
        windowResolver: MacWindowResolver,
        capturer: any MacAccessibilitySnapshotCapturing,
        controlDiscovery: LocalAppAccessibilityControlDiscovery = LocalAppAccessibilityControlDiscovery(),
        screenProvider: any DebugUIScreenMetadataProviding,
        currentProcessID: Int32
    ) {
        self.windowResolver = windowResolver
        self.capturer = capturer
        self.controlDiscovery = controlDiscovery
        self.screenProvider = screenProvider
        self.currentProcessID = currentProcessID
    }

    public func inspect(
        scope: DebugUIInspectionScreenScope,
        minConfidence: Double
    ) throws -> [DebugUIAccessibilityInspectionResult] {
        let screens = try screenProvider.screens(scope: scope)
        guard !screens.isEmpty else {
            throw DebugUIAccessibilityInspectionError.noScreenAvailable
        }

        let targets = visibleInspectableTargets(on: screens)
        guard capturer.trustStatus() == .trusted else {
            throw DebugUIAccessibilityInspectionError.accessibilityNotTrusted
        }
        return windowFrameResults(
            screens: screens,
            targets: targets,
            minConfidence: minConfidence
        )
    }

    private func accessibilityElementResults(
        screens: [DebugUIScreenMetadata],
        targets: [MacWindowTargetCandidate],
        minConfidence: Double
    ) throws -> [DebugUIAccessibilityInspectionResult] {
        guard capturer.trustStatus() == .trusted else {
            throw DebugUIAccessibilityInspectionError.accessibilityNotTrusted
        }

        var elementsByScreenID = Dictionary(
            uniqueKeysWithValues: screens.map { ($0.screenID, [DebugUIElement]()) }
        )
        let limits = MacAccessibilitySnapshotLimits(
            maxDepth: 6,
            maxChildrenPerNode: 90,
            maxTotalNodes: 600,
            maxTextLength: 120
        )
        var occludingWindowBounds: [WindowTargetBounds] = []

        for target in targets {
            guard let tree = try? capturer.captureTree(target: target, limits: limits) else {
                occludingWindowBounds.append(target.bounds)
                continue
            }
            let snapshot = MacAccessibilitySnapshot(
                target: target,
                limits: limits,
                root: tree.root,
                totalNodeCount: tree.totalNodeCount,
                isTreeTruncated: tree.isTreeTruncated
            )
            let windowBounds = snapshot.root.frame ?? target.bounds
            let controls = controlDiscovery.discover(in: snapshot).controls
            for control in controls {
                guard let element = debugElement(
                    for: control,
                    target: target,
                    windowBounds: windowBounds,
                    screens: screens,
                    occludingWindowBounds: occludingWindowBounds
                ) else {
                    continue
                }
                elementsByScreenID[element.screenID, default: []].append(element.element)
            }
            occludingWindowBounds.append(windowBounds)
        }

        return screens.map { screen in
            let elements = (elementsByScreenID[screen.screenID] ?? [])
                .sorted(by: Self.elementSort)
            let frame = DebugUIInspectionFrame(elements: elements)
                .validated(minConfidence: minConfidence)
            let fingerprint = Self.fingerprint(for: screen, elements: frame.elements)
            let snapshot = DebugUIScreenCaptureSnapshot(
                screenID: screen.screenID,
                screenFrame: screen.appKitFrame,
                pixelSize: HotLoopSize(
                    width: screen.captureFrame.width,
                    height: screen.captureFrame.height,
                    space: .screen
                ),
                pngData: Data(),
                fingerprint: fingerprint
            )
            return DebugUIAccessibilityInspectionResult(snapshot: snapshot, frame: frame)
        }
    }

    private func windowFrameResults(
        screens: [DebugUIScreenMetadata],
        targets: [MacWindowTargetCandidate],
        minConfidence: Double
    ) -> [DebugUIAccessibilityInspectionResult] {
        var elementsByScreenID = Dictionary(
            uniqueKeysWithValues: screens.map { ($0.screenID, [DebugUIElement]()) }
        )
        let limits = MacAccessibilitySnapshotLimits(
            maxDepth: 0,
            maxChildrenPerNode: 0,
            maxTotalNodes: 1,
            maxTextLength: 120
        )
        var occludingWindowBounds: [WindowTargetBounds] = []
        var visibleWindowIndex = 0

        for target in targets {
            let tree = try? capturer.captureTree(target: target, limits: limits)
            let windowBounds = tree?.root.frame ?? target.bounds
            defer { occludingWindowBounds.append(windowBounds) }

            guard Self.isVisible(windowBounds, occludingWindowBounds: occludingWindowBounds) else {
                continue
            }

            let visualStyle = Self.windowFrameStyle(at: visibleWindowIndex)
            visibleWindowIndex += 1

            for screen in screens where Self.intersects(windowBounds, screen.captureFrame) {
                guard let bbox = DebugUIAccessibilityGeometry.boundingBox(
                    for: windowBounds,
                    screenFrame: screen.captureFrame
                ) else {
                    continue
                }

                let label = Self.windowLabel(for: target)
                elementsByScreenID[screen.screenID, default: []].append(
                    DebugUIElement(
                        id: "window-\(target.windowID)",
                        type: .draggable,
                        label: label,
                        description: "Window frame \(label)",
                        bbox: bbox,
                        confidence: 1,
                        visualStyle: visualStyle
                    )
                )
            }
        }

        return screens.map { screen in
            let elements = (elementsByScreenID[screen.screenID] ?? [])
                .sorted(by: Self.elementSort)
            let frame = DebugUIInspectionFrame(elements: elements)
                .validated(minConfidence: minConfidence)
            let fingerprint = Self.fingerprint(for: screen, elements: frame.elements)
            let snapshot = DebugUIScreenCaptureSnapshot(
                screenID: screen.screenID,
                screenFrame: screen.appKitFrame,
                pixelSize: HotLoopSize(
                    width: screen.captureFrame.width,
                    height: screen.captureFrame.height,
                    space: .screen
                ),
                pngData: Data(),
                fingerprint: fingerprint
            )
            return DebugUIAccessibilityInspectionResult(snapshot: snapshot, frame: frame)
        }
    }

    private func visibleInspectableTargets(
        on screens: [DebugUIScreenMetadata]
    ) -> [MacWindowTargetCandidate] {
        windowResolver.enumerateCandidates()
            .filter { target in
                target.isVisible
                    && target.isOnScreen
                    && target.safetyAssessment.status == .allowed
                    && !target.isIPhoneMirroring
                    && target.processID != currentProcessID
                    && screens.contains { screen in
                        Self.intersects(target.bounds, screen.captureFrame)
                    }
            }
    }

    private func debugElement(
        for control: LocalAppDiscoveredControl,
        target: MacWindowTargetCandidate,
        windowBounds: WindowTargetBounds,
        screens: [DebugUIScreenMetadata],
        occludingWindowBounds: [WindowTargetBounds]
    ) -> (screenID: UInt32, element: DebugUIElement)? {
        guard control.isEnabled,
              let rawBounds = control.frame,
              let type = Self.elementType(for: control)
        else {
            return nil
        }

        guard let bounds = DebugUIAccessibilityGeometry.normalizedBounds(
            for: rawBounds,
            targetBounds: windowBounds,
            rootBounds: windowBounds
        ),
            let screen = screens.first(where: { Self.intersects(bounds, $0.captureFrame) }),
              let bbox = DebugUIAccessibilityGeometry.boundingBox(
                for: bounds,
                screenFrame: screen.captureFrame
              )
        else {
            return nil
        }

        guard Self.isVisible(bounds, occludingWindowBounds: occludingWindowBounds),
              Self.shouldRender(control: control, type: type, bbox: bbox, screen: screen)
        else {
            return nil
        }

        let label = Self.label(for: control, type: type)
        return (
            screen.screenID,
            DebugUIElement(
                id: "ax-\(target.windowID)-\(control.id)",
                type: type,
                label: label,
                description: Self.description(for: control, target: target),
                bbox: bbox,
                confidence: 1
            )
        )
    }

    private static func elementType(for control: LocalAppDiscoveredControl) -> DebugUIElementType? {
        switch control.kind {
        case .button:
            if isWindowControl(control) {
                return .windowControl
            }
            return isToolbarControl(control) ? .toolbarIcon : .button
        case .textField, .searchField:
            return .input
        case .checkbox:
            return .checkbox
        case .menuItem:
            return .menuItem
        case .group:
            return control.actions.contains("AXPress") ? .button : nil
        case .unknown:
            return nil
        }
    }

    private static func isWindowControl(_ control: LocalAppDiscoveredControl) -> Bool {
        let label = control.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["close", "minimize", "zoom", "fullscreen", "full screen"].contains(label)
    }

    private static func isToolbarControl(_ control: LocalAppDiscoveredControl) -> Bool {
        guard control.kind == .button else { return false }
        let role = control.role ?? ""
        let label = control.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return role == "AXButton" && label.count <= 24
    }

    private static func label(
        for control: LocalAppDiscoveredControl,
        type: DebugUIElementType
    ) -> String {
        let trimmed = control.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return type.rawValue.replacingOccurrences(of: "_", with: " ")
    }

    private static func description(
        for control: LocalAppDiscoveredControl,
        target: MacWindowTargetCandidate
    ) -> String {
        [
            target.appName,
            target.title,
            control.role
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    private static func windowLabel(for target: MacWindowTargetCandidate) -> String {
        [
            target.appName,
            target.title
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? "window \(target.windowID)"
    }

    private static func windowFrameStyle(at index: Int) -> DebugUIOverlayStyle {
        windowFrameStyles[index % windowFrameStyles.count]
    }

    private static let windowFrameStyles: [DebugUIOverlayStyle] = [
        DebugUIOverlayStyle(overlayColor: "#EF4444", borderColor: "#F87171", labelColor: "#FFFFFF"),
        DebugUIOverlayStyle(overlayColor: "#F97316", borderColor: "#FB923C", labelColor: "#FFFFFF"),
        DebugUIOverlayStyle(overlayColor: "#EAB308", borderColor: "#FACC15", labelColor: "#111827"),
        DebugUIOverlayStyle(overlayColor: "#22C55E", borderColor: "#4ADE80", labelColor: "#052E16"),
        DebugUIOverlayStyle(overlayColor: "#06B6D4", borderColor: "#22D3EE", labelColor: "#083344"),
        DebugUIOverlayStyle(overlayColor: "#3B82F6", borderColor: "#60A5FA", labelColor: "#FFFFFF"),
        DebugUIOverlayStyle(overlayColor: "#8B5CF6", borderColor: "#A78BFA", labelColor: "#FFFFFF"),
        DebugUIOverlayStyle(overlayColor: "#EC4899", borderColor: "#F472B6", labelColor: "#FFFFFF"),
        DebugUIOverlayStyle(overlayColor: "#84CC16", borderColor: "#A3E635", labelColor: "#1A2E05"),
        DebugUIOverlayStyle(overlayColor: "#14B8A6", borderColor: "#2DD4BF", labelColor: "#042F2E")
    ]

    private static func shouldRender(
        control: LocalAppDiscoveredControl,
        type: DebugUIElementType,
        bbox: DebugUIBoundingBox,
        screen: DebugUIScreenMetadata
    ) -> Bool {
        guard bbox.width >= 4, bbox.height >= 4 else { return false }

        let screenWidth = screen.captureFrame.width
        let screenHeight = screen.captureFrame.height
        guard screenWidth > 0, screenHeight > 0 else { return false }

        let area = bbox.width * bbox.height
        let screenArea = screenWidth * screenHeight
        let areaFraction = area / screenArea
        let widthFraction = bbox.width / screenWidth
        let heightFraction = bbox.height / screenHeight

        if type == .input {
            return areaFraction <= 0.045
                && heightFraction <= 0.18
                && widthFraction <= 0.65
        }
        if control.kind == .group && areaFraction > 0.08 {
            return false
        }
        if areaFraction > 0.12 {
            return false
        }
        if heightFraction > 0.55 && widthFraction > 0.10 {
            return false
        }
        if widthFraction > 0.85 && heightFraction > 0.05 {
            return false
        }

        return true
    }

    private static func isVisible(
        _ bounds: WindowTargetBounds,
        occludingWindowBounds: [WindowTargetBounds]
    ) -> Bool {
        !visibleFragments(
            of: bounds,
            afterSubtracting: occludingWindowBounds
        ).isEmpty
    }

    private static func intersects(
        _ lhs: WindowTargetBounds,
        _ rhs: WindowTargetBounds
    ) -> Bool {
        lhs.x < rhs.x + rhs.width
            && lhs.x + lhs.width > rhs.x
            && lhs.y < rhs.y + rhs.height
            && lhs.y + lhs.height > rhs.y
    }

    private static func visibleFragments(
        of bounds: WindowTargetBounds,
        afterSubtracting occluders: [WindowTargetBounds]
    ) -> [WindowTargetBounds] {
        guard bounds.hasPositiveArea else { return [] }

        var fragments = [bounds]
        for occluder in occluders where occluder.hasPositiveArea {
            fragments = fragments.flatMap { subtract(occluder, from: $0) }
            if fragments.isEmpty {
                return []
            }
        }

        return fragments
    }

    private static func subtract(
        _ occluder: WindowTargetBounds,
        from fragment: WindowTargetBounds
    ) -> [WindowTargetBounds] {
        guard let overlap = intersection(fragment, occluder) else {
            return [fragment]
        }

        let fragmentMaxX = fragment.x + fragment.width
        let fragmentMaxY = fragment.y + fragment.height
        let overlapMaxX = overlap.x + overlap.width
        let overlapMaxY = overlap.y + overlap.height

        let candidates = [
            WindowTargetBounds(
                x: fragment.x,
                y: fragment.y,
                width: fragment.width,
                height: overlap.y - fragment.y
            ),
            WindowTargetBounds(
                x: fragment.x,
                y: overlapMaxY,
                width: fragment.width,
                height: fragmentMaxY - overlapMaxY
            ),
            WindowTargetBounds(
                x: fragment.x,
                y: overlap.y,
                width: overlap.x - fragment.x,
                height: overlap.height
            ),
            WindowTargetBounds(
                x: overlapMaxX,
                y: overlap.y,
                width: fragmentMaxX - overlapMaxX,
                height: overlap.height
            )
        ]

        return candidates.filter(\.hasPositiveArea)
    }

    private static func intersection(
        _ lhs: WindowTargetBounds,
        _ rhs: WindowTargetBounds
    ) -> WindowTargetBounds? {
        let minX = max(lhs.x, rhs.x)
        let minY = max(lhs.y, rhs.y)
        let maxX = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let maxY = min(lhs.y + lhs.height, rhs.y + rhs.height)
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0, height > 0 else {
            return nil
        }

        return WindowTargetBounds(x: minX, y: minY, width: width, height: height)
    }

    private static func elementSort(_ lhs: DebugUIElement, _ rhs: DebugUIElement) -> Bool {
        if lhs.bbox.y != rhs.bbox.y {
            return lhs.bbox.y < rhs.bbox.y
        }
        if lhs.bbox.x != rhs.bbox.x {
            return lhs.bbox.x < rhs.bbox.x
        }
        return lhs.id < rhs.id
    }

    private static func fingerprint(
        for screen: DebugUIScreenMetadata,
        elements: [DebugUIElement]
    ) -> String {
        let payload = ([String(screen.screenID)] + elements.map { element in
            [
                element.id,
                element.type.rawValue,
                element.label,
                String(format: "%.1f", element.bbox.x),
                String(format: "%.1f", element.bbox.y),
                String(format: "%.1f", element.bbox.width),
                String(format: "%.1f", element.bbox.height)
            ].joined(separator: "|")
        }).joined(separator: "\n")
        return SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public enum DebugUIAccessibilityGeometry {
    static func normalizedBounds(
        for bounds: WindowTargetBounds,
        targetBounds: WindowTargetBounds,
        rootBounds: WindowTargetBounds? = nil
    ) -> WindowTargetBounds? {
        let rootBounds = rootBounds ?? targetBounds
        let grounded = WindowTargetBounds(
            x: normalizedAxisOrigin(
                bounds.x,
                length: bounds.width,
                rootOrigin: rootBounds.x,
                rootLength: rootBounds.width,
                targetOrigin: targetBounds.x
            ),
            y: normalizedAxisOrigin(
                bounds.y,
                length: bounds.height,
                rootOrigin: rootBounds.y,
                rootLength: rootBounds.height,
                targetOrigin: targetBounds.y
            ),
            width: bounds.width,
            height: bounds.height
        )
        return intersection(grounded, targetBounds)
    }

    private static func normalizedAxisOrigin(
        _ origin: Double,
        length: Double,
        rootOrigin: Double,
        rootLength: Double,
        targetOrigin: Double
    ) -> Double {
        let rootMax = rootOrigin + rootLength
        let center = origin + length / 2
        if center >= rootOrigin && center <= rootMax {
            return targetOrigin + (origin - rootOrigin)
        }
        return targetOrigin + origin
    }

    public static func boundingBox(
        for bounds: WindowTargetBounds,
        screenFrame: WindowTargetBounds
    ) -> DebugUIBoundingBox? {
        let minX = max(bounds.x, screenFrame.x)
        let minY = max(bounds.y, screenFrame.y)
        let maxX = min(bounds.x + bounds.width, screenFrame.x + screenFrame.width)
        let maxY = min(bounds.y + bounds.height, screenFrame.y + screenFrame.height)
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0, height > 0 else {
            return nil
        }

        return DebugUIBoundingBox(
            x: minX - screenFrame.x,
            y: minY - screenFrame.y,
            width: width,
            height: height
        )
    }

    private static func intersection(
        _ lhs: WindowTargetBounds,
        _ rhs: WindowTargetBounds
    ) -> WindowTargetBounds? {
        let minX = max(lhs.x, rhs.x)
        let minY = max(lhs.y, rhs.y)
        let maxX = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let maxY = min(lhs.y + lhs.height, rhs.y + rhs.height)
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0, height > 0 else {
            return nil
        }

        return WindowTargetBounds(x: minX, y: minY, width: width, height: height)
    }

}

private struct AppKitDebugUIScreenMetadataProvider: DebugUIScreenMetadataProviding {
    func screens(scope: DebugUIInspectionScreenScope) throws -> [DebugUIScreenMetadata] {
        let screens: [NSScreen]
        switch scope {
        case .main:
            guard let screen = NSScreen.main ?? NSScreen.screens.first else {
                throw DebugUIAccessibilityInspectionError.noScreenAvailable
            }
            screens = [screen]
        case .all:
            screens = NSScreen.screens
        }

        return try screens.map(Self.metadata(for:))
    }

    private static func metadata(for screen: NSScreen) throws -> DebugUIScreenMetadata {
        let displayID = try displayID(for: screen)
        let appKitFrame = screen.frame
        let captureFrame = CGDisplayBounds(displayID)

        return DebugUIScreenMetadata(
            screenID: displayID,
            appKitFrame: HotLoopRect(
                x: appKitFrame.origin.x,
                y: appKitFrame.origin.y,
                width: appKitFrame.width,
                height: appKitFrame.height,
                space: .screen
            ),
            captureFrame: WindowTargetBounds(
                x: captureFrame.origin.x,
                y: captureFrame.origin.y,
                width: captureFrame.width,
                height: captureFrame.height
            )
        )
    }

    private static func displayID(for screen: NSScreen) throws -> UInt32 {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let value = screen.deviceDescription[key] as? NSNumber else {
            throw DebugUIAccessibilityInspectionError.missingDisplayIdentifier
        }
        return value.uint32Value
    }
}
