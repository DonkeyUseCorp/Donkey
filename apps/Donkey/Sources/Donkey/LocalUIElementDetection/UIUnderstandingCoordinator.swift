import AppKit
import CryptoKit
import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

private enum UIUnderstandingLog {
    static let overlay = Logger(subsystem: "com.donkey.app", category: "ui-understanding")
}

/// Which hosted backend supplies the "AI" evidence rendered on the overlay.
/// `vision` is the active path (RunPod OmniParser V2 via /api/vision).
/// `screenshotParse` is the older streaming parser, kept compiled but disabled.
private enum RemoteAIEngine {
    case vision
    case screenshotParse
}

/// Always-on engine that turns the user's windows into structured UI understanding (accessibility +
/// vision elements) for the agent to reason over. It runs in every build; only the visual overlay is
/// a debug concern, injected through `DebugUIInspectionOverlayRendering`.
@MainActor
final class UIUnderstandingCoordinator {
    // The real overlay renderer: AppKit in debug builds, a no-op in production. Drawing is routed
    // through the gated `overlayController` accessor below so the engine keeps parsing and caching
    // for the agent even while the overlay is off.
    private let realOverlayController: any DebugUIInspectionOverlayRendering
    private let noopOverlayController: any DebugUIInspectionOverlayRendering =
        NoopDebugUIInspectionOverlayRenderer()
    private let rendersOverlay: Bool
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
    private var lastVisionSignatures: [UInt32: ScreenshotSignature] = [:]
    // How many vision elements the last successful parse produced per window. Paired with
    // `lastVisionSignatures` so the unchanged-signature skip can tell "unchanged and its boxes are
    // still on screen" (safe to skip) from "unchanged but its boxes were lost" (must re-parse to
    // recover), instead of skipping forever and leaving the window with no vision overlay.
    private var lastVisionElementCounts: [UInt32: Int] = [:]
    private var visionBackoff: [UInt32: VisionBackoff] = [:]
    private var lastActiveWindowIDs: [UInt32: Set<UInt32>] = [:]
    private var windowElementCache: [UInt32: [DebugUIElement]] = [:]
    private var isWarmingBackground = false
    private var lastBackgroundWarmCount: Int?
    private let remoteAIEngine: RemoteAIEngine = .vision

    private struct VisionBackoff {
        var nextAttempt: Date
        var failureStreak: Int
    }
    private var timer: Timer?
    private var activeAccessibilityTimer: Timer?
    private var notificationObservers: [NSObjectProtocol] = []
    private var movementEventMonitors: [Any] = []
    private var currentConfig: DebugUIOverlayConfiguration = .disabled
    // The understanding engine always parses and publishes — the agent reads the shared store
    // regardless of any overlay. Only the visible overlay is gated: it draws when this instance
    // renders one (debug builds) and the dev-overlay config turns it on.
    private var overlayActive: Bool { rendersOverlay && currentConfig.enabled }
    // Routes every render/close to the real renderer only while the overlay is active; otherwise a
    // no-op renderer, so engine bookkeeping (caching for the agent) runs without drawing anything.
    private var overlayController: any DebugUIInspectionOverlayRendering {
        overlayActive ? realOverlayController : noopOverlayController
    }
    private var isAnalyzing = false
    private var isRefreshingActiveAccessibility = false

    /// - Parameters:
    ///   - overlayController: where parsed frames are painted while the overlay is active. Production
    ///     injects a no-op renderer; the engine parses and caches regardless of what is drawn.
    ///   - rendersOverlay: whether this instance can drive a visible overlay. Render-only smoothing
    ///     work (the high-frequency active-window accessibility pass) is skipped when false, and the
    ///     overlay never draws. The engine still runs in every build.
    init(
        configURL: URL? = nil,
        overlayController: any DebugUIInspectionOverlayRendering = NoopDebugUIInspectionOverlayRenderer(),
        rendersOverlay: Bool = false
    ) {
        self.configURL = configURL
        self.realOverlayController = overlayController
        self.rendersOverlay = rendersOverlay
    }

