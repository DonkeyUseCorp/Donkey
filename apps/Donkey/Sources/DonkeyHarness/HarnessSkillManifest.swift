import Foundation

/// The author-supplied manifest that travels with an installable skill (`manifest.json` at the
/// skill bundle root). Everything in Donkey is a skill — a folder of markdown instructions
/// (`SKILL.md`) plus optional runnable scripts — so the manifest carries only the distribution
/// metadata the install pipeline needs: identity, version, integrity, and the trust signal. The
/// operating content itself still lives in `SKILL.md`, never here.
///
/// The manifest is OPTIONAL. Built-in skills ship without one, and a downloaded skill that omits it
/// still installs — identity then falls back to the directory name and `SKILL.md` frontmatter, the
/// same way discovery already works today.
public struct HarnessSkillManifest: Codable, Equatable, Sendable {
    /// Stable identity; matches the install directory and the `id:` frontmatter in `SKILL.md`.
    public var skillID: String
    /// Semantic version of this skill bundle. Drives the versioned install layout and updates.
    public var version: String
    public var name: String?
    public var description: String?
    public var author: String?
    /// Permissions the skill's scripts need; surfaced to the user before install.
    public var requiredPermissions: [HarnessPermission]
    /// Script ids the bundle advertises (informational; discovery still reads `scripts/` from disk).
    public var scriptIDs: [String]
    /// Lowest app version this skill supports, if the author pins one.
    public var minAppVersion: String?
    /// SHA-256 of the distributed artifact, lowercase hex. Verified at install time.
    public var checksum: String?
    /// Optional cryptographic signature over the artifact (see `HarnessSkillSignature`).
    public var signature: HarnessSkillSignature?

    public init(
        skillID: String,
        version: String,
        name: String? = nil,
        description: String? = nil,
        author: String? = nil,
        requiredPermissions: [HarnessPermission] = [],
        scriptIDs: [String] = [],
        minAppVersion: String? = nil,
        checksum: String? = nil,
        signature: HarnessSkillSignature? = nil
    ) {
        self.skillID = skillID
        self.version = version
        self.name = name
        self.description = description
        self.author = author
        self.requiredPermissions = requiredPermissions
        self.scriptIDs = scriptIDs
        self.minAppVersion = minAppVersion
        self.checksum = checksum
        self.signature = signature
    }

    /// Default filename at the root of a skill bundle.
    public static let fileName = "manifest.json"

    /// Tolerant decode: a malformed or absent manifest returns nil rather than throwing, so the
    /// install/discovery paths can fall back to `SKILL.md` frontmatter.
    public static func decode(from data: Data) -> HarnessSkillManifest? {
        try? JSONDecoder().decode(HarnessSkillManifest.self, from: data)
    }

    public static func load(from url: URL) -> HarnessSkillManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(from: data)
    }
}

/// A signature over a distributed skill artifact. The format is intentionally provider-neutral and
/// algorithm-tagged so the real catalog's signing scheme can slot in without changing the install
/// pipeline. `ed25519` is verified with CryptoKit at install time; the public key is matched against
/// the host's set of trusted publisher keys.
public struct HarnessSkillSignature: Codable, Equatable, Sendable {
    public enum Algorithm: String, Codable, Equatable, Sendable {
        case ed25519
    }

    public var algorithm: Algorithm
    /// Base64 of the signer's public key.
    public var publicKey: String
    /// Base64 of the detached signature over the artifact bytes.
    public var signature: String

    public init(algorithm: Algorithm = .ed25519, publicKey: String, signature: String) {
        self.algorithm = algorithm
        self.publicKey = publicKey
        self.signature = signature
    }
}
