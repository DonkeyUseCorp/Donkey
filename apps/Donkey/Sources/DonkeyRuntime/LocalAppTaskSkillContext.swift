import DonkeyContracts
import DonkeyHarness
import Foundation

public enum BuiltInLocalAppSkillPacks {
    public static var rootURL: URL? {
        DonkeyResourceBundle.runtime?.resourceURL?.appendingPathComponent("BuiltInSkills", isDirectory: true)
    }

    /// Built-in skills ship inside the bundle and never change at runtime, so discover them (which
    /// walks the BuiltInSkills tree and reads every SKILL.md from disk) exactly once. Callers on the
    /// planning hot path — `defaultContext` and `appOperatingGuidance` run per turn — reuse this.
    private static let cachedDescriptors: [HarnessSkillDescriptor] = {
        guard let rootURL else { return [] }
        return HarnessSkillFileSystemSource(
            roots: [rootURL],
            sourceKind: .builtIn
        ).discover()
    }()

    /// Learned application skill packs (saved by `application.learning.saveSkillPack`) can appear
    /// mid-session, so unlike the bundled packs they are re-discovered with a short TTL. This is
    /// what makes learning compound: a pack saved in one session is matched and preloaded like a
    /// built-in in every later session.
    private final class TTLDescriptorCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: (descriptors: [HarnessSkillDescriptor], at: Date)?

        func descriptors(ttl: TimeInterval, discover: () -> [HarnessSkillDescriptor]) -> [HarnessSkillDescriptor] {
            lock.lock()
            defer { lock.unlock() }
            if let cached, Date().timeIntervalSince(cached.at) < ttl {
                return cached.descriptors
            }
            let fresh = discover()
            cached = (fresh, Date())
            return fresh
        }

