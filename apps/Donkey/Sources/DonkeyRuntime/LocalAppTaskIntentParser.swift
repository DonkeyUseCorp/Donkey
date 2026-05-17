import DonkeyContracts
import Foundation

public struct LocalAppTaskIntentParser: Sendable {
    public var taskDefinitions: [LocalAppTaskDefinition]

    public init(taskDefinitions: [LocalAppTaskDefinition]) {
        self.taskDefinitions = taskDefinitions
    }

    public func parse(_ command: String) -> TaskIntent? {
        let normalizedCommand = Self.normalizedPhrase(command)
        guard let definition = taskDefinitions.first(where: { matches($0, normalizedCommand: normalizedCommand) }) else {
            return nil
        }

        let parsedEntities = parseEntities(from: command, using: definition)
        if let missingEntity = definition.entityRules.first(where: { rule in
            rule.required && parsedEntities.normalized[rule.name] == nil
        }) {
            return TaskIntent(
                intentID: "\(definition.taskType)-needs-\(missingEntity.name)",
                taskType: definition.taskType,
                targetApp: definition.targetApp,
                confidence: 0.45,
                parserSource: .deterministic,
                needsConfirmation: true,
                metadata: [
                    "parser": "local-app-task-deterministic-v1",
                    "missingEntity": missingEntity.name
                ].merging(definition.metadata) { current, _ in current }
            )
        }

        let primaryEntity = definition.verificationEntityName
            .flatMap { parsedEntities.normalized[$0] }
            ?? parsedEntities.normalized.values.sorted().first
            ?? definition.taskType

        return TaskIntent(
            intentID: "\(definition.taskType)-\(slug(primaryEntity))",
            taskType: definition.taskType,
            targetApp: definition.targetApp,
            entities: parsedEntities.raw,
            normalizedEntities: parsedEntities.normalized,
            confidence: parsedEntities.usedAlias ? 0.96 : 0.88,
            parserSource: .deterministic,
            needsConfirmation: false,
            metadata: [
                "parser": "local-app-task-deterministic-v1",
                "entityAliasExpanded": String(parsedEntities.usedAlias),
                "rawCommandNormalized": normalizedCommand
            ].merging(definition.metadata) { current, _ in current }
        )
    }

    private func matches(
        _ definition: LocalAppTaskDefinition,
        normalizedCommand: String
    ) -> Bool {
        let paddedCommand = " \(normalizedCommand) "
        return definition.triggerTerms
            .map(Self.normalizedPhrase)
            .contains { paddedCommand.contains(" \($0) ") }
    }

    private func parseEntities(
        from command: String,
        using definition: LocalAppTaskDefinition
    ) -> (raw: [String: String], normalized: [String: String], usedAlias: Bool) {
        var raw: [String: String] = [:]
        var normalized: [String: String] = [:]
        var usedAlias = false

        for rule in definition.entityRules {
            guard let candidate = entityCandidate(from: command, rule: rule) else { continue }
            raw[rule.name] = candidate.raw
            normalized[rule.name] = candidate.normalized
            usedAlias = usedAlias || candidate.usedAlias
        }

        return (raw, normalized, usedAlias)
    }

    private func entityCandidate(
        from command: String,
        rule: LocalAppTaskEntityRule
    ) -> (raw: String, normalized: String, usedAlias: Bool)? {
        let aliases = rule.aliases.reduce(into: [:]) { result, item in
            result[Self.normalizedPhrase(item.key)] = item.value
        }
        let normalizedCommand = Self.normalizedPhrase(command)
        let paddedCommand = " \(normalizedCommand) "

        if let alias = aliases.keys.sorted(by: { $0.count > $1.count }).first(where: { paddedCommand.contains(" \($0) ") }),
           let normalized = aliases[alias] {
            return (alias, normalized, true)
        }

        for marker in rule.markers.map(Self.normalizedPhrase) {
            let pattern = #"\b\#(NSRegularExpression.escapedPattern(for: marker))\b\s+(.+)$"#
            if let match = firstCapture(in: command, pattern: pattern) {
                let cleaned = cleanEntityCandidate(match)
                guard !cleaned.isEmpty else { continue }
                let normalized = aliases[Self.normalizedPhrase(cleaned)] ?? titleCased(cleaned)
                return (cleaned, normalized, normalized != titleCased(cleaned))
            }
        }

        return nil
    }

    private func firstCapture(in command: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        guard let match = regex.firstMatch(in: command, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: command)
        else {
            return nil
        }

        return String(command[captureRange])
    }

    private func cleanEntityCandidate(_ candidate: String) -> String {
        var cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))

        let suffixPattern = #"\s+(today|tomorrow|tonight|please|pls)$"#
        while let regex = try? NSRegularExpression(pattern: suffixPattern, options: [.caseInsensitive]) {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            guard let match = regex.firstMatch(in: cleaned, options: [], range: range),
                  let swiftRange = Range(match.range, in: cleaned)
            else {
                break
            }
            cleaned.removeSubrange(swiftRange)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return cleaned
    }

    private func titleCased(_ value: String) -> String {
        Self.normalizedPhrase(value)
            .split(separator: " ")
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    private func slug(_ value: String) -> String {
        Self.normalizedPhrase(value)
            .split(separator: " ")
            .joined(separator: "-")
    }

    public static func normalizedPhrase(_ value: String) -> String {
        let folded = value.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars)
            .split(separator: " ")
            .joined(separator: " ")
            .lowercased()
    }
}
