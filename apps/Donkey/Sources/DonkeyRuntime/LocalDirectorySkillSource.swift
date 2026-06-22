import DonkeyHarness
import Foundation

/// Reads an "already downloaded" skill bundle from a path on disk and hands it to the installer.
///
/// This is the concrete `SkillSource` for now: distribution over the site catalog is not wired yet,
/// so a skill is whatever folder or `.zip` is already present locally. The locator on the `SkillRef`
/// is the bundle path; if it is omitted the source falls back to `<baseDirectory>/<skillID>`.
public struct LocalDirectorySkillSource: SkillSource {
    /// Optional directory the source resolves skill ids against when a ref carries no absolute path.
    public var baseDirectory: URL?

    public init(baseDirectory: URL? = nil) {
        self.baseDirectory = baseDirectory
    }

    public func fetch(_ ref: SkillRef) async throws -> FetchedSkill {
        let url = try resolve(ref)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SkillSourceError.notFound(url.path)
        }
        let manifest = manifest(forBundleAt: url)
        return FetchedSkill(ref: ref, url: url, manifest: manifest)
    }

    private func resolve(_ ref: SkillRef) throws -> URL {
        if !ref.locator.isEmpty {
            return URL(fileURLWithPath: ref.locator)
        }
        guard let baseDirectory else {
            throw SkillSourceError.notFound("no locator and no base directory for \(ref.skillID)")
        }
        return baseDirectory.appendingPathComponent(ref.skillID, isDirectory: true)
    }

    /// Loads the manifest from a directory bundle so the installer can verify checksum/signature.
    /// Zip bundles are read after extraction by the installer, so nil here is fine.
    private func manifest(forBundleAt url: URL) -> HarnessSkillManifest? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return HarnessSkillManifest.load(from: url.appendingPathComponent(HarnessSkillManifest.fileName))
    }
}
