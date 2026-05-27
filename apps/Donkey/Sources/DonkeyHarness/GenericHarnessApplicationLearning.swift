import Foundation

public struct HarnessApplicationLearningObservation: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var focusedApp: String?
    public var focusedWindowTitle: String?
    public var screenshotArtifactURL: String?
    public var accessibilityArtifactURL: String?
    public var visibleText: [String: String]
    public var elements: [HarnessWorldElement]
    public var navigationPath: [String]
    public var changedFromPrevious: String
    public var safetyNotes: [String]
    public var capturedAt: Date
    public var metadata: [String: String]

    public init(
        id: String,
        title: String,
        focusedApp: String? = nil,
        focusedWindowTitle: String? = nil,
        screenshotArtifactURL: String? = nil,
        accessibilityArtifactURL: String? = nil,
        visibleText: [String: String] = [:],
        elements: [HarnessWorldElement] = [],
        navigationPath: [String] = [],
        changedFromPrevious: String = "",
        safetyNotes: [String] = [],
        capturedAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.focusedApp = focusedApp
        self.focusedWindowTitle = focusedWindowTitle
        self.screenshotArtifactURL = screenshotArtifactURL
        self.accessibilityArtifactURL = accessibilityArtifactURL
        self.visibleText = visibleText
        self.elements = elements
        self.navigationPath = navigationPath
        self.changedFromPrevious = changedFromPrevious
        self.safetyNotes = safetyNotes
        self.capturedAt = capturedAt
        self.metadata = metadata
    }
}

public struct HarnessApplicationWorkflowStep: Codable, Equatable, Sendable {
    public var id: String
    public var summary: String
    public var toolName: String?
    public var inputHints: [String: String]
    public var safetyClass: HarnessToolSafetyClass
    public var verification: String
    public var metadata: [String: String]

    public init(
        id: String,
        summary: String,
        toolName: String? = nil,
        inputHints: [String: String] = [:],
        safetyClass: HarnessToolSafetyClass = .readOnly,
        verification: String = "",
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.summary = summary
        self.toolName = toolName
        self.inputHints = inputHints
        self.safetyClass = safetyClass
        self.verification = verification
        self.metadata = metadata
    }
}

public struct HarnessApplicationWorkflowRecipe: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var steps: [HarnessApplicationWorkflowStep]
    public var verificationCriteria: [String]
    public var metadata: [String: String]

    public init(
        id: String,
        name: String,
        summary: String,
        steps: [HarnessApplicationWorkflowStep] = [],
        verificationCriteria: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.steps = steps
        self.verificationCriteria = verificationCriteria
        self.metadata = metadata
    }
}

public struct HarnessApplicationProfile: Codable, Equatable, Sendable {
    public var skillID: String
    public var appName: String
    public var bundleIdentifier: String?
    public var learningGoal: String
    public var observations: [HarnessApplicationLearningObservation]
    public var workflowRecipes: [HarnessApplicationWorkflowRecipe]
    public var generatedScriptIDs: [String]
    public var safetyNotes: [String]
    public var generatedAt: Date
    public var metadata: [String: String]

    public init(
        skillID: String,
        appName: String,
        bundleIdentifier: String? = nil,
        learningGoal: String,
        observations: [HarnessApplicationLearningObservation],
        workflowRecipes: [HarnessApplicationWorkflowRecipe] = [],
        generatedScriptIDs: [String] = [],
        safetyNotes: [String] = [],
        generatedAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.skillID = skillID
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.learningGoal = learningGoal
        self.observations = observations
        self.workflowRecipes = workflowRecipes
        self.generatedScriptIDs = generatedScriptIDs
        self.safetyNotes = safetyNotes
        self.generatedAt = generatedAt
        self.metadata = metadata
    }
}

public struct HarnessApplicationLearningDraft: Codable, Equatable, Sendable {
    public var id: String
    public var taskID: String
    public var skillID: String
    public var appName: String
    public var bundleIdentifier: String?
    public var learningGoal: String
    public var explorationPolicy: String
    public var observations: [HarnessApplicationLearningObservation]
    public var profile: HarnessApplicationProfile?
    public var createdAt: Date
    public var updatedAt: Date
    public var metadata: [String: String]

