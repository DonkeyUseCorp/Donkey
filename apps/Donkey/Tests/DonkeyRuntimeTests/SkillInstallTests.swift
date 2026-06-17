import CryptoKit
import DonkeyContracts
import DonkeyHarness
import DonkeyRuntime
import Foundation
import Testing

/// Covers the dynamic-skill install pipeline: a downloaded skill bundle is verified, placed in the
/// versioned install tree, discovered as an `.installed` skill, and removed again — without ever
/// shadowing a built-in skill or breaking the existing discovery.
@Suite
struct SkillInstallTests {
    // MARK: - Helpers

    /// A throwaway install root per test so nothing touches the user's real Application Support.
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("donkey-skill-tests-\(UUID().uuidString)", isDirectory: true)
    }

    /// Writes a skill bundle (SKILL.md + one script) to disk and returns its directory. The manifest
    /// is written last with a checksum/signature computed over the content, since the content hash
    /// excludes the manifest itself.
    private func makeBundle(
        skillID: String,
        version: String,
        marker: String = "operate the widget",
        sign signingKey: Curve25519.Signing.PrivateKey? = nil,
        corruptSignature: Bool = false,
        wrongChecksum: Bool = false,
        includeManifest: Bool = true
    ) throws -> URL {
        let dir = tempRoot().appendingPathComponent("bundle-\(skillID)-\(version)", isDirectory: true)
        let scripts = dir.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)

        let skillMarkdown = """
        # \(skillID.capitalized)
        id: \(skillID)
        description: \(marker)
        apps: TestWidget, com.test.widget
        """
        try skillMarkdown.write(
            to: dir.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try "tell application \"TestWidget\" to activate"
            .write(to: scripts.appendingPathComponent("open.applescript"), atomically: true, encoding: .utf8)

        guard includeManifest else { return dir }

        let checksum = HarnessSkillInstaller.contentChecksum(of: dir)
        var signature: HarnessSkillSignature?
        if let signingKey {
            let digest = corruptSignature ? Data("not-the-digest".utf8) : (hexData(checksum) ?? Data())
            let raw = try signingKey.signature(for: digest)
            signature = HarnessSkillSignature(
                publicKey: signingKey.publicKey.rawRepresentation.base64EncodedString(),
                signature: raw.base64EncodedString()
            )
        }

        let manifest = HarnessSkillManifest(
            skillID: skillID,
            version: version,
            name: skillID.capitalized,
            description: marker,
            checksum: wrongChecksum ? String(repeating: "0", count: 64) : checksum,
            signature: signature
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: dir.appendingPathComponent(HarnessSkillManifest.fileName))
        return dir
    }

    private func hexData(_ hex: String) -> Data? {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i ... i + 1]), radix: 16) else { return nil }
            bytes.append(b)
            i += 2
        }
        return Data(bytes)
    }

    private func install(
        _ bundle: URL,
        root: URL,
        trusted: Set<String> = [],
        requireSignature: Bool = false
    ) async throws -> HarnessSkillInstaller.InstallResult {
        let installer = HarnessSkillInstaller(
            installRoot: root,
            trustedPublicKeys: trusted,
            requireSignature: requireSignature
        )
        let manager = HarnessSkillInstallManager(
            source: LocalDirectorySkillSource(),
            installer: installer
        )
        return try await manager.install(SkillRef(skillID: bundle.lastPathComponent, locator: bundle.path))
    }

    private func discovered(in root: URL) -> [HarnessSkillDescriptor] {
        let installer = HarnessSkillInstaller(installRoot: root)
        return HarnessSkillFileSystemSource(
            roots: installer.currentBundleRoots(),
            sourceKind: .installed
        ).discover()
    }

    // MARK: - Tests

    @Test
    func installsVerifiesAndDiscoversASkill() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let bundle = try makeBundle(skillID: "test-widget", version: "1.0.0")
        let result = try await install(bundle, root: root)

        #expect(result.skillID == "test-widget")
        #expect(result.version == "1.0.0")
        #expect(result.signed == false)

        let current = root.appendingPathComponent("test-widget/current/SKILL.md")
        #expect(FileManager.default.fileExists(atPath: current.path))

        let receipts = HarnessSkillInstaller(installRoot: root).installedReceipts()
        #expect(receipts.map(\.skillID) == ["test-widget"])
        #expect(receipts.first?.version == "1.0.0")

        let descriptors = discovered(in: root)
        let descriptor = try #require(descriptors.first { $0.id == "test-widget" })
        #expect(descriptor.sourceKind == .installed)
        // Installed scripts are trusted-validated (verified at install time).
        #expect(descriptor.scripts.allSatisfy { $0.validationStatus == .validated })
        #expect(descriptor.scripts.isEmpty == false)

        // The discovered installed skill registers and is searchable like any other skill.
        let registry = HarnessSkillRegistry(skills: descriptors)
        #expect(await registry.descriptor(id: "test-widget") != nil)
        #expect(await registry.search(query: "widget").contains { $0.descriptor.id == "test-widget" })
    }

    @Test
    func rejectsChecksumMismatchWithoutInstalling() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let bundle = try makeBundle(skillID: "bad-sum", version: "1.0.0", wrongChecksum: true)
        await #expect(throws: HarnessSkillInstaller.InstallError.self) {
            _ = try await install(bundle, root: root)
        }
        #expect(discovered(in: root).isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("bad-sum/current").path) == false)
    }

    @Test
    func verifiesTrustedSignatureAndRejectsUntrustedOrInvalid() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let trusted = Set([key.publicKey.rawRepresentation.base64EncodedString()])

        // Trusted + valid signature installs and is marked signed.
        let okRoot = tempRoot()
        defer { try? FileManager.default.removeItem(at: okRoot) }
        let signed = try makeBundle(skillID: "signed-ok", version: "1.0.0", sign: key)
        let result = try await install(signed, root: okRoot, trusted: trusted)
        #expect(result.signed)

        // Same signature, but the host trusts no keys → rejected before crypto check.
        let untrustedRoot = tempRoot()
        defer { try? FileManager.default.removeItem(at: untrustedRoot) }
        let signed2 = try makeBundle(skillID: "signed-untrusted", version: "1.0.0", sign: key)
        await #expect(throws: HarnessSkillInstaller.InstallError.untrustedSignature) {
            _ = try await install(signed2, root: untrustedRoot, trusted: [])
        }

        // Trusted key, but the signature does not cover this content → rejected.
        let invalidRoot = tempRoot()
        defer { try? FileManager.default.removeItem(at: invalidRoot) }
        let tampered = try makeBundle(skillID: "signed-bad", version: "1.0.0", sign: key, corruptSignature: true)
        await #expect(throws: HarnessSkillInstaller.InstallError.invalidSignature) {
            _ = try await install(tampered, root: invalidRoot, trusted: trusted)
        }
    }

    @Test
    func requireSignatureRejectsUnsignedBundles() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try makeBundle(skillID: "needs-sig", version: "1.0.0")
        await #expect(throws: HarnessSkillInstaller.InstallError.signatureRequired) {
            _ = try await install(bundle, root: root, requireSignature: true)
        }
    }

    @Test
    func updatingReplacesTheCurrentVersionAndPrunesOld() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await install(try makeBundle(skillID: "widget", version: "1.0.0", marker: "v1 widget"), root: root)
        _ = try await install(try makeBundle(skillID: "widget", version: "2.0.0", marker: "v2 widget"), root: root)

        let receipts = HarnessSkillInstaller(installRoot: root).installedReceipts()
        #expect(receipts.first?.version == "2.0.0")

        let descriptor = try #require(discovered(in: root).first { $0.id == "widget" })
        #expect(descriptor.summary.contains("v2 widget"))

        // Only the current version directory (plus the `current` symlink) remains.
        let versions = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("widget"),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).map(\.lastPathComponent).sorted()
        #expect(versions == ["2.0.0", "current"])
    }

    @Test
    func uninstallRemovesTheSkill() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await install(try makeBundle(skillID: "removable", version: "1.0.0"), root: root)
        #expect(discovered(in: root).isEmpty == false)

        let manager = HarnessSkillInstallManager(installer: HarnessSkillInstaller(installRoot: root))
        try await manager.uninstall(skillID: "removable")

        #expect(discovered(in: root).isEmpty)
        #expect(HarnessSkillInstaller(installRoot: root).installedReceipts().isEmpty)
    }

    @Test
    func installsBundleWithoutAManifest() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // No manifest: identity comes from the SKILL.md `id:` frontmatter.
        let bundle = try makeBundle(skillID: "no-manifest", version: "ignored", includeManifest: false)
        let result = try await install(bundle, root: root)
        #expect(result.skillID == "no-manifest")
        #expect(discovered(in: root).contains { $0.id == "no-manifest" })
    }

    @Test
    func existingBuiltInSkillsAreUnaffected() {
        // Regression: the built-in catalog still discovers normally and is not shadowed.
        let descriptors = BuiltInLocalAppSkillPacks.descriptors()
        #expect(descriptors.contains { $0.id == "music" })
        // No duplicate ids leak through the merged built-in/installed/learned discovery.
        let ids = descriptors.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
