import CryptoKit
import Foundation
import os

/// A step in the first-run tool-bundle setup, reported as it happens so a UI can narrate progress.
/// Emitted ONLY when real work runs: an already-current or unpublished bundle produces no events at all,
/// so a caller can treat the first event as "setup actually started". Retries are the installer's own
/// concern — `.retrying` says it failed an attempt and will try again; `.failed` says it gave up.
public enum BundledToolsSetupEvent: Sendable, Equatable {
    case started
    /// Download progress in 0...1, or nil when the server didn't advertise a content length.
    case downloading(fraction: Double?)
    case verifying
    case installing
    case completed
    case retrying(attempt: Int, maxAttempts: Int)
    case failed
}

/// Downloads the prebuilt CLI tools bundle (ffmpeg, yt-dlp, ...) into Application Support on first run, so
/// the shipped app stays small and the capability skills "just work" without the user installing anything.
///
/// Serialized via an actor: safe to call on every launch and concurrently — it no-ops when the manifest
/// version is already installed, when nothing is published yet, or when an install is already in flight.
/// Verifies the SHA-256 before trusting the bytes and swaps the new tools in atomically. A failed attempt
/// is retried with backoff a few times before giving up; the caller never drives retries.
public actor BundledToolsInstaller {
    public static let shared = BundledToolsInstaller()

    private var installing = false
    private let log = Logger(subsystem: "com.donkey.app", category: "BundledTools")

    /// How many times to attempt the download+install before surfacing `.failed`. A flaky network on
    /// first run shouldn't strand the tools; the app retries here and again on the next launch.
    private static let maxAttempts = 3

    /// How many recently-used bundle versions to keep alongside the current one. A dev build and a prod
    /// build pin different versions, so more than one survives; the cap stops the per-version store from
    /// growing without bound as versions roll (each extracted bundle is ~180MB on disk).
    private static let versionsToKeep = 3

    enum InstallError: Error {
        case badURL
        case checksumMismatch(expected: String, got: String)
        case extractFailed(status: Int32)
        case noToolsInArchive
        case downloadProducedNoFile
    }

    public init() {}

    /// Ensure the published tools bundle is installed and current. Returns whether usable tools are present
    /// afterward. Cheap to call repeatedly; the heavy download runs only when the installed version differs
    /// from the manifest. Pass `onEvent` to narrate progress — it fires only when a real download/install
    /// runs (never for the already-current or nothing-published no-ops), so the first event marks the start
    /// of actual setup. Failed attempts are retried internally before `.failed` is reported.
    @discardableResult
    public func installIfNeeded(
        onEvent: (@Sendable (BundledToolsSetupEvent) -> Void)? = nil
    ) async -> Bool {
        guard let manifest = BundledTools.loadManifest(), manifest.isPublished else {
            // Nothing published yet (empty sha256): rely on whatever is already on disk (e.g. a dev symlink
            // or an offline-baked bundle); never download something unverified.
            if let present = BundledTools.resolvedInstallDirectory() {
                repairSelfExtractingTools(in: present)
                return true
            }
            return false
        }
        // This build pins exactly one bundle version; it only ever reads and writes that version's own
        // directory, so a different build's version sitting in a sibling directory is irrelevant here.
        let dest = BundledTools.installDirectory(forVersion: manifest.version)
        if BundledTools.isInstalled(at: dest) {
            // Already installed — but still make sure the self-extracting tools actually launch (a hardened
            // copy without the library-validation exception can't start, which the presence check alone
            // would hide), and refresh the mtime so version GC treats this version as in-use.
            touch(dest)
            repairSelfExtractingTools(in: dest)
            return true
        }
        guard !installing else { return false }
        installing = true
        defer { installing = false }

        // Real work is about to run: announce it, then attempt the download+install, retrying a flaky
        // network a few times with backoff before giving up. The user never drives these retries.
        onEvent?(.started)
        for attempt in 1...Self.maxAttempts {
            do {
                try await install(manifest, into: dest, onEvent: onEvent)
                log.info("installed bundled tools \(manifest.version, privacy: .public)")
                onEvent?(.completed)
                return true
            } catch {
                log.error("bundled tools install attempt \(attempt, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                if attempt < Self.maxAttempts {
                    onEvent?(.retrying(attempt: attempt, maxAttempts: Self.maxAttempts))
                    // Linear backoff (2s, 4s, …): enough to ride out a transient hiccup without making a
                    // first run feel stuck.
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                }
            }
        }
        onEvent?(.failed)
        // Even when this build's pinned version failed to install, the app still has usable tools whenever
        // any version is present (the agent keeps working), so report that rather than a hard "no tools".
        return BundledTools.resolvedInstallDirectory() != nil
    }

    private func install(
        _ manifest: BundledTools.Manifest,
        into dest: URL,
        onEvent: (@Sendable (BundledToolsSetupEvent) -> Void)?
    ) async throws {
        guard let url = URL(string: manifest.url) else { throw InstallError.badURL }
        let fm = FileManager.default

        let downloaded = try await download(from: url, onEvent: onEvent)
        defer { try? fm.removeItem(at: downloaded) }

        onEvent?(.verifying)
        let digest = try sha256Hex(of: downloaded)
        guard digest == manifest.sha256.lowercased() else {
            throw InstallError.checksumMismatch(expected: manifest.sha256.lowercased(), got: digest)
        }
        onEvent?(.installing)

        // Extract into a private staging dir, then swap into place so a crash mid-extract never leaves a
        // half-populated tools directory that `isInstalled` would treat as good.
        let staging = fm.temporaryDirectory.appendingPathComponent("donkey-tools-stage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try extractTarGz(downloaded, into: staging)

        let root = try resolveToolsRoot(in: staging)
        clearLegacyFlatInstall()
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: root, to: dest)

        markExecutables(in: dest)
        repairSelfExtractingTools(in: dest)
        touch(dest)
        pruneOldVersions(keeping: manifest.version)
    }

    /// Stamp the version directory's mtime as "just used" so version GC keeps the bundles an app build
    /// actually launches. Called on both the already-installed and the freshly-installed paths.
    private func touch(_ directory: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path)
    }

    /// Remove a pre-namespacing flat install (loose ffmpeg + dylibs + the old `.version` marker directly
    /// under `baseDirectory`) the one time it is found, so an app updated from an older build reclaims that
    /// copy instead of leaving ~180MB of orphaned files. A version install is a subdirectory that itself
    /// holds ffmpeg; those are never touched, so this can't delete a sibling build's pinned tools.
    private func clearLegacyFlatInstall() {
        guard BundledTools.hasLegacyFlatInstall else { return }
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: BundledTools.baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory && BundledTools.isInstalled(at: entry) { continue }
            try? fm.removeItem(at: entry)
        }
    }

    /// Keep the current version plus the few most-recently-used others, reclaiming truly stale installs so
    /// the tools store can't grow without bound as versions roll. mtime is refreshed on each launch that
    /// uses a version, so a dev build and a prod build that are both in active use both survive; only a
    /// version nothing has launched in a while ages out (and re-downloads on demand, which the now-immutable
    /// published assets make reliable).
    private func pruneOldVersions(keeping current: String) {
        let fm = FileManager.default
        let versions = BundledTools.installedVersions() // most-recently-used first
        var keep = Set(versions.prefix(Self.versionsToKeep).map { $0.lastPathComponent })
        keep.insert(current)
        for directory in versions where !keep.contains(directory.lastPathComponent) {
            try? fm.removeItem(at: directory)
        }
    }

    /// Download the archive to a temp file, reporting fractional progress as the bytes arrive. A
    /// `URLSessionDownloadTask` streams straight to disk (so a ~250MB bundle never sits in memory) and its
    /// `Progress` is observed for the fraction. The completion handler's temp file is deleted the moment
    /// the handler returns, so it is moved to a stable temp path the caller owns and removes.
    private func download(
        from url: URL,
        onEvent: (@Sendable (BundledToolsSetupEvent) -> Void)?
    ) async throws -> URL {
        onEvent?(.downloading(fraction: 0))
        // The KVO observation outlives this call's stack frame (it fires on a background queue), so it is
        // held in a small reference box that the completion handler invalidates. `lastReportedPercent`
        // lives there too, so we coalesce the firehose of progress callbacks down to whole-percent steps.
        final class ProgressBox: @unchecked Sendable {
            var observation: NSKeyValueObservation?
            var lastReportedPercent = -1
        }
        let box = ProgressBox()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { temporaryURL, _, error in
                box.observation?.invalidate()
                box.observation = nil
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let temporaryURL else {
                    continuation.resume(throwing: InstallError.downloadProducedNoFile)
                    return
                }
                let stable = FileManager.default.temporaryDirectory
                    .appendingPathComponent("donkey-tools-dl-\(UUID().uuidString).tar.gz")
                do {
                    try FileManager.default.moveItem(at: temporaryURL, to: stable)
                    continuation.resume(returning: stable)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            box.observation = task.progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
                let percent = Int((progress.fractionCompleted * 100).rounded(.down))
                guard percent != box.lastReportedPercent else { return }
                box.lastReportedPercent = percent
                // `isIndeterminate` is true until a content length is known; surface nil so the UI can say
                // "Downloading…" without a misleading 0%.
                onEvent?(.downloading(fraction: progress.isIndeterminate ? nil : progress.fractionCompleted))
            }
            task.resume()
        }
    }

    /// Some bundled tools (yt-dlp) are PyInstaller onefile binaries that unpack a private Python.framework
    /// to a temp dir at launch and `dlopen()` it. If the shipped copy carries the hardened-runtime flag
    /// without the library-validation exception, that load is rejected ("different Team IDs") and the tool
    /// cannot start — which reads to the agent as a missing tool and sends it hunting for a pip/python path.
    /// We can't guarantee how a downloaded artifact was signed, so we make the installed copy launchable by
    /// construction: probe each self-extracting tool, and if it won't start, ad-hoc re-sign it with the
    /// exception (keeping the hardened runtime). A copy that already launches is left untouched, so a
    /// correctly Developer-ID-signed, notarized release binary keeps its signature.
    private func repairSelfExtractingTools(in directory: URL) {
        for name in BundledTools.selfExtractingExecutableNames {
            let tool = directory.appendingPathComponent(name)
            guard FileManager.default.isExecutableFile(atPath: tool.path) else { continue }
            if toolLaunches(tool) { continue }
            log.error("bundled \(name, privacy: .public) will not launch as signed; re-signing with the library-validation exception")
            adhocResignWithLibraryValidationException(tool)
            if !toolLaunches(tool) {
                log.error("bundled \(name, privacy: .public) still will not launch after re-signing")
            }
        }
    }

    /// True if the tool runs to a clean exit. `--version` is a cheap, network-free probe that still forces a
    /// PyInstaller binary to extract and load its private runtime, so a signing failure surfaces here.
    private func toolLaunches(_ tool: URL) -> Bool {
        let process = Process()
        process.executableURL = tool
        process.arguments = ["--version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Re-sign ad-hoc with the library-validation exception so a self-extracting tool can load the runtime it
    /// unpacks. Ad-hoc is enough to execute a non-quarantined subprocess (the installer fetches over HTTPS,
    /// which sets no quarantine), and it matches how the dev pipeline signs these tools.
    private func adhocResignWithLibraryValidationException(_ tool: URL) {
        let entitlements = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
            <key>com.apple.security.cs.disable-library-validation</key><true/>
        </dict></plist>
        """
        let entitlementsFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("donkey-lv-\(UUID().uuidString).entitlements")
        do {
            try entitlements.write(to: entitlementsFile, atomically: true, encoding: .utf8)
        } catch {
            log.error("could not write entitlements for re-signing: \(String(describing: error), privacy: .public)")
            return
        }
        defer { try? FileManager.default.removeItem(at: entitlementsFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--options", "runtime", "--entitlements", entitlementsFile.path, tool.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log.error("could not run codesign to repair a bundled tool: \(String(describing: error), privacy: .public)")
        }
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
