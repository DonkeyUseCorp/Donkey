import DonkeyHarness
import Foundation

public extension Notification.Name {
    /// Posted after a skill is installed, updated, or uninstalled so observers (e.g. UI) can refresh.
    /// The harness itself does not need this — it re-reads the skill catalog at the start of each
    /// turn — but invalidating the discovery cache here makes a change visible immediately.
    static let donkeySkillsChanged = Notification.Name("com.donkey.skillsChanged")
}

/// Coordinates the install pipeline end to end: resolve a skill from a `SkillSource`, verify and
/// place it via `HarnessSkillInstaller`, then make it visible to the running harness.
///
/// Installed skills become live without any registry plumbing here: every consumer
/// (`app_skill`/`skill_run`, the planner's skill catalog, the per-run skill registry) reads
/// `BuiltInLocalAppSkillPacks.descriptors()`, which now folds in the installed directory. This
/// manager just performs the disk change, drops the discovery cache so the next read is fresh, and
/// announces it.
public struct HarnessSkillInstallManager: Sendable {
    public var source: SkillSource
    public var installer: HarnessSkillInstaller

    public init(
        source: SkillSource = LocalDirectorySkillSource(),
        installer: HarnessSkillInstaller = HarnessSkillInstaller()
    ) {
        self.source = source
        self.installer = installer
    }

    /// Install (or update — the layout is versioned, so installing a new version is the update) the
    /// referenced skill. Throws without changing the live install on any fetch/verify failure.
    @discardableResult
    public func install(_ ref: SkillRef) async throws -> HarnessSkillInstaller.InstallResult {
        let fetched = try await source.fetch(ref)
        let result = try installer.install(fetched)
        await refreshAfterChange()
        return result
    }

    public func uninstall(skillID: String) async throws {
        try installer.uninstall(skillID: skillID)
        await refreshAfterChange()
    }

    public func installedSkills() -> [InstallReceipt] {
        installer.installedReceipts()
    }

    private func refreshAfterChange() async {
        BuiltInLocalAppSkillPacks.invalidateInstalledCache()
        await MainActor.run {
            NotificationCenter.default.post(name: .donkeySkillsChanged, object: nil)
        }
    }
}
