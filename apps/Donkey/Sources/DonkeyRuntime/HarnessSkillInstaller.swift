import CryptoKit
import DonkeyHarness
import Foundation

/// Installs verified skill bundles into the on-disk install directory and removes them again.
///
/// The pipeline is: materialize the fetched bundle into a temp working copy, verify its integrity
/// (content checksum + optional signature) BEFORE it touches the live install tree, then place it at
/// a versioned path and repoint the `current` symlink. Any failure throws and leaves the previously
/// installed version untouched — a bad download can never replace a good install.
///
/// Layout (under `Skills/Installed/`):
/// ```
/// <skillID>/<version>/{SKILL.md, scripts/, manifest.json, receipt.json}
/// <skillID>/current -> <version>
/// ```
public struct HarnessSkillInstaller: Sendable {
    public var installRoot: URL
    /// Base64 public keys whose signatures the host trusts. A signed bundle installs only when its
    /// signing key is in this set; an empty set rejects all signed bundles.
    public var trustedPublicKeys: Set<String>
    /// When true, a bundle without a verified signature is rejected. Off by default so locally
    /// authored / already-downloaded dev bundles install on checksum alone.
    public var requireSignature: Bool

    public init(
        installRoot: URL = HarnessSkillInstaller.defaultInstallRoot(),
        trustedPublicKeys: Set<String> = [],
        requireSignature: Bool = false
    ) {
        self.installRoot = installRoot
        self.trustedPublicKeys = trustedPublicKeys
        self.requireSignature = requireSignature
    }

