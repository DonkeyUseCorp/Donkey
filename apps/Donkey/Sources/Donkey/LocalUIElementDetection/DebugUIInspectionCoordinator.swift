#if DONKEY_DEBUG_OVERLAY

import AppKit
import CryptoKit
import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

private enum DebugUIInspectionLog {
    static let overlay = Logger(subsystem: "com.donkey.app", category: "debug-ui-inspection")
}

@MainActor
final class DebugUIInspectionCoordinator {
    private let overlayController = DebugUIInspectionOverlayController()
    private let captureService = DebugUIScreenCaptureService()
    private let accessibilityInspectionService = DebugUIAccessibilityInspectionService()
    private let windowResolver = MacWindowResolver()
    private let windowScreenshotCapturer = ScreenCaptureKitWindowScreenshotCapturer()
    private let configURL: URL?
    private var analyzer: (any DebugUIInspectionAnalyzing)?
    private var trackers: [UInt32: DebugUIElementTracker] = [:]
    private var lastFingerprints: [UInt32: String] = [:]
    private var lastRenderedFrames: [UInt32: DebugUIInspectionFrame] = [:]
    private var lastSnapshots: [UInt32: DebugUIScreenCaptureSnapshot] = [:]
    private var timer: Timer?
    private var activeAccessibilityTimer: Timer?
    private var notificationObservers: [NSObjectProtocol] = []
    private var movementEventMonitors: [Any] = []
    private var currentConfig: DebugUIOverlayConfiguration = .disabled
    private var isAnalyzing = false
    private var isRefreshingActiveAccessibility = false

    init(configURL: URL? = nil) {
        self.configURL = configURL
    }

    func start() {
        DebugUIInspectionLog.overlay.info(
            "debug inspection starting configURL=\(self.configURL?.path ?? "candidate-search", privacy: .public)"
        )
        stop()
        installNotificationObservers()
        reloadConfigAndReschedule(force: true)
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        activeAccessibilityTimer?.invalidate()
        activeAccessibilityTimer = nil
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        for monitor in movementEventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        notificationObservers.removeAll()
        movementEventMonitors.removeAll()
        overlayController.close()
        trackers.removeAll()
        lastFingerprints.removeAll()
        lastRenderedFrames.removeAll()
        lastSnapshots.removeAll()
        isAnalyzing = false
        isRefreshingActiveAccessibility = false
        currentConfig = .disabled
    }

