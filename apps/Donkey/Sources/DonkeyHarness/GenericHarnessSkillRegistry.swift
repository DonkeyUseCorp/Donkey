import Foundation

public enum HarnessSkillSourceKind: String, Codable, Equatable, Sendable {
    case builtIn
    case plugin
    case userDirectory
    case workspace
    case remoteCatalog
}

public struct HarnessSkillDescriptor: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var description: String
    public var sourceKind: HarnessSkillSourceKind
    public var instructionPath: String?
    public var tags: [String]
    public var providedToolNames: [String]
    public var scripts: [HarnessSkillScriptDescriptor]
    public var requiredPermissions: [HarnessPermission]
    public var metadata: [String: String]

    public init(
        id: String,
        name: String,
        summary: String,
        description: String = "",
        sourceKind: HarnessSkillSourceKind,
        instructionPath: String? = nil,
        tags: [String] = [],
        providedToolNames: [String] = [],
        scripts: [HarnessSkillScriptDescriptor] = [],
        requiredPermissions: [HarnessPermission] = [],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.description = description
        self.sourceKind = sourceKind
        self.instructionPath = instructionPath
        self.tags = Array(Set(tags)).sorted()
        self.providedToolNames = Array(Set(providedToolNames)).sorted()
        self.scripts = scripts.sorted { $0.id < $1.id }
        self.requiredPermissions = requiredPermissions
        self.metadata = metadata
    }
}

public enum HarnessSkillScriptLanguage: String, Codable, Equatable, Sendable {
    case appleScript
    case shell
    case javaScript
    case python
    case swift
    case unknown
}

public enum HarnessSkillScriptValidationStatus: String, Codable, Equatable, Sendable {
    case generated
    case pendingValidation
    case validated
    case rejected
}

public struct HarnessSkillScriptDescriptor: Codable, Equatable, Sendable {
    public var id: String
    public var language: HarnessSkillScriptLanguage
    public var purpose: String
    public var relativePath: String
    public var generatedBy: String?
    public var validationStatus: HarnessSkillScriptValidationStatus
    public var requiredPermissions: [HarnessPermission]
    public var safetyClass: HarnessToolSafetyClass
    public var metadata: [String: String]

    public init(
        id: String,
        language: HarnessSkillScriptLanguage,
        purpose: String,
        relativePath: String,
        generatedBy: String? = nil,
        validationStatus: HarnessSkillScriptValidationStatus = .pendingValidation,
        requiredPermissions: [HarnessPermission] = [],
        safetyClass: HarnessToolSafetyClass = .sensitive,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.language = language
        self.purpose = purpose
        self.relativePath = relativePath
        self.generatedBy = generatedBy
        self.validationStatus = validationStatus
        self.requiredPermissions = requiredPermissions
        self.safetyClass = safetyClass
        self.metadata = metadata
    }
}

public struct HarnessSkillSearchResult: Codable, Equatable, Sendable {
    public var descriptor: HarnessSkillDescriptor
    public var score: Int
    public var matchedFields: [String]

    public init(
        descriptor: HarnessSkillDescriptor,
        score: Int,
        matchedFields: [String]
    ) {
        self.descriptor = descriptor
        self.score = score
        self.matchedFields = Array(Set(matchedFields)).sorted()
    }
}

