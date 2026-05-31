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

public struct LocalAppTaskSkillContext: Equatable, Sendable {
    public var snippets: [String]

    public init(snippets: [String]) {
        self.snippets = snippets
    }

    /// Builds skill guidance that scales to many skills via progressive disclosure (no embeddings):
    ///   1. A compact discovery catalog — one line per skill (id + summary + tags) for the top-K
    ///      lexically-relevant skills — so the planner can SEE what is available and pick one.
    ///   2. The FULL instruction body of the single best-matched skill, so its concrete execution
    ///      steps (e.g. skill.load → skill.script.execute) are never truncated.
    /// Context stays bounded regardless of the total number of skills: K one-liners + 1 full body.
    /// The planner can `skill.load` any other catalog entry to get that skill's full body on demand.
    public static func defaultContext(
        command: String = "",
        taskDefinitions: [LocalAppTaskDefinition],
        appFinderCatalog: [LocalAppFinderCatalogEntry],
        maxSkills: Int = 24,
        detailCharacters: Int = 4_000
    ) -> LocalAppTaskSkillContext {
        let ranked = rankedBuiltInSkillDescriptors(
            command: command,
            taskDefinitions: taskDefinitions,
            appFinderCatalog: appFinderCatalog
        )
        guard !ranked.isEmpty else {
            return LocalAppTaskSkillContext(snippets: [])
        }

        let catalogEntries = ranked.prefix(max(1, maxSkills)).map(\.descriptor)
        let catalog = (["Available skills (pick the most relevant for the request; load it with skill.load to get its full steps):"]
            + catalogEntries.map(discoveryLine(for:)))
            .joined(separator: "\n")

        var snippets = [catalog]
        if let top = ranked.first, top.score > 0 {
            snippets.append(BuiltInLocalAppSkillPacks.instructionSnippet(for: top.descriptor, maxCharacters: detailCharacters))
        }
        return LocalAppTaskSkillContext(snippets: snippets)
    }

    /// One compact catalog line for discovery: `- <id>: <summary> (tags: a, b)`.
    private static func discoveryLine(for descriptor: HarnessSkillDescriptor) -> String {
        let tags = descriptor.tags.isEmpty ? "" : " (tags: \(descriptor.tags.joined(separator: ", ")))"
        return "- \(descriptor.id): \(descriptor.summary)\(tags)"
    }

    private static func rankedBuiltInSkillDescriptors(
        command: String,
        taskDefinitions: [LocalAppTaskDefinition],
        appFinderCatalog: [LocalAppFinderCatalogEntry]
    ) -> [(descriptor: HarnessSkillDescriptor, score: Int)] {
        // App-specific operating skills (those declaring `apps:`) are vision-driving playbooks
        // consumed via `appOperatingGuidance(forApp:)` by the vision action path — they are not
        // intent-planning skills, so keep them out of the planner's skill catalog/ranking.
        let descriptors = BuiltInLocalAppSkillPacks.descriptors()
            .filter { ($0.metadata["apps"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !descriptors.isEmpty else { return [] }

        var taskValues: [String] = []
        for definition in taskDefinitions {
            taskValues.append(definition.taskType)
            taskValues.append(definition.targetApp.appName)
            taskValues.append(definition.metadata["displayTitle"] ?? "")
            taskValues.append(definition.metadata["domain"] ?? "")
            taskValues.append(definition.metadata["catalogEntry"] ?? "")
        }
        let taskTokens = tokens(in: taskValues.joined(separator: " "))

        var catalogValues: [String] = []
        for entry in appFinderCatalog {
            catalogValues.append(entry.appName)
            catalogValues.append(entry.description)
            for capability in entry.capabilities {
                catalogValues.append(capability.id)
                catalogValues.append(capability.summary)
                catalogValues.append(capability.controlProfiles.joined(separator: " "))
            }
        }
        let catalogTokens = tokens(in: catalogValues.joined(separator: " "))
        // The user's actual request is the strongest signal for which skills the task needs, so
        // weight command matches heavily. Without this, selection only reflects installed apps and
        // static task definitions, which can miss (or arbitrarily pick) the skill the task requires.
        let commandTokens = tokens(in: command)
        let availableTokens = taskTokens.union(catalogTokens).union(commandTokens)
        return descriptors.map { descriptor in
            // Score over id, name, summary, tags, and the file-based `keywords:` trigger words.
            let descriptorTokens = tokens(
                in: ([descriptor.id, descriptor.name, descriptor.summary, descriptor.metadata["keywords"] ?? ""]
                    + descriptor.tags)
                    .joined(separator: " ")
            )
            let score = descriptorTokens.intersection(availableTokens).count
                + 3 * descriptorTokens.intersection(commandTokens).count
            return (descriptor: descriptor, score: score)
        }
        .sorted {
            if $0.score == $1.score {
                return $0.descriptor.name < $1.descriptor.name
            }
            return $0.score > $1.score
        }
    }

    private static func tokens(in value: String) -> Set<String> {
        ControlTextRelevance.tokens(in: value)
    }
}
