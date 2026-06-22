import DonkeyRuntime
import Foundation
import Testing

@Suite
struct BundledToolsTests {
    private func decode(_ json: String) -> BundledTools.Manifest? {
        try? JSONDecoder().decode(BundledTools.Manifest.self, from: Data(json.utf8))
    }

    @Test
    func emptyChecksumMeansNotPublished() {
        // An empty sha256 is the "nothing published yet" sentinel: callers must not download.
        let m = decode(#"{"version":"1","arch":"arm64","url":"https://x/y.tar.gz","sha256":""}"#)
        #expect(m?.isPublished == false)
    }

    @Test
    func realChecksumAndURLMeansPublished() {
        let m = decode(#"{"version":"1","arch":"arm64","url":"https://x/y.tar.gz","sha256":"abc123"}"#)
        #expect(m?.isPublished == true)
    }

    @Test
    func malformedURLIsNotPublished() {
        let m = decode(#"{"version":"1","arch":"arm64","url":"","sha256":"abc123"}"#)
        #expect(m?.isPublished == false)
    }

    @Test
    func shippedManifestLoadsAndNamesAnArm64Asset() {
        // The manifest bundled into the app must parse and point at a versioned arm64 tools asset.
        let m = BundledTools.loadManifest()
        #expect(m != nil)
        #expect(m?.arch == "arm64")
        #expect(m?.url.contains("donkey-tools") == true)
    }

    @Test
    func installDirectoryIsUnderApplicationSupport() {
        #expect(BundledTools.installDirectory.path.contains("Application Support/Donkey/donkey-tools"))
    }
}
