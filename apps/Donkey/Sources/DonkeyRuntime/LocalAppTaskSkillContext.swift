import DonkeyContracts
import DonkeyHarness
import Foundation

public enum BuiltInLocalAppSkillPacks {
    public static var rootURL: URL? {
        Bundle.module.resourceURL?.appendingPathComponent("BuiltInSkills", isDirectory: true)
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

    public static func descriptors() -> [HarnessSkillDescriptor] {
        cachedDescriptors
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
        let wanted = Set(
            ([appName, bundleIdentifier].compactMap { $0 })
                .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard !wanted.isEmpty else { return nil }

        let match = descriptors().first { descriptor in
            let apps = (descriptor.metadata["apps"] ?? "")
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return apps.contains { app in wanted.contains { AppNameMatching.matches($0, app) } }
        }
        guard let match else { return nil }
        let body = bounded(strippedSkillMetadata(from: match.description), maxCharacters: maxCharacters)
        return body.isEmpty ? nil : body
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
