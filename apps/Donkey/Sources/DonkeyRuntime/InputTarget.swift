import DonkeyContracts
import Foundation

/// A pinned handle to the one window the harness intends to drive: its process, window id, bounds, and
/// bundle. Built from a freshly resolved `MacWindowTargetCandidate` so a background action routes to a
/// specific `(pid, windowID)` instead of "whatever is frontmost". Because candidates come from the
/// on-screen window list, a pinned target is already on the active Space and not minimized.
public struct InputTarget: Equatable, Sendable {
    public var processID: pid_t
    public var windowID: UInt32
    public var bounds: WindowTargetBounds
    public var bundleIdentifier: String?

    public init(
        processID: pid_t,
        windowID: UInt32,
        bounds: WindowTargetBounds,
        bundleIdentifier: String? = nil
    ) {
        self.processID = processID
        self.windowID = windowID
        self.bounds = bounds
        self.bundleIdentifier = bundleIdentifier
    }

    public init(candidate: MacWindowTargetCandidate) {
        self.init(
            processID: pid_t(candidate.processID),
            windowID: candidate.windowID,
            bounds: candidate.bounds,
            bundleIdentifier: candidate.bundleIdentifier
        )
    }
}
