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
    private var notificationObservers: [NSObjectProtocol] = []
    private var currentConfig: DebugUIOverlayConfiguration = .disabled
    private var isAnalyzing = false

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
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        notificationObservers.removeAll()
        overlayController.close()
        trackers.removeAll()
        lastFingerprints.removeAll()
        lastRenderedFrames.removeAll()
        lastSnapshots.removeAll()
        isAnalyzing = false
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
        try await analyzeGeminiWindowScreens(force: force)
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
        DebugUIInspectionLog.overlay.info(
            "debug inspection rendering source=\(stage, privacy: .public) screenID=\(screen.screenID, privacy: .public) elements=\(trackedFrame.elements.count, privacy: .public)"
        )
        lastFingerprints[screen.screenID] = fingerprint
        lastRenderedFrames[screen.screenID] = trackedFrame
        lastSnapshots[screen.screenID] = snapshot
        overlayController.render(frame: trackedFrame, snapshot: snapshot)
    }

    private func analyzeGeminiWindowScreens(force: Bool) async throws {
        let screens = try screenSurfaces(scope: currentConfig.screenScope)
        let activeScreenIDs = Set(screens.map(\.screenID))
        overlayController.closeScreens(except: activeScreenIDs)
        lastRenderedFrames = lastRenderedFrames.filter { activeScreenIDs.contains($0.key) }
        let accessibilityFrames = accessibilityFramesForGeminiFusion()
        renderFastLocalFrames(
            screens: screens,
            frames: accessibilityFrames,
            stage: "accessibility",
            force: force
        )

        let targets = visibleOverlayTargets(on: screens)
        guard !targets.isEmpty else {
            ageMissingGeminiScreens(activeScreenIDs: Set(accessibilityFrames.keys))
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
                overlayController.render(frame: trackedFrame, snapshot: snapshot)
            }
            return
        }

        let client = try backendInferenceClient()
        var captures: [DebugUIWindowCapture] = []
        for target in targets {
            do {
                let screenshot = try await windowScreenshotCapturer.capture(target: target)
                let compressed = Self.compressedGeminiImage(from: screenshot)
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
                    "debug inspection skipped gemini windowID=\(target.windowID, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
            }
        }

        let renderedScreenIDs = Set(captures.flatMap { capture in
            screens.filter { Self.intersects(capture.target.bounds, Self.windowBounds(from: $0.appKitFrame)) }.map(\.screenID)
        }).union(accessibilityFrames.keys)
        ageMissingGeminiScreens(activeScreenIDs: renderedScreenIDs)

        for screen in screens where renderedScreenIDs.contains(screen.screenID) {
            let screenBounds = Self.windowBounds(from: screen.appKitFrame)
            let screenCaptures = captures.filter { Self.intersects($0.target.bounds, screenBounds) }
            let accessibilityFrame = accessibilityFrames[screen.screenID] ?? DebugUIInspectionFrame()
            let fingerprint = Self.fingerprint(
                screenID: screen.screenID,
                captures: screenCaptures,
                accessibilityFrame: accessibilityFrame
            )
            guard force || lastFingerprints[screen.screenID] != fingerprint || needsTrackerWarmup(screenID: screen.screenID) else {
                DebugUIInspectionLog.overlay.debug(
                    "debug inspection skipped unchanged gemini screenID=\(screen.screenID, privacy: .public)"
                )
                continue
            }
            lastFingerprints[screen.screenID] = fingerprint

            let localEvidenceFrame = accessibilityFrame

            var elements: [DebugUIElement] = []
            for capture in screenCaptures {
                let capturePixelSize = HotLoopSize(
                    width: capture.parsePixelSize.width,
                    height: capture.parsePixelSize.height,
                    space: .window
                )
                let request = LocalUIUnderstandingRequest(
                    traceID: "debug-ui-gemini-\(screen.screenID)-\(capture.target.windowID)-\(fingerprint)",
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
                        "donkeyVision.ai": "gemini",
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
                    let result = try await client.parseScreenshot(
                        request,
                        imageData: capture.parseImageData,
                        contentType: capture.parseContentType
                    )
                    elements += ScreenshotParseDebugUIOverlayMapper.frame(
                        from: result,
                        target: capture.target,
                        capturePixelSize: capturePixelSize,
                        screenFrame: screenBounds,
                        minConfidence: currentConfig.minConfidence
                    ).elements
                } catch {
                    DebugUIInspectionLog.overlay.error(
                        "debug inspection gemini parse failed windowID=\(capture.target.windowID, privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                }
            }

            var tracker = trackers[screen.screenID] ?? DebugUIElementTracker()
            let geminiFrame = DebugUIInspectionFrame(elements: elements)
            let fusedFrame = DebugUIInspectionFrameFusion.fused(
                accessibilityFrame: localEvidenceFrame,
                geminiFrame: geminiFrame
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
                    "debug inspection skipped stable gemini render screenID=\(screen.screenID, privacy: .public)"
                )
                continue
            }

            let snapshot = Self.screenPointSnapshot(screen: screen, fingerprint: fingerprint)
            DebugUIInspectionLog.overlay.info(
                "debug inspection rendering source=gemini-fused screenID=\(screen.screenID, privacy: .public) windows=\(screenCaptures.count, privacy: .public) localEvidenceElements=\(localEvidenceFrame.elements.count, privacy: .public) geminiElements=\(geminiFrame.elements.count, privacy: .public) elements=\(trackedFrame.elements.count, privacy: .public)"
            )
            logSampleMappings(frame: trackedFrame, snapshot: snapshot)
            lastRenderedFrames[screen.screenID] = trackedFrame
            lastSnapshots[screen.screenID] = snapshot
            overlayController.render(frame: trackedFrame, snapshot: snapshot)
        }
    }

    private func accessibilityFramesForGeminiFusion() -> [UInt32: DebugUIInspectionFrame] {
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
            DebugUIInspectionLog.overlay.info(
                "debug inspection rendering source=accessibility screenID=\(snapshot.screenID, privacy: .public) elements=\(trackedFrame.elements.count, privacy: .public)"
            )
            logSampleMappings(frame: trackedFrame, snapshot: snapshot)
            lastRenderedFrames[snapshot.screenID] = trackedFrame
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

    private func ageMissingGeminiScreens(activeScreenIDs: Set<UInt32>) {
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
                && screens.contains { Self.intersects(target.bounds, Self.windowBounds(from: $0.appKitFrame)) }
        }
    }

    private func logSampleMappings(
        frame: DebugUIInspectionFrame,
        snapshot: DebugUIScreenCaptureSnapshot
    ) {
        let screenPointSize = HotLoopSize(
            width: snapshot.screenFrame.size.width,
            height: snapshot.screenFrame.size.height,
            space: .screen
        )
        for element in frame.elements.prefix(3) {
            let localFrame = DebugUIOverlayGeometry.localLayerFrame(
                for: element.bbox,
                screenshotPixelSize: snapshot.pixelSize,
                screenPointSize: screenPointSize
            )
            DebugUIInspectionLog.overlay.info(
                "debug inspection mapping id=\(element.id, privacy: .public) label=\(element.label, privacy: .public) bbox=\(Self.describe(element.bbox), privacy: .public) local=\(Self.describe(localFrame), privacy: .public) pixels=\(Self.describe(snapshot.pixelSize), privacy: .public) points=\(Self.describe(screenPointSize), privacy: .public)"
            )
        }
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

    private static func windowBounds(from rect: HotLoopRect) -> WindowTargetBounds {
        WindowTargetBounds(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.size.width,
            height: rect.size.height
        )
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

    private static func compressedGeminiImage(
        from screenshot: CapturedWindowScreenshot
    ) -> DebugUICompressedImage {
        let fallbackSize = HotLoopSize(
            width: Double(screenshot.imageWidth),
            height: Double(screenshot.imageHeight),
            space: .window
        )
        guard let source = CGImageSourceCreateWithData(screenshot.pngData as CFData, nil) else {
            return DebugUICompressedImage(
                data: screenshot.pngData,
                contentType: "image/png",
                pixelSize: fallbackSize
            )
        }

        let maxPixelDimension = 896
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary),
              let encoded = NSMutableData() as CFMutableData?,
              let destination = CGImageDestinationCreateWithData(
                encoded,
                UTType.jpeg.identifier as CFString,
                1,
                nil
              )
        else {
            return DebugUICompressedImage(
                data: screenshot.pngData,
                contentType: "image/png",
                pixelSize: fallbackSize
            )
        }

        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.48
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return DebugUICompressedImage(
                data: screenshot.pngData,
                contentType: "image/png",
                pixelSize: fallbackSize
            )
        }

        return DebugUICompressedImage(
            data: encoded as Data,
            contentType: "image/jpeg",
            pixelSize: HotLoopSize(
                width: Double(image.width),
                height: Double(image.height),
                space: .window
            )
        )
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

private struct DebugUICompressedImage: Sendable {
    var data: Data
    var contentType: String
    var pixelSize: HotLoopSize
}
