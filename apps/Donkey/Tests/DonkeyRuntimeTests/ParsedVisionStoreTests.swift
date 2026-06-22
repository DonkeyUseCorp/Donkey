import DonkeyContracts
import DonkeyRuntime
import Testing

/// Coverage for the per-app parsed-vision cache: a fresh capture reuses the stored elements only when
/// the window looks unchanged, and the app key matches case- and whitespace-insensitively. (The
/// parse-pixel → normalized click mapping is covered in `VisionComputerUseToolsTests`.)
@Suite
struct ParsedVisionStoreTests {
    private func signature(fill: UInt8) -> ScreenshotSignature {
        ScreenshotSignature(
            pixels: [UInt8](repeating: fill, count: 64 * 64),
            dimension: 64
        )
    }

    private func element(id: String, label: String, bbox: DebugUIBoundingBox) -> DebugUIElement {
        DebugUIElement(id: id, type: .button, label: label, bbox: bbox, confidence: 0.9)
    }

    @Test
    func reusesCacheWhenWindowUnchanged() {
        let store = ParsedVisionStore()
        let element = element(id: "1", label: "Discover Weekly", bbox: DebugUIBoundingBox(x: 0, y: 0, width: 10, height: 10))
        store.store(appKey: "com.spotify.client", entry: ParsedVisionStore.Entry(
            signature: signature(fill: 100),
            elements: [element],
            imagePixelWidth: 800,
            imagePixelHeight: 600,
            capturedAtUptimeMS: 0
        ))

        // An identical fingerprint is reused.
        let reused = store.reusableEntry(
            appKey: "com.spotify.client",
            signature: signature(fill: 100),
            changedFractionThreshold: 0.02
        )
        #expect(reused?.elements.first?.label == "Discover Weekly")
    }

    @Test
    func reparsesWhenWindowChangedBeyondThreshold() {
        let store = ParsedVisionStore()
        store.store(appKey: "spotify", entry: ParsedVisionStore.Entry(
            signature: signature(fill: 0),
            elements: [element(id: "1", label: "X", bbox: DebugUIBoundingBox(x: 0, y: 0, width: 1, height: 1))],
            imagePixelWidth: 10,
            imagePixelHeight: 10,
            capturedAtUptimeMS: 0
        ))
        // A wholly different image (every cell maxed) is far above the change threshold → no reuse.
        let reused = store.reusableEntry(
            appKey: "spotify",
            signature: signature(fill: 255),
            changedFractionThreshold: 0.02
        )
        #expect(reused == nil)
    }

    @Test
    func appKeyMatchingIsCaseAndWhitespaceInsensitive() {
        let store = ParsedVisionStore()
        store.store(appKey: "Com.Spotify.Client", entry: ParsedVisionStore.Entry(
            signature: signature(fill: 5),
            elements: [],
            imagePixelWidth: 1,
            imagePixelHeight: 1,
            capturedAtUptimeMS: 0
        ))
        #expect(store.latest(appKey: "  com.spotify.client ") != nil)
    }
}