    private func installNotificationObservers() {
        let appNotificationNames: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didChangeScreenParametersNotification
        ]
        notificationObservers = appNotificationNames.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh(force: true)
                }
            }
        }
        let workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(force: true)
            }
        }
        notificationObservers.append(workspaceObserver)

        let movementMask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: movementMask, handler: { [weak self] _ in
            Task { @MainActor in
                self?.reprojectRenderedFramesFromCurrentWindowBounds()
            }
        }) {
            movementEventMonitors.append(globalMonitor)
        }
        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: movementMask, handler: { [weak self] event in
            Task { @MainActor in
                self?.reprojectRenderedFramesFromCurrentWindowBounds()
            }
            return event
        }) {
            movementEventMonitors.append(localMonitor)
        }
    }

    private func reloadConfigAndReschedule(force: Bool = false) {
        let newConfig = DebugUIOverlayConfiguration.load(fileURL: configURL)
        let cadenceChanged = newConfig.cadenceSeconds != currentConfig.cadenceSeconds
        let enablementChanged = newConfig.enabled != currentConfig.enabled
        let scopeChanged = newConfig.screenScope != currentConfig.screenScope
        let modeChanged = newConfig.mode != currentConfig.mode
        let confidenceChanged = newConfig.minConfidence != currentConfig.minConfidence
        let activeWindowChanged = newConfig.activeWindowOnly != currentConfig.activeWindowOnly
        let targetFilterChanged = newConfig.targetBundleIdentifiers != currentConfig.targetBundleIdentifiers
            || newConfig.targetAppNames != currentConfig.targetAppNames
        currentConfig = newConfig

        if force || enablementChanged || scopeChanged || modeChanged || confidenceChanged || activeWindowChanged || targetFilterChanged {
            DebugUIInspectionLog.overlay.info(
                "debug inspection config enabled=\(String(newConfig.enabled), privacy: .public) mode=\(newConfig.mode, privacy: .public) cadence=\(newConfig.cadenceSeconds, privacy: .public) scope=\(newConfig.screenScope.rawValue, privacy: .public) minConfidence=\(newConfig.minConfidence, privacy: .public) activeWindowOnly=\(String(newConfig.activeWindowOnly), privacy: .public) targetBundles=\(newConfig.targetBundleIdentifiers.joined(separator: ","), privacy: .public) targetApps=\(newConfig.targetAppNames.joined(separator: ","), privacy: .public)"
            )
        }

        if cadenceChanged || timer == nil || force {
            timer?.invalidate()
            let newTimer = Timer(timeInterval: newConfig.cadenceSeconds, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
            timer = newTimer
            RunLoop.main.add(newTimer, forMode: .common)
        }

        if newConfig.enabled {
            if activeAccessibilityTimer == nil || force {
                activeAccessibilityTimer?.invalidate()
                let newTimer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.refreshActiveAccessibilityFrame()
                    }
                }
                activeAccessibilityTimer = newTimer
                RunLoop.main.add(newTimer, forMode: .common)
            }
        } else {
            activeAccessibilityTimer?.invalidate()
            activeAccessibilityTimer = nil
        }

        if enablementChanged || scopeChanged || modeChanged || confidenceChanged || activeWindowChanged || targetFilterChanged {
            lastFingerprints.removeAll()
            trackers.removeAll()
            lastRenderedFrames.removeAll()
            lastSnapshots.removeAll()
            if !newConfig.enabled {
                overlayController.close()
            }
        }
    }

    private func refresh(force: Bool = false) {
        reloadConfigAndReschedule()
        guard currentConfig.enabled else { return }
        guard !isAnalyzing else {
            DebugUIInspectionLog.overlay.debug("debug inspection skipped refresh because analysis is already running")
            return
        }

        isAnalyzing = true
        Task { @MainActor in
            defer { isAnalyzing = false }
            do {
                try await analyzeVisibleScreens(force: force)
            } catch {
                DebugUIInspectionLog.overlay.error(
                    "debug inspection failed error=\(String(describing: error), privacy: .public)"
                )
                if lastRenderedFrames.isEmpty {
                    overlayController.close()
                    lastFingerprints.removeAll()
                    trackers.removeAll()
                }
            }
        }
    }

    private func analyzeVisibleScreens(force: Bool) async throws {
        try await analyzeRemoteAIWindowScreens(force: force)
    }

    private func needsTrackerWarmup(screenID: UInt32) -> Bool {
        lastRenderedFrames[screenID]?.elements.isEmpty == true
    }

    private func renderFastLocalFrames(
        screens: [DebugUIScreenSurface],
        frames: [UInt32: DebugUIInspectionFrame],
        stage: String,
        force: Bool
    ) {
        for screen in screens {
            guard let frame = frames[screen.screenID],
                  !frame.elements.isEmpty
            else {
                continue
            }
            let fingerprint = Self.fingerprint(
                screenID: screen.screenID,
                captures: [],
                accessibilityFrame: frame
            )
            renderFastLocalFrame(
                screen: screen,
                frame: frame,
                fingerprint: "\(fingerprint)-\(stage)",
                stage: stage,
                force: force
            )
        }
    }

    private func renderFastLocalFrame(
        screen: DebugUIScreenSurface,
        frame: DebugUIInspectionFrame,
        fingerprint: String,
        stage: String,
        force: Bool
    ) {
        guard force || lastFingerprints[screen.screenID] != fingerprint || needsTrackerWarmup(screenID: screen.screenID) else {
            return
        }

        var tracker = trackers[screen.screenID] ?? DebugUIElementTracker()
        let trackedFrame = tracker.update(with: frame)
        trackers[screen.screenID] = tracker
        guard force
            || lastRenderedFrames[screen.screenID]?.isOverlayRenderEquivalent(to: trackedFrame) != true
        else {
            return
        }

        let snapshot = Self.screenPointSnapshot(screen: screen, fingerprint: fingerprint)
        lastFingerprints[screen.screenID] = fingerprint
        lastRenderedFrames[screen.screenID] = trackedFrame
        lastSnapshots[screen.screenID] = snapshot
        logLayoutDiagnostics(stage: stage, screen: screen, frame: trackedFrame, captures: [])
        overlayController.render(frame: trackedFrame, snapshot: snapshot)
    }

    private func refreshActiveAccessibilityFrame() {
        guard currentConfig.enabled,
              !isRefreshingActiveAccessibility,
              let screens = try? screenSurfaces(scope: currentConfig.screenScope)
        else {
            return
        }

        isRefreshingActiveAccessibility = true
        defer { isRefreshingActiveAccessibility = false }

        do {
            let results = try accessibilityInspectionService.inspectProgressively(
                scope: currentConfig.screenScope,
                minConfidence: currentConfig.minConfidence,
                frontmostOnly: true,
                focusedOnly: true,
                targetBundleIdentifiers: currentConfig.targetBundleIdentifiers,
                targetAppNames: currentConfig.targetAppNames
            ) { [weak self] partialResults in
                self?.renderActiveAccessibilityResults(
                    partialResults,
                    screens: screens,
                    stage: "active-accessibility-progress"
                )
            }
            renderActiveAccessibilityResults(
                results,
                screens: screens,
                stage: "active-accessibility"
            )
        } catch {
            DebugUIInspectionLog.overlay.debug(
                "debug inspection skipped active accessibility refresh error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    private func renderActiveAccessibilityResults(
        _ results: [DebugUIAccessibilityInspectionResult],
        screens: [DebugUIScreenSurface],
        stage: String
    ) {
        let frames = Dictionary(
            uniqueKeysWithValues: results.map { result in
                (
                    result.snapshot.screenID,
                    Self.frameInScreenPointSpace(
                        result.frame,
                        snapshot: result.snapshot
                    )
                )
            }
        )

        for screen in screens {
            guard let accessibilityFrame = frames[screen.screenID],
                  !accessibilityFrame.elements.isEmpty
            else {
                continue
            }

            let existing = lastRenderedFrames[screen.screenID] ?? DebugUIInspectionFrame()
            let progressiveAccessibilityFrame: DebugUIInspectionFrame
            if stage.contains("progress") {
                let incomingIDs = Set(accessibilityFrame.elements.map(\.id))
                let incomingWindowIDs = Set(accessibilityFrame.elements.compactMap(Self.windowID(for:)))
                let carriedAccessibilityElements = existing.elements.filter { element in
                    guard Self.isAccessibilityEvidence(element),
                          !incomingIDs.contains(element.id),
                          let windowID = Self.windowID(for: element)
                    else {
                        return false
                    }
                    return incomingWindowIDs.contains(windowID)
                }
                progressiveAccessibilityFrame = DebugUIInspectionFrame(
                    elements: carriedAccessibilityElements + accessibilityFrame.elements
                )
            } else {
                progressiveAccessibilityFrame = accessibilityFrame
            }
            let nonAccessibilityFrame = DebugUIInspectionFrame(
                elements: existing.elements.filter { !Self.isAccessibilityEvidence($0) }
            )
            let fusedFrame = DebugUIInspectionFrameFusion.fused(
                accessibilityFrame: progressiveAccessibilityFrame,
                aiFrame: nonAccessibilityFrame
            )
            guard !fusedFrame.elements.isEmpty,
                  lastRenderedFrames[screen.screenID]?.isOverlayRenderEquivalent(to: fusedFrame) != true
            else {
                continue
            }

            var tracker = trackers[screen.screenID] ?? DebugUIElementTracker()
            let trackedFrame = tracker.update(
                with: fusedFrame,
                renderNewElementsImmediately: true
            )
            trackers[screen.screenID] = tracker

            let snapshot = Self.screenPointSnapshot(
                screen: screen,
                fingerprint: "\(stage)-\(Self.frameSignature(trackedFrame))"
            )
            lastRenderedFrames[screen.screenID] = trackedFrame
            lastSnapshots[screen.screenID] = snapshot
            logLayoutDiagnostics(stage: stage, screen: screen, frame: trackedFrame, captures: [])
            overlayController.render(frame: trackedFrame, snapshot: snapshot)
        }
    }

    private func reprojectRenderedFramesFromCurrentWindowBounds() {
        guard currentConfig.enabled,
              !lastRenderedFrames.isEmpty,
              let screens = try? screenSurfaces(scope: currentConfig.screenScope)
        else {
            return
        }

        let candidates = Dictionary(
            uniqueKeysWithValues: windowResolver.enumerateCandidates()
                .filter { $0.isVisible && $0.isOnScreen && $0.safetyAssessment.status == .allowed }
                .map { ($0.windowID, $0) }
        )
        let screensByID = Dictionary(uniqueKeysWithValues: screens.map { ($0.screenID, $0) })
        var elementsByScreenID = Dictionary(
            uniqueKeysWithValues: screens.map { ($0.screenID, [DebugUIElement]()) }
        )
        var changed = false

        for (screenID, frame) in lastRenderedFrames {
            for element in frame.elements {
                guard let projected = Self.reproject(
                    element,
                    sourceScreen: screensByID[screenID],
                    currentWindowTargets: candidates,
                    screens: screens
                ) else {
                    if Self.windowID(for: element) == nil {
                        elementsByScreenID[screenID, default: []].append(element)
                    } else {
                        changed = true
                    }
                    continue
                }

                elementsByScreenID[projected.screenID, default: []].append(projected.element)
                changed = changed || projected.screenID != screenID || projected.element.bbox != element.bbox
            }
        }

        guard changed else { return }

        var activeScreenIDs = Set<UInt32>()
        for screen in screens {
            let elements = elementsByScreenID[screen.screenID] ?? []
            if elements.isEmpty {
                lastRenderedFrames.removeValue(forKey: screen.screenID)
                lastSnapshots.removeValue(forKey: screen.screenID)
                continue
            }

            activeScreenIDs.insert(screen.screenID)
            let frame = DebugUIInspectionFrame(elements: elements.sorted(by: Self.elementSort))
            let snapshot = Self.screenPointSnapshot(
                screen: screen,
                fingerprint: "window-geometry-\(Self.frameSignature(frame))"
            )
            lastRenderedFrames[screen.screenID] = frame
            lastSnapshots[screen.screenID] = snapshot
            logLayoutDiagnostics(stage: "window-geometry", screen: screen, frame: frame, captures: [])
            overlayController.render(frame: frame, snapshot: snapshot)
        }

        overlayController.closeScreens(except: activeScreenIDs)
    }

    private func analyzeRemoteAIWindowScreens(force: Bool) async throws {
        let screens = try screenSurfaces(scope: currentConfig.screenScope)
        let activeScreenIDs = Set(screens.map(\.screenID))
        overlayController.closeScreens(except: activeScreenIDs)
        lastRenderedFrames = lastRenderedFrames.filter { activeScreenIDs.contains($0.key) }
        let accessibilityFrames = accessibilityFramesForRemoteAIFusion()
        renderFastLocalFrames(
            screens: screens,
            frames: accessibilityFrames,
            stage: "accessibility",
            force: force
        )

        let targets = visibleOverlayTargets(on: screens)
        guard !targets.isEmpty else {
            ageMissingRemoteAIScreens(activeScreenIDs: Set(accessibilityFrames.keys))
            for screen in screens where accessibilityFrames[screen.screenID] != nil {
                let accessibilityFrame = accessibilityFrames[screen.screenID] ?? DebugUIInspectionFrame()
                let fingerprint = Self.fingerprint(
                    screenID: screen.screenID,
                    captures: [],
                    accessibilityFrame: accessibilityFrame
                )
                guard force || lastFingerprints[screen.screenID] != fingerprint || needsTrackerWarmup(screenID: screen.screenID) else {
                    continue
                }
                lastFingerprints[screen.screenID] = fingerprint
                var tracker = trackers[screen.screenID] ?? DebugUIElementTracker()
                let trackedFrame = tracker.update(with: accessibilityFrame)
                trackers[screen.screenID] = tracker
                let snapshot = Self.screenPointSnapshot(screen: screen, fingerprint: fingerprint)
                lastRenderedFrames[screen.screenID] = trackedFrame
                lastSnapshots[screen.screenID] = snapshot
                logLayoutDiagnostics(stage: "accessibility-fallback", screen: screen, frame: trackedFrame, captures: [])
                overlayController.render(frame: trackedFrame, snapshot: snapshot)
            }
            return
        }

        let client = try backendInferenceClient()
        var captures: [DebugUIWindowCapture] = []
        for target in targets {
            do {
                let screenshot = try await windowScreenshotCapturer.capture(target: target)
                let compressed = Self.compressedRemoteAIImage(from: screenshot)
                captures.append(
                    DebugUIWindowCapture(
                        target: target,
                        screenshot: screenshot,
                        parseImageData: compressed.data,
                        parseContentType: compressed.contentType,
                        parsePixelSize: compressed.pixelSize
                    )
                )
            } catch {
                DebugUIInspectionLog.overlay.error(
                    "debug inspection skipped remote AI windowID=\(target.windowID, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
            }
        }

        let renderedScreenIDs = Set(captures.flatMap { capture in
            screens.filter { Self.intersects(capture.target.bounds, $0.captureFrame) }.map(\.screenID)
        }).union(accessibilityFrames.keys)
        ageMissingRemoteAIScreens(activeScreenIDs: renderedScreenIDs)

        for screen in screens where renderedScreenIDs.contains(screen.screenID) {
            let screenBounds = screen.captureFrame
            let screenCaptures = captures.filter { Self.intersects($0.target.bounds, screenBounds) }
            let accessibilityFrame = accessibilityFrames[screen.screenID] ?? DebugUIInspectionFrame()
            let fingerprint = Self.fingerprint(
                screenID: screen.screenID,
                captures: screenCaptures,
                accessibilityFrame: accessibilityFrame
            )
            guard force || lastFingerprints[screen.screenID] != fingerprint || needsTrackerWarmup(screenID: screen.screenID) else {
                DebugUIInspectionLog.overlay.debug(
                    "debug inspection skipped unchanged remote AI screenID=\(screen.screenID, privacy: .public)"
                )
                continue
            }

            let localEvidenceFrame = accessibilityFrame

            let currentWindowIDs = Set(screenCaptures.map(\.target.windowID))
            var elements = (lastRenderedFrames[screen.screenID]?.elements ?? [])
                .filter { element in
                    guard !Self.isAccessibilityEvidence(element) else { return false }
                    guard let windowID = Self.windowID(for: element) else { return true }
                    return currentWindowIDs.contains(windowID)
                }

            func renderRemoteAIFrame(stage: String, updatesFingerprint: Bool) {
                var tracker = trackers[screen.screenID] ?? DebugUIElementTracker()
                let remoteAIFrame = DebugUIInspectionFrame(elements: elements)
                let fusedFrame = DebugUIInspectionFrameFusion.fused(
                    accessibilityFrame: localEvidenceFrame,
                    aiFrame: remoteAIFrame
                )
                let trackedFrame = tracker.update(
                    with: fusedFrame,
                    renderNewElementsImmediately: true
                )
                trackers[screen.screenID] = tracker
                if !force,
                   let previousFrame = lastRenderedFrames[screen.screenID],
                   trackedFrame.isOverlayRenderEquivalent(to: previousFrame) {
                    DebugUIInspectionLog.overlay.debug(
                        "debug inspection skipped stable \(stage, privacy: .public) render screenID=\(screen.screenID, privacy: .public)"
                    )
                    return
                }

                let snapshot = Self.screenPointSnapshot(
                    screen: screen,
                    fingerprint: updatesFingerprint ? fingerprint : "\(fingerprint)-\(stage)-\(Self.frameSignature(trackedFrame))"
                )
                logLayoutDiagnostics(stage: stage, screen: screen, frame: trackedFrame, captures: screenCaptures)
                if updatesFingerprint {
                    lastFingerprints[screen.screenID] = fingerprint
                }
                lastRenderedFrames[screen.screenID] = trackedFrame
                lastSnapshots[screen.screenID] = snapshot
                overlayController.render(frame: trackedFrame, snapshot: snapshot)
            }

            for capture in screenCaptures {
                let capturePixelSize = HotLoopSize(
                    width: capture.parsePixelSize.width,
                    height: capture.parsePixelSize.height,
                    space: .window
                )
                let request = LocalUIUnderstandingRequest(
                    traceID: "debug-ui-ai-\(screen.screenID)-\(capture.target.windowID)-\(fingerprint)",
                    targetID: "window-\(capture.target.windowID)",
                    imageFileURL: nil,
                    cropBounds: HotLoopRect(
                        x: 0,
                        y: 0,
                        width: capturePixelSize.width,
                        height: capturePixelSize.height,
                        space: .window
                    ),
                    pixelSize: capturePixelSize,
                    metadata: [
                        "source": "debug-ui-inspection-overlay",
                        "screenshot.scope": "targetWindow",
                        "screenshot.desktopCaptureAllowed": "false",
                        "target.windowID": String(capture.target.windowID),
                        "target.processID": String(capture.target.processID),
                        "target.appName": capture.target.appName ?? "",
                        "target.bundleIdentifier": capture.target.bundleIdentifier ?? "",
                        "target.title": capture.target.title ?? "",
                        "target.bounds.x": String(capture.target.bounds.x),
                        "target.bounds.y": String(capture.target.bounds.y),
                        "target.bounds.width": String(capture.target.bounds.width),
                        "target.bounds.height": String(capture.target.bounds.height),
                        "capture.method": capture.screenshot.captureMethod.rawValue,
                        "capture.coordinateSpace": capture.screenshot.coordinateSpace,
                        "capture.originalBytes": String(capture.screenshot.pngData.count),
                        "capture.parseBytes": String(capture.parseImageData.count),
                        "capture.parseContentType": capture.parseContentType,
                        "capture.parseWidth": String(Int(capture.parsePixelSize.width.rounded())),
                        "capture.parseHeight": String(Int(capture.parsePixelSize.height.rounded()))
                    ]
                )
                do {
                    let result = try await client.parseScreenshotStream(
                        request,
                        imageData: capture.parseImageData,
                        contentType: capture.parseContentType
                    ) { partialResult in
                        let parsedElements = ScreenshotParseDebugUIOverlayMapper.frame(
                            from: partialResult,
                            target: capture.target,
                            capturePixelSize: capturePixelSize,
                            screenFrame: screenBounds,
                            minConfidence: self.currentConfig.minConfidence
                        ).elements
                        elements.removeAll { Self.windowID(for: $0) == capture.target.windowID }
                        elements += parsedElements
                        renderRemoteAIFrame(stage: "ai-progress", updatesFingerprint: false)
                    }
                    let parsedElements = ScreenshotParseDebugUIOverlayMapper.frame(
                        from: result,
                        target: capture.target,
                        capturePixelSize: capturePixelSize,
                        screenFrame: screenBounds,
                        minConfidence: currentConfig.minConfidence
                    ).elements
                    elements.removeAll { Self.windowID(for: $0) == capture.target.windowID }
                    elements += parsedElements
                    renderRemoteAIFrame(stage: "ai-progress", updatesFingerprint: false)
                } catch {
                    DebugUIInspectionLog.overlay.error(
                        "debug inspection remote AI parse failed windowID=\(capture.target.windowID, privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                }
            }

            renderRemoteAIFrame(stage: "ai-fused", updatesFingerprint: true)
        }
    }

    private func accessibilityFramesForRemoteAIFusion() -> [UInt32: DebugUIInspectionFrame] {
        do {
            let results = try accessibilityInspectionService.inspect(
                scope: currentConfig.screenScope,
                minConfidence: currentConfig.minConfidence,
                frontmostOnly: currentConfig.activeWindowOnly,
                focusedOnly: currentConfig.activeWindowOnly,
                targetBundleIdentifiers: currentConfig.targetBundleIdentifiers,
                targetAppNames: currentConfig.targetAppNames
            )
            return Dictionary(
                uniqueKeysWithValues: results.map { result in
                    (
                        result.snapshot.screenID,
                        Self.frameInScreenPointSpace(
                            result.frame,
                            snapshot: result.snapshot
                        )
                    )
                }
            )
        } catch {
            DebugUIInspectionLog.overlay.info(
                "debug inspection skipped accessibility fusion error=\(String(describing: error), privacy: .public)"
            )
            return [:]
        }
    }

    private func activeAccessibilityFrames() -> [UInt32: DebugUIInspectionFrame] {
        do {
            let results = try accessibilityInspectionService.inspect(
                scope: currentConfig.screenScope,
                minConfidence: currentConfig.minConfidence,
                frontmostOnly: true,
                focusedOnly: true,
                targetBundleIdentifiers: currentConfig.targetBundleIdentifiers,
                targetAppNames: currentConfig.targetAppNames
            )
            return Dictionary(
                uniqueKeysWithValues: results.map { result in
                    (
                        result.snapshot.screenID,
                        Self.frameInScreenPointSpace(
                            result.frame,
                            snapshot: result.snapshot
                        )
                    )
                }
            )
        } catch {
            DebugUIInspectionLog.overlay.debug(
                "debug inspection skipped active accessibility refresh error=\(String(describing: error), privacy: .public)"
            )
            return [:]
        }
    }

    private static func frameInScreenPointSpace(
        _ frame: DebugUIInspectionFrame,
        snapshot: DebugUIScreenCaptureSnapshot
    ) -> DebugUIInspectionFrame {
        guard snapshot.pixelSize.width > 0,
              snapshot.pixelSize.height > 0,
              snapshot.screenFrame.size.width > 0,
              snapshot.screenFrame.size.height > 0
        else {
            return frame
        }

        let scaleX = snapshot.screenFrame.size.width / snapshot.pixelSize.width
        let scaleY = snapshot.screenFrame.size.height / snapshot.pixelSize.height
        guard abs(scaleX - 1) > 0.0001 || abs(scaleY - 1) > 0.0001 else {
            return frame
        }

        return DebugUIInspectionFrame(
            elements: frame.elements.map { element in
                DebugUIElement(
                    id: element.id,
                    type: element.type,
                    label: element.label,
                    description: element.description,
                    bbox: DebugUIBoundingBox(
                        x: element.bbox.x * scaleX,
                        y: element.bbox.y * scaleY,
                        width: element.bbox.width * scaleX,
                        height: element.bbox.height * scaleY
                    ),
                    confidence: element.confidence,
                    visualStyle: element.visualStyle,
                    metadata: element.metadata.merging([
                        "coordinate.fusionSpace": "screenPoints",
                        "coordinate.fusionScaleX": String(format: "%.6f", scaleX),
                        "coordinate.fusionScaleY": String(format: "%.6f", scaleY)
                    ]) { current, _ in current }
                )
            }
        )
    }

    private func analyzeAccessibilityScreens(force: Bool) throws {
        let results = try accessibilityInspectionService.inspect(
            scope: currentConfig.screenScope,
            minConfidence: currentConfig.minConfidence,
            frontmostOnly: currentConfig.activeWindowOnly,
            focusedOnly: currentConfig.activeWindowOnly,
            targetBundleIdentifiers: currentConfig.targetBundleIdentifiers,
            targetAppNames: currentConfig.targetAppNames
        )
        DebugUIInspectionLog.overlay.debug(
            "debug inspection accessibility screens=\(results.count, privacy: .public) force=\(String(force), privacy: .public)"
        )

        let activeScreenIDs = Set(results.map(\.snapshot.screenID))
        ageMissingAccessibilityScreens(activeScreenIDs: activeScreenIDs)

        for result in results {
            let snapshot = result.snapshot
            if !force, lastFingerprints[snapshot.screenID] == snapshot.fingerprint {
                DebugUIInspectionLog.overlay.debug(
                    "debug inspection sampling unchanged accessibility screenID=\(snapshot.screenID, privacy: .public)"
                )
            }
            lastFingerprints[snapshot.screenID] = snapshot.fingerprint
            lastSnapshots[snapshot.screenID] = snapshot

            var tracker = trackers[snapshot.screenID] ?? DebugUIElementTracker()
            let trackedFrame = tracker.update(with: result.frame)
            trackers[snapshot.screenID] = tracker
            if !force,
               let previousFrame = lastRenderedFrames[snapshot.screenID],
               trackedFrame.isOverlayRenderEquivalent(to: previousFrame) {
                DebugUIInspectionLog.overlay.debug(
                    "debug inspection skipped stable accessibility render screenID=\(snapshot.screenID, privacy: .public)"
                )
                continue
            }
            lastRenderedFrames[snapshot.screenID] = trackedFrame
            if let screen = try? screenSurfaces(scope: currentConfig.screenScope).first(where: { $0.screenID == snapshot.screenID }) {
                logLayoutDiagnostics(stage: "accessibility", screen: screen, frame: trackedFrame, captures: [])
            }
            overlayController.render(frame: trackedFrame, snapshot: snapshot)
        }

        let retainedScreenIDs = Set(lastRenderedFrames.keys).union(activeScreenIDs)
        overlayController.closeScreens(except: retainedScreenIDs)
        lastFingerprints = lastFingerprints.filter { retainedScreenIDs.contains($0.key) }
        lastSnapshots = lastSnapshots.filter { retainedScreenIDs.contains($0.key) }
    }

    private func ageMissingAccessibilityScreens(activeScreenIDs: Set<UInt32>) {
        ageMissingScreens(activeScreenIDs: activeScreenIDs)
    }

    private func ageMissingRemoteAIScreens(activeScreenIDs: Set<UInt32>) {
        ageMissingScreens(activeScreenIDs: activeScreenIDs)
    }

    private func ageMissingScreens(activeScreenIDs: Set<UInt32>) {
        let missingScreenIDs = Set(lastRenderedFrames.keys).subtracting(activeScreenIDs)
        for screenID in missingScreenIDs {
            var tracker = trackers[screenID] ?? DebugUIElementTracker()
            let trackedFrame = tracker.update(with: DebugUIInspectionFrame())
            trackers[screenID] = tracker
            if trackedFrame.elements.isEmpty {
                lastRenderedFrames.removeValue(forKey: screenID)
                lastFingerprints.removeValue(forKey: screenID)
                lastSnapshots.removeValue(forKey: screenID)
                continue
            }

            if let snapshot = lastSnapshots[screenID] {
                if let previousFrame = lastRenderedFrames[screenID],
                   trackedFrame.isOverlayRenderEquivalent(to: previousFrame) {
                    continue
                }
                lastRenderedFrames[screenID] = trackedFrame
                overlayController.render(frame: trackedFrame, snapshot: snapshot)
            }
        }
    }

    private func screenSurfaces(scope: DebugUIInspectionScreenScope) throws -> [DebugUIScreenSurface] {
        let screens: [NSScreen]
        switch scope {
        case .main:
            guard let screen = NSScreen.main ?? NSScreen.screens.first else {
                return [Self.fallbackScreenSurface(displayID: CGMainDisplayID())]
                    .filter { $0.screenID != 0 }
            }
            screens = [screen]
        case .all:
            screens = NSScreen.screens
        }

        if screens.isEmpty {
            var count: UInt32 = 0
            CGGetActiveDisplayList(0, nil, &count)
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
            CGGetActiveDisplayList(count, &displays, &count)
            return displays.filter { $0 != 0 }.map(Self.fallbackScreenSurface)
        }

        return try screens.map { screen in
            let displayID = try Self.displayID(for: screen)
            let appKitFrame = screen.frame
            let captureFrame = CGDisplayBounds(displayID)
            return DebugUIScreenSurface(
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
    }

    private func visibleOverlayTargets(on screens: [DebugUIScreenSurface]) -> [MacWindowTargetCandidate] {
        let bundleFilters = Set(currentConfig.targetBundleIdentifiers.map(Self.normalizedTargetFilter))
        let appNameFilters = Set(currentConfig.targetAppNames.map(Self.normalizedTargetFilter))
        return windowResolver.enumerateCandidates().filter { target in
            target.isVisible
                && target.isOnScreen
                && (!currentConfig.activeWindowOnly || target.isFrontmost)
                && (!currentConfig.activeWindowOnly || target.isFocused)
                && target.safetyAssessment.status == .allowed
                && !target.isIPhoneMirroring
                && target.processID != ProcessInfo.processInfo.processIdentifier
                && Self.matchesTargetFilter(
                    target,
                    bundleFilters: bundleFilters,
                    appNameFilters: appNameFilters
                )
                && screens.contains { Self.intersects(target.bounds, $0.captureFrame) }
        }
    }

    private func logLayoutDiagnostics(
        stage: String,
        screen: DebugUIScreenSurface,
        frame: DebugUIInspectionFrame,
        captures: [DebugUIWindowCapture]
    ) {
        _ = stage
        _ = screen
        _ = frame
        _ = captures
    }

    private func sourceCounts(_ elements: [DebugUIElement]) -> (ax: Int, ai: Int, cv: Int, other: Int) {
        var ax = 0
        var ai = 0
        var cv = 0
        var other = 0
        for element in elements {
            switch Self.sourceName(for: element) {
            case "AX": ax += 1
            case "AI": ai += 1
            case "CV": cv += 1
            default: other += 1
            }
        }
        return (ax, ai, cv, other)
    }

    private static func sourceName(for element: DebugUIElement) -> String {
        let fusionSource = element.metadata["debugUIFusion.source"] ?? ""
        let sources = metadataValue("localUIElement.sources", metadata: element.metadata) ?? ""
        if fusionSource == "ai" || sources.contains("remote-screenshot-parser") || element.id.hasPrefix("ai-") {
            return "AI"
        }
        if fusionSource == "native-visual" || sources.contains("shape") || sources.contains("ocr") || sources.contains("layout") || element.id.hasPrefix("native-visual-") {
            return "CV"
        }
        if sources.contains("accessibility") || element.id.hasPrefix("ax-") || sources.contains("window-chrome-geometry") || element.id.hasPrefix("window-chrome-") {
            return "AX"
        }
        return "OTHER"
    }

    private static func shortLabel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 80 else { return trimmed }
        return String(trimmed.prefix(77)) + "..."
    }

    private static func describe(_ box: DebugUIBoundingBox) -> String {
        String(
            format: "x=%.1f y=%.1f w=%.1f h=%.1f",
            box.x,
            box.y,
            box.width,
            box.height
        )
    }

    private static func describe(_ rect: CGRect) -> String {
        String(
            format: "x=%.1f y=%.1f w=%.1f h=%.1f",
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height
        )
    }

    private static func describe(_ rect: HotLoopRect) -> String {
        String(
            format: "x=%.1f y=%.1f w=%.1f h=%.1f",
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height
        )
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

    private static func describe(_ size: HotLoopSize) -> String {
        String(format: "w=%.1f h=%.1f", size.width, size.height)
    }

    private func analyzerInstance() throws -> any DebugUIInspectionAnalyzing {
        if let analyzer {
            return analyzer
        }

        let configuration = try DonkeyBackendInferenceConfiguration.fromEnvironment()
        DebugUIInspectionLog.overlay.info(
            "debug inspection using backend baseURL=\(configuration.baseURL.absoluteString, privacy: .public)"
        )
        let created = HostedDebugUIInspectionAnalyzer(
            backend: DonkeyBackendInferenceClient(configuration: configuration)
        )
        analyzer = created
        return created
    }

    private func backendInferenceClient() throws -> DonkeyBackendInferenceClient {
        let configuration = try DonkeyBackendInferenceConfiguration.fromEnvironment()
        return DonkeyBackendInferenceClient(configuration: configuration)
    }

    private static func displayID(for screen: NSScreen) throws -> UInt32 {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let value = screen.deviceDescription[key] as? NSNumber else {
            throw DebugUIScreenCaptureError.missingDisplayIdentifier
        }
        return value.uint32Value
    }

    private static func fallbackScreenSurface(displayID: CGDirectDisplayID) -> DebugUIScreenSurface {
        let bounds = CGDisplayBounds(displayID)
        return DebugUIScreenSurface(
            screenID: displayID,
            appKitFrame: HotLoopRect(
                x: bounds.origin.x,
                y: bounds.origin.y,
                width: bounds.width,
                height: bounds.height,
                space: .screen
            ),
            captureFrame: WindowTargetBounds(
                x: bounds.origin.x,
                y: bounds.origin.y,
                width: bounds.width,
                height: bounds.height
            )
        )
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

    private static func intersects(
        _ lhs: WindowTargetBounds,
        _ rhs: WindowTargetBounds
    ) -> Bool {
        lhs.x < rhs.x + rhs.width
            && lhs.x + lhs.width > rhs.x
            && lhs.y < rhs.y + rhs.height
            && lhs.y + lhs.height > rhs.y
    }

    private static func reproject(
        _ element: DebugUIElement,
        sourceScreen: DebugUIScreenSurface?,
        currentWindowTargets: [UInt32: MacWindowTargetCandidate],
        screens: [DebugUIScreenSurface]
    ) -> (screenID: UInt32, element: DebugUIElement)? {
        guard let windowID = windowID(for: element),
              let target = currentWindowTargets[windowID],
              let localBounds = localBounds(for: element)
        else {
            return nil
        }

        let previousTarget = targetBounds(for: element)
        let scaleX = previousTarget.flatMap { $0.width > 0 ? target.bounds.width / $0.width : nil } ?? 1
        let scaleY = previousTarget.flatMap { $0.height > 0 ? target.bounds.height / $0.height : nil } ?? 1
        let absoluteBounds: WindowTargetBounds
        if let previousTarget,
           let sourceScreen {
            let deltaX = target.bounds.x - previousTarget.x
            let deltaY = target.bounds.y - previousTarget.y
            absoluteBounds = WindowTargetBounds(
                x: sourceScreen.captureFrame.x + element.bbox.x + deltaX,
                y: sourceScreen.captureFrame.y + element.bbox.y + deltaY,
                width: element.bbox.width * scaleX,
                height: element.bbox.height * scaleY
            )
        } else {
            absoluteBounds = WindowTargetBounds(
                x: target.bounds.x + localBounds.x * scaleX,
                y: target.bounds.y + localBounds.y * scaleY,
                width: localBounds.width * scaleX,
                height: localBounds.height * scaleY
            )
        }
        let updatedLocalBounds = WindowTargetBounds(
            x: localBounds.x * scaleX,
            y: localBounds.y * scaleY,
            width: localBounds.width * scaleX,
            height: localBounds.height * scaleY
        )

        guard let screen = screens.first(where: { intersects(absoluteBounds, $0.captureFrame) }),
              let bbox = clippedBoundingBox(absoluteBounds, screenFrame: screen.captureFrame)
        else {
            return nil
        }

        var metadata = element.metadata
        metadata.merge(targetBoundsMetadata(target.bounds)) { _, new in new }
        metadata.merge(boundsMetadata(prefix: "debugOverlay.localBounds.", bounds: updatedLocalBounds)) { _, new in new }
        return (
            screen.screenID,
            DebugUIElement(
                id: element.id,
                type: element.type,
                label: element.label,
                description: element.description,
                bbox: bbox,
                confidence: element.confidence,
                visualStyle: element.visualStyle,
                metadata: metadata
            )
        )
    }

    private static func clippedBoundingBox(
        _ bounds: WindowTargetBounds,
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

    private static func elementSort(_ lhs: DebugUIElement, _ rhs: DebugUIElement) -> Bool {
        if lhs.bbox.y != rhs.bbox.y { return lhs.bbox.y < rhs.bbox.y }
        if lhs.bbox.x != rhs.bbox.x { return lhs.bbox.x < rhs.bbox.x }
        return lhs.id < rhs.id
    }

    private static func isAccessibilityEvidence(_ element: DebugUIElement) -> Bool {
        let sources = metadataValue("localUIElement.sources", metadata: element.metadata) ?? ""
        return sources.contains("accessibility")
            || element.id.hasPrefix("ax-")
            || sources.contains("window-chrome-geometry")
            || element.id.hasPrefix("window-chrome-")
    }

    private static func windowID(for element: DebugUIElement) -> UInt32? {
        metadataValue("target.windowID", metadata: element.metadata).flatMap(UInt32.init)
    }

    private static func targetBounds(for element: DebugUIElement) -> WindowTargetBounds? {
        metadataBounds(prefix: "target.bounds.", metadata: element.metadata)
    }

    private static func localBounds(for element: DebugUIElement) -> WindowTargetBounds? {
        metadataBounds(prefix: "debugOverlay.localBounds.", metadata: element.metadata)
    }

    private static func metadataBounds(
        prefix: String,
        metadata: [String: String]
    ) -> WindowTargetBounds? {
        guard let xValue = metadataValue(prefix + "x", metadata: metadata),
              let yValue = metadataValue(prefix + "y", metadata: metadata),
              let widthValue = metadataValue(prefix + "width", metadata: metadata),
              let heightValue = metadataValue(prefix + "height", metadata: metadata),
              let x = Double(xValue),
              let y = Double(yValue),
              let width = Double(widthValue),
              let height = Double(heightValue),
              width > 0,
              height > 0
        else {
            return nil
        }

        return WindowTargetBounds(x: x, y: y, width: width, height: height)
    }

    private static func metadataValue(
        _ key: String,
        metadata: [String: String]
    ) -> String? {
        if let value = metadata[key] {
            return value
        }

        let suffix = ".\(key)"
        return metadata
            .sorted { $0.key < $1.key }
            .first { entry in entry.key.hasSuffix(suffix) }?
            .value
    }

    private static func targetBoundsMetadata(_ bounds: WindowTargetBounds) -> [String: String] {
        boundsMetadata(prefix: "target.bounds.", bounds: bounds)
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

    private static func fingerprint(
        screenID: UInt32,
        captures: [DebugUIWindowCapture],
        accessibilityFrame: DebugUIInspectionFrame? = nil
    ) -> String {
        let input = captures.map { capture in
            [
                String(screenID),
                String(capture.target.windowID),
                String(capture.target.bounds.x),
                String(capture.target.bounds.y),
                String(capture.target.bounds.width),
                String(capture.target.bounds.height),
                SHA256.hash(data: capture.parseImageData).map { String(format: "%02x", $0) }.joined()
            ].joined(separator: ":")
        }.joined(separator: "|")
        let accessibilityInput = (accessibilityFrame?.elements ?? []).map { element in
            [
                element.id,
                element.type.rawValue,
                element.label,
                String(format: "%.2f", element.bbox.x),
                String(format: "%.2f", element.bbox.y),
                String(format: "%.2f", element.bbox.width),
                String(format: "%.2f", element.bbox.height),
                String(format: "%.3f", element.confidence)
            ].joined(separator: ":")
        }.joined(separator: "|")
        let combinedInput = [input, accessibilityInput]
            .filter { !$0.isEmpty }
            .joined(separator: "||")
        return SHA256.hash(data: Data(combinedInput.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func frameSignature(_ frame: DebugUIInspectionFrame) -> String {
        frame.elements.map { element in
            [
                element.id,
                String(format: "%.1f", element.bbox.x),
                String(format: "%.1f", element.bbox.y),
                String(format: "%.1f", element.bbox.width),
                String(format: "%.1f", element.bbox.height)
            ].joined(separator: ":")
        }.joined(separator: "|")
    }

    private static func screenPointSnapshot(
        screen: DebugUIScreenSurface,
        fingerprint: String
    ) -> DebugUIScreenCaptureSnapshot {
        DebugUIScreenCaptureSnapshot(
            screenID: screen.screenID,
            screenFrame: screen.appKitFrame,
            pixelSize: HotLoopSize(
                width: screen.appKitFrame.size.width,
                height: screen.appKitFrame.size.height,
                space: .screen
            ),
            pngData: Data(),
            fingerprint: fingerprint
        )
    }

    private static func compressedRemoteAIImage(
        from screenshot: CapturedWindowScreenshot
    ) -> CompressedScreenshot {
        ScreenshotCompression.compressedForModel(screenshot)
    }
}

private struct DebugUIScreenSurface: Equatable, Sendable {
    var screenID: UInt32
    var appKitFrame: HotLoopRect
    var captureFrame: WindowTargetBounds
}

private struct DebugUIWindowCapture: Sendable {
    var target: MacWindowTargetCandidate
    var screenshot: CapturedWindowScreenshot
    var parseImageData: Data
    var parseContentType: String
    var parsePixelSize: HotLoopSize
}

#endif
