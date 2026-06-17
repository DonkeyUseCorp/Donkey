@preconcurrency import AppKit
import CoreGraphics
import CryptoKit
import DonkeyContracts
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct DebugUIOverlayConfiguration: Equatable, Sendable {
    /// The only knob the dev-overlay JSON file controls: flip the debug overlay on or off.
    /// Everything else below is a fixed, sensible default — the old tuning fields were never used.
    public var enabled: Bool

    public var mode: String { "donkeyVision" }
    public var cadenceSeconds: TimeInterval { 1.0 }
    public var screenScope: DebugUIInspectionScreenScope { .main }
    public var minConfidence: Double { 0.25 }
    public var activeWindowOnly: Bool { true }
    public var targetBundleIdentifiers: [String] { [] }
    public var targetAppNames: [String] { [] }

    public init(enabled: Bool = false) {
        self.enabled = enabled
    }

    public static let disabled = DebugUIOverlayConfiguration(enabled: false)

    public static func defaultConfigURL(fileManager: FileManager = .default) -> URL? {
        guard let applicationSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return nil
        }

        return applicationSupport
            .appendingPathComponent("Donkey", isDirectory: true)
            .appendingPathComponent("dev-overlay.json", isDirectory: false)
    }

    public static func load(
        fileURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> DebugUIOverlayConfiguration {
        let urls: [URL]
        if let fileURL {
            urls = [fileURL]
        } else {
            urls = candidateConfigURLs(fileManager: fileManager)
        }

        let enabled = urls.lazy.compactMap { url -> Bool? in
            guard fileManager.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let raw = try? JSONDecoder().decode(RawDebugUIOverlayConfiguration.self, from: data)
            else {
                return nil
            }
            return raw.enabled ?? false
        }.first ?? false

        return DebugUIOverlayConfiguration(enabled: enabled)
    }

    public static func candidateConfigURLs(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> [URL] {
        var urls: [URL] = []
        if let defaultConfigURL = defaultConfigURL(fileManager: fileManager) {
            urls.append(defaultConfigURL)
        }

        #if DEBUG
        if let value = environment["DONKEY_DEV_OVERLAY_CONFIG"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            urls.append(URL(fileURLWithPath: value))
        }
        if let value = bundle.object(forInfoDictionaryKey: "DonkeyDevOverlayConfigPath") as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            urls.append(URL(fileURLWithPath: value))
        }
        urls.append(contentsOf: repoConfigCandidates(fileManager: fileManager))
        #endif

        var seen = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }

    #if DEBUG
    private static func repoConfigCandidates(fileManager: FileManager) -> [URL] {
        var candidates: [URL] = []
        var directory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        for _ in 0..<8 {
            candidates.append(directory.appendingPathComponent("dev-overlay.json", isDirectory: false))
            candidates.append(
                directory
                    .appendingPathComponent("apps", isDirectory: true)
                    .appendingPathComponent("Donkey", isDirectory: true)
                    .appendingPathComponent("dev-overlay.json", isDirectory: false)
            )
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { break }
            directory = parent
        }
        return candidates
    }
    #endif
}

private struct RawDebugUIOverlayConfiguration: Codable {
    var enabled: Bool?
}

public struct DebugUIElementTracker: Equatable, Sendable {
    private var previousElements: [DebugUIElement]
    private var lastObservedElements: [DebugUIElement]
    private var appearanceCounts: [String: Int]
    private var missingCounts: [String: Int]
    private var pendingMovements: [String: PendingTrackedElement]
    private var pendingContent: [String: PendingTrackedElement]
    private var appearanceThreshold: Int
    private var disappearanceTolerance: Int
    private var stableDisappearanceTolerance: Int
    private var stableIDPrefixes: [String]
    private var movementConfirmationSamples: Int

