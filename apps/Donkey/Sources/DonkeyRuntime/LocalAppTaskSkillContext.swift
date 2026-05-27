import DonkeyContracts
import DonkeyHarness
import Foundation

public enum BuiltInLocalAppSkillPacks {
    public static var rootURL: URL? {
        Bundle.module.resourceURL?.appendingPathComponent("BuiltInSkills", isDirectory: true)
    }

    public static func descriptors() -> [HarnessSkillDescriptor] {
        guard let rootURL else { return [] }
        return HarnessSkillFileSystemSource(
            roots: [rootURL],
            sourceKind: .builtIn
        ).discover()
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

    public static func defaultContext(
        taskDefinitions: [LocalAppTaskDefinition],
        appFinderCatalog: [LocalAppFinderCatalogEntry],
        maxSkills: Int = 8
    ) -> LocalAppTaskSkillContext {
        let descriptors = selectedBuiltInSkillDescriptors(
            taskDefinitions: taskDefinitions,
            appFinderCatalog: appFinderCatalog,
            maxSkills: maxSkills
        )
        return LocalAppTaskSkillContext(
            snippets: descriptors.map {
                BuiltInLocalAppSkillPacks.instructionSnippet(for: $0)
            }
        )
    }

    private static func selectedBuiltInSkillDescriptors(
        taskDefinitions: [LocalAppTaskDefinition],
        appFinderCatalog: [LocalAppFinderCatalogEntry],
        maxSkills: Int
    ) -> [HarnessSkillDescriptor] {
        let descriptors = BuiltInLocalAppSkillPacks.descriptors()
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
        let availableTokens = taskTokens.union(catalogTokens)
        let scored: [(descriptor: HarnessSkillDescriptor, score: Int)] = descriptors.map { descriptor in
            let descriptorTokens = tokens(
                in: ([descriptor.id, descriptor.name, descriptor.summary] + descriptor.tags)
                    .joined(separator: " ")
            )
            let score = descriptorTokens.intersection(availableTokens).count
            return (descriptor: descriptor, score: score)
        }
        .sorted {
            if $0.score == $1.score {
                return $0.descriptor.name < $1.descriptor.name
            }
            return $0.score > $1.score
        }

        let matching = scored.filter { $0.score > 0 }.map { $0.descriptor }
        if !matching.isEmpty {
            return Array(matching.prefix(max(0, maxSkills)))
        }

        return Array(descriptors.prefix(max(0, maxSkills)))
    }

    private static func tokens(in value: String) -> Set<String> {
        Set(
            value.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { !$0.isEmpty }
        )
    }
}
