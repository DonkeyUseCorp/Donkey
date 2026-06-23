import Foundation

/// The prebuilt CLI tools (ffmpeg, ffprobe, yt-dlp, ...) that Donkey's capability skills run by bare
/// name. The shipped app stays small and downloads a self-contained arm64 bundle on first run into
/// Application Support; this type is the shared knowledge of *what* to fetch and *where* it lives.
///
/// `bundled-tools.json` (in the app's resource bundle) is the single source of truth for the version,
/// download URL, and checksum; scripts/publish-bundled-tools.sh builds the artifact and rewrites it.
public enum BundledTools {
    /// Bare executable names of the tools shipped in the bundle — the mandatory media set from
    /// scripts/publish-bundled-tools.sh plus the document tools fetched in fetch-bundled-tools.sh. Donkey
    /// resolves these from `installDirectory`, which `shellEnvironment()` puts on PATH, so capability
    /// skills run them by bare name. This is the single Swift home for the list; keep it in step with the
    /// fetch/publish scripts when the bundle gains or drops a tool.
    public static let executableNames: Set<String> = [
        "ffmpeg", "ffprobe", "yt-dlp", "lit", "pdf-fill", "qpdf", "exiftool"
    ]

    /// Tools that unpack a private interpreter/runtime to a temp dir at launch and `dlopen()` it — a
    /// PyInstaller onefile binary like `yt-dlp`. Under the hardened runtime, library validation rejects
    /// that load when the extracted framework's Team ID differs from the binary's ("different Team IDs"),
    /// so a copy signed with the runtime flag but no exception cannot start at all. These need the
    /// `com.apple.security.cs.disable-library-validation` entitlement; `scripts/sign-bundled-tools.sh`
    /// signs exactly these with it, and `BundledToolsInstaller` repairs the downloaded copy the same way.
    /// Keep this list in step with that script.
    public static let selfExtractingExecutableNames: Set<String> = ["yt-dlp"]

    /// The manifest describing the published tools bundle. An empty `sha256` means nothing is published
    /// yet, so callers should treat the bundle as unavailable rather than downloading something unverified.
    public struct Manifest: Decodable, Sendable, Equatable {
        public let version: String
        public let arch: String
        public let url: String
        public let sha256: String

        public var isPublished: Bool {
            !sha256.isEmpty && URL(string: url) != nil
        }
    }

    /// Where first-run-downloaded tools are extracted. Writable, survives app updates, and is the first
    /// place `shellEnvironment()` looks for the tools on PATH.
    public static var installDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Donkey", isDirectory: true)
            .appendingPathComponent("donkey-tools", isDirectory: true)
    }

    /// The version-marker file written after a successful install, so we re-download only when the
    /// manifest names a newer bundle.
    static var installedVersionMarker: URL {
        installDirectory.appendingPathComponent(".version", isDirectory: false)
    }

    /// The bundle is usable if a sentinel tool exists in the install directory. ffmpeg is mandatory in
    /// every bundle, so its presence is the cheapest "are the tools really here" check.
    public static func isInstalled(at directory: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("ffmpeg").path)
    }

    /// The version currently installed in Application Support, or nil if none/partial.
    public static var installedVersion: String? {
        guard isInstalled(at: installDirectory),
              let raw = try? String(contentsOf: installedVersionMarker, encoding: .utf8)
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Load the bundled manifest from the app's resources. Returns nil if it is missing or malformed.
    public static func loadManifest() -> Manifest? {
        guard let url = DonkeyResourceBundle.runtime?.url(forResource: "bundled-tools", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }
}