    public init(
        previousElements: [DebugUIElement] = [],
        appearanceThreshold: Int = 2,
        disappearanceTolerance: Int = 2,
        movementConfirmationSamples: Int = 2,
        stableDisappearanceTolerance: Int? = nil,
        stableIDPrefixes: [String] = []
    ) {
        self.previousElements = previousElements
        self.lastObservedElements = previousElements
        self.appearanceCounts = Dictionary(uniqueKeysWithValues: previousElements.map { ($0.id, appearanceThreshold) })
        self.missingCounts = [:]
        self.pendingMovements = [:]
        self.pendingContent = [:]
        self.appearanceThreshold = max(1, appearanceThreshold)
        self.disappearanceTolerance = max(0, disappearanceTolerance)
        // Stable-ID elements (e.g. accessibility boxes) keep a fixed identity across scans, so a
        // brief detection gap should not yank them — that is what reads as flicker. Volatile
        // elements (e.g. vision parses that reassign IDs every pass) must stay at the base
        // tolerance, otherwise stale boxes linger and stack. Never below the base tolerance.
        self.stableDisappearanceTolerance = max(
            max(0, disappearanceTolerance),
            stableDisappearanceTolerance ?? disappearanceTolerance
        )
        self.stableIDPrefixes = stableIDPrefixes
        self.movementConfirmationSamples = max(1, movementConfirmationSamples)
    }

    private func disappearanceTolerance(for element: DebugUIElement) -> Int {
        for prefix in stableIDPrefixes where element.id.hasPrefix(prefix) {
            return stableDisappearanceTolerance
        }
        return disappearanceTolerance
    }

    public mutating func update(
        with frame: DebugUIInspectionFrame,
        renderNewElementsImmediately: Bool = false
    ) -> DebugUIInspectionFrame {
        let isInitialObservation = previousElements.isEmpty && lastObservedElements.isEmpty
        var usedPreviousIDs = Set<String>()
        let matchBase = semanticMatchBase()
        var trackedCandidates: [DebugUIElement] = []

        for incoming in frame.elements {
            if let previous = previousElements.first(where: { $0.id == incoming.id }) {
                usedPreviousIDs.insert(incoming.id)
                trackedCandidates.append(stableElement(incoming, matchedTo: previous))
                continue
            }
            if let observed = lastObservedElements.first(where: { $0.id == incoming.id }) {
                usedPreviousIDs.insert(incoming.id)
                trackedCandidates.append(stableElement(incoming, matchedTo: observed))
                continue
            }

            guard let match = bestSemanticMatch(
                for: incoming,
                in: matchBase,
                usedPreviousIDs: usedPreviousIDs
            ) else {
                trackedCandidates.append(incoming)
                continue
            }

            usedPreviousIDs.insert(match.id)
            trackedCandidates.append(stableElement(incoming.replacingID(match.id), matchedTo: match))
        }

        lastObservedElements = trackedCandidates
        let trackedIDs = Set(trackedCandidates.map(\.id))
        var rendered: [DebugUIElement] = []

        if isInitialObservation {
            rendered = trackedCandidates
            for candidate in trackedCandidates {
                appearanceCounts[candidate.id] = appearanceThreshold
                missingCounts[candidate.id] = nil
            }
        } else {
            for candidate in trackedCandidates {
                if previousElements.contains(where: { $0.id == candidate.id }) {
                    appearanceCounts[candidate.id] = appearanceThreshold
                    missingCounts[candidate.id] = nil
                    rendered.append(candidate)
                    continue
                }

                let count = min(appearanceThreshold, (appearanceCounts[candidate.id] ?? 0) + 1)
                appearanceCounts[candidate.id] = count
                missingCounts[candidate.id] = nil
                if renderNewElementsImmediately || count >= appearanceThreshold {
                    rendered.append(candidate)
                }
            }
        }

        for previous in previousElements where !trackedIDs.contains(previous.id) {
            let missingCount = (missingCounts[previous.id] ?? 0) + 1
            if missingCount <= disappearanceTolerance(for: previous) {
                missingCounts[previous.id] = missingCount
                rendered.append(previous)
            } else {
                missingCounts[previous.id] = nil
                appearanceCounts[previous.id] = nil
            }
        }

        let renderedIDs = Set(rendered.map(\.id))
        appearanceCounts = appearanceCounts.filter { trackedIDs.contains($0.key) || renderedIDs.contains($0.key) }
        missingCounts = missingCounts.filter { renderedIDs.contains($0.key) }
        pendingMovements = pendingMovements.filter { trackedIDs.contains($0.key) || renderedIDs.contains($0.key) }
        pendingContent = pendingContent.filter { trackedIDs.contains($0.key) || renderedIDs.contains($0.key) }
        previousElements = rendered
        return DebugUIInspectionFrame(elements: rendered)
    }

