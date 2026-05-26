import AppKit
import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation
import OSLog

private enum DebugUIInspectionLog {
    static let overlay = Logger(subsystem: "com.donkey.app", category: "debug-ui-inspection")
}

@MainActor
final class DebugUIInspectionCoordinator {
    private let overlayController = DebugUIInspectionOverlayController()
    private let captureService = DebugUIScreenCaptureService()
    private let accessibilityInspectionService = DebugUIAccessibilityInspectionService()
    private let configURL: URL?
    private var analyzer: (any DebugUIInspectionAnalyzing)?
    private var trackers: [UInt32: DebugUIElementTracker] = [:]
    private var lastFingerprints: [UInt32: String] = [:]
    private var lastRenderedFrames: [UInt32: DebugUIInspectionFrame] = [:]
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
        let providerChanged = newConfig.provider != currentConfig.provider
        let confidenceChanged = newConfig.minConfidence != currentConfig.minConfidence
        currentConfig = newConfig

        if force || enablementChanged || scopeChanged || providerChanged || confidenceChanged {
            DebugUIInspectionLog.overlay.info(
                "debug inspection config enabled=\(String(newConfig.enabled), privacy: .public) provider=\(newConfig.provider.rawValue, privacy: .public) cadence=\(newConfig.cadenceSeconds, privacy: .public) scope=\(newConfig.screenScope.rawValue, privacy: .public) minConfidence=\(newConfig.minConfidence, privacy: .public)"
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

        if enablementChanged || scopeChanged || providerChanged || confidenceChanged {
            lastFingerprints.removeAll()
            trackers.removeAll()
            lastRenderedFrames.removeAll()
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
        if currentConfig.provider == .accessibility {
            try analyzeAccessibilityScreens(force: force)
            return
        }

        let snapshots = try captureService.captureScreens(scope: currentConfig.screenScope)
        DebugUIInspectionLog.overlay.debug(
            "debug inspection captured screens=\(snapshots.count, privacy: .public) force=\(String(force), privacy: .public)"
        )
        let activeScreenIDs = Set(snapshots.map(\.screenID))
        overlayController.closeScreens(except: activeScreenIDs)
        lastRenderedFrames = lastRenderedFrames.filter { activeScreenIDs.contains($0.key) }
        let analyzer = try analyzerInstance()

        for snapshot in snapshots {
            guard force || lastFingerprints[snapshot.screenID] != snapshot.fingerprint else {
                DebugUIInspectionLog.overlay.debug(
                    "debug inspection skipped unchanged screenID=\(snapshot.screenID, privacy: .public)"
                )
                continue
            }
            lastFingerprints[snapshot.screenID] = snapshot.fingerprint
            DebugUIInspectionLog.overlay.info(
                "debug inspection analyzing screenID=\(snapshot.screenID, privacy: .public) pixels=\(snapshot.pixelSize.width, privacy: .public)x\(snapshot.pixelSize.height, privacy: .public)"
            )
            let frame = try await analyzer.inspect(
                DebugUIInspectionRequest(
                    provider: currentConfig.provider,
                    screenshotBase64: snapshot.base64PNG,
                    pixelSize: snapshot.pixelSize,
                    minConfidence: currentConfig.minConfidence,
                    metadata: [
                        "screen.id": String(snapshot.screenID),
                        "screen.scope": currentConfig.screenScope.rawValue
                    ]
                )
            )
            var tracker = trackers[snapshot.screenID] ?? DebugUIElementTracker()
            let trackedFrame = tracker.update(with: frame)
            trackers[snapshot.screenID] = tracker
            DebugUIInspectionLog.overlay.info(
                "debug inspection rendering screenID=\(snapshot.screenID, privacy: .public) elements=\(trackedFrame.elements.count, privacy: .public)"
            )
            logSampleMappings(frame: trackedFrame, snapshot: snapshot)
            lastRenderedFrames[snapshot.screenID] = trackedFrame
            overlayController.render(frame: trackedFrame, snapshot: snapshot)
        }
    }

    private func analyzeAccessibilityScreens(force: Bool) throws {
        let results = try accessibilityInspectionService.inspect(
            scope: currentConfig.screenScope,
            minConfidence: currentConfig.minConfidence
        )
        DebugUIInspectionLog.overlay.debug(
            "debug inspection accessibility screens=\(results.count, privacy: .public) force=\(String(force), privacy: .public)"
        )

        let activeScreenIDs = Set(results.map(\.snapshot.screenID))
        overlayController.closeScreens(except: activeScreenIDs)
        lastRenderedFrames = lastRenderedFrames.filter { activeScreenIDs.contains($0.key) }

        for result in results {
            let snapshot = result.snapshot
            guard force || lastFingerprints[snapshot.screenID] != snapshot.fingerprint else {
                DebugUIInspectionLog.overlay.debug(
                    "debug inspection skipped unchanged accessibility screenID=\(snapshot.screenID, privacy: .public)"
                )
                continue
            }
            lastFingerprints[snapshot.screenID] = snapshot.fingerprint

            var tracker = trackers[snapshot.screenID] ?? DebugUIElementTracker()
            let trackedFrame = tracker.update(with: result.frame)
            trackers[snapshot.screenID] = tracker
            DebugUIInspectionLog.overlay.info(
                "debug inspection rendering source=accessibility screenID=\(snapshot.screenID, privacy: .public) elements=\(trackedFrame.elements.count, privacy: .public)"
            )
            logSampleMappings(frame: trackedFrame, snapshot: snapshot)
            lastRenderedFrames[snapshot.screenID] = trackedFrame
            overlayController.render(frame: trackedFrame, snapshot: snapshot)
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
}
