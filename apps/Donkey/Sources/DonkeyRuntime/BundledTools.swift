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
        "ffmpeg", "ffprobe", "yt-dlp", "lit", "pdf-fill", "epub-pack", "reframe", "qpdf", "exiftool"
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

    /// Parent of the per-version tool installs. Writable, survives app updates, and is where
    /// `shellEnvironment()` looks for the tools on PATH. Each published bundle lives in its own
    /// `<baseDirectory>/<version>` subdirectory (see `installDirectory(forVersion:)`), so an app build
    /// reads and writes only the version its manifest pins — a different build (e.g. a dev copy) installing
    /// another version into a sibling directory cannot disturb it. The overlay symlink dir is a sibling of
    /// this one.
    public static var baseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Donkey", isDirectory: true)
            .appendingPathComponent("donkey-tools", isDirectory: true)
    }

    /// Where a specific bundle version is installed. The version string IS the directory name, so the
    /// directory itself records which bundle is present — there is no separate marker file to drift out of
    /// sync with the bytes on disk.
    public static func installDirectory(forVersion version: String) -> URL {
        baseDirectory.appendingPathComponent(version, isDirectory: true)
    }

    /// The bundle is usable if a sentinel tool exists in the directory. ffmpeg is mandatory in every
    /// bundle, so its presence is the cheapest "are the tools really here" check.
    public static func isInstalled(at directory: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("ffmpeg").path)
    }

    /// A pre-namespacing install: ffmpeg sits directly under `baseDirectory` instead of in a `<version>`
    /// subdirectory. The installer clears such a layout once before installing the versioned set, so an
    /// app updated from an older build reclaims the loose copy rather than leaving it as orphaned cruft.
    public static var hasLegacyFlatInstall: Bool { isInstalled(at: baseDirectory) }

    /// Installed bundle versions present on disk — each a `<baseDirectory>/<version>` directory holding a
    /// usable ffmpeg — ordered most-recently-used first (the installer refreshes a version's mtime on every
    /// launch that uses it). Empty when nothing is installed. The legacy flat layout is not a version
    /// directory, so it never appears here.
    public static func installedVersions() -> [URL] {
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return entries.filter { isInstalled(at: $0) }.sorted { modified($0) > modified($1) }
    }

    /// The install directory the running app should use right now: the version its manifest pins when that
    /// version is installed, otherwise the most-recently-used installed version (so usable tools still
    /// resolve while the pinned version is still downloading, or when the manifest can't be read). `nil`
    /// only when no tools are installed at all.
    public static func resolvedInstallDirectory() -> URL? {
        if let version = loadManifest()?.version {
            let pinned = installDirectory(forVersion: version)
            if isInstalled(at: pinned) { return pinned }
        }
        if let newest = installedVersions().first { return newest }
        // A pre-namespacing flat install still has usable tools until the versioned install replaces them,
        // so a build updated from an older copy keeps its capabilities through the one-time migration.
        return hasLegacyFlatInstall ? baseDirectory : nil
    }

    /// Whether the tools this app build pins are ready, i.e. setup has nothing left to do: the manifest's
    /// version is installed, or — when nothing is published — any usable tools exist (a dev symlink or
    /// offline-baked copy). Drives the "setup already done" decisions.
    public static var isCurrentVersionReady: Bool {
        if let manifest = loadManifest(), manifest.isPublished {
            return isInstalled(at: installDirectory(forVersion: manifest.version))
        }
        return resolvedInstallDirectory() != nil
    }

    /// Load the bundled manifest from the app's resources. Returns nil if it is missing or malformed.
    public static func loadManifest() -> Manifest? {
        guard let url = DonkeyResourceBundle.runtime?.url(forResource: "bundled-tools", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }
}