    private func semanticMatchBase() -> [DebugUIElement] {
        var seen = Set<String>()
        return (previousElements + lastObservedElements).filter { element in
            guard !seen.contains(element.id) else { return false }
            seen.insert(element.id)
            return true
        }
    }

    private mutating func stableElement(
        _ incoming: DebugUIElement,
        matchedTo previous: DebugUIElement
    ) -> DebugUIElement {
        let geometryStable = stableGeometryElement(incoming, matchedTo: previous)
        return stableContentElement(geometryStable, matchedTo: previous)
    }

    private mutating func stableGeometryElement(
        _ incoming: DebugUIElement,
        matchedTo previous: DebugUIElement
    ) -> DebugUIElement {
        if shouldReusePreviousBounds(incoming.bbox, previous.bbox) {
            pendingMovements[incoming.id] = nil
            return copy(incoming, bbox: previous.bbox)
        }

        if isLargeMovement(from: previous.bbox, to: incoming.bbox) {
            pendingMovements[incoming.id] = nil
            return incoming
        }

        let pending = pendingMovements[incoming.id]
        let nextCount: Int
        if let pending,
           shouldReusePreviousBounds(incoming.bbox, pending.element.bbox) {
            nextCount = min(movementConfirmationSamples, pending.count + 1)
        } else {
            nextCount = 1
        }

        if nextCount >= movementConfirmationSamples {
            pendingMovements[incoming.id] = nil
            return incoming
        }

        pendingMovements[incoming.id] = PendingTrackedElement(element: incoming, count: nextCount)
        return copy(incoming, bbox: previous.bbox)
    }

    private mutating func stableContentElement(
        _ incoming: DebugUIElement,
        matchedTo previous: DebugUIElement
    ) -> DebugUIElement {
        if hasSameRenderContent(incoming, previous) {
            pendingContent[incoming.id] = nil
            return incoming
        }

        let pending = pendingContent[incoming.id]
        let nextCount: Int
        if let pending,
           hasSameRenderContent(incoming, pending.element) {
            nextCount = min(movementConfirmationSamples, pending.count + 1)
        } else {
            nextCount = 1
        }

        if nextCount >= movementConfirmationSamples {
            pendingContent[incoming.id] = nil
            return incoming
        }

        pendingContent[incoming.id] = PendingTrackedElement(element: incoming, count: nextCount)
        return DebugUIElement(
            id: incoming.id,
            type: incoming.type,
            label: previous.label,
            description: incoming.description,
            bbox: incoming.bbox,
            confidence: incoming.confidence,
            visualStyle: previous.visualStyle,
            metadata: stableRenderMetadata(incoming: incoming.metadata, previous: previous.metadata)
        )
    }

    private func shouldReusePreviousBounds(
        _ incoming: DebugUIBoundingBox,
        _ previous: DebugUIBoundingBox
    ) -> Bool {
        let maximumDelta = max(
            abs(incoming.x - previous.x),
            abs(incoming.y - previous.y),
            abs(incoming.width - previous.width),
            abs(incoming.height - previous.height)
        )
        return maximumDelta <= jitterTolerance(for: previous) && matchScore(previous, incoming) >= 0.70
    }

    private func isLargeMovement(
        from previous: DebugUIBoundingBox,
        to incoming: DebugUIBoundingBox
    ) -> Bool {
        let maximumDelta = max(
            abs(incoming.x - previous.x),
            abs(incoming.y - previous.y),
            abs(incoming.width - previous.width),
            abs(incoming.height - previous.height)
        )
        let threshold = max(48.0, max(previous.width, previous.height) * 0.25)
        return maximumDelta >= threshold || matchScore(previous, incoming) < 0.12
    }

    private func jitterTolerance(for bbox: DebugUIBoundingBox) -> Double {
        min(max(6.0, min(bbox.width, bbox.height) * 0.08), 10.0)
    }

    private func hasSameRenderContent(
        _ lhs: DebugUIElement,
        _ rhs: DebugUIElement
    ) -> Bool {
        lhs.type == rhs.type
            && lhs.label.trimmingCharacters(in: .whitespacesAndNewlines)
                == rhs.label.trimmingCharacters(in: .whitespacesAndNewlines)
            && lhs.visualStyle == rhs.visualStyle
            && lhs.metadata["localUIElement.sources"] == rhs.metadata["localUIElement.sources"]
    }