    public static func defaultInstallRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Donkey", isDirectory: true)
            .appendingPathComponent("Skills", isDirectory: true)
            .appendingPathComponent("Installed", isDirectory: true)
    }

    public enum InstallError: Error, CustomStringConvertible, Equatable, Sendable {
        case missingSkillMarkdown
        case checksumMismatch(expected: String, actual: String)
        case untrustedSignature
        case invalidSignature
        case signatureRequired
        case extractionFailed(String)

        public var description: String {
            switch self {
            case .missingSkillMarkdown:
                return "Skill bundle has no SKILL.md."
            case .checksumMismatch(let expected, let actual):
                return "Skill checksum mismatch (expected \(expected), got \(actual))."
            case .untrustedSignature:
                return "Skill is signed by a key that is not trusted."
            case .invalidSignature:
                return "Skill signature does not verify."
            case .signatureRequired:
                return "Skill is unsigned but a signature is required."
            case .extractionFailed(let message):
                return "Could not extract skill bundle: \(message)"
            }
        }
    }

    public struct InstallResult: Equatable, Sendable {
        public var skillID: String
        public var version: String
        public var installedPath: URL
        public var verifiedChecksum: String
        public var signed: Bool
    }

    // MARK: - Install

    @discardableResult
    public func install(_ fetched: FetchedSkill) throws -> InstallResult {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("donkey-skill-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }

        let bundle = try materialize(fetched.url, into: staging)

        let skillMarkdown = bundle.appendingPathComponent("SKILL.md")
        guard fileManager.fileExists(atPath: skillMarkdown.path) else {
            throw InstallError.missingSkillMarkdown
        }

        let manifest = fetched.manifest
            ?? HarnessSkillManifest.load(from: bundle.appendingPathComponent(HarnessSkillManifest.fileName))
        let skillID = resolveSkillID(manifest: manifest, bundle: bundle, ref: fetched.ref)
        let version = manifest?.version ?? fetched.ref.version ?? "0.0.0"

        let checksum = Self.contentChecksum(of: bundle)
        if let expected = manifest?.checksum, expected.lowercased() != checksum {
            throw InstallError.checksumMismatch(expected: expected.lowercased(), actual: checksum)
        }

        let signed = try verifySignature(manifest?.signature, contentChecksumHex: checksum)
        if requireSignature && !signed {
            throw InstallError.signatureRequired
        }

        let skillRoot = installRoot.appendingPathComponent(skillID, isDirectory: true)
        let versionDir = skillRoot.appendingPathComponent(version, isDirectory: true)
        try fileManager.createDirectory(at: skillRoot, withIntermediateDirectories: true)

        // Swap the verified bundle into place. Build at a temp sibling, then rename, so a partially
        // written version directory is never observable.
        let incoming = skillRoot.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
        if fileManager.fileExists(atPath: incoming.path) {
            try fileManager.removeItem(at: incoming)
        }
        try fileManager.copyItem(at: bundle, to: incoming)

        let receipt = InstallReceipt(
            skillID: skillID,
            version: version,
            installedAt: Date(),
            checksum: checksum,
            signed: signed,
            publicKey: signed ? manifest?.signature?.publicKey : nil,
            sourceLocator: fetched.ref.locator
        )
        try receipt.write(to: incoming.appendingPathComponent(InstallReceipt.fileName))

        if fileManager.fileExists(atPath: versionDir.path) {
            try fileManager.removeItem(at: versionDir)
        }
        try fileManager.moveItem(at: incoming, to: versionDir)

        try repointCurrent(skillRoot: skillRoot, to: version)

        return InstallResult(
            skillID: skillID,
            version: version,
            installedPath: versionDir,
            verifiedChecksum: checksum,
            signed: signed
        )
    }

    // MARK: - Uninstall

    public func uninstall(skillID: String) throws {
        let dir = installRoot.appendingPathComponent(skillID, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Listing

    public func installedReceipts() -> [InstallReceipt] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: installRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries.compactMap { skillDir in
            let current = skillDir.appendingPathComponent("current", isDirectory: true)
            return InstallReceipt.load(from: current.appendingPathComponent(InstallReceipt.fileName))
        }
        .sorted { $0.skillID < $1.skillID }
    }

    /// The discovery root for installed skills: each `<skillID>/current` directory.
    public func currentBundleRoots() -> [URL] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: installRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .map { $0.appendingPathComponent("current", isDirectory: true) }
            .filter { fileManager.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) }
    }

    // MARK: - Internals

    private func materialize(_ source: URL, into staging: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw InstallError.extractionFailed("source does not exist at \(source.path)")
        }

        if isDirectory.boolValue {
            let dest = staging.appendingPathComponent("bundle", isDirectory: true)
            try fileManager.copyItem(at: source, to: dest)
            return Self.bundleRoot(in: dest)
        }

        // Treat a file as a zip archive and extract it with ditto (handles PKZip on macOS).
        let extracted = staging.appendingPathComponent("bundle", isDirectory: true)
        try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
        try Self.unzip(source, to: extracted)
        return Self.bundleRoot(in: extracted)
    }

    /// A zip can wrap the bundle in a single top-level folder. If the extracted root contains exactly
    /// one directory and no SKILL.md, descend into it.
    private static func bundleRoot(in directory: URL) -> URL {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.appendingPathComponent("SKILL.md").path) {
            return directory
        }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return directory
        }
        let directories = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        if directories.count == 1,
           fileManager.fileExists(atPath: directories[0].appendingPathComponent("SKILL.md").path) {
            return directories[0]
        }
        return directory
    }

    private static func unzip(_ archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        let pipe = Pipe()
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw InstallError.extractionFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "ditto exit \(process.terminationStatus)"
            throw InstallError.extractionFailed(message)
        }
    }

    private func resolveSkillID(
        manifest: HarnessSkillManifest?,
        bundle: URL,
        ref: SkillRef
    ) -> String {
        if let id = manifest?.skillID, !id.isEmpty { return id }
        if let id = Self.skillMarkdownID(at: bundle.appendingPathComponent("SKILL.md")) { return id }
        if !ref.skillID.isEmpty { return ref.skillID }
        return bundle.deletingLastPathComponent().lastPathComponent
    }

    /// Minimal `id:` frontmatter scan so an unmanifested bundle still installs under its declared id.
    private static func skillMarkdownID(at url: URL) -> String? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in contents.split(whereSeparator: \.isNewline).map(String.init).prefix(40) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("id:") else { continue }
            let value = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Verifies the signature when present. Returns true if a valid, trusted signature was checked;
    /// false if there is no signature. Throws on a present-but-bad/untrusted signature.
    private func verifySignature(
        _ signature: HarnessSkillSignature?,
        contentChecksumHex: String
    ) throws -> Bool {
        guard let signature else { return false }
        guard trustedPublicKeys.contains(signature.publicKey) else {
            throw InstallError.untrustedSignature
        }
        guard
            let keyData = Data(base64Encoded: signature.publicKey),
            let sigData = Data(base64Encoded: signature.signature),
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else {
            throw InstallError.invalidSignature
        }
        // The signature is over the canonical content digest bytes.
        let digest = Data(hexString: contentChecksumHex) ?? Data(contentChecksumHex.utf8)
        guard key.isValidSignature(sigData, for: digest) else {
            throw InstallError.invalidSignature
        }
        return true
    }

    private func repointCurrent(skillRoot: URL, to version: String) throws {
        let fileManager = FileManager.default
        let current = skillRoot.appendingPathComponent("current")
        // Remove any prior link/file regardless of type before recreating it.
        if (try? current.checkResourceIsReachable()) == true
            || (try? fileManager.attributesOfItem(atPath: current.path)) != nil {
            try? fileManager.removeItem(at: current)
        }
        // Relative destination ("<version>", not an absolute URL) so the link resolves next to
        // itself regardless of the install root's absolute path.
        try fileManager.createSymbolicLink(atPath: current.path, withDestinationPath: version)

        // Prune other versions so installs stay self-cleaning.
        if let versions = try? fileManager.contentsOfDirectory(
            at: skillRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in versions where entry.lastPathComponent != version && entry.lastPathComponent != "current" {
                if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    try? fileManager.removeItem(at: entry)
                }
            }
        }
    }

    /// Packaging-independent content hash: SHA-256 over each file's relative path and bytes in sorted
    /// path order, excluding install/distribution metadata. The same value results whether the bundle
    /// arrived as a folder or a zip, so a manifest checksum is meaningful across both.
    public static func contentChecksum(of bundle: URL) -> String {
        let fileManager = FileManager.default
        let excluded: Set<String> = [HarnessSkillManifest.fileName, InstallReceipt.fileName]
        var files: [(relative: String, url: URL)] = []
        if let enumerator = fileManager.enumerator(
            at: bundle,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let relative = url.standardizedFileURL.path
                    .replacingOccurrences(of: bundle.standardizedFileURL.path, with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if excluded.contains((relative as NSString).lastPathComponent) { continue }
                files.append((relative, url))
            }
        }
        files.sort { $0.relative < $1.relative }

        var hasher = SHA256()
        for file in files {
            hasher.update(data: Data(file.relative.utf8))
            hasher.update(data: Data([0]))
            if let data = try? Data(contentsOf: file.url) {
                hasher.update(data: data)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// What the installer records next to an installed skill. Read back to list installs and to know how
/// each was verified.
public struct InstallReceipt: Codable, Equatable, Sendable {
    public var skillID: String
    public var version: String
    public var installedAt: Date
    public var checksum: String
    public var signed: Bool
    public var publicKey: String?
    public var sourceLocator: String

    public static let fileName = "receipt.json"

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func load(from url: URL) -> InstallReceipt? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(InstallReceipt.self, from: data)
    }
}

private extension Data {
    /// Parses an even-length lowercase/uppercase hex string into bytes; nil on malformed input.
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let byte = UInt8(String(chars[index ... index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
            index += 2
        }
        self = Data(bytes)
    }
}
