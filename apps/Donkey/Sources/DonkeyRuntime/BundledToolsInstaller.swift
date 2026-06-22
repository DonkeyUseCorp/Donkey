import CryptoKit
import Foundation
import os

/// Downloads the prebuilt CLI tools bundle (ffmpeg, yt-dlp, ...) into Application Support on first run, so
/// the shipped app stays small and the capability skills "just work" without the user installing anything.
///
/// Serialized via an actor: safe to call on every launch and concurrently — it no-ops when the manifest
/// version is already installed, when nothing is published yet, or when an install is already in flight.
/// Verifies the SHA-256 before trusting the bytes and swaps the new tools in atomically.
public actor BundledToolsInstaller {
    public static let shared = BundledToolsInstaller()

    private var installing = false
    private let log = Logger(subsystem: "com.donkey.app", category: "BundledTools")

    enum InstallError: Error {
        case badURL
        case checksumMismatch(expected: String, got: String)
        case extractFailed(status: Int32)
        case noToolsInArchive
    }

    public init() {}

    /// Ensure the published tools bundle is installed and current. Returns whether usable tools are present
    /// afterward. Cheap to call repeatedly; the heavy download runs only when the installed version differs
    /// from the manifest.
    @discardableResult
    public func installIfNeeded() async -> Bool {
        guard let manifest = BundledTools.loadManifest(), manifest.isPublished else {
            // Nothing published yet (empty sha256): rely on whatever is already on disk (e.g. a dev symlink
            // or an offline-baked bundle); never download something unverified.
            return BundledTools.isInstalled(at: BundledTools.installDirectory)
        }
        if BundledTools.installedVersion == manifest.version { return true }
        guard !installing else { return false }
        installing = true
        defer { installing = false }

        do {
            try await install(manifest)
            log.info("installed bundled tools \(manifest.version, privacy: .public)")
            return true
        } catch {
            log.error("bundled tools install failed: \(String(describing: error), privacy: .public)")
            return BundledTools.isInstalled(at: BundledTools.installDirectory)
        }
    }

    private func install(_ manifest: BundledTools.Manifest) async throws {
        guard let url = URL(string: manifest.url) else { throw InstallError.badURL }
        let fm = FileManager.default

        let (downloaded, _) = try await URLSession.shared.download(from: url)
        defer { try? fm.removeItem(at: downloaded) }

        let digest = try sha256Hex(of: downloaded)
        guard digest == manifest.sha256.lowercased() else {
            throw InstallError.checksumMismatch(expected: manifest.sha256.lowercased(), got: digest)
        }

        // Extract into a private staging dir, then swap into place so a crash mid-extract never leaves a
        // half-populated tools directory that `isInstalled` would treat as good.
        let staging = fm.temporaryDirectory.appendingPathComponent("donkey-tools-stage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try extractTarGz(downloaded, into: staging)

        let root = try resolveToolsRoot(in: staging)
        let dest = BundledTools.installDirectory
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: root, to: dest)

        markExecutables(in: dest)
        try manifest.version.write(to: BundledTools.installedVersionMarker, atomically: true, encoding: .utf8)
    }

    /// Stream the file through SHA-256 so a ~250MB archive isn't all held in memory.
    private func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func extractTarGz(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.extractFailed(status: process.terminationStatus)
        }
    }

    /// The tarball may be flat (ffmpeg at the root) or wrapped in a top-level dir; return whichever level
    /// actually holds the tools.
    private func resolveToolsRoot(in staging: URL) throws -> URL {
        if BundledTools.isInstalled(at: staging) { return staging }
        let entries = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where BundledTools.isInstalled(at: entry) { return entry }
        throw InstallError.noToolsInArchive
    }

    /// tar preserves modes, but be defensive: mark every top-level regular file executable so a bare-name
    /// invocation works even if the archive lost its bits.
    private func markExecutables(in directory: URL) {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        for entry in entries {
            let isRegular = (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            if isRegular {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entry.path)
            }
        }
    }
}