    private func stableRenderMetadata(
        incoming: [String: String],
        previous: [String: String]
    ) -> [String: String] {
        guard let sources = previous["localUIElement.sources"] else {
            return incoming
        }

        var metadata = incoming
        metadata["localUIElement.sources"] = sources
        return metadata
    }

    private func copy(
        _ element: DebugUIElement,
        bbox: DebugUIBoundingBox
    ) -> DebugUIElement {
        DebugUIElement(
            id: element.id,
            type: element.type,
            label: element.label,
            description: element.description,
            bbox: bbox,
            confidence: element.confidence,
            visualStyle: element.visualStyle,
            metadata: element.metadata
        )
    }

    private func bestSemanticMatch(
        for incoming: DebugUIElement,
        in candidates: [DebugUIElement],
        usedPreviousIDs: Set<String>
    ) -> DebugUIElement? {
        candidates
            .filter { previous in
                !usedPreviousIDs.contains(previous.id)
                    && previous.type == incoming.type
                    && normalized(previous.label) == normalized(incoming.label)
            }
            .max { left, right in
                matchScore(left.bbox, incoming.bbox) < matchScore(right.bbox, incoming.bbox)
            }
            .flatMap { candidate in
                matchScore(candidate.bbox, incoming.bbox) >= 0.25 ? candidate : nil
            }
    }

    private func matchScore(_ lhs: DebugUIBoundingBox, _ rhs: DebugUIBoundingBox) -> Double {
        let overlap = intersectionArea(lhs, rhs)
        let union = lhs.width * lhs.height + rhs.width * rhs.height - overlap
        let iou = union > 0 ? overlap / union : 0
        let centerDistance = hypot(
            (lhs.x + lhs.width / 2) - (rhs.x + rhs.width / 2),
            (lhs.y + lhs.height / 2) - (rhs.y + rhs.height / 2)
        )
        let distanceScore = max(0, 1 - centerDistance / 160)
        return max(iou, distanceScore * 0.5)
    }

    private func intersectionArea(_ lhs: DebugUIBoundingBox, _ rhs: DebugUIBoundingBox) -> Double {
        let minX = max(lhs.x, rhs.x)
        let minY = max(lhs.y, rhs.y)
        let maxX = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let maxY = min(lhs.y + lhs.height, rhs.y + rhs.height)
        return max(0, maxX - minX) * max(0, maxY - minY)
    }

    private func normalized(_ value: String) -> String {
        value
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }
}

private struct PendingTrackedElement: Equatable, Sendable {
    var element: DebugUIElement
    var count: Int
}

public extension DebugUIInspectionFrame {
    func isOverlayRenderEquivalent(to other: DebugUIInspectionFrame) -> Bool {
        guard elements.count == other.elements.count else { return false }

        return zip(elements, other.elements).allSatisfy { lhs, rhs in
            lhs.id == rhs.id
                && lhs.type == rhs.type
                && lhs.label == rhs.label
                && lhs.bbox == rhs.bbox
                && lhs.visualStyle == rhs.visualStyle
                && lhs.metadata["localUIElement.sources"] == rhs.metadata["localUIElement.sources"]
        }
    }
}

public enum DebugUIOverlayGeometry {
    public static func stableLabelFrame(
        for text: String,
        boxFrame: CGRect,
        containerSize: CGSize
    ) -> CGRect {
        let height = 18.0
        let availableWidth = max(64.0, Double(containerSize.width) - max(0, boxFrame.minX))
        let estimatedWidth = Double(text.count) * 6.5 + 14
        let bucketedWidth: Double
        if estimatedWidth <= 96 {
            bucketedWidth = 96
        } else if estimatedWidth <= 160 {
            bucketedWidth = 160
        } else if estimatedWidth <= 240 {
            bucketedWidth = 240
        } else {
            bucketedWidth = 320
        }
        let width = min(bucketedWidth, availableWidth)
        let labelY: Double
        if boxFrame.minY >= height + 2 {
            labelY = boxFrame.minY - height - 2
        } else {
            labelY = min(
                max(0, Double(boxFrame.minY) + 2),
                max(0, Double(containerSize.height) - height)
            )
        }

        return CGRect(
            x: max(0, min(Double(boxFrame.minX), Double(containerSize.width) - width)),
            y: labelY,
            width: width,
            height: height
        ).integral
    }