    public init(
        id: String,
        taskID: String,
        skillID: String,
        appName: String,
        bundleIdentifier: String? = nil,
        learningGoal: String,
        explorationPolicy: String,
        observations: [HarnessApplicationLearningObservation] = [],
        profile: HarnessApplicationProfile? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.taskID = taskID
        self.skillID = skillID
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.learningGoal = learningGoal
        self.explorationPolicy = explorationPolicy
        self.observations = observations
        self.profile = profile
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }
}

public struct HarnessApplicationSkillPackSaveResult: Codable, Equatable, Sendable {
    public var skill: HarnessSkillDescriptor
    public var directoryPath: String
    public var writtenFiles: [String]
    public var scriptCount: Int

    public init(
        skill: HarnessSkillDescriptor,
        directoryPath: String,
        writtenFiles: [String],
        scriptCount: Int
    ) {
        self.skill = skill
        self.directoryPath = directoryPath
        self.writtenFiles = writtenFiles
        self.scriptCount = scriptCount
    }
}

public actor HarnessApplicationLearningStore {
    private var draftsByID: [String: HarnessApplicationLearningDraft]

    public init(drafts: [HarnessApplicationLearningDraft] = []) {
        self.draftsByID = Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0) })
    }

    @discardableResult
    public func begin(
        draftID: String,
        taskID: String,
        skillID: String,
        appName: String,
        bundleIdentifier: String?,
        learningGoal: String,
        explorationPolicy: String,
        metadata: [String: String] = [:]
    ) -> HarnessApplicationLearningDraft {
        let draft = HarnessApplicationLearningDraft(
            id: draftID,
            taskID: taskID,
            skillID: skillID,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            learningGoal: learningGoal,
            explorationPolicy: explorationPolicy,
            metadata: metadata
        )
        draftsByID[draftID] = draft
        return draft
    }

    public func draft(id: String) -> HarnessApplicationLearningDraft? {
        draftsByID[id]
    }

    @discardableResult
    public func record(
        draftID: String,
        observation: HarnessApplicationLearningObservation
    ) -> HarnessApplicationLearningDraft? {
        guard var draft = draftsByID[draftID] else { return nil }
        if let index = draft.observations.firstIndex(where: { $0.id == observation.id }) {
            draft.observations[index] = observation
        } else {
            draft.observations.append(observation)
        }
        draft.updatedAt = Date()
        draftsByID[draftID] = draft
        return draft
    }

    @discardableResult
    public func distill(
        draftID: String,
        workflowRecipes: [HarnessApplicationWorkflowRecipe] = [],
        generatedScriptIDs: [String] = [],
        safetyNotes: [String] = [],
        metadata: [String: String] = [:]
    ) -> HarnessApplicationProfile? {
        guard var draft = draftsByID[draftID],
              !draft.observations.isEmpty
        else {
            return nil
        }
        let profile = HarnessApplicationProfile(
            skillID: draft.skillID,
            appName: draft.appName,
            bundleIdentifier: draft.bundleIdentifier,
            learningGoal: draft.learningGoal,
            observations: draft.observations,
            workflowRecipes: workflowRecipes.isEmpty ? Self.defaultRecipes(for: draft) : workflowRecipes,
            generatedScriptIDs: generatedScriptIDs,
            safetyNotes: Array(Set(draft.observations.flatMap(\.safetyNotes) + safetyNotes)).sorted(),
            metadata: draft.metadata.merging(metadata) { current, _ in current }
        )
        draft.profile = profile
        draft.updatedAt = Date()
        draftsByID[draftID] = draft
        return profile
    }

    private static func defaultRecipes(for draft: HarnessApplicationLearningDraft) -> [HarnessApplicationWorkflowRecipe] {
        let steps = draft.observations.enumerated().map { index, observation in
            HarnessApplicationWorkflowStep(
                id: "observe-\(index + 1)",
                summary: "Observe \(observation.title)",
                toolName: "screen.observe",
                inputHints: ["stateID": observation.id],
                safetyClass: .readOnly,
                verification: observation.focusedWindowTitle ?? observation.title
            )
        }
        return [
            HarnessApplicationWorkflowRecipe(
                id: "inspect-\(slug(draft.appName))",
                name: "Inspect \(draft.appName)",
                summary: "Safely observe learned \(draft.appName) surfaces before acting.",
                steps: steps,
                verificationCriteria: draft.observations.map(\.title),
                metadata: ["generated": "defaultObservationRecipe"]
            )
        ]
    }

    private static func slug(_ value: String) -> String {
        value.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "-")
    }
}