        func invalidate() {
            lock.lock()
            defer { lock.unlock() }
            cached = nil
        }
    }

    private static let learnedPackCache = TTLDescriptorCache()
    private static let installedPackCache = TTLDescriptorCache()

    public static func learnedDescriptors() -> [HarnessSkillDescriptor] {
        learnedPackCache.descriptors(ttl: 30) {
            HarnessSkillFileSystemSource(
                roots: [HarnessApplicationSkillPackWriter.defaultRootDirectory()],
                sourceKind: .userDirectory
            ).discover()
        }
    }

    /// Skills the user installed from the catalog. Each lives at `Installed/<id>/current`; like
    /// learned packs they can appear mid-session, so they are re-discovered with a short TTL.
    public static func installedDescriptors() -> [HarnessSkillDescriptor] {
        installedPackCache.descriptors(ttl: 30) {
            let roots = HarnessSkillInstaller().currentBundleRoots()
            guard !roots.isEmpty else { return [] }
            return HarnessSkillFileSystemSource(roots: roots, sourceKind: .installed).discover()
        }
    }

    /// Drop the installed-skill cache so a just-installed/uninstalled skill is visible immediately
    /// rather than after the TTL. Called by `HarnessSkillInstallManager` after a change.
    public static func invalidateInstalledCache() {
        installedPackCache.invalidate()
    }

    /// Built-in first, then installed, then learned, so a curated built-in always wins on an id
    /// collision and an installed catalog skill wins over a learned one. Dedup by id also guards the
    /// `HarnessSkillRegistry` (which keys uniquely on id) against a duplicate-id crash.
    public static func descriptors() -> [HarnessSkillDescriptor] {
        dedupedByID(cachedDescriptors + installedDescriptors() + learnedDescriptors())
    }

    private static func dedupedByID(
        _ descriptors: [HarnessSkillDescriptor]
    ) -> [HarnessSkillDescriptor] {
        var seen = Set<String>()
        var result: [HarnessSkillDescriptor] = []
        for descriptor in descriptors where seen.insert(descriptor.id).inserted {
            result.append(descriptor)
        }
        return result
    }

    public static func instructionSnippet(
        for descriptor: HarnessSkillDescriptor,
        maxCharacters: Int = 1_200
    ) -> String {
        let header = [
            "Skill: \(descriptor.name)",
            "Skill ID: \(descriptor.id)",
            descriptor.tags.isEmpty ? "" : "Tags: \(descriptor.tags.joined(separator: ", "))",
            descriptor.providedToolNames.isEmpty ? "" : "Tools: \(descriptor.providedToolNames.joined(separator: ", "))"
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")

        let body = bounded(
            strippedSkillMetadata(from: descriptor.description),
            maxCharacters: max(200, maxCharacters - header.count - 2)
        )
        return [header, body]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }

    /// Returns the operating playbook for an app-specific skill (one whose `apps:` frontmatter names
    /// this app by display name or bundle identifier), or nil if no app-specific skill is installed.
    /// This is how the runtime learns how to drive a particular app WITHOUT a hardcoded app list:
    /// add a `BuiltInSkills/<app>/SKILL.md` with an `apps:` line and it is discovered here.
    ///
    /// Consumed by the vision-driving action path (`VisionActionPlanner` via
    /// `UserQueryCommandHandler.handleVisionAction`) to supply per-app operating guidance when a
    /// non-scriptable app is driven by vision.
    public static func appOperatingGuidance(
        forApp appName: String,
        bundleIdentifier: String? = nil,
        maxCharacters: Int = 4_000
    ) -> String? {
        guard let match = appSkillDescriptor(forApp: appName, bundleIdentifier: bundleIdentifier) else {
            return nil
        }
        let body = bounded(strippedSkillMetadata(from: match.description), maxCharacters: maxCharacters)
        return body.isEmpty ? nil : body
    }

    /// The app-specific skill descriptor (one whose `apps:` frontmatter names this app by display
    /// name or bundle identifier), or nil when no app-specific skill is installed. Exposes the
    /// skill's id and validated scripts so callers can advertise runnable workflows alongside the
    /// operating playbook.
    public static func appSkillDescriptor(
        forApp appName: String,
        bundleIdentifier: String? = nil
    ) -> HarnessSkillDescriptor? {
        let wanted = Set(
            ([appName, bundleIdentifier].compactMap { $0 })
                .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard !wanted.isEmpty else { return nil }

        return descriptors().first { descriptor in
            let apps = (descriptor.metadata["apps"] ?? "")
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return apps.contains { app in wanted.contains { AppNameMatching.matches($0, app) } }
        }
    }

    /// A compact, one-line-per-skill catalog of every available skill (built-in + installed + learned) for
    /// the understanding boundary to choose from: `id`, the one-line description, and the trigger keywords.
    /// The model returns the ids of the skills a task should follow (`relevantSkillIDs`) and the harness
    /// preloads those guides — so no intent is matched in Swift; the model routes against this list.
    public static func skillSelectionCatalog() -> String? {
        let skills = descriptors().sorted { $0.id < $1.id }
        guard !skills.isEmpty else { return nil }
        let lines = skills.map { skill -> String in
            let keywords = (skill.metadata["keywords"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let keywordsText = keywords.isEmpty ? "" : " [keywords: \(keywords)]"
            return "  - \(skill.id): \(skill.summary)\(keywordsText)"
        }
        return lines.joined(separator: "\n")
    }

    /// The full operating guide for a skill selected by id (built-in, installed, or learned) — a labeled
    /// header plus the SKILL.md body with frontmatter stripped, bounded for the prompt. This is the
    /// capability-skill analogue of `appOperatingGuidance(forApp:)`: the understanding boundary names the
    /// `relevantSkillIDs` a task needs and the harness preloads each one's guide into the planner, so a task
    /// in a skill's domain gets that skill's playbook from step one without the model having to find it.
    public static func skillGuidance(forID id: String, maxCharacters: Int = 3_500) -> String? {
        let wanted = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty,
              let match = descriptors().first(where: { $0.id.lowercased() == wanted })
        else { return nil }
        let snippet = instructionSnippet(for: match, maxCharacters: maxCharacters)
        return snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : snippet
    }

    public static func scriptSource(
        skillID: String,
        relativePath: String
    ) -> String? {
        guard let descriptor = descriptors().first(where: { $0.id == skillID }),
              let directory = descriptor.metadata["directory"]
        else {
            return nil
        }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: false)
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : source
    }

    private static func strippedSkillMetadata(from contents: String) -> String {
        contents
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let lowered = trimmed.lowercased()
                return !lowered.hasPrefix("id:")
                    && !lowered.hasPrefix("description:")
                    && !lowered.hasPrefix("tags:")
                    && !lowered.hasPrefix("keywords:")
                    && !lowered.hasPrefix("apps:")
                    && !lowered.hasPrefix("scripts:")
                    && !lowered.hasPrefix("tools:")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bounded(_ value: String, maxCharacters: Int) -> String {
        guard value.count > maxCharacters else { return value }
        return String(value.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