    public static func appKitFrame(
        for bbox: DebugUIBoundingBox,
        screenshotPixelSize: HotLoopSize,
        screenFrame: HotLoopRect
    ) -> CGRect {
        guard screenshotPixelSize.width > 0,
              screenshotPixelSize.height > 0
        else {
            return .zero
        }

        let scaleX = screenFrame.size.width / screenshotPixelSize.width
        let scaleY = screenFrame.size.height / screenshotPixelSize.height
        return CGRect(
            x: screenFrame.origin.x + bbox.x * scaleX,
            y: screenFrame.origin.y + screenFrame.size.height - (bbox.y + bbox.height) * scaleY,
            width: bbox.width * scaleX,
            height: bbox.height * scaleY
        )
    }

    public static func localLayerFrame(
        for bbox: DebugUIBoundingBox,
        screenshotPixelSize: HotLoopSize,
        screenPointSize: HotLoopSize
    ) -> CGRect {
        guard screenshotPixelSize.width > 0,
              screenshotPixelSize.height > 0
        else {
            return .zero
        }

        let scaleX = screenPointSize.width / screenshotPixelSize.width
        let scaleY = screenPointSize.height / screenshotPixelSize.height
        let height = bbox.height * scaleY
        return CGRect(
            x: bbox.x * scaleX,
            y: screenPointSize.height - (bbox.y * scaleY + height),
            width: bbox.width * scaleX,
            height: height
        )
    }
}

public enum DebugUIScreenCaptureError: Error, Equatable, Sendable {
    case noScreenAvailable
    case missingDisplayIdentifier
    case screenCapturePermissionDenied
    case blankCapture(displayID: UInt32)
    case captureFailed(displayID: UInt32)
    case pngEncodingFailed(displayID: UInt32)
}

public struct DebugUIScreenCaptureSnapshot: Equatable, Sendable {
    public var screenID: UInt32
    public var screenFrame: HotLoopRect
    public var pixelSize: HotLoopSize
    public var pngData: Data
    public var fingerprint: String

    public init(
        screenID: UInt32,
        screenFrame: HotLoopRect,
        pixelSize: HotLoopSize,
        pngData: Data,
        fingerprint: String
    ) {
        self.screenID = screenID
        self.screenFrame = screenFrame
        self.pixelSize = pixelSize
        self.pngData = pngData
        self.fingerprint = fingerprint
    }

    public var base64PNG: String {
        pngData.base64EncodedString()
    }
}

public struct DebugUIScreenCaptureService: Sendable {
    private static let maxInspectionPixelDimension = 1_600

    public init() {}

    public func captureScreens(
        scope: DebugUIInspectionScreenScope
    ) throws -> [DebugUIScreenCaptureSnapshot] {
        guard Self.screenCaptureAccessGranted() else {
            throw DebugUIScreenCaptureError.screenCapturePermissionDenied
        }

        let screens: [NSScreen]
        switch scope {
        case .main:
            guard let screen = NSScreen.main ?? NSScreen.screens.first else {
                return try Self.fallbackDisplayIDs(scope: scope).map(capture)
            }
            screens = [screen]
        case .all:
            screens = NSScreen.screens
        }

        if screens.isEmpty {
            return try Self.fallbackDisplayIDs(scope: scope).map(capture)
        }
        return try screens.map(capture)
    }

    private static func screenCaptureAccessGranted() -> Bool {
        // Preflight only — never prompt here. The system dialog is requested through the in-notch
        // pre-gate (on user approval); runtime capture just checks and falls back if not granted.
        CGPreflightScreenCaptureAccess()
    }