public struct HarnessApplicationSkillPackWriter: Sendable {
    public var rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public static func defaultRootDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Donkey", isDirectory: true)
            .appendingPathComponent("Skills", isDirectory: true)
            .appendingPathComponent("LearnedApplications", isDirectory: true)
    }

    public func save(
        profile: HarnessApplicationProfile,
        scripts: [HarnessGeneratedScriptArtifact] = []
    ) throws -> HarnessApplicationSkillPackSaveResult {
        let skillID = sanitizedSlug(profile.skillID.isEmpty ? "learned-\(profile.appName)" : profile.skillID)
        var savedProfile = profile
        savedProfile.generatedScriptIDs = Array(
            Set(profile.generatedScriptIDs + scripts.filter { $0.validationStatus == .validated }.map(\.id))
        ).sorted()
        let skillDirectory = rootDirectory.appendingPathComponent(skillID, isDirectory: true)
        let scriptsDirectory = skillDirectory.appendingPathComponent("scripts", isDirectory: true)
        let evidenceDirectory = skillDirectory.appendingPathComponent("evidence", isDirectory: true)

        try FileManager.default.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)

        var written: [String] = []
        let skillMarkdown = skillMarkdown(for: savedProfile, skillID: skillID, scripts: scripts)
        let skillMarkdownURL = skillDirectory.appendingPathComponent("SKILL.md")
        try write(skillMarkdown, to: skillMarkdownURL)
        written.append(skillMarkdownURL.path)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let profileURL = skillDirectory.appendingPathComponent("app-profile.json")
        try encoder.encode(savedProfile).write(to: profileURL, options: .atomic)
        written.append(profileURL.path)

        let workflowsURL = skillDirectory.appendingPathComponent("workflows.json")
        try encoder.encode(savedProfile.workflowRecipes).write(to: workflowsURL, options: .atomic)
        written.append(workflowsURL.path)

        let evidenceIndex = savedProfile.observations.map { observation in
            HarnessApplicationEvidenceIndexEntry(
                id: observation.id,
                title: observation.title,
                screenshotArtifactURL: observation.screenshotArtifactURL,
                accessibilityArtifactURL: observation.accessibilityArtifactURL,
                focusedWindowTitle: observation.focusedWindowTitle,
                navigationPath: observation.navigationPath
            )
        }
        let evidenceURL = evidenceDirectory.appendingPathComponent("index.json")
        try encoder.encode(evidenceIndex).write(to: evidenceURL, options: .atomic)
        written.append(evidenceURL.path)

        var scriptDescriptors: [HarnessSkillScriptDescriptor] = []
        for artifact in scripts where artifact.validationStatus == .validated {
            let scriptName = "\(sanitizedSlug(artifact.id)).\(fileExtension(for: artifact.language))"
            let scriptURL = scriptsDirectory.appendingPathComponent(scriptName)
            try write(artifact.source, to: scriptURL)
            written.append(scriptURL.path)
            scriptDescriptors.append(
                HarnessSkillScriptDescriptor(
                    id: sanitizedSlug(artifact.id),
                    language: skillLanguage(for: artifact.language),
                    purpose: artifact.metadata["purpose"] ?? artifact.id,
                    relativePath: "scripts/\(scriptName)",
                    generatedBy: artifact.createdByToolName,
                    validationStatus: .validated,
                    requiredPermissions: requiredPermissions(for: artifact.language),
                    safetyClass: artifact.language == .appleScript ? .guardedInput : .sensitive,
                    metadata: artifact.metadata.merging([
                        "scriptArtifactID": artifact.id,
                        "source": "applicationLearning"
                    ]) { current, _ in current }
                )
            )
        }

        let descriptor = HarnessSkillDescriptor(
            id: skillID,
            name: "\(profile.appName) Learned Application",
            summary: "Learned surfaces and safe workflows for \(profile.appName).",
            description: skillMarkdown,
            sourceKind: .userDirectory,
            instructionPath: skillMarkdownURL.path,
            tags: ["application-learning", "learned-app", sanitizedSlug(profile.appName)],
            providedToolNames: [
                "screen.observe",
                "elements.get",
                "element.perform",
                "state.verify"
            ],
            scripts: scriptDescriptors,
            requiredPermissions: [.screenCapture, .accessibility],
            metadata: [
                "appName": profile.appName,
                "bundleIdentifier": profile.bundleIdentifier ?? "",
                "directory": skillDirectory.path,
                "source": "applicationLearning"
            ]
        )

        return HarnessApplicationSkillPackSaveResult(
            skill: descriptor,
            directoryPath: skillDirectory.path,
            writtenFiles: written.sorted(),
            scriptCount: scriptDescriptors.count
        )
    }

    private struct HarnessApplicationEvidenceIndexEntry: Codable, Equatable {
        var id: String
        var title: String
        var screenshotArtifactURL: String?
        var accessibilityArtifactURL: String?
        var focusedWindowTitle: String?
        var navigationPath: [String]
    }

    private func skillMarkdown(
        for profile: HarnessApplicationProfile,
        skillID: String,
        scripts: [HarnessGeneratedScriptArtifact]
    ) -> String {
        let visibleSurfaces = profile.observations
            .map { "- \($0.title): \($0.focusedWindowTitle ?? "window unknown")" }
            .joined(separator: "\n")
        let workflows = profile.workflowRecipes
            .map { "- \($0.name): \($0.summary)" }
            .joined(separator: "\n")
        let safety = profile.safetyNotes.isEmpty
            ? "- Default to read-only observation and ask before destructive, send, purchase, or overwrite actions."
            : profile.safetyNotes.map { "- \($0)" }.joined(separator: "\n")
        let scriptLines = scripts
            .filter { $0.validationStatus == .validated }
            .map { "- \($0.id): \($0.metadata["purpose"] ?? $0.id)" }
            .joined(separator: "\n")

        return """
        # \(profile.appName) Learned Application
        id: \(skillID)
        description: Learned surfaces and safe workflows for \(profile.appName).
        tags: application-learning, learned-app, \(sanitizedSlug(profile.appName))
        tools: screen.observe, elements.get, element.perform, state.verify

        Use this skill when operating \(profile.appName) or a compatible app surface.

        Learning goal: \(profile.learningGoal)

        Prefer safe exploration first: observe the screen, inspect Accessibility elements, open menus or tabs only when the action is reversible, and ask before destructive, sending, purchasing, or save-overwrite actions.

        ## Learned Surfaces

        \(visibleSurfaces.isEmpty ? "- No surfaces recorded." : visibleSurfaces)

        ## Workflow Recipes

        \(workflows.isEmpty ? "- No workflow recipes recorded." : workflows)

        ## Safety Notes

        \(safety)

        ## Scripts

        \(scriptLines.isEmpty ? "- No validated scripts recorded." : scriptLines)
        """
    }

    private func write(_ value: String, to url: URL) throws {
        try value.write(to: url, atomically: true, encoding: .utf8)
    }

    private func sanitizedSlug(_ value: String) -> String {
        let slug = value.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "-")
        return slug.isEmpty ? "learned-application" : slug
    }

    private func fileExtension(for language: HarnessGeneratedScriptLanguage) -> String {
        switch language {
        case .appleScript:
            return "applescript"
        case .shell:
            return "sh"
        case .javaScript:
            return "js"
        case .python:
            return "py"
        case .swift:
            return "swift"
        case .unknown:
            return "txt"
        }
    }

    private func skillLanguage(for language: HarnessGeneratedScriptLanguage) -> HarnessSkillScriptLanguage {
        switch language {
        case .appleScript:
            return .appleScript
        case .shell:
            return .shell
        case .javaScript:
            return .javaScript
        case .python:
            return .python
        case .swift:
            return .swift
        case .unknown:
            return .unknown
        }
    }

    private func requiredPermissions(for language: HarnessGeneratedScriptLanguage) -> [HarnessPermission] {
        switch language {
        case .appleScript:
            return [.appControl, .input]
        case .shell, .javaScript, .python, .swift:
            return [.input]
        case .unknown:
            return []
        }
    }
}
