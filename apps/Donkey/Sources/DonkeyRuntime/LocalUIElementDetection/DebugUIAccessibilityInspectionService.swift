@preconcurrency import AppKit
import CoreGraphics
import CryptoKit
import DonkeyContracts
import Foundation
import OSLog

private enum DebugUIAccessibilityInspectionLog {
    static let overlay = Logger(subsystem: "com.donkey.app", category: "debug-ui-inspection")
}

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
    private let screenCapturer: any DebugUIScreenCapturing
    private let elementDetectionService: LocalUIElementDetectionService
    private let currentProcessID: Int32

    public init() {
        self.init(
            windowResolver: MacWindowResolver(),
            capturer: ApplicationServicesMacAccessibilitySnapshotCapturer(
                maximumTraversalNanoseconds: 2_000_000_000
            ),
            screenProvider: AppKitDebugUIScreenMetadataProvider(),
            screenCapturer: DebugUIScreenCaptureService(),
            elementDetectionService: LocalUIElementDetectionService(),
            currentProcessID: ProcessInfo.processInfo.processIdentifier
        )
    }

    init(
        windowResolver: MacWindowResolver,
        capturer: any MacAccessibilitySnapshotCapturing,
        controlDiscovery: LocalAppAccessibilityControlDiscovery = LocalAppAccessibilityControlDiscovery(),
        screenProvider: any DebugUIScreenMetadataProviding,
        screenCapturer: any DebugUIScreenCapturing = EmptyDebugUIScreenCapturer(),
        elementDetectionService: LocalUIElementDetectionService = LocalUIElementDetectionService(),
        currentProcessID: Int32
    ) {
        self.windowResolver = windowResolver
        self.capturer = capturer
        self.controlDiscovery = controlDiscovery
        self.screenProvider = screenProvider
        self.screenCapturer = screenCapturer
        self.elementDetectionService = elementDetectionService
        self.currentProcessID = currentProcessID
    }

    public func inspect(
        scope: DebugUIInspectionScreenScope,
        minConfidence: Double,
        frontmostOnly: Bool = false,
        focusedOnly: Bool = false,
        targetBundleIdentifiers: [String] = [],
        targetAppNames: [String] = []
    ) throws -> [DebugUIAccessibilityInspectionResult] {
        let screens = try screenProvider.screens(scope: scope)
        guard !screens.isEmpty else {
            throw DebugUIAccessibilityInspectionError.noScreenAvailable
        }

        let targets = visibleInspectableTargets(
            on: screens,
            frontmostOnly: frontmostOnly,
            focusedOnly: focusedOnly,
            targetBundleIdentifiers: targetBundleIdentifiers,
            targetAppNames: targetAppNames
        )
        guard capturer.trustStatus() == .trusted else {
            throw DebugUIAccessibilityInspectionError.accessibilityNotTrusted
        }
        guard !targets.isEmpty else {
            return []
        }

        return localElementDetectionResults(
            screens: screens,
            targets: targets,
            minConfidence: minConfidence
        )
    }

    public func inspectProgressively(
        scope: DebugUIInspectionScreenScope,
        minConfidence: Double,
        frontmostOnly: Bool = false,
        focusedOnly: Bool = false,
        targetBundleIdentifiers: [String] = [],
        targetAppNames: [String] = [],
        onPartialResults: ([DebugUIAccessibilityInspectionResult]) -> Void
    ) throws -> [DebugUIAccessibilityInspectionResult] {
        let screens = try screenProvider.screens(scope: scope)
        guard !screens.isEmpty else {
            throw DebugUIAccessibilityInspectionError.noScreenAvailable
        }

        let targets = visibleInspectableTargets(
            on: screens,
            frontmostOnly: frontmostOnly,
            focusedOnly: focusedOnly,
            targetBundleIdentifiers: targetBundleIdentifiers,
            targetAppNames: targetAppNames
        )
        guard capturer.trustStatus() == .trusted else {
            throw DebugUIAccessibilityInspectionError.accessibilityNotTrusted
        }
        guard !targets.isEmpty else {
            return []
        }

        guard let progressiveCapturer = capturer as? any MacAccessibilitySnapshotProgressCapturing else {
            let results = localElementDetectionResults(
                screens: screens,
                targets: targets,
                minConfidence: minConfidence
            )
            onPartialResults(results)
            return results
        }

        return progressiveLocalElementDetectionResults(
            screens: screens,
            targets: targets,
            minConfidence: minConfidence,
            progressiveCapturer: progressiveCapturer,
            onPartialResults: onPartialResults
        )
    }

    private func localElementDetectionResults(
        screens: [DebugUIScreenMetadata],
        targets: [MacWindowTargetCandidate],
        minConfidence: Double
    ) -> [DebugUIAccessibilityInspectionResult] {
        let candidatesByScreenID = accessibilityCandidatesByScreen(
            screens: screens,
            targets: targets
        )

        return inspectionResults(
            screens: screens,
            candidatesByScreenID: candidatesByScreenID,
            minConfidence: minConfidence,
            fingerprintSalt: "final"
        )
    }

    private func progressiveLocalElementDetectionResults(
        screens: [DebugUIScreenMetadata],
        targets: [MacWindowTargetCandidate],
        minConfidence: Double,
        progressiveCapturer: any MacAccessibilitySnapshotProgressCapturing,
        onPartialResults: ([DebugUIAccessibilityInspectionResult]) -> Void
    ) -> [DebugUIAccessibilityInspectionResult] {
        var candidatesByScreenID = Dictionary(
            uniqueKeysWithValues: screens.map { ($0.screenID, [LocalUIElementCandidate]()) }
        )
        let limits = Self.debugOverlayAccessibilityLimits
        var occludingWindowBounds: [WindowTargetBounds] = []
        var visibleWindowIndex = 0
        var pendingCandidateCount = 0
        var publishSequence = 0
        var lastPublishUptime = ProcessInfo.processInfo.systemUptime

        func publishPartial(force: Bool, target: MacWindowTargetCandidate) {
            let now = ProcessInfo.processInfo.systemUptime
            guard force || pendingCandidateCount >= 8 || now - lastPublishUptime >= 0.045 else {
                return
            }
            pendingCandidateCount = 0
            lastPublishUptime = now
            publishSequence += 1
            let results = inspectionResults(
                screens: screens,
                candidatesByScreenID: candidatesByScreenID,
                minConfidence: minConfidence,
                fingerprintSalt: "progress-\(publishSequence)"
            )
            guard results.contains(where: { !$0.frame.elements.isEmpty }) else {
                return
            }
            onPartialResults(results)
        }

        for target in targets {
            var windowBounds = target.bounds
            var visibleWindowIsRenderable = false
            var partialControls: [LocalAppDiscoveredControl] = []
            var partialVisibleText: [String] = []
            var emittedCandidateIDs = Set<String>()

            let tree = try? progressiveCapturer.captureTree(
                target: target,
                limits: limits
            ) { node in
                if node.nodeID == "ax-1" {
                    windowBounds = node.frame ?? target.bounds
                    visibleWindowIsRenderable = Self.isVisible(
                        windowBounds,
                        occludingWindowBounds: occludingWindowBounds
                    )
                    if visibleWindowIsRenderable {
                        for screen in screens where Self.intersects(windowBounds, screen.captureFrame) {
                            if let candidate = windowCandidate(
                                target: target,
                                windowBounds: windowBounds,
                                screen: screen,
                                visibleWindowIndex: visibleWindowIndex
                            ), emittedCandidateIDs.insert(candidate.id).inserted {
                                candidatesByScreenID[screen.screenID, default: []].append(candidate)
                                pendingCandidateCount += 1
                            }
                        }
                        publishPartial(force: true, target: target)
                    }
                    return
                }

                if let text = controlDiscovery.visibleText(for: node) {
                    partialVisibleText.append(text)
                }
                if visibleWindowIsRenderable,
                   let candidate = broadAccessibilityCandidate(
                       for: node,
                       target: target,
                       windowBounds: windowBounds,
                       screens: screens,
                       occludingWindowBounds: occludingWindowBounds
                   ),
                   emittedCandidateIDs.insert(candidate.candidate.id).inserted {
                    candidatesByScreenID[candidate.screenID, default: []].append(candidate.candidate)
                    pendingCandidateCount += 1
                    publishPartial(force: false, target: target)
                }

                guard visibleWindowIsRenderable,
                      let control = controlDiscovery.control(for: node)
                else {
                    return
                }
                partialControls.append(control)

                guard let candidate = accessibilityCandidate(
                    for: control,
                    target: target,
                    windowBounds: windowBounds,
                    screens: screens,
                    occludingWindowBounds: occludingWindowBounds
                ), emittedCandidateIDs.insert(candidate.candidate.id).inserted
                else {
                    return
                }

                candidatesByScreenID[candidate.screenID, default: []].append(candidate.candidate)
                pendingCandidateCount += 1
                publishPartial(force: false, target: target)
            }

            guard let tree else {
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
            let finalWindowBounds = snapshot.root.frame ?? target.bounds
            defer { occludingWindowBounds.append(finalWindowBounds) }

            removeCandidates(for: target, from: &candidatesByScreenID)
            guard Self.isVisible(finalWindowBounds, occludingWindowBounds: occludingWindowBounds) else {
                continue
            }

            for screen in screens where Self.intersects(finalWindowBounds, screen.captureFrame) {
                if let candidate = windowCandidate(
                    target: target,
                    windowBounds: finalWindowBounds,
                    screen: screen,
                    visibleWindowIndex: visibleWindowIndex
                ) {
                    candidatesByScreenID[screen.screenID, default: []].append(candidate)
                }
            }
            visibleWindowIndex += 1

            let controlIndex = controlDiscovery.discover(in: snapshot)
            let controls = controlIndex.controls
            Self.logDiscoverySummary(
                target: target,
                snapshot: snapshot,
                controls: controls,
                visibleText: controlIndex.visibleText.isEmpty
                    ? partialVisibleText.joined(separator: " ")
                    : controlIndex.visibleText
            )
            for control in controls {
                guard let candidate = accessibilityCandidate(
                    for: control,
                    target: target,
                    windowBounds: finalWindowBounds,
                    screens: screens,
                    occludingWindowBounds: occludingWindowBounds
                ) else {
                    continue
                }
                candidatesByScreenID[candidate.screenID, default: []].append(candidate.candidate)
            }
            for candidate in broadAccessibilityCandidates(
                root: snapshot.root,
                target: target,
                windowBounds: finalWindowBounds,
                screens: screens,
                occludingWindowBounds: occludingWindowBounds
            ) {
                candidatesByScreenID[candidate.screenID, default: []].append(candidate.candidate)
            }
            pendingCandidateCount = 1
            publishPartial(force: true, target: target)
        }

        return inspectionResults(
            screens: screens,
            candidatesByScreenID: candidatesByScreenID,
            minConfidence: minConfidence,
            fingerprintSalt: "final"
        )
    }

    private func inspectionResults(
        screens: [DebugUIScreenMetadata],
        candidatesByScreenID: [UInt32: [LocalUIElementCandidate]],
        minConfidence: Double,
        fingerprintSalt: String
    ) -> [DebugUIAccessibilityInspectionResult] {
        return screens.map { screen in
            let fallbackSnapshot = DebugUIScreenCaptureSnapshot(
                screenID: screen.screenID,
                screenFrame: screen.appKitFrame,
                pixelSize: HotLoopSize(
                    width: screen.captureFrame.width,
                    height: screen.captureFrame.height,
                    space: .screen
                ),
                pngData: Data(),
                fingerprint: Self.fingerprint(
                    for: screen,
                    elements: []
                )
            )
            let snapshot = fallbackSnapshot
            let accessibilityCandidates = Self.scaleCandidates(
                candidatesByScreenID[screen.screenID] ?? [],
                from: screen.captureFrame,
                to: snapshot.pixelSize
            )
            let frame = DebugUIInspectionFrame(
                elements: accessibilityCandidates
                    .filter { $0.bounds.hasPositiveArea }
                    .map(Self.debugElementFromUnfilteredAccessibilityCandidate)
                    .sorted(by: Self.elementSort)
            )
            let fingerprint = Self.fingerprint(for: screen, elements: frame.elements)
            let outputSnapshot = DebugUIScreenCaptureSnapshot(
                screenID: snapshot.screenID,
                screenFrame: snapshot.screenFrame,
                pixelSize: snapshot.pixelSize,
                pngData: snapshot.pngData,
                fingerprint: "\(snapshot.fingerprint)-\(fingerprint)-\(fingerprintSalt)"
            )
            return DebugUIAccessibilityInspectionResult(snapshot: outputSnapshot, frame: frame)
        }
    }

    private func removeCandidates(
        for target: MacWindowTargetCandidate,
        from candidatesByScreenID: inout [UInt32: [LocalUIElementCandidate]]
    ) {
        let windowID = String(target.windowID)
        for screenID in candidatesByScreenID.keys {
            candidatesByScreenID[screenID]?.removeAll { candidate in
                candidate.metadata["target.windowID"] == windowID
            }
        }
    }

    private func accessibilityCandidatesByScreen(
        screens: [DebugUIScreenMetadata],
        targets: [MacWindowTargetCandidate]
    ) -> [UInt32: [LocalUIElementCandidate]] {
        var candidatesByScreenID = Dictionary(
            uniqueKeysWithValues: screens.map { ($0.screenID, [LocalUIElementCandidate]()) }
        )
        let limits = Self.debugOverlayAccessibilityLimits
        var occludingWindowBounds: [WindowTargetBounds] = []
        var visibleWindowIndex = 0

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
            defer { occludingWindowBounds.append(windowBounds) }

            guard Self.isVisible(windowBounds, occludingWindowBounds: occludingWindowBounds) else {
                continue
            }

            for screen in screens where Self.intersects(windowBounds, screen.captureFrame) {
                if let candidate = windowCandidate(
                    target: target,
                    windowBounds: windowBounds,
                    screen: screen,
                    visibleWindowIndex: visibleWindowIndex
                ) {
                    candidatesByScreenID[screen.screenID, default: []].append(candidate)
                }
            }
            visibleWindowIndex += 1

            let controlIndex = controlDiscovery.discover(in: snapshot)
            let controls = controlIndex.controls
            Self.logDiscoverySummary(
                target: target,
                snapshot: snapshot,
                controls: controls,
                visibleText: controlIndex.visibleText
            )
            for control in controls {
                guard let candidate = accessibilityCandidate(
                    for: control,
                    target: target,
                    windowBounds: windowBounds,
                    screens: screens,
                    occludingWindowBounds: occludingWindowBounds
                ) else {
                    continue
                }
                candidatesByScreenID[candidate.screenID, default: []].append(candidate.candidate)
            }
            for candidate in broadAccessibilityCandidates(
                root: snapshot.root,
                target: target,
                windowBounds: windowBounds,
                screens: screens,
                occludingWindowBounds: occludingWindowBounds
            ) {
                candidatesByScreenID[candidate.screenID, default: []].append(candidate.candidate)
            }
        }

        return candidatesByScreenID
    }

    private func windowCandidate(
        target: MacWindowTargetCandidate,
        windowBounds: WindowTargetBounds,
        screen: DebugUIScreenMetadata,
        visibleWindowIndex: Int
    ) -> LocalUIElementCandidate? {
        guard let bbox = DebugUIAccessibilityGeometry.boundingBox(
            for: windowBounds,
            screenFrame: screen.captureFrame
        ) else {
            return nil
        }

        let label = Self.windowLabel(for: target)
        return LocalUIElementCandidate(
            id: "window-\(target.windowID)",
            source: .accessibility,
            signalKind: .accessibilityRole,
            typeHint: .draggable,
            label: label,
            role: "AXWindow",
            bounds: HotLoopRect(
                x: bbox.x,
                y: bbox.y,
                width: bbox.width,
                height: bbox.height,
                space: .screen
            ),
            confidence: 1,
            metadata: [
                "target.windowID": String(target.windowID),
                "target.appName": target.appName ?? "",
                "target.title": target.title ?? "",
                "windowFrameStyle.index": String(visibleWindowIndex),
                "classification.reason": "accessibilityWindowFrame"
            ]
            .merging(Self.boundsMetadata(prefix: "target.bounds.", bounds: target.bounds)) { current, _ in current }
            .merging(Self.boundsMetadata(prefix: "debugOverlay.localBounds.", bounds: Self.localBounds(for: windowBounds, in: target.bounds))) { current, _ in current }
        )
    }

    private static func scaleCandidates(
        _ candidates: [LocalUIElementCandidate],
        from captureFrame: WindowTargetBounds,
        to pixelSize: HotLoopSize
    ) -> [LocalUIElementCandidate] {
        guard captureFrame.width > 0,
              captureFrame.height > 0,
              pixelSize.width > 0,
              pixelSize.height > 0
        else {
            return candidates
        }

        let scaleX = pixelSize.width / captureFrame.width
        let scaleY = pixelSize.height / captureFrame.height
        guard abs(scaleX - 1) > 0.0001 || abs(scaleY - 1) > 0.0001 else {
            return candidates
        }

        return candidates.map { candidate in
            var scaled = candidate
            scaled.bounds = HotLoopRect(
                x: candidate.bounds.origin.x * scaleX,
                y: candidate.bounds.origin.y * scaleY,
                width: candidate.bounds.size.width * scaleX,
                height: candidate.bounds.size.height * scaleY,
                space: pixelSize.space
            )
            scaled.metadata = candidate.metadata.merging([
                "coordinate.scaleX": String(format: "%.6f", scaleX),
                "coordinate.scaleY": String(format: "%.6f", scaleY),
                "coordinate.source.width": String(captureFrame.width),
                "coordinate.source.height": String(captureFrame.height),
                "coordinate.target.width": String(pixelSize.width),
                "coordinate.target.height": String(pixelSize.height)
            ]) { current, _ in current }
            return scaled
        }
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
        let limits = Self.debugOverlayAccessibilityLimits
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
                        visualStyle: visualStyle,
                        metadata: [
                            "target.windowID": String(target.windowID),
                            "target.appName": target.appName ?? "",
                            "target.title": target.title ?? "",
                            "classification.reason": "accessibilityWindowFrame"
                        ]
                        .merging(Self.boundsMetadata(prefix: "target.bounds.", bounds: target.bounds)) { current, _ in current }
                        .merging(Self.boundsMetadata(prefix: "debugOverlay.localBounds.", bounds: Self.localBounds(for: windowBounds, in: target.bounds))) { current, _ in current }
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
        on screens: [DebugUIScreenMetadata],
        frontmostOnly: Bool = false,
        focusedOnly: Bool = false,
        targetBundleIdentifiers: [String] = [],
        targetAppNames: [String] = []
    ) -> [MacWindowTargetCandidate] {
        let bundleFilters = Set(targetBundleIdentifiers.map(Self.normalizedTargetFilter))
        let appNameFilters = Set(targetAppNames.map(Self.normalizedTargetFilter))
        return windowResolver.enumerateCandidates()
            .filter { target in
                target.isVisible
                    && target.isOnScreen
                    && (!frontmostOnly || target.isFrontmost)
                    && (!focusedOnly || target.isFocused)
                    && Self.matchesTargetFilter(
                        target,
                        bundleFilters: bundleFilters,
                        appNameFilters: appNameFilters
                    )
                    && target.safetyAssessment.status == .allowed
                    && !target.isIPhoneMirroring
                    && target.processID != currentProcessID
                    && screens.contains { screen in
                        Self.intersects(target.bounds, screen.captureFrame)
                    }
            }
    }

    private static func matchesTargetFilter(
        _ target: MacWindowTargetCandidate,
        bundleFilters: Set<String>,
        appNameFilters: Set<String>
    ) -> Bool {
        guard !bundleFilters.isEmpty || !appNameFilters.isEmpty else {
            return true
        }
        if let bundleIdentifier = target.bundleIdentifier,
           bundleFilters.contains(normalizedTargetFilter(bundleIdentifier)) {
            return true
        }
        if let appName = target.appName,
           appNameFilters.contains(normalizedTargetFilter(appName)) {
            return true
        }
        return false
    }

    private static func normalizedTargetFilter(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
                confidence: 1,
                metadata: [
                    "target.windowID": String(target.windowID),
                    "target.appName": target.appName ?? "",
                    "target.title": target.title ?? "",
                    "classification.reason": "accessibilityControlDiscovery"
                ]
                .merging(Self.boundsMetadata(prefix: "target.bounds.", bounds: target.bounds)) { current, _ in current }
                .merging(Self.boundsMetadata(prefix: "debugOverlay.localBounds.", bounds: Self.localBounds(for: bounds, in: target.bounds))) { current, _ in current }
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
        case .link:
            return .link
        case .menuItem:
            return .menuItem
        case .listItem:
            return .listItem
        case .group:
            return control.actions.contains("AXPress") ? .button : .listItem
        case .unknown:
            return nil
        }
    }

    private static func broadElementType(forRole role: String) -> DebugUIElementType? {
        switch role {
        case "AXRow", "AXOutlineRow", "AXCell", "AXGroup", "AXImage", "AXStaticText":
            return .listItem
        case "AXButton", "AXMenuButton":
            return .button
        case "AXLink":
            return .link
        case "AXMenuItem":
            return .menuItem
        case "AXSearchField", "AXTextField", "AXTextArea", "AXComboBox":
            return .input
        case "AXCheckBox", "AXRadioButton":
            return .checkbox
        default:
            return .other
        }
    }

    private static func broadLabel(
        for node: MacAccessibilitySnapshotNode,
        role: String
    ) -> String? {
        if let label = [node.label, node.title, node.valueSummary]
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return label
        }

        var labels: [String] = []
        collectLabels(node, labels: &labels)
        let descendantLabel = labels
            .prefix(8)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !descendantLabel.isEmpty {
            return descendantLabel
        }

        if role == "AXImage" {
            return "image"
        }
        return "\(role) \(node.nodeID)"
    }

    private static func collectLabels(
        _ node: MacAccessibilitySnapshotNode,
        labels: inout [String]
    ) {
        for child in node.children {
            if let label = [child.label, child.title, child.valueSummary]
                .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }) {
                labels.append(label)
            }
            collectLabels(child, labels: &labels)
        }
    }

    private func accessibilityCandidate(
        for control: LocalAppDiscoveredControl,
        target: MacWindowTargetCandidate,
        windowBounds: WindowTargetBounds,
        screens: [DebugUIScreenMetadata],
        occludingWindowBounds: [WindowTargetBounds]
    ) -> (screenID: UInt32, candidate: LocalUIElementCandidate)? {
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
            LocalUIElementCandidate(
                id: "ax-\(target.windowID)-\(control.id)",
                source: .accessibility,
                signalKind: .accessibilityRole,
                typeHint: type,
                label: label,
                role: control.role,
                bounds: HotLoopRect(
                    x: bbox.x,
                    y: bbox.y,
                    width: bbox.width,
                    height: bbox.height,
                    space: .screen
                ),
                confidence: 1,
                actions: control.actions,
                metadata: [
                    "target.windowID": String(target.windowID),
                    "target.appName": target.appName ?? "",
                    "target.title": target.title ?? "",
                    "accessibility.nodeID": control.id,
                    "accessibility.role": control.role ?? "",
                    "accessibility.actions": control.actions.joined(separator: ","),
                    "classification.reason": "accessibilityControlDiscovery"
                ]
                .merging(Self.boundsMetadata(prefix: "target.bounds.", bounds: target.bounds)) { current, _ in current }
                .merging(Self.boundsMetadata(prefix: "debugOverlay.localBounds.", bounds: Self.localBounds(for: bounds, in: target.bounds))) { current, _ in current }
                .merging(control.metadata) { current, _ in current }
            )
        )
    }

    private func broadAccessibilityCandidates(
        root: MacAccessibilitySnapshotNode,
        target: MacWindowTargetCandidate,
        windowBounds: WindowTargetBounds,
        screens: [DebugUIScreenMetadata],
        occludingWindowBounds: [WindowTargetBounds]
    ) -> [(screenID: UInt32, candidate: LocalUIElementCandidate)] {
        var candidates: [(screenID: UInt32, candidate: LocalUIElementCandidate)] = []
        collectBroadAccessibilityCandidates(
            node: root,
            target: target,
            windowBounds: windowBounds,
            screens: screens,
            occludingWindowBounds: occludingWindowBounds,
            candidates: &candidates
        )
        return candidates
    }

    private func collectBroadAccessibilityCandidates(
        node: MacAccessibilitySnapshotNode,
        target: MacWindowTargetCandidate,
        windowBounds: WindowTargetBounds,
        screens: [DebugUIScreenMetadata],
        occludingWindowBounds: [WindowTargetBounds],
        candidates: inout [(screenID: UInt32, candidate: LocalUIElementCandidate)]
    ) {
        if let candidate = broadAccessibilityCandidate(
            for: node,
            target: target,
            windowBounds: windowBounds,
            screens: screens,
            occludingWindowBounds: occludingWindowBounds
        ) {
            candidates.append(candidate)
        }

        for child in node.children {
            collectBroadAccessibilityCandidates(
                node: child,
                target: target,
                windowBounds: windowBounds,
                screens: screens,
                occludingWindowBounds: occludingWindowBounds,
                candidates: &candidates
            )
        }
    }

    private func broadAccessibilityCandidate(
        for node: MacAccessibilitySnapshotNode,
        target: MacWindowTargetCandidate,
        windowBounds: WindowTargetBounds,
        screens: [DebugUIScreenMetadata],
        occludingWindowBounds: [WindowTargetBounds]
    ) -> (screenID: UInt32, candidate: LocalUIElementCandidate)? {
        guard node.nodeID != "ax-1",
              let rawBounds = node.frame
        else {
            return nil
        }
        let role = node.role ?? "AXUnknown"
        let type = Self.broadElementType(forRole: role) ?? .other
        let label = Self.broadLabel(for: node, role: role) ?? "\(role) \(node.nodeID)"

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

        return (
            screen.screenID,
            LocalUIElementCandidate(
                id: "ax-node-\(target.windowID)-\(node.nodeID)",
                source: .accessibility,
                signalKind: role == "AXStaticText" ? .text : .accessibilityRole,
                typeHint: type,
                label: label,
                role: role,
                bounds: HotLoopRect(
                    x: bbox.x,
                    y: bbox.y,
                    width: bbox.width,
                    height: bbox.height,
                    space: .screen
                ),
                confidence: role == "AXStaticText" ? 0.82 : 0.9,
                actions: node.actions,
                metadata: [
                    "target.windowID": String(target.windowID),
                    "target.appName": target.appName ?? "",
                    "target.title": target.title ?? "",
                    "accessibility.nodeID": node.nodeID,
                    "accessibility.role": role,
                    "accessibility.actions": node.actions.joined(separator: ","),
                    "classification.reason": "accessibilityBroadNodeEvidence"
                ]
                .merging(Self.boundsMetadata(prefix: "target.bounds.", bounds: target.bounds)) { current, _ in current }
                .merging(Self.boundsMetadata(prefix: "debugOverlay.localBounds.", bounds: Self.localBounds(for: bounds, in: target.bounds))) { current, _ in current }
            )
        )
    }

    private static func debugElementFromUnfilteredAccessibilityCandidate(
        _ candidate: LocalUIElementCandidate
    ) -> DebugUIElement {
        let type = candidate.typeHint ?? .other
        let label = candidate.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackLabel = [
            candidate.role,
            candidate.metadata["accessibility.role"],
            candidate.id
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? type.rawValue
        return DebugUIElement(
            id: candidate.id,
            type: type,
            label: label?.isEmpty == false ? label! : fallbackLabel,
            description: [
                candidate.source.rawValue,
                candidate.signalKind.rawValue,
                candidate.role ?? ""
            ].filter { !$0.isEmpty }.joined(separator: " "),
            bbox: DebugUIBoundingBox(
                x: candidate.bounds.origin.x,
                y: candidate.bounds.origin.y,
                width: candidate.bounds.size.width,
                height: candidate.bounds.size.height
            ),
            confidence: candidate.confidence,
            visualStyle: DebugUIOverlayStyle.style(for: type),
            metadata: candidate.metadata.merging([
                "debugOverlay.unfilteredAccessibility": "true",
                "localUIElement.sources": candidate.source.rawValue,
                "localUIElement.reasonCodes": [
                    "\(candidate.source.rawValue).\(candidate.signalKind.rawValue)",
                    "debugUnfilteredAX"
                ].joined(separator: ",")
            ]) { current, _ in current }
        )
    }

    private static func isWindowControl(_ control: LocalAppDiscoveredControl) -> Bool {
        let label = control.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["close", "minimize", "zoom", "fullscreen", "full screen"].contains(label)
    }

    private static func isToolbarControl(_ control: LocalAppDiscoveredControl) -> Bool {
        guard control.kind == .button else { return false }
        let role = control.role ?? ""
        guard role == "AXButton" else { return false }
        guard let frame = control.frame else {
            return control.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return frame.width <= 72 && frame.height <= 56
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

    private static func logDiscoverySummary(
        target: MacWindowTargetCandidate,
        snapshot: MacAccessibilitySnapshot,
        controls: [LocalAppDiscoveredControl],
        visibleText: String
    ) {
        _ = target
        _ = snapshot
        _ = controls
        _ = visibleText
    }

    private static func controlKindSummary(_ controls: [LocalAppDiscoveredControl]) -> String {
        let counts = Dictionary(grouping: controls, by: \.kind)
            .mapValues(\.count)
        return counts
            .sorted { lhs, rhs in lhs.key.rawValue < rhs.key.rawValue }
            .map { "\($0.key.rawValue):\($0.value)" }
            .joined(separator: ",")
    }

    private static func roleSummary(_ root: MacAccessibilitySnapshotNode) -> String {
        var counts: [String: Int] = [:]
        collectRoles(root, counts: &counts)
        return counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(12)
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
    }

    private static func collectRoles(
        _ node: MacAccessibilitySnapshotNode,
        counts: inout [String: Int]
    ) {
        let role = node.role ?? "nil"
        counts[role, default: 0] += 1
        for child in node.children {
            collectRoles(child, counts: &counts)
        }
    }

    private static func localBounds(
        for bounds: WindowTargetBounds,
        in targetBounds: WindowTargetBounds
    ) -> WindowTargetBounds {
        WindowTargetBounds(
            x: bounds.x - targetBounds.x,
            y: bounds.y - targetBounds.y,
            width: bounds.width,
            height: bounds.height
        )
    }

    private static func boundsMetadata(
        prefix: String,
        bounds: WindowTargetBounds
    ) -> [String: String] {
        [
            prefix + "x": String(bounds.x),
            prefix + "y": String(bounds.y),
            prefix + "width": String(bounds.width),
            prefix + "height": String(bounds.height)
        ]
    }

    private static func describe(_ bounds: WindowTargetBounds?) -> String {
        guard let bounds else { return "nil" }
        return describe(bounds)
    }

    private static func describe(_ bounds: WindowTargetBounds) -> String {
        String(
            format: "x=%.1f y=%.1f w=%.1f h=%.1f",
            bounds.x,
            bounds.y,
            bounds.width,
            bounds.height
        )
    }

    private static func windowFrameStyle(at index: Int) -> DebugUIOverlayStyle {
        windowFrameStyles[index % windowFrameStyles.count]
    }

    private static let debugOverlayAccessibilityLimits = MacAccessibilitySnapshotLimits(
        maxDepth: 32,
        maxChildrenPerNode: 10_000,
        maxTotalNodes: 50_000,
        maxTextLength: 300
    )

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
                return try Self.fallbackDisplayIDs(scope: scope).map(Self.metadata(for:))
            }
            screens = [screen]
        case .all:
            screens = NSScreen.screens
        }

        if screens.isEmpty {
            return try Self.fallbackDisplayIDs(scope: scope).map(Self.metadata(for:))
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

    private static func metadata(for displayID: CGDirectDisplayID) -> DebugUIScreenMetadata {
        let captureFrame = CGDisplayBounds(displayID)
        let bounds = WindowTargetBounds(
            x: captureFrame.origin.x,
            y: captureFrame.origin.y,
            width: captureFrame.width,
            height: captureFrame.height
        )
        return DebugUIScreenMetadata(
            screenID: displayID,
            appKitFrame: HotLoopRect(
                x: bounds.x,
                y: bounds.y,
                width: bounds.width,
                height: bounds.height,
                space: .screen
            ),
            captureFrame: bounds
        )
    }

    private static func fallbackDisplayIDs(scope: DebugUIInspectionScreenScope) throws -> [CGDirectDisplayID] {
        switch scope {
        case .main:
            let displayID = CGMainDisplayID()
            guard displayID != 0 else {
                throw DebugUIAccessibilityInspectionError.noScreenAvailable
            }
            return [displayID]
        case .all:
            var count: UInt32 = 0
            CGGetActiveDisplayList(0, nil, &count)
            guard count > 0 else {
                throw DebugUIAccessibilityInspectionError.noScreenAvailable
            }
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
            CGGetActiveDisplayList(count, &displays, &count)
            return Array(displays.prefix(Int(count))).filter { $0 != 0 }
        }
    }
}

private struct EmptyDebugUIScreenCapturer: DebugUIScreenCapturing {
    func captureScreens(
        scope: DebugUIInspectionScreenScope
    ) throws -> [DebugUIScreenCaptureSnapshot] {
        []
    }
}

private extension LocalUIElementDetectionTrace {
    func clippedToTargetWindows(
        _ targetWindowBounds: [WindowTargetBounds]
    ) -> LocalUIElementDetectionTrace {
        guard !targetWindowBounds.isEmpty else {
            return self
        }
        let hasAccessibilityControls = elements.contains { element in
            element.sources.contains(.accessibility) && element.type != .draggable
        }
        var copy = self
        copy.elements = elements.compactMap { element in
            guard let window = Self.bestWindow(for: element, in: targetWindowBounds),
                  let clippedBounds = Self.intersection(element.bounds, window)
            else {
                return nil
            }
            guard clippedBounds.size.width >= 4, clippedBounds.size.height >= 4 else {
                return nil
            }

            if !element.sources.contains(.accessibility),
               element.sources.contains(.layout),
               !Self.contains(window, element.bounds, tolerance: 8) {
                return nil
            }
            if hasAccessibilityControls,
               !element.sources.contains(.accessibility),
               !element.sources.contains(.template),
               !element.sources.contains(.hoverProbe),
               element.confidence < 0.75 {
                return nil
            }

            var clipped = element
            clipped.bounds = clippedBounds
            if !Self.nearlyEqual(clippedBounds, element.bounds) {
                clipped.metadata = clipped.metadata.merging([
                    "debugUIElement.clippedToTargetWindow": "true"
                ]) { current, _ in current }
            }
            return clipped
        }
        return copy
    }

    static func bestWindow(
        for element: LocalUIElement,
        in windows: [WindowTargetBounds]
    ) -> WindowTargetBounds? {
        windows
            .compactMap { window -> (window: WindowTargetBounds, overlap: Double)? in
                guard let intersection = intersection(element.bounds, window) else {
                    return nil
                }
                let overlap = intersection.size.width * intersection.size.height
                return overlap > 0 ? (window, overlap) : nil
            }
            .max { lhs, rhs in lhs.overlap < rhs.overlap }?
            .window
    }

    static func intersection(
        _ elementBounds: HotLoopRect,
        _ windowBounds: WindowTargetBounds
    ) -> HotLoopRect? {
        let minX = max(elementBounds.origin.x, windowBounds.x)
        let minY = max(elementBounds.origin.y, windowBounds.y)
        let maxX = min(
            elementBounds.origin.x + elementBounds.size.width,
            windowBounds.x + windowBounds.width
        )
        let maxY = min(
            elementBounds.origin.y + elementBounds.size.height,
            windowBounds.y + windowBounds.height
        )
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0, height > 0 else {
            return nil
        }
        return HotLoopRect(
            x: minX,
            y: minY,
            width: width,
            height: height,
            space: elementBounds.space
        )
    }

    static func nearlyEqual(
        _ lhs: HotLoopRect,
        _ rhs: HotLoopRect
    ) -> Bool {
        lhs.space == rhs.space
            && abs(lhs.origin.x - rhs.origin.x) <= 0.001
            && abs(lhs.origin.y - rhs.origin.y) <= 0.001
            && abs(lhs.size.width - rhs.size.width) <= 0.001
            && abs(lhs.size.height - rhs.size.height) <= 0.001
    }

    static func contains(
        _ windowBounds: WindowTargetBounds,
        _ elementBounds: HotLoopRect,
        tolerance: Double
    ) -> Bool {
        let minX = windowBounds.x - tolerance
        let minY = windowBounds.y - tolerance
        let maxX = windowBounds.x + windowBounds.width + tolerance
        let maxY = windowBounds.y + windowBounds.height + tolerance
        return elementBounds.origin.x >= minX
            && elementBounds.origin.y >= minY
            && elementBounds.origin.x + elementBounds.size.width <= maxX
            && elementBounds.origin.y + elementBounds.size.height <= maxY
    }

    static func substantialOverlap(
        _ elementBounds: HotLoopRect,
        _ windowBounds: WindowTargetBounds
    ) -> Bool {
        guard let intersection = intersection(elementBounds, windowBounds) else {
            return false
        }
        let overlap = intersection.size.width * intersection.size.height
        let area = elementBounds.size.width * elementBounds.size.height
        return area > 0 && overlap / area >= 0.72
    }
}