    private func capture(screen: NSScreen) throws -> DebugUIScreenCaptureSnapshot {
        let displayID = try Self.displayID(for: screen)
        guard let image = CGDisplayCreateImage(displayID) else {
            throw DebugUIScreenCaptureError.captureFailed(displayID: displayID)
        }
        let inspectionImage = Self.inspectionImage(from: image)
        guard !Self.isLikelyBlank(inspectionImage) else {
            throw DebugUIScreenCaptureError.blankCapture(displayID: displayID)
        }
        guard let pngData = Self.pngData(from: inspectionImage) else {
            throw DebugUIScreenCaptureError.pngEncodingFailed(displayID: displayID)
        }

        let frame = screen.frame
        return DebugUIScreenCaptureSnapshot(
            screenID: displayID,
            screenFrame: HotLoopRect(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.size.width,
                height: frame.size.height,
                space: .screen
            ),
            pixelSize: HotLoopSize(
                width: Double(inspectionImage.width),
                height: Double(inspectionImage.height),
                space: .screen
            ),
            pngData: pngData,
            fingerprint: Self.fingerprint(for: pngData)
        )
    }

    private func capture(displayID: CGDirectDisplayID) throws -> DebugUIScreenCaptureSnapshot {
        guard let image = CGDisplayCreateImage(displayID) else {
            throw DebugUIScreenCaptureError.captureFailed(displayID: displayID)
        }
        let inspectionImage = Self.inspectionImage(from: image)
        guard !Self.isLikelyBlank(inspectionImage) else {
            throw DebugUIScreenCaptureError.blankCapture(displayID: displayID)
        }
        guard let pngData = Self.pngData(from: inspectionImage) else {
            throw DebugUIScreenCaptureError.pngEncodingFailed(displayID: displayID)
        }

        let bounds = CGDisplayBounds(displayID)
        return DebugUIScreenCaptureSnapshot(
            screenID: displayID,
            screenFrame: HotLoopRect(
                x: bounds.origin.x,
                y: bounds.origin.y,
                width: bounds.width,
                height: bounds.height,
                space: .screen
            ),
            pixelSize: HotLoopSize(
                width: Double(inspectionImage.width),
                height: Double(inspectionImage.height),
                space: .screen
            ),
            pngData: pngData,
            fingerprint: Self.fingerprint(for: pngData)
        )
    }

    private static func displayID(for screen: NSScreen) throws -> UInt32 {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let value = screen.deviceDescription[key] as? NSNumber else {
            throw DebugUIScreenCaptureError.missingDisplayIdentifier
        }
        return value.uint32Value
    }

    private static func fallbackDisplayIDs(scope: DebugUIInspectionScreenScope) throws -> [CGDirectDisplayID] {
        switch scope {
        case .main:
            let displayID = CGMainDisplayID()
            guard displayID != 0 else {
                throw DebugUIScreenCaptureError.noScreenAvailable
            }
            return [displayID]
        case .all:
            var count: UInt32 = 0
            CGGetActiveDisplayList(0, nil, &count)
            guard count > 0 else {
                throw DebugUIScreenCaptureError.noScreenAvailable
            }
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
            CGGetActiveDisplayList(count, &displays, &count)
            return Array(displays.prefix(Int(count))).filter { $0 != 0 }
        }
    }

    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }

    private static func inspectionImage(from image: CGImage) -> CGImage {
        let longestEdge = max(image.width, image.height)
        guard longestEdge > maxInspectionPixelDimension else {
            return image
        }

        let scale = Double(maxInspectionPixelDimension) / Double(longestEdge)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return image
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private static func isLikelyBlank(_ image: CGImage) -> Bool {
        let width = 32
        let height = 32
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }

            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

            let bytes = buffer.bindMemory(to: UInt8.self)
            var luminanceTotal = 0
            var brightPixels = 0
            for offset in stride(from: 0, to: bytes.count, by: bytesPerPixel) {
                let red = Int(bytes[offset])
                let green = Int(bytes[offset + 1])
                let blue = Int(bytes[offset + 2])
                let luminance = (red + green + blue) / 3
                luminanceTotal += luminance
                if luminance > 24 {
                    brightPixels += 1
                }
            }

            let pixelCount = width * height
            let averageLuminance = Double(luminanceTotal) / Double(pixelCount * 255)
            let brightFraction = Double(brightPixels) / Double(pixelCount)
            return averageLuminance < 0.02 && brightFraction < 0.01
        }
    }

    private static func fingerprint(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

protocol DebugUIScreenCapturing: Sendable {
    func captureScreens(
        scope: DebugUIInspectionScreenScope
    ) throws -> [DebugUIScreenCaptureSnapshot]
}

extension DebugUIScreenCaptureService: DebugUIScreenCapturing {}
