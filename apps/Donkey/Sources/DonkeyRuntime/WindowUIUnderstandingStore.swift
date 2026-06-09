import DonkeyContracts
import Foundation

/// Process-wide cache of the latest *fused accessibility + vision* understanding per app, produced by
/// the always-on `UIUnderstandingCoordinator`. The agent's decision tools read this first so a
/// `screen.captureAndAnalyze` reuses elements that were already extracted (often for a background
/// window) instead of paying for a fresh parse.
///
/// Like `ParsedVisionStore`, elements are stored in the parse image's pixel space together with that
/// pixel size, and reuse is gated by a `ScreenshotSignature` so a stale entry is never reused for a
/// window that has since changed. Keyed by a stable app key (bundle identifier, falling back to app
/// name) so the agent can look it up by the app it is acting on.
public final class WindowUIUnderstandingStore: @unchecked Sendable {
    public static let shared = WindowUIUnderstandingStore()

    public struct Entry: Sendable {
        public var signature: ScreenshotSignature
        /// Fused accessibility + vision elements with `bbox` in the parse image's pixel space.
        public var elements: [DebugUIElement]
        public var imagePixelWidth: Int
        public var imagePixelHeight: Int
        public var capturedAtUptimeMS: Double

        public init(
            signature: ScreenshotSignature,
            elements: [DebugUIElement],
            imagePixelWidth: Int,
            imagePixelHeight: Int,
            capturedAtUptimeMS: Double
        ) {
            self.signature = signature
            self.elements = elements
            self.imagePixelWidth = imagePixelWidth
            self.imagePixelHeight = imagePixelHeight
            self.capturedAtUptimeMS = capturedAtUptimeMS
        }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init() {}

    public func store(appKey: String, entry: Entry) {
        let key = Self.normalize(appKey)
        guard !key.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        entries[key] = entry
    }

    public func latest(appKey: String) -> Entry? {
        let key = Self.normalize(appKey)
        guard !key.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return entries[key]
    }

    /// Returns the cached entry only when its fingerprint is close enough to `signature` to treat the
    /// window as unchanged, so the caller can reuse its elements without re-parsing.
    public func reusableEntry(
        appKey: String,
        signature: ScreenshotSignature,
        changedFractionThreshold: Double
    ) -> Entry? {
        guard let entry = latest(appKey: appKey) else { return nil }
        let changed = signature.changedFraction(from: entry.signature)
        return changed <= changedFractionThreshold ? entry : nil
    }

    private static func normalize(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