public actor HarnessSkillRegistry {
    private var skillsByID: [String: HarnessSkillDescriptor]

    public init(skills: [HarnessSkillDescriptor] = []) {
        self.skillsByID = Dictionary(uniqueKeysWithValues: skills.map { ($0.id, $0) })
    }

    public func register(_ skill: HarnessSkillDescriptor) {
        skillsByID[skill.id] = skill
    }

    public func register(contentsOf skills: [HarnessSkillDescriptor]) {
        for skill in skills {
            skillsByID[skill.id] = skill
        }
    }

    public func descriptor(id: String) -> HarnessSkillDescriptor? {
        skillsByID[id]
    }

    public func descriptors() -> [HarnessSkillDescriptor] {
        skillsByID.values.sorted {
            if $0.name == $1.name {
                return $0.id < $1.id
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public func search(
        query: String,
        limit: Int = 8
    ) -> [HarnessSkillSearchResult] {
        let tokens = Self.tokens(query)
        guard !tokens.isEmpty else {
            return Array(descriptors().prefix(max(0, limit))).map {
                HarnessSkillSearchResult(descriptor: $0, score: 0, matchedFields: [])
            }
        }

        return skillsByID.values.compactMap { skill in
            let scored = Self.score(skill: skill, tokens: tokens)
            guard scored.score > 0 else { return nil }
            return HarnessSkillSearchResult(
                descriptor: skill,
                score: scored.score,
                matchedFields: scored.fields
            )
        }
        .sorted {
            if $0.score == $1.score {
                return $0.descriptor.name < $1.descriptor.name
            }
            return $0.score > $1.score
        }
        .prefix(max(0, limit))
        .map { $0 }
    }

    private static func score(
        skill: HarnessSkillDescriptor,
        tokens: [String]
    ) -> (score: Int, fields: [String]) {
        var score = 0
        var fields: [String] = []
        for token in tokens {
            if normalized(skill.name).contains(token) {
                score += 8
                fields.append("name")
            }
            if normalized(skill.id).contains(token) {
                score += 6
                fields.append("id")
            }
            if normalized(skill.summary).contains(token) {
                score += 4
                fields.append("summary")
            }
            if normalized(skill.description).contains(token) {
                score += 2
                fields.append("description")
            }
            if skill.tags.contains(where: { normalized($0).contains(token) }) {
                score += 3
                fields.append("tags")
            }
            if skill.providedToolNames.contains(where: { normalized($0).contains(token) }) {
                score += 3
                fields.append("tools")
            }
        }
        return (score, fields)
    }

    private static func tokens(_ value: String) -> [String] {
        normalized(value)
            .split(separator: " ")
            .map(String.init)
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .map { character in
                character.isLetter || character.isNumber ? character : " "
            }
            .reduce(into: "") { result, character in
                if character == " ", result.last == " " {
                    return
                }
                result.append(character)
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct HarnessSkillFileSystemSource: Sendable {
    public var roots: [URL]
    public var maxDepth: Int
    public var sourceKind: HarnessSkillSourceKind

    public init(
        roots: [URL],
        maxDepth: Int = 4,
        sourceKind: HarnessSkillSourceKind = .userDirectory
    ) {
        self.roots = roots
        self.maxDepth = max(0, maxDepth)
        self.sourceKind = sourceKind
    }

    public func discover() -> [HarnessSkillDescriptor] {
        roots.flatMap { root in
            discover(in: root)
        }
        .sorted {
            if $0.name == $1.name {
                return $0.id < $1.id
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func discover(in root: URL) -> [HarnessSkillDescriptor] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return []
        }

        var descriptors: [HarnessSkillDescriptor] = []
        if let rootSkill = descriptor(forSkillMarkdownAt: root.appendingPathComponent("SKILL.md")) {
            descriptors.append(rootSkill)
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return descriptors
        }

        for case let url as URL in enumerator {
            let depth = relativeDepth(of: url, from: root)
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            guard url.lastPathComponent == "SKILL.md",
                  url != root.appendingPathComponent("SKILL.md"),
                  let descriptor = descriptor(forSkillMarkdownAt: url)
            else {
                continue
            }
            descriptors.append(descriptor)
        }

        return descriptors
    }

    private func descriptor(forSkillMarkdownAt url: URL) -> HarnessSkillDescriptor? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path),
              let contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            return nil
        }

        let directory = url.deletingLastPathComponent()
        let directoryName = directory.lastPathComponent
        let name = firstMarkdownHeading(in: contents) ?? titleCased(directoryName)
        let summary = metadataLine(named: "description", in: contents)
            ?? firstNonEmptyBodyLine(in: contents)
            ?? "Skill instructions for \(name)."
        let tags = metadataList(named: "tags", in: contents)
        let toolNames = metadataList(named: "tools", in: contents)
        let id = metadataLine(named: "id", in: contents)
            ?? slug(directoryName.isEmpty ? name : directoryName)

        return HarnessSkillDescriptor(
            id: id,
            name: name,
            summary: summary,
            description: contents,
            sourceKind: sourceKind,
            instructionPath: url.path,
            tags: tags,
            providedToolNames: toolNames,
            scripts: scriptDescriptors(in: directory),
            metadata: [
                "source": sourceKind == .builtIn ? "builtInFilesystem" : "filesystem",
                "directory": directory.path
            ]
        )
    }

    private func metadataLine(named key: String, in contents: String) -> String? {
        let normalizedKey = key.lowercased()
        for line in contents.split(whereSeparator: \.isNewline).map(String.init).prefix(40) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = trimmed.lowercased()
            guard lowered.hasPrefix("\(normalizedKey):") else { continue }
            let value = String(trimmed.dropFirst(key.count + 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func metadataList(named key: String, in contents: String) -> [String] {
        guard let line = metadataLine(named: key, in: contents) else { return [] }
        return line
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func firstMarkdownHeading(in contents: String) -> String? {
        for line in contents.split(whereSeparator: \.isNewline).map(String.init).prefix(20) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("# ") else { continue }
            let heading = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            return heading.isEmpty ? nil : heading
        }
        return nil
    }

    private func firstNonEmptyBodyLine(in contents: String) -> String? {
        for line in contents.split(whereSeparator: \.isNewline).map(String.init).prefix(80) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.contains(":") {
                continue
            }
            return trimmed
        }
        return nil
    }

    private func scriptDescriptors(in skillDirectory: URL) -> [HarnessSkillScriptDescriptor] {
        let scriptsDirectory = skillDirectory.appendingPathComponent("scripts", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: scriptsDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                at: scriptsDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              )
        else {
            return []
        }

        return enumerator.compactMap { item -> HarnessSkillScriptDescriptor? in
            guard let url = item as? URL,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  let language = scriptLanguage(for: url)
            else {
                return nil
            }

            let relativePath = relativePath(of: url, from: skillDirectory)
            let basename = url.deletingPathExtension().lastPathComponent
            return HarnessSkillScriptDescriptor(
                id: slug(relativePath),
                language: language,
                purpose: titleCased(basename),
                relativePath: relativePath,
                validationStatus: .pendingValidation,
                requiredPermissions: requiredPermissions(for: language),
                safetyClass: language == .appleScript ? .guardedInput : .sensitive,
                metadata: [
                    "source": "filesystem",
                    "scriptDirectory": scriptsDirectory.path
                ]
            )
        }
        .sorted { $0.id < $1.id }
    }

    private func scriptLanguage(for url: URL) -> HarnessSkillScriptLanguage? {
        switch url.pathExtension.lowercased() {
        case "applescript", "scpt":
            return .appleScript
        case "sh", "bash", "zsh":
            return .shell
        case "js", "mjs":
            return .javaScript
        case "py":
            return .python
        case "swift":
            return .swift
        default:
            return nil
        }
    }

    private func requiredPermissions(for language: HarnessSkillScriptLanguage) -> [HarnessPermission] {
        switch language {
        case .appleScript:
            return [.appControl, .input]
        case .shell, .javaScript, .python, .swift:
            return [.input]
        case .unknown:
            return []
        }
    }

    private func relativePath(of url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func relativeDepth(of url: URL, from root: URL) -> Int {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        return max(0, components.count - rootComponents.count)
    }

    private func titleCased(_ value: String) -> String {
        value
            .split { !$0.isLetter && !$0.isNumber }
            .map { word in word.prefix(1).uppercased() + word.dropFirst() }
            .joined(separator: " ")
    }

    private func slug(_ value: String) -> String {
        value.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "-")
    }
}
