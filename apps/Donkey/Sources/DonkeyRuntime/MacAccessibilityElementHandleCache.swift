@preconcurrency import ApplicationServices
import Foundation

/// MainActor-confined cache of the live `AXUIElement` handles captured during an observe, keyed by
/// process. A handle keeps pointing at the same logical control even after siblings are inserted,
/// removed, or reordered — and errors cleanly once the control is destroyed — so resolving an action
/// against the held handle is far more robust than re-walking the tree by positional node index.
///
/// The cache is replaced wholesale for a process on each observe; that replacement *is* the
/// invalidation. Handles live only until the next observe of the same process drops them (bounded by
/// the snapshot's node limit), so there is nothing to expire or evict by hand.
///
/// `AXUIElement` is a `CFType` and not `Sendable`; all access is confined to the main actor. Callers
/// off the main thread (the action backend runs inside a timeout on a background queue) reach the
/// cache through a `DispatchQueue.main.sync` hop, the same pattern the backend already uses to read
/// the frontmost application.
@MainActor
final class MacAccessibilityElementHandleCache {
    static let shared = MacAccessibilityElementHandleCache()

    private var handlesByProcess: [pid_t: [String: AXUIElement]] = [:]

    /// Replaces every handle held for `processID` with the freshly captured set, releasing the prior
    /// snapshot's handles.
    func replace(processID: pid_t, handles: [String: AXUIElement]) {
        if handles.isEmpty {
            handlesByProcess.removeValue(forKey: processID)
        } else {
            handlesByProcess[processID] = handles
        }
    }

    /// The live handle captured for `nodeID` in the latest observe of `processID`, or nil if there is
    /// no current snapshot for that process or it didn't contain the node.
    func handle(processID: pid_t, nodeID: String) -> AXUIElement? {
        handlesByProcess[processID]?[nodeID]
    }

    /// Drops all handles for a process (e.g. when it exits). Tests also use this to reset state.
    func clear(processID: pid_t) {
        handlesByProcess.removeValue(forKey: processID)
    }
}
