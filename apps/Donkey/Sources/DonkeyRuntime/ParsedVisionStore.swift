import DonkeyContracts
import Foundation

/// Process-wide cache of the most recent vision parse per app, so a typed command can reuse the
/// elements that were already detected instead of paying for another `/api/vision` parse
/// on every turn. Keyed by a stable app key (bundle identifier, falling back to app name).
///
/// Reuse is gated by `ScreenshotSignature`: a fresh capture is fingerprinted and compared to the
/// cached one; only when the window looks unchanged (below the change threshold) do we reuse the
/// stored elements. Elements are stored in the parse image's pixel space together with that pixel
/// size, so the caller can map a box back to the *current* window bounds even if the window moved.
public final class ParsedVisionStore: @unchecked Sendable {
    public static let shared = ParsedVisionStore()

    public struct Entry: Sendable {
        public var signature: ScreenshotSignature
        /// Detected elements with `bbox` in the parse image's pixel space (NOT screen points).
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