    func start() {
        UIUnderstandingLog.overlay.info(
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
        realOverlayController.close()
        trackers.removeAll()
        lastFingerprints.removeAll()
        lastRenderedFrames.removeAll()
        lastSnapshots.removeAll()
        lastVisionSignatures.removeAll()
        lastVisionElementCounts.removeAll()
        visionBackoff.removeAll()
        lastActiveWindowIDs.removeAll()
        windowElementCache.removeAll()
        isAnalyzing = false
        isWarmingBackground = false
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
        // The dev-overlay config file only flips the visible overlay on or off; the engine parses
        // and caches in every build regardless. `enabled` is therefore purely the overlay switch.
        let newConfig = DebugUIOverlayConfiguration.load(fileURL: configURL)
        let enablementChanged = newConfig.enabled != currentConfig.enabled
        currentConfig = newConfig

        if force || enablementChanged {
            UIUnderstandingLog.overlay.info(
                "debug inspection overlay enabled=\(String(newConfig.enabled), privacy: .public)"
            )
        }

        if timer == nil || force {
            timer?.invalidate()
            let newTimer = Timer(timeInterval: newConfig.cadenceSeconds, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
            timer = newTimer
            RunLoop.main.add(newTimer, forMode: .common)
        }

        // The 0.12s active-accessibility pass exists purely to keep the visible overlay smooth, so
        // it only runs when this instance actually renders. Headless (production) parsing relies on
        // the main cadence below.
        if overlayActive {
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

        if enablementChanged {
            lastFingerprints.removeAll()
            trackers.removeAll()
            lastRenderedFrames.removeAll()
            lastSnapshots.removeAll()
            lastVisionSignatures.removeAll()
            lastVisionElementCounts.removeAll()
            visionBackoff.removeAll()
            lastActiveWindowIDs.removeAll()
            windowElementCache.removeAll()
            if !newConfig.enabled {
                realOverlayController.close()
            }
        }
    }

    private func refresh(force: Bool = false) {
        reloadConfigAndReschedule()
        // The engine runs in every build, gated only by sign-in: the AI parse pass hits the hosted
        // backend, which would just 401 while signed out, so it idles until sign-in restores it (the
        // app delegate also stops this coordinator on sign-out). The overlay is gated separately.
        guard BackendSessionGate.shared.isAuthenticated else { return }
        guard !isAnalyzing else {
            UIUnderstandingLog.overlay.debug("debug inspection skipped refresh because analysis is already running")
            return
        }

        isAnalyzing = true
        Task { @MainActor in
            defer { isAnalyzing = false }
            do {
                try await analyzeVisibleScreens(force: force)
            } catch {
                UIUnderstandingLog.overlay.error(
                    "debug inspection failed error=\(String(describing: error), privacy: .public)"
                )
                if lastRenderedFrames.isEmpty {
                    realOverlayController.close()
                    lastFingerprints.removeAll()
                    trackers.removeAll()
                }
            }
        }

        // Warm background windows' overlays off the critical path so switching to any window is
        // instant. This runs on its own single-flight task and does not block active rendering.
        scheduleBackgroundWarm()
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

        // Carry the already-detected vision/AI elements into this fast accessibility render. The
        // element tracker is shared across every render path, so feeding it an accessibility-ONLY
        // frame here would mark the vision boxes "missing" and age them out within
        // `disappearanceTolerance` cycles — which, once the vision parse is skipped for an unchanged
        // window, makes the boxes flicker (appear, vanish, reappear on the next real parse). Fusing
        // the carried AI elements keeps them present every cycle, matching the active-accessibility
        // path's behavior. Scope the carry-forward to this frame's window so a previous window's
        // boxes do not survive a window switch.
        let focusedWindowIDs = Set(frame.elements.compactMap(Self.windowID(for:)))
        let carriedAIFrame = DebugUIInspectionFrame(
            elements: (lastRenderedFrames[screen.screenID]?.elements ?? [])
                .filter { element in
                    guard !Self.isAccessibilityEvidence(element) else { return false }
                    guard let windowID = Self.windowID(for: element) else { return true }
                    return focusedWindowIDs.contains(windowID)
                }
        )
        let fusedFrame = DebugUIInspectionFrameFusion.fused(
            accessibilityFrame: frame,
            aiFrame: carriedAIFrame
        )

        var tracker = trackers[screen.screenID] ?? Self.makeElementTracker()
        let trackedFrame = tracker.update(with: fusedFrame, renderNewElementsImmediately: true)
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
        cacheRenderedElements(trackedFrame.elements)
        logLayoutDiagnostics(stage: stage, screen: screen, frame: trackedFrame, captures: [])
        overlayController.render(frame: trackedFrame, snapshot: snapshot)
    }

    private func refreshActiveAccessibilityFrame() {
        guard overlayActive,
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
            UIUnderstandingLog.overlay.debug(
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
            let focusedWindowIDs = Set(accessibilityFrame.elements.compactMap(Self.windowID(for:)))

            // Detect a focused-window switch. On switch we do not throw the previous window's
            // metadata away — it stays in `windowElementCache`. Instead we reset the tracker and
            // seed the carried-forward AI from this window's cache so its last-known vision boxes
            // reappear instantly, rather than blanking until the next ~1Hz vision pass.
            let switchedWindow = !focusedWindowIDs.isEmpty
                && lastActiveWindowIDs[screen.screenID].map { $0 != focusedWindowIDs } == true
            if switchedWindow {
                trackers[screen.screenID] = Self.makeElementTracker()
                lastFingerprints[screen.screenID] = nil
            }
            if !focusedWindowIDs.isEmpty {
                lastActiveWindowIDs[screen.screenID] = focusedWindowIDs
            }

            // Carry forward only AI boxes that belong to the focused window. In steady state they
            // are already on screen (`existing`); right after a switch `existing` still holds the
            // previous window, so pull this window's boxes from the per-window cache instead.
            let carriedAIElements: [DebugUIElement]
            if switchedWindow {
                carriedAIElements = cachedElements(
                    forWindows: focusedWindowIDs,
                    screens: screens,
                    where: { !Self.isAccessibilityEvidence($0) }
                )[screen.screenID] ?? []
            } else {
                carriedAIElements = existing.elements.filter { element in
                    guard !Self.isAccessibilityEvidence(element) else { return false }
                    guard let windowID = Self.windowID(for: element) else { return true }
                    return focusedWindowIDs.contains(windowID)
                }
            }

            let progressiveAccessibilityFrame: DebugUIInspectionFrame
            if stage.contains("progress") {
                let incomingIDs = Set(accessibilityFrame.elements.map(\.id))
                // While a scan streams in, hold the previously rendered accessibility boxes for the
                // focused window so partial frames do not flicker. After a switch those come from
                // the cache, since `existing` is still the previous window.
                let priorAccessibilityElements: [DebugUIElement]
                if switchedWindow {
                    priorAccessibilityElements = cachedElements(
                        forWindows: focusedWindowIDs,
                        screens: screens,
                        where: { Self.isAccessibilityEvidence($0) }
                    )[screen.screenID] ?? []
                } else {
                    priorAccessibilityElements = existing.elements.filter { Self.isAccessibilityEvidence($0) }
                }
                let carriedAccessibilityElements = priorAccessibilityElements.filter { element in
                    guard !incomingIDs.contains(element.id),
                          let windowID = Self.windowID(for: element)
                    else {
                        return false
                    }
                    return focusedWindowIDs.contains(windowID)
                }
                progressiveAccessibilityFrame = DebugUIInspectionFrame(
                    elements: carriedAccessibilityElements + accessibilityFrame.elements
                )
            } else {
                progressiveAccessibilityFrame = accessibilityFrame
            }
            let nonAccessibilityFrame = DebugUIInspectionFrame(elements: carriedAIElements)
            let fusedFrame = DebugUIInspectionFrameFusion.fused(
                accessibilityFrame: progressiveAccessibilityFrame,
                aiFrame: nonAccessibilityFrame
            )
            guard !fusedFrame.elements.isEmpty,
                  lastRenderedFrames[screen.screenID]?.isOverlayRenderEquivalent(to: fusedFrame) != true
            else {
                continue
            }

            var tracker = trackers[screen.screenID] ?? Self.makeElementTracker()
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
            cacheRenderedElements(trackedFrame.elements)
            logLayoutDiagnostics(stage: stage, screen: screen, frame: trackedFrame, captures: [])
            overlayController.render(frame: trackedFrame, snapshot: snapshot)
        }
    }

    private func reprojectRenderedFramesFromCurrentWindowBounds() {
        guard overlayActive,
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
        // Drop cached state for windows that no longer exist so the per-window caches do not grow
        // without bound over a long session.
        let liveWindowIDs = Set(windowResolver.enumerateCandidates().map(\.windowID))
        windowElementCache = windowElementCache.filter { liveWindowIDs.contains($0.key) }
        lastVisionSignatures = lastVisionSignatures.filter { liveWindowIDs.contains($0.key) }
        lastVisionElementCounts = lastVisionElementCounts.filter { liveWindowIDs.contains($0.key) }
        visionBackoff = visionBackoff.filter { liveWindowIDs.contains($0.key) }
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
                var tracker = trackers[screen.screenID] ?? Self.makeElementTracker()
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
                UIUnderstandingLog.overlay.error(
                    "debug inspection skipped remote AI windowID=\(target.windowID, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
            }
        }

        UIUnderstandingLog.overlay.debug(
            "debug inspection remote AI captures engine=\(String(describing: self.remoteAIEngine), privacy: .public) targets=\(targets.count, privacy: .public) captures=\(captures.count, privacy: .public) screens=\(screens.count, privacy: .public)"
        )

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
                UIUnderstandingLog.overlay.debug(
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
            // If a captured window has no AI on screen yet (e.g. the user just switched back to it),
            // seed from its cached vision boxes so they reappear immediately instead of blanking
            // until this parse returns.
            let windowsWithAI = Set(elements.compactMap(Self.windowID(for:)))
            let missingAIWindows = currentWindowIDs.subtracting(windowsWithAI)
            if !missingAIWindows.isEmpty {
                elements += cachedElements(
                    forWindows: missingAIWindows,
                    screens: screens,
                    where: { !Self.isAccessibilityEvidence($0) }
                )[screen.screenID] ?? []
            }

            func renderRemoteAIFrame(stage: String, updatesFingerprint: Bool) {
                var tracker = trackers[screen.screenID] ?? Self.makeElementTracker()
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
                    UIUnderstandingLog.overlay.debug(
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
                cacheRenderedElements(trackedFrame.elements)
                let aiCount = trackedFrame.elements.filter { !Self.isAccessibilityEvidence($0) }.count
                UIUnderstandingLog.overlay.debug(
                    "debug inspection rendering \(stage, privacy: .public) screenID=\(screen.screenID, privacy: .public) totalElements=\(trackedFrame.elements.count, privacy: .public) aiElements=\(aiCount, privacy: .public)"
                )
                overlayController.render(frame: trackedFrame, snapshot: snapshot)
            }

            for capture in screenCaptures {
                let capturePixelSize = HotLoopSize(
                    width: capture.parsePixelSize.width,
                    height: capture.parsePixelSize.height,
                    space: .window
                )

                if remoteAIEngine == .vision {
                    let windowID = capture.target.windowID
                    // Back off after failures so a broken or cold backend isn't
                    // re-hit (and re-logged) every refresh cycle.
                    if let backoff = visionBackoff[windowID], Date() < backoff.nextAttempt {
                        continue
                    }
                    // Skip the network call when this window looks unchanged since the last
                    // successful vision parse; its elements are still carried forward in
                    // `elements`. We compare a scale-normalized grayscale signature with a
                    // per-pixel noise floor instead of an exact byte hash, so caret blink,
                    // the clock, cursor motion, or a sub-pixel resize don't force a re-parse.
                    // Built from the raw capture so JPEG quantization noise never enters.
                    let signature = ScreenshotSignature.make(fromImageData: capture.screenshot.pngData)
                    if let signature, let previous = lastVisionSignatures[windowID] {
                        let changedFraction = signature.changedFraction(from: previous)
                        // The unchanged-signature skip assumes this window's boxes are still being
                        // carried forward in `elements`. If they were lost (aged out across a window
                        // switch, or never re-seeded) we must re-parse to recover them instead of
                        // skipping forever — but only when the last parse actually produced boxes, so
                        // a genuinely element-free window doesn't re-parse every pass.
                        let carriedAICount = elements.reduce(into: 0) { count, element in
                            if !Self.isAccessibilityEvidence(element),
                               Self.windowID(for: element) == windowID {
                                count += 1
                            }
                        }
                        let expectedAI = (lastVisionElementCounts[windowID] ?? 0) > 0
                        if changedFraction <= Self.visionChangedFractionThreshold,
                           carriedAICount > 0 || !expectedAI {
                            UIUnderstandingLog.overlay.debug(
                                "debug inspection skipped unchanged vision windowID=\(windowID, privacy: .public) changedFraction=\(changedFraction, privacy: .public)"
                            )
                            continue
                        }
                    }
                    do {
                        UIUnderstandingLog.overlay.debug(
                            "debug inspection vision request sending windowID=\(windowID, privacy: .public) captureBytes=\(capture.parseImageData.count, privacy: .public)"
                        )
                        let requestStart = Date()
                        let response = try await client.parseScreenshotVision(
                            imageData: capture.parseImageData
                        )
                        let elapsedMs = Int(Date().timeIntervalSince(requestStart) * 1000)
                        let parsedElements = VisionParseDebugUIOverlayMapper.frame(
                            from: response,
                            target: capture.target,
                            screenFrame: screenBounds,
                            minConfidence: currentConfig.minConfidence
                        ).elements
                        UIUnderstandingLog.overlay.info(
                            "debug inspection vision parsed windowID=\(windowID, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public) responseElements=\(response.elements.count, privacy: .public) mappedElements=\(parsedElements.count, privacy: .public) minConfidence=\(self.currentConfig.minConfidence, privacy: .public) responseImage=\(Int(response.image.width), privacy: .public)x\(Int(response.image.height), privacy: .public) captureBytes=\(capture.parseImageData.count, privacy: .public)"
                        )
                        elements.removeAll { Self.windowID(for: $0) == windowID }
                        elements += parsedElements
                        if let signature {
                            lastVisionSignatures[windowID] = signature
                        }
                        lastVisionElementCounts[windowID] = parsedElements.count
                        visionBackoff[windowID] = nil
                        renderRemoteAIFrame(stage: "vision", updatesFingerprint: false)
                        publishUnderstanding(for: capture.target, signature: signature)
                    } catch {
                        let backoff = Self.nextVisionBackoff(after: visionBackoff[windowID])
                        visionBackoff[windowID] = backoff
                        UIUnderstandingLog.overlay.error(
                            "debug inspection vision parse failed windowID=\(windowID, privacy: .public) failureStreak=\(backoff.failureStreak, privacy: .public) retryInSeconds=\(Int(backoff.nextAttempt.timeIntervalSinceNow.rounded()), privacy: .public) error=\(String(describing: error), privacy: .public)"
                        )
                    }
                    continue
                }

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
                    UIUnderstandingLog.overlay.error(
                        "debug inspection remote AI parse failed windowID=\(capture.target.windowID, privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                }
            }

            renderRemoteAIFrame(stage: "ai-fused", updatesFingerprint: true)
        }
    }

    /// Kick a single-flight background pass that pre-extracts and caches understanding for windows
    /// the user is not currently looking at, so switching to any of them (or the agent acting on one)
    /// is instant. Runs whenever the engine does; only meaningful while the active window is handled
    /// live, otherwise every window is already analyzed.
    private func scheduleBackgroundWarm() {
        guard currentConfig.activeWindowOnly,
              remoteAIEngine == .vision,
              !isWarmingBackground
        else {
            return
        }
        isWarmingBackground = true
        Task { @MainActor in
            defer { self.isWarmingBackground = false }
            guard let screens = try? self.screenSurfaces(scope: self.currentConfig.screenScope) else {
                return
            }
            let activeWindowIDs = Set(self.visibleOverlayTargets(on: screens).map(\.windowID))
            let backgroundWarmCount = self.backgroundWarmTargets(
                on: screens,
                excluding: activeWindowIDs
            ).count
            // Only log when the count changes so the ~1Hz warm pass doesn't spam an identical line.
            if self.lastBackgroundWarmCount != backgroundWarmCount {
                self.lastBackgroundWarmCount = backgroundWarmCount
                UIUnderstandingLog.overlay.info(
                    "debug inspection background warm windows=\(backgroundWarmCount, privacy: .public)"
                )
            }
            // Warm background windows that have no cached accessibility yet — the scan runs off the
            // main actor since a cold first-launch walk is slow; vision is a slow network parse, so
            // warm just one window per pass.
            await self.warmBackgroundAccessibility(screens: screens, excluding: activeWindowIDs)
            await self.warmNextBackgroundVisionWindow(screens: screens, excluding: activeWindowIDs)
        }
    }

    /// Cap how many background windows we ever warm, so a desktop full of windows does not trigger a
    /// flood of captures and vision parses. The frontmost background windows (the ones most likely to
    /// be switched to) are warmed first.
    private static let backgroundWarmWindowCap = 5

    /// Candidate windows eligible for background warming: every visible, allowed window except the
    /// active one(s) the live path already handles, capped to `backgroundWarmWindowCap`. Unlike
    /// `visibleOverlayTargets` this ignores the frontmost/focused requirement so background windows
    /// are included.
    private func backgroundWarmTargets(
        on screens: [DebugUIScreenSurface],
        excluding excludedWindowIDs: Set<UInt32>
    ) -> [MacWindowTargetCandidate] {
        let bundleFilters = Set(currentConfig.targetBundleIdentifiers.map(Self.normalizedTargetFilter))
        let appNameFilters = Set(currentConfig.targetAppNames.map(Self.normalizedTargetFilter))
        let eligible = windowResolver.enumerateCandidates().filter { target in
            target.isVisible
                && target.isOnScreen
                && !excludedWindowIDs.contains(target.windowID)
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
        return Array(eligible.prefix(Self.backgroundWarmWindowCap))
    }

    private func hasCachedAccessibility(forWindow windowID: UInt32) -> Bool {
        windowElementCache[windowID]?.contains(where: Self.isAccessibilityEvidence) ?? false
    }

    /// Run one all-windows accessibility scan and cache the accessibility boxes for background
    /// windows that have none yet. Skips entirely once every background window is covered so we are
    /// not walking every app's accessibility tree on a loop.
    private func warmBackgroundAccessibility(
        screens: [DebugUIScreenSurface],
        excluding activeWindowIDs: Set<UInt32>
    ) async {
        let pending = backgroundWarmTargets(on: screens, excluding: activeWindowIDs)
            .filter { !hasCachedAccessibility(forWindow: $0.windowID) }
        guard !pending.isEmpty else { return }
        let pendingWindowIDs = Set(pending.map(\.windowID))

        // The accessibility tree walk is slow cross-process IPC — a cold first-launch scan can run
        // long enough to beachball if it happens on the main actor. Snapshot the Sendable inputs and
        // run `inspect` off the main actor, then resume here to merge (AX reads are thread-safe and
        // the service and its results are Sendable). The `isWarmingBackground` guard around this pass
        // stays held across the await, so scans never overlap.
        let service = accessibilityInspectionService
        let scope = currentConfig.screenScope
        let minConfidence = currentConfig.minConfidence
        let targetBundleIdentifiers = currentConfig.targetBundleIdentifiers
        let targetAppNames = currentConfig.targetAppNames

        let results: [DebugUIAccessibilityInspectionResult]
        do {
            results = try await Task.detached(priority: .utility) {
                try service.inspect(
                    scope: scope,
                    minConfidence: minConfidence,
                    frontmostOnly: false,
                    focusedOnly: false,
                    targetBundleIdentifiers: targetBundleIdentifiers,
                    targetAppNames: targetAppNames
                )
            }.value
        } catch {
            UIUnderstandingLog.overlay.debug(
                "debug inspection background accessibility warm skipped error=\(String(describing: error), privacy: .public)"
            )
            return
        }

        var accessibilityByWindow: [UInt32: [DebugUIElement]] = [:]
        for result in results {
            let frame = Self.frameInScreenPointSpace(result.frame, snapshot: result.snapshot)
            for element in frame.elements {
                guard let windowID = Self.windowID(for: element),
                      pendingWindowIDs.contains(windowID)
                else {
                    continue
                }
                accessibilityByWindow[windowID, default: []].append(element)
            }
        }
        guard !accessibilityByWindow.isEmpty else { return }
        for (windowID, accessibilityElements) in accessibilityByWindow {
            let existingAI = (windowElementCache[windowID] ?? []).filter { !Self.isAccessibilityEvidence($0) }
            windowElementCache[windowID] = accessibilityElements + existingAI
        }
        UIUnderstandingLog.overlay.info(
            "debug inspection warmed background accessibility windows=\(accessibilityByWindow.count, privacy: .public)"
        )
    }

    /// Vision-parse one not-yet-parsed background window and cache its boxes. One per pass keeps the
    /// parser from being hammered; the per-window signature marks it done so we do not re-parse it.
    private func warmNextBackgroundVisionWindow(
        screens: [DebugUIScreenSurface],
        excluding activeWindowIDs: Set<UInt32>
    ) async {
        let candidate = backgroundWarmTargets(on: screens, excluding: activeWindowIDs)
            .first { target in
                lastVisionSignatures[target.windowID] == nil
                    && (visionBackoff[target.windowID].map { Date() >= $0.nextAttempt } ?? true)
            }
        guard let target = candidate,
              let screen = screens.first(where: { Self.intersects(target.bounds, $0.captureFrame) })
        else {
            return
        }
        let client: DonkeyBackendInferenceClient
        do {
            client = try backendInferenceClient()
        } catch {
            return
        }

        let windowID = target.windowID
        do {
            let screenshot = try await windowScreenshotCapturer.capture(target: target)
            let signature = ScreenshotSignature.make(fromImageData: screenshot.pngData)
            let compressed = Self.compressedRemoteAIImage(from: screenshot)
            let requestStart = Date()
            let response = try await client.parseScreenshotVision(imageData: compressed.data)
            let elapsedMs = Int(Date().timeIntervalSince(requestStart) * 1000)
            let parsedElements = VisionParseDebugUIOverlayMapper.frame(
                from: response,
                target: target,
                screenFrame: screen.captureFrame,
                minConfidence: currentConfig.minConfidence
            ).elements
            // Keep whatever accessibility we already cached for this window and replace its vision.
            let existingAccessibility = (windowElementCache[windowID] ?? []).filter(Self.isAccessibilityEvidence)
            windowElementCache[windowID] = existingAccessibility + parsedElements
            if let signature {
                lastVisionSignatures[windowID] = signature
            }
            lastVisionElementCounts[windowID] = parsedElements.count
            visionBackoff[windowID] = nil
            publishUnderstanding(for: target, signature: signature)
            UIUnderstandingLog.overlay.info(
                "debug inspection warmed background vision windowID=\(windowID, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public) mappedElements=\(parsedElements.count, privacy: .public)"
            )
        } catch {
            let backoff = Self.nextVisionBackoff(after: visionBackoff[windowID])
            visionBackoff[windowID] = backoff
            UIUnderstandingLog.overlay.error(
                "debug inspection background vision warm failed windowID=\(windowID, privacy: .public) failureStreak=\(backoff.failureStreak, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
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
            UIUnderstandingLog.overlay.info(
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
            UIUnderstandingLog.overlay.debug(
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
        UIUnderstandingLog.overlay.debug(
            "debug inspection accessibility screens=\(results.count, privacy: .public) force=\(String(force), privacy: .public)"
        )

        let activeScreenIDs = Set(results.map(\.snapshot.screenID))
        ageMissingAccessibilityScreens(activeScreenIDs: activeScreenIDs)

        for result in results {
            let snapshot = result.snapshot
            if !force, lastFingerprints[snapshot.screenID] == snapshot.fingerprint {
                UIUnderstandingLog.overlay.debug(
                    "debug inspection sampling unchanged accessibility screenID=\(snapshot.screenID, privacy: .public)"
                )
            }
            lastFingerprints[snapshot.screenID] = snapshot.fingerprint
            lastSnapshots[snapshot.screenID] = snapshot

            var tracker = trackers[snapshot.screenID] ?? Self.makeElementTracker()
            let trackedFrame = tracker.update(with: result.frame)
            trackers[snapshot.screenID] = tracker
            if !force,
               let previousFrame = lastRenderedFrames[snapshot.screenID],
               trackedFrame.isOverlayRenderEquivalent(to: previousFrame) {
                UIUnderstandingLog.overlay.debug(
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
            var tracker = trackers[screenID] ?? Self.makeElementTracker()
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
        UIUnderstandingLog.overlay.info(
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

    /// A window must change by more than this fraction of its normalized grayscale cells before
    /// we re-run a vision parse. ~1.2% of a 64x64 grid is ~50 cells — enough to ignore caret/clock
    /// flicker while still catching a small new control or panel.
    private static let visionChangedFractionThreshold = 0.012

    /// Tracker used for the debug overlay. Within a single focused window, vision (OmniParser)
    /// reassigns IDs and jitters labels every parse, so vision boxes must drop immediately
    /// (tolerance 0) or stale boxes pile up as overlapping duplicates. Accessibility boxes keep
    /// stable IDs, so a short hysteresis bridges the brief detection gaps between the ~8Hz
    /// accessibility scan and the ~1Hz vision pass that otherwise make a box strobe. Across a
    /// window switch the previous window's metadata is not thrown away — it is cached per window
    /// and restored instantly (see `windowElementCache` and `renderActiveAccessibilityResults`).
    private static func makeElementTracker() -> DebugUIElementTracker {
        DebugUIElementTracker(
            appearanceThreshold: 1,
            disappearanceTolerance: 0,
            movementConfirmationSamples: 1,
            stableDisappearanceTolerance: 4,
            stableIDPrefixes: ["ax-", "window-chrome-"]
        )
    }

    /// Remember each window's most recent overlay elements (accessibility + vision) so that when
    /// the user switches back to a window we can paint its last-known overlay immediately instead
    /// of waiting for a fresh accessibility scan and vision parse.
    private func cacheRenderedElements(_ elements: [DebugUIElement]) {
        var byWindow: [UInt32: [DebugUIElement]] = [:]
        for element in elements {
            guard let windowID = Self.windowID(for: element) else { continue }
            byWindow[windowID, default: []].append(element)
        }
        for (windowID, windowElements) in byWindow {
            let newAI = windowElements.filter { !Self.isAccessibilityEvidence($0) }
            if newAI.isEmpty {
                // An accessibility-only render (e.g. the moment right after a window switch, before
                // its vision parse returns) must not wipe this window's cached vision boxes. Refresh
                // the accessibility portion but keep the existing AI, so a later switch back to this
                // window can seed its boxes from cache instantly instead of blanking and re-parsing.
                let existingAI = (windowElementCache[windowID] ?? []).filter { !Self.isAccessibilityEvidence($0) }
                let newAX = windowElements.filter(Self.isAccessibilityEvidence)
                windowElementCache[windowID] = newAX + existingAI
            } else {
                windowElementCache[windowID] = windowElements
            }
        }
    }

    /// Publish this window's fused accessibility + vision understanding to the shared store that the
    /// agent reads when it decides what to act on. Elements are stored in window-local point space,
    /// with the window's point size as the image size — exactly the geometry the agent's tools map
    /// back to a screen point, so a warmed background window is instantly actionable without a parse.
    private func publishUnderstanding(for target: MacWindowTargetCandidate, signature: ScreenshotSignature?) {
        guard let signature else { return }
        let imageWidth = Int(target.bounds.width.rounded())
        let imageHeight = Int(target.bounds.height.rounded())
        guard imageWidth > 0, imageHeight > 0 else { return }

        let elements = (windowElementCache[target.windowID] ?? []).compactMap { element -> DebugUIElement? in
            guard let local = Self.localBounds(for: element) else { return nil }
            return DebugUIElement(
                id: element.id,
                type: element.type,
                label: element.label,
                description: element.description,
                bbox: DebugUIBoundingBox(x: local.x, y: local.y, width: local.width, height: local.height),
                confidence: element.confidence,
                visualStyle: element.visualStyle,
                metadata: element.metadata
            )
        }
        guard !elements.isEmpty else { return }

        let appKey = (target.bundleIdentifier?.isEmpty == false ? target.bundleIdentifier : nil)
            ?? target.appName
            ?? ""
        WindowUIUnderstandingStore.shared.store(
            appKey: appKey,
            entry: WindowUIUnderstandingStore.Entry(
                signature: signature,
                elements: elements,
                imagePixelWidth: imageWidth,
                imagePixelHeight: imageHeight,
                capturedAtUptimeMS: ProcessInfo.processInfo.systemUptime * 1_000
            )
        )
    }

    /// Pull cached elements for the given windows, reprojected onto the window's current on-screen
    /// position so a window that moved while unfocused still lines up. Reprojection with no source
    /// screen places each element from its stored window-local bounds against the window's current
    /// bounds; if the window is not currently enumerable we fall back to the cached geometry.
    private func cachedElements(
        forWindows windowIDs: Set<UInt32>,
        screens: [DebugUIScreenSurface],
        where predicate: (DebugUIElement) -> Bool
    ) -> [UInt32: [DebugUIElement]] {
        guard !windowIDs.isEmpty else { return [:] }
        let candidates = Dictionary(
            uniqueKeysWithValues: windowResolver.enumerateCandidates().map { ($0.windowID, $0) }
        )
        var byScreen: [UInt32: [DebugUIElement]] = [:]
        for windowID in windowIDs {
            for element in windowElementCache[windowID] ?? [] where predicate(element) {
                if let projected = Self.reproject(
                    element,
                    sourceScreen: nil,
                    currentWindowTargets: candidates,
                    screens: screens
                ) {
                    byScreen[projected.screenID, default: []].append(projected.element)
                }
            }
        }
        return byScreen
    }

    private static func nextVisionBackoff(after previous: VisionBackoff?) -> VisionBackoff {
        let baseSeconds = 2.0
        let capSeconds = 30.0
        let failureStreak = (previous?.failureStreak ?? 0) + 1
        let delay = min(baseSeconds * pow(2, Double(failureStreak - 1)), capSeconds)
        return VisionBackoff(
            nextAttempt: Date().addingTimeInterval(delay),
            failureStreak: failureStreak
        )
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
        // OmniParser's OCR runs on the uploaded pixels, so the default 896px / q0.48
        // (tuned for hosted LLM vision) blurs dense UI — e.g. file-list rows fuse into
        // one box. 1568px @ q0.8 separates them while staying a small payload (~hundreds
        // of KB, not MB); coordinates still map back through the returned pixelSize.
        ScreenshotCompression.compressedForModel(
            screenshot,
            maxPixelDimension: 1568,
            jpegQuality: 0.8
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
