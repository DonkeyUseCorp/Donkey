import Foundation

/// Process-wide signal for whether the user is actually engaging Donkey right now. The always-on
/// vision warm caches consult this so they only spend on parses around real Donkey use instead of
/// burning the backend the entire time the app sits open and idle.
///
/// "Engaged" means either a harness run is in flight, or the last interaction (a submitted command, or
/// a just-finished run) landed within the engagement window. When neither holds, the warm caches stop
/// parsing — the first command after a quiet period pays one inline parse, which is exactly when the
/// spend is warranted.
public final class DonkeyEngagement: @unchecked Sendable {
    public static let shared = DonkeyEngagement()

    /// How long after the last interaction the warm caches keep running before idling out. Long enough
    /// to cover a quick follow-up without re-warming from cold, short enough that walking away stops the
    /// spend within about a minute.
    public static let defaultEngagementWindowMS: Double = 60_000

    private let lock = NSLock()
    private var activeRunDepth = 0
    private var lastInteractionUptimeMS: Double?
    private let uptimeMS: @Sendable () -> Double

    public init(uptimeMS: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime * 1_000 }) {
        self.uptimeMS = uptimeMS
    }

    /// Record a direct user interaction with Donkey (a submitted command). Opens the engagement window.
    public func noteInteraction() {
        lock.lock(); lastInteractionUptimeMS = uptimeMS(); lock.unlock()
    }

    /// Bracket an active harness run. While depth > 0 the user is engaged unconditionally so warming
    /// keeps the understanding store fresh for the whole task, however long it runs.
    public func beginRun() {
        lock.lock(); activeRunDepth += 1; lock.unlock()
    }

    /// Pairs with `beginRun`. Stamps an interaction on the way out so the window stays open briefly
    /// after the run for a follow-up command before warming idles out.
    public func endRun() {
        lock.lock()
        activeRunDepth = max(0, activeRunDepth - 1)
        lastInteractionUptimeMS = uptimeMS()
        lock.unlock()
    }

    /// True when a run is in flight or the last interaction is within `windowMS`.
    public func isEngaged(windowMS: Double = DonkeyEngagement.defaultEngagementWindowMS) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if activeRunDepth > 0 { return true }
        guard let last = lastInteractionUptimeMS else { return false }
        return uptimeMS() - last < windowMS
    }
}
