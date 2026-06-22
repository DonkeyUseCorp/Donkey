import AppKit
import DonkeyContracts
import DonkeyRuntime
import Foundation

/// Decision the warm-cache monitor makes each tick. Pure and separate from the monitor so the
/// big-change / debounce logic is unit-testable without capture or network.
public enum VisionWarmCacheDecision: String, Equatable, Sendable {
    case parse
    case skipUnchanged
    case skipDebounced
}

public enum VisionWarmCachePolicy {
    /// Parse when this is the first sighting of an app, or when the screen changed by at least
    /// `bigChangeThreshold` of its cells AND we haven't parsed this app within
    /// `minReparseIntervalMS`. The threshold is deliberately higher than the reuse threshold: the
    /// reuse check asks "is this the same screen?", this asks "did something big happen?".
    public static func decide(
        previous: ScreenshotSignature?,
        next: ScreenshotSignature,
        bigChangeThreshold: Double,
        lastParseUptimeMS: Double?,
        nowUptimeMS: Double,
        minReparseIntervalMS: Double
    ) -> VisionWarmCacheDecision {
        guard let previous else { return .parse }
        let changed = next.changedFraction(from: previous)
        guard changed >= bigChangeThreshold else { return .skipUnchanged }
        if let lastParseUptimeMS, nowUptimeMS - lastParseUptimeMS < minReparseIntervalMS {
            return .skipDebounced
        }
        return .parse
    }
}

/// Process-wide gate that lets an active vision drive pause the warm-cache monitor, so the two never
/// race to parse and write the same app's entry in `ParsedVisionStore` at the same time.
public final class VisionWarmCacheActivity: @unchecked Sendable {
    public static let shared = VisionWarmCacheActivity()

    private let lock = NSLock()
    private var depth = 0

    public init() {}

    public var isSuspended: Bool {
        lock.lock(); defer { lock.unlock() }
        return depth > 0
    }

    public func suspend() {
        lock.lock(); depth += 1; lock.unlock()
    }

    public func resume() {
        lock.lock(); depth = max(0, depth - 1); lock.unlock()
    }
}

/// Always-on, non-LLM monitor that keeps `ParsedVisionStore` warm: it watches the frontmost user
/// window's screenshot fingerprint and, when a *big* change happens, captures + parses once and
/// stores the result. So when the model later calls `screen.captureAndAnalyze`, the window is usually
/// unchanged since the last big change and the parse is reused instantly instead of paid for inline.
///
/// This is detection-driven, not action-driven: it fires on any large on-screen change (a navigation,
/// a new dialog), independent of whether the agent caused it.
@MainActor
public final class FrontmostVisionWarmCache {
    private let analyzer: any DebugUIInspectionAnalyzing
    private let store: ParsedVisionStore
    private let capture: VisionActionDriver.ScreenshotCapture
    private let permissionChecker: any ScreenRecordingPermissionChecking
    private let cadenceNanoseconds: UInt64
    private let bigChangeThreshold: Double
    private let minReparseIntervalMS: Double
    private let minConfidence: Double
    private let uptimeMS: @Sendable () -> Double

    private var task: Task<Void, Never>?
    private var lastSignatureByApp: [String: ScreenshotSignature] = [:]
    private var lastParseUptimeMSByApp: [String: Double] = [:]

    public init(
        analyzer: any DebugUIInspectionAnalyzing,
        store: ParsedVisionStore = .shared,
        capture: @escaping VisionActionDriver.ScreenshotCapture = { try await ScreenCaptureKitWindowScreenshotCapturer().capture(target: $0) },
        permissionChecker: any ScreenRecordingPermissionChecking = CoreGraphicsScreenRecordingPermissionChecker(),
        cadenceNanoseconds: UInt64 = 700_000_000,
        bigChangeThreshold: Double = 0.10,
        minReparseIntervalMS: Double = 1_500,
        minConfidence: Double = 0.25,
        uptimeMS: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime * 1_000 }
    ) {
        self.analyzer = analyzer
        self.store = store
        self.capture = capture
        self.permissionChecker = permissionChecker
        self.cadenceNanoseconds = cadenceNanoseconds
        self.bigChangeThreshold = bigChangeThreshold
        self.minReparseIntervalMS = minReparseIntervalMS
        self.minConfidence = minConfidence
        self.uptimeMS = uptimeMS
    }

    /// Builds the monitor from the environment-configured vision backend, or returns nil when the
    /// backend isn't configured (so the app simply doesn't run it).
    public static func fromEnvironment() -> FrontmostVisionWarmCache? {
        guard let configuration = try? DonkeyBackendInferenceConfiguration.fromEnvironment() else {
            return nil
        }
        let backend = DonkeyBackendInferenceClient(configuration: configuration)
        return FrontmostVisionWarmCache(analyzer: HostedDebugUIInspectionAnalyzer(backend: backend))
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.loop()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func loop() async {
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(nanoseconds: cadenceNanoseconds)
        }
    }

    func tick() async {
        guard !VisionWarmCacheActivity.shared.isSuspended else { return }
        // Nothing to keep warm while signed out — the parse would only 401. Skip the expensive capture
        // entirely rather than spending it on a doomed backend call.
        guard BackendSessionGate.shared.isAuthenticated else { return }
        // Only warm around real Donkey use. While the user isn't engaging Donkey (no task running and
        // no recent interaction) there is nothing to keep warm for, so skip the parse instead of
        // draining the backend the whole time the app sits open and idle.
        guard DonkeyEngagement.shared.isEngaged() else { return }
        guard permissionChecker.hasScreenRecordingAccess() else { return }
        guard let target = MacWindowResolver().frontmostUserAppTarget() else { return }
        let appKey = target.bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? target.appName ?? ""
        guard !appKey.isEmpty else { return }
        guard let shot = try? await capture(target),
              let signature = ScreenshotSignature.make(fromImageData: shot.pngData) else {
            return
        }

        let decision = VisionWarmCachePolicy.decide(
            previous: lastSignatureByApp[appKey],
            next: signature,
            bigChangeThreshold: bigChangeThreshold,
            lastParseUptimeMS: lastParseUptimeMSByApp[appKey],
            nowUptimeMS: uptimeMS(),
            minReparseIntervalMS: minReparseIntervalMS
        )

        // On debounce keep the OLD fingerprint so the next eligible tick still sees the big change and
        // can parse once the debounce window clears. Otherwise record what we just saw.
        if decision != .skipDebounced {
            lastSignatureByApp[appKey] = signature
        }
        guard decision == .parse else { return }

        let compressed = ScreenshotCompression.compressedForModel(shot)
        let imageWidth = max(1, Int(compressed.pixelSize.width.rounded()))
        let imageHeight = max(1, Int(compressed.pixelSize.height.rounded()))
        guard let frame = try? await analyzer.inspect(
            DebugUIInspectionRequest(
                imageDataURL: compressed.base64DataURL,
                pixelSize: compressed.pixelSize,
                minConfidence: minConfidence
            )
        ) else {
            return
        }
        // A drive may have suspended us while we were capturing and parsing. Re-check before writing so
        // a warm parse that started before the drive cannot overwrite the drive's fresher entry.
        guard !VisionWarmCacheActivity.shared.isSuspended else { return }
        store.store(
            appKey: appKey,
            entry: ParsedVisionStore.Entry(
                signature: signature,
                elements: frame.elements,
                imagePixelWidth: imageWidth,
                imagePixelHeight: imageHeight,
                capturedAtUptimeMS: uptimeMS()
            )
        )
        lastParseUptimeMSByApp[appKey] = uptimeMS()
    }
}
