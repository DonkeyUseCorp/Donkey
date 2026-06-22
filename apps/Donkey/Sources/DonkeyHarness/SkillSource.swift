import Foundation

/// A reference to a skill the user wants to install, independent of where it lives. Today the only
/// concrete source reads bundles already on disk; the same ref shape is what a future catalog client
/// resolves over the network.
public struct SkillRef: Equatable, Sendable {
    public var skillID: String
    public var version: String?
    /// Source-specific locator (a file path for the local source; a catalog id/URL later).
    public var locator: String

    public init(skillID: String, version: String? = nil, locator: String) {
        self.skillID = skillID
        self.version = version
        self.locator = locator
    }
}

/// A skill bundle that a source has produced locally and is ready for the installer to verify and
/// place into the install directory. `url` points at either a directory or a `.zip` containing the
/// bundle (`SKILL.md`, optional `scripts/`, optional `manifest.json`).
public struct FetchedSkill: Equatable, Sendable {
    public var ref: SkillRef
    public var url: URL
    /// Manifest parsed from the bundle, when present. Carries the expected checksum/signature.
    public var manifest: HarnessSkillManifest?

    public init(ref: SkillRef, url: URL, manifest: HarnessSkillManifest? = nil) {
        self.ref = ref
        self.url = url
        self.manifest = manifest
    }
}

public enum SkillSourceError: Error, CustomStringConvertible, Equatable, Sendable {
    case notFound(String)
    case notImplemented(String)
    case malformedBundle(String)

    public var description: String {
        switch self {
        case .notFound(let message): return "Skill not found: \(message)"
        case .notImplemented(let message): return "Skill source not implemented: \(message)"
        case .malformedBundle(let message): return "Malformed skill bundle: \(message)"
        }
    }
}

/// Where installable skills come from. The installer depends only on this protocol, so the on-disk
/// "already downloaded" source and the future hosted-catalog client are interchangeable.
public protocol SkillSource: Sendable {
    func fetch(_ ref: SkillRef) async throws -> FetchedSkill
}

/// The seam the future site catalog drops into: it will resolve a `SkillRef` against
/// `DONKEY_WEB_BASE_URL`, download the bundle, and hand it to the installer for verification. The
/// download/publish API is not designed yet, so this is a deliberate stub — skills are treated as
/// "already downloaded" via `LocalDirectorySkillSource` for now.
public struct RemoteCatalogSkillSource: SkillSource {
    public init() {}

    public func fetch(_ ref: SkillRef) async throws -> FetchedSkill {
        throw SkillSourceError.notImplemented(
            "Remote skill catalog download is not wired yet; install from a local bundle for now."
        )
    }
}
