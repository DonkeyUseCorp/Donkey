import AppKit
import CoreGraphics

/// Watches for macOS Mission Control and reports when it becomes active or inactive.
///
/// macOS exposes no public notification for Mission Control, so we poll the window
/// server. When Mission Control opens, the Dock process puts up one or more full-display
/// windows; its space/backdrop surface sits just below the dock window level. That
/// backdrop is the signal.
///
/// Two Dock-owned full-screen windows are NOT Mission Control and must be ruled out: the
/// always-present wallpaper (drawn at a deeply negative window level) and the auto-hide
/// Dock's reveal surface (a full-display window drawn whenever the Dock slides into view).
/// `detectFullScreenDockWindow` documents how Mission Control is told apart from a mere
/// reveal so that revealing an auto-hidden Dock no longer hides the notch.
///
/// Two things make naive polling feel bad, and this type handles both:
///   - The poll runs on a background queue, not a main-thread timer. Mission Control's
///     open/close animation starves the main run loop, which would otherwise delay a
///     main-thread poll until the animation finishes — the source of the "laggy" feel.
///   - The full-screen Dock window briefly disappears mid-transition. We turn the state
///     ON immediately but OFF only after the signal has been gone for a few polls, so the
///     notch doesn't twitch on those gaps.
///
/// Threading contract (why `@unchecked Sendable` is sound): `onChange`, `isActive`, the
/// timer, and the observer are touched only on the main thread; `screenSizes`,
/// `publishedActive`, and `offPollStreak` are touched only on `queue`. The two sides
/// communicate by dispatching across, never by sharing.
final class MissionControlMonitor: @unchecked Sendable {
    /// Always invoked on the main thread when the active/inactive state flips.
    var onChange: ((Bool) -> Void)?
    private(set) var isActive = false

    private let queue = DispatchQueue(label: "com.donkey.mission-control-monitor", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var screenParameterObserver: Any?

    // Queue-confined state.
    private var screenSizes: [CGSize] = []
    private var publishedActive = false
    private var offPollStreak = 0

    /// A Dock-owned window must cover at least this fraction of a screen in both axes to
    /// count as Mission Control. The Dock strip is large in only one axis, so requiring
    /// both keeps the strip (and ordinary windows) from matching.
    private let coverageThreshold: CGFloat = 0.9

    /// 100 ms is responsive without being costly; the geometry-only query is cheap.
    private let pollInterval: TimeInterval = 0.1

    /// Mission Control drops its full-screen Dock window for a poll or two during the
    /// open/close transition. Turn ON the instant we see the signal, but turn OFF only
    /// after it has been absent this many consecutive polls, so the notch rides the gaps.
    private let deactivationDebouncePolls = 3

    func start() {
        stop()
        refreshScreenSizes()
        screenParameterObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshScreenSizes()
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Fire immediately so the first activation doesn't pay one-time setup latency.
        timer.schedule(deadline: .now(), repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if let screenParameterObserver {
            NotificationCenter.default.removeObserver(screenParameterObserver)
            self.screenParameterObserver = nil
        }
        queue.async { [weak self] in
            self?.publishedActive = false
            self?.offPollStreak = 0
        }
        if isActive {
            isActive = false
            onChange?(false)
        }
    }

    /// Main thread: snapshot screen sizes and hand them to the polling queue.
    private func refreshScreenSizes() {
        let sizes = NSScreen.screens.map(\.frame.size)
        queue.async { [weak self] in
            self?.screenSizes = sizes
        }
    }

    /// Polling queue: detect, debounce, and publish state changes to the main thread.
    private func poll() {
        let detected = Self.detectFullScreenDockWindow(
            screenSizes: screenSizes,
            coverageThreshold: coverageThreshold
        )

        let next: Bool
        if detected {
            offPollStreak = 0
            next = true
        } else {
            offPollStreak += 1
            next = offPollStreak >= deactivationDebouncePolls ? false : publishedActive
        }

        guard next != publishedActive else { return }
        publishedActive = next
        DispatchQueue.main.async { [weak self] in
            self?.deliver(next)
        }
    }

    /// Main thread: surface the flip to the owner.
    private func deliver(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        onChange?(active)
    }

    /// Returns true when the on-screen, Dock-owned windows look like Mission Control rather
    /// than a revealed auto-hide Dock.
    ///
    /// Both put up a full-display Dock-owned window, so coverage alone can't tell them apart.
    /// Two observed traits do, and we require either one so the check degrades safely if a
    /// macOS release shifts the window levels:
    ///   - Mission Control draws a backdrop off the dock window level (observed just below
    ///     it); the lone reveal surface sits at exactly the dock level.
    ///   - Mission Control draws several full-display surfaces at once; a reveal draws one.
    /// The wallpaper (a deeply negative level) is always excluded.
    private static func detectFullScreenDockWindow(
        screenSizes: [CGSize],
        coverageThreshold: CGFloat
    ) -> Bool {
        guard !screenSizes.isEmpty else { return false }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))

        var fullDisplayDockWindows = 0
        var hasWindowOffDockLevel = false

        for window in windows {
            guard let owner = window[kCGWindowOwnerName as String] as? String, owner == "Dock" else {
                continue
            }
            // Skip the deep background layers (wallpaper, desktop icons) at negative levels.
            guard let layer = window[kCGWindowLayer as String] as? Int, layer >= 0 else {
                continue
            }
            guard let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else {
                continue
            }
            let coversAnyScreen = screenSizes.contains {
                bounds.width >= $0.width * coverageThreshold && bounds.height >= $0.height * coverageThreshold
            }
            guard coversAnyScreen else { continue }

            fullDisplayDockWindows += 1
            if layer != dockLevel {
                hasWindowOffDockLevel = true
            }
        }

        return hasWindowOffDockLevel || fullDisplayDockWindows >= 2
    }
}
