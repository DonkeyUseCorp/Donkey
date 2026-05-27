import Foundation

public struct HarnessMemoryEntry: Codable, Equatable, Sendable {
    public var id: String
    public var summary: String
    public var value: String
    public var metadata: [String: String]

    public init(
        id: String,
        summary: String,
        value: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.summary = summary
        self.value = value
        self.metadata = metadata
    }
}

public struct HarnessAppLookupEntry: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var bundleIdentifier: String?
    public var path: String?
    public var isInstalled: Bool
    public var metadata: [String: String]

    public init(
        id: String,
        name: String,
        bundleIdentifier: String? = nil,
        path: String? = nil,
        isInstalled: Bool = true,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.isInstalled = isInstalled
        self.metadata = metadata
    }
}

public enum HarnessGeneratedScriptLanguage: String, Codable, Equatable, Sendable {
    case appleScript
    case shell
    case javaScript
    case python
    case swift
    case unknown
}

public struct HarnessGeneratedScriptArtifact: Codable, Equatable, Sendable {
    public var id: String
    public var language: HarnessGeneratedScriptLanguage
    public var source: String
    public var validationStatus: HarnessSkillScriptValidationStatus
    public var createdByToolName: String
    public var ownerSkillID: String?
    public var metadata: [String: String]

    public init(
        id: String,
        language: HarnessGeneratedScriptLanguage,
        source: String,
        validationStatus: HarnessSkillScriptValidationStatus = .pendingValidation,
        createdByToolName: String,
        ownerSkillID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.language = language
        self.source = source
        self.validationStatus = validationStatus
        self.createdByToolName = createdByToolName
        self.ownerSkillID = ownerSkillID
        self.metadata = metadata
    }
}

public struct HarnessScriptExecutionOutcome: Equatable, Sendable {
    public var succeeded: Bool
    public var summary: String
    public var output: String
    public var metadata: [String: String]

    public init(
        succeeded: Bool,
        summary: String,
        output: String = "",
        metadata: [String: String] = [:]
    ) {
        self.succeeded = succeeded
        self.summary = summary
        self.output = output
        self.metadata = metadata
    }
}

public actor HarnessGeneratedScriptStore {
    private var artifactsByID: [String: HarnessGeneratedScriptArtifact]

    public init(artifacts: [HarnessGeneratedScriptArtifact] = []) {
        self.artifactsByID = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.id, $0) })
    }

    public func upsert(_ artifact: HarnessGeneratedScriptArtifact) {
        artifactsByID[artifact.id] = artifact
    }

    public func artifact(id: String) -> HarnessGeneratedScriptArtifact? {
        artifactsByID[id]
    }

    public func artifacts(ownerSkillID: String? = nil) -> [HarnessGeneratedScriptArtifact] {
        artifactsByID.values
            .filter { artifact in
                guard let ownerSkillID else { return true }
                return artifact.ownerSkillID == ownerSkillID
            }
            .sorted { $0.id < $1.id }
    }

    public func validate(
        id: String,
        metadata: [String: String] = [:]
    ) -> HarnessGeneratedScriptArtifact? {
        guard var artifact = artifactsByID[id] else { return nil }
        artifact.validationStatus = .validated
        artifact.metadata.merge(metadata) { current, _ in current }
        artifactsByID[id] = artifact
        return artifact
    }

    public func reject(
        id: String,
        reason: String
    ) -> HarnessGeneratedScriptArtifact? {
        guard var artifact = artifactsByID[id] else { return nil }
        artifact.validationStatus = .rejected
        artifact.metadata["rejection.reason"] = reason
        artifactsByID[id] = artifact
        return artifact
    }
}

public struct HarnessBuiltInToolServices: Sendable {
    public var memoryEntries: [HarnessMemoryEntry]
    public var appEntries: [HarnessAppLookupEntry]
    public var skillRegistry: HarnessSkillRegistry?
    public var generatedScripts: HarnessGeneratedScriptStore
    public var applicationLearningStore: HarnessApplicationLearningStore
    public var applicationSkillPackWriter: HarnessApplicationSkillPackWriter?
    public var appleScriptExecutor: (@Sendable (HarnessGeneratedScriptArtifact, HarnessToolExecutionContext) async -> HarnessScriptExecutionOutcome)?
    public var skillScriptExecutor: (@Sendable (HarnessGeneratedScriptArtifact, HarnessToolExecutionContext) async -> HarnessScriptExecutionOutcome)?

    public init(
        memoryEntries: [HarnessMemoryEntry] = [],
        appEntries: [HarnessAppLookupEntry] = [],
        skillRegistry: HarnessSkillRegistry? = nil,
        generatedScripts: HarnessGeneratedScriptStore = HarnessGeneratedScriptStore(),
        applicationLearningStore: HarnessApplicationLearningStore = HarnessApplicationLearningStore(),
        applicationSkillPackWriter: HarnessApplicationSkillPackWriter? = nil,
        appleScriptExecutor: (@Sendable (HarnessGeneratedScriptArtifact, HarnessToolExecutionContext) async -> HarnessScriptExecutionOutcome)? = nil,
        skillScriptExecutor: (@Sendable (HarnessGeneratedScriptArtifact, HarnessToolExecutionContext) async -> HarnessScriptExecutionOutcome)? = nil
    ) {
        self.memoryEntries = memoryEntries
        self.appEntries = appEntries
        self.skillRegistry = skillRegistry
        self.generatedScripts = generatedScripts
        self.applicationLearningStore = applicationLearningStore
        self.applicationSkillPackWriter = applicationSkillPackWriter
        self.appleScriptExecutor = appleScriptExecutor
        self.skillScriptExecutor = skillScriptExecutor
    }
}

public enum BuiltInHarnessToolExecutors {
    public static func tools(
        descriptors: [HarnessToolDescriptor],
        services: HarnessBuiltInToolServices = HarnessBuiltInToolServices()
    ) -> [HarnessTool] {
        descriptors.map { descriptor in
            HarnessTool(descriptor: descriptor) { context in
                await execute(context, services: services)
            }
        }
    }

    private static func execute(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        switch context.call.name {
        case "conversation.respond":
            return conversationRespond(context)
        case "user.clarify":
            return userClarify(context)
        case "permission.request":
            return permissionRequest(context)
        case "memory.retrieve":
            return memoryRetrieve(context, services: services)
        case "skill.search":
            return await skillSearch(context, services: services)
        case "skill.load":
            return await skillLoad(context, services: services)
        case "skill.script.generate":
            return await scriptGenerate(context, services: services, ownerSkillID: context.call.input["skillID"])
        case "skill.script.validate":
            return await scriptValidate(context, services: services)
        case "skill.script.execute":
            return await scriptExecute(context, services: services, executor: services.skillScriptExecutor)
        case "app.search":
            return appSearch(context, services: services)
        case "app.openOrFocus":
            return appOpenOrFocus(context, services: services)
        case "screen.observe":
            return screenObserve(context)
        case "elements.get":
            return elementsGet(context)
        case "element.perform":
            return elementPerform(context)
        case "text.enter":
            return textEnter(context)
        case "keyboard.press":
            return keyboardPress(context)
        case "automation.applescript.generate":
            return await appleScriptGenerate(context, services: services)
        case "automation.applescript.execute":
            return await scriptExecute(context, services: services, executor: services.appleScriptExecutor)
        case "application.learning.start":
            return await applicationLearningStart(context, services: services)
        case "application.learning.captureState":
            return await applicationLearningCaptureState(context, services: services)
        case "application.learning.proposeExploration":
            return applicationLearningProposeExploration(context)
        case "application.learning.distill":
            return await applicationLearningDistill(context, services: services)
        case "application.learning.saveSkillPack":
            return await applicationLearningSaveSkillPack(context, services: services)
        case "state.verify":
            return stateVerify(context)
        case "run.pause", "run.resume", "run.recover", "run.cancel", "run.complete", "run.failSafe":
            return lifecycle(context)
        default:
            return HarnessToolResult(
                callID: context.call.id,
                toolName: context.call.name,
                status: .unknownTool,
                summary: "Unknown harness tool: \(context.call.name)",
                metadata: ["reason": "unknownTool"]
            )
        }
    }

    private static func conversationRespond(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        let response = context.call.input["response"] ?? context.call.input["message"] ?? ""
        return success(
            context,
            summary: response.isEmpty ? "Conversation response recorded." : "Conversation response recorded.",
            facts: [
                "lastConversationResponseLength": String(response.count),
                "lastAcceptedTool": context.call.name
            ],
            metadata: ["externalAction": "false"]
        )
    }

    private static func userClarify(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        let question = trimmed(context.call.input["question"]) ?? "What detail should I use?"
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .waitingForUser,
            summary: "Task stopped for user clarification.",
            question: question,
            metadata: ["gate": "clarification"]
        )
    }

    private static func permissionRequest(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        let permissions = context.call.input["permission"]
            .map { [$0] }
            ?? context.call.input["permissions"]?
                .split(separator: ",")
                .map(String.init)
            ?? []
        let missing = permissions.compactMap { HarnessPermission(rawValue: trimmed($0) ?? "") }
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .waitingForPermission,
            summary: "Task stopped for permission.",
            missingPermissions: missing,
            metadata: [
                "gate": "permission",
                "requestedPermissions": missing.map(\.rawValue).joined(separator: ",")
            ]
        )
    }

    private static func memoryRetrieve(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) -> HarnessToolResult {
        guard let query = trimmed(context.call.input["query"]) else {
            return invalidInput(context, "memory.retrieve requires a non-empty query.")
        }

        let tokens = tokens(in: query)
        let configuredMatches = services.memoryEntries
            .filter { entry in matches(tokens: tokens, values: [entry.id, entry.summary, entry.value] + Array(entry.metadata.values)) }
            .prefix(8)
            .map { "\($0.id): \($0.summary)" }
        let worldMatches = (context.worldModel.facts.map { "\($0.key): \($0.value)" }
            + context.worldModel.visibleText.map { "\($0.key): \($0.value)" })
            .filter { matches(tokens: tokens, values: [$0]) }
            .prefix(8)
        let snippets = Array(configuredMatches + worldMatches)

        return success(
            context,
            summary: snippets.isEmpty ? "No relevant memory found." : "Retrieved \(snippets.count) memory snippet(s).",
            facts: [
                "memory.retrieve.query": query,
                "memory.retrieve.count": String(snippets.count),
                "memory.retrieve.snippets": snippets.joined(separator: "\n"),
                "lastAcceptedTool": context.call.name
            ],
            metadata: ["resultCount": String(snippets.count)]
        )
    }

    private static func skillSearch(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard let registry = services.skillRegistry else {
            return failed(context, "Skill registry is not configured.", reason: "missingSkillRegistry")
        }
        let query = trimmed(context.call.input["query"]) ?? context.worldModel.facts["taskType"] ?? context.call.input["skillID"] ?? ""
        let results = await registry.search(query: query)
        let skillIDs = results.map(\.descriptor.id)
        return success(
            context,
            summary: "Found \(skillIDs.count) skill(s).",
            facts: [
                "skill.search.query": query,
                "skill.search.ids": skillIDs.joined(separator: ","),
                "lastAcceptedTool": context.call.name
            ],
            metadata: [
                "resultCount": String(skillIDs.count),
                "skillIDs": skillIDs.joined(separator: ",")
            ]
        )
    }

    private static func skillLoad(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard let registry = services.skillRegistry else {
            return failed(context, "Skill registry is not configured.", reason: "missingSkillRegistry")
        }
        guard let skillID = trimmed(context.call.input["skillID"]) else {
            return invalidInput(context, "skill.load requires a skillID.")
        }
        guard let skill = await registry.descriptor(id: skillID) else {
            return failed(context, "Skill was not found: \(skillID)", reason: "skillNotFound")
        }

        return success(
            context,
            summary: "Loaded skill \(skill.name).",
            facts: [
                "skill.loaded.id": skill.id,
                "skill.loaded.name": skill.name,
                "skill.loaded.tools": skill.providedToolNames.joined(separator: ","),
                "lastAcceptedTool": context.call.name
            ],
            metadata: [
                "skillID": skill.id,
                "instructionPath": skill.instructionPath ?? "",
                "scriptIDs": skill.scripts.map(\.id).joined(separator: ",")
            ]
        )
    }

    private static func scriptGenerate(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices,
        ownerSkillID: String?
    ) async -> HarnessToolResult {
        guard let language = generatedLanguage(context.call.input["language"]) else {
            return invalidInput(context, "\(context.call.name) requires a supported language.")
        }
        guard let purpose = trimmed(context.call.input["purpose"] ?? context.call.input["goal"]) else {
            return invalidInput(context, "\(context.call.name) requires a purpose or goal.")
        }

        let artifactID = trimmed(context.call.input["scriptID"])
            ?? trimmed(context.call.input["scriptArtifactID"])
            ?? "\(context.call.name.replacingOccurrences(of: ".", with: "-"))-\(stableIDSeed(from: purpose))"
        let source = context.call.input["scriptSource"] ?? context.call.input["source"] ?? ""
        let artifact = HarnessGeneratedScriptArtifact(
            id: artifactID,
            language: language,
            source: source,
            validationStatus: .pendingValidation,
            createdByToolName: context.call.name,
            ownerSkillID: ownerSkillID,
            metadata: context.call.input.merging([
                "directExecution": "false",
                "purpose": purpose
            ]) { current, _ in current }
        )
        await services.generatedScripts.upsert(artifact)

        return success(
            context,
            summary: "Generated script artifact \(artifactID) pending validation.",
            facts: [
                "script.generated.id": artifactID,
                "script.generated.language": language.rawValue,
                "script.generated.validationStatus": HarnessSkillScriptValidationStatus.pendingValidation.rawValue,
                "lastAcceptedTool": context.call.name
            ],
            metadata: [
                "scriptArtifactID": artifactID,
                "language": language.rawValue,
                "validationStatus": HarnessSkillScriptValidationStatus.pendingValidation.rawValue,
                "directExecution": "false"
            ]
        )
    }

    private static func scriptValidate(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard let scriptID = trimmed(context.call.input["scriptID"] ?? context.call.input["scriptArtifactID"]) else {
            return invalidInput(context, "\(context.call.name) requires a scriptID or scriptArtifactID.")
        }
        guard let artifact = await services.generatedScripts.artifact(id: scriptID) else {
            return failed(context, "Script artifact was not found: \(scriptID)", reason: "scriptNotFound")
        }
        guard !artifact.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            _ = await services.generatedScripts.reject(id: scriptID, reason: "emptyScriptSource")
            return failed(context, "Script artifact has no source to validate.", reason: "emptyScriptSource")
        }

        let validated = await services.generatedScripts.validate(
            id: scriptID,
            metadata: [
                "validation.policy": context.call.input["validationPolicy"] ?? "",
                "validatedBy": context.call.name
            ]
        )

        return success(
            context,
            summary: "Validated script artifact \(scriptID).",
            facts: [
                "script.validated.id": scriptID,
                "script.validated.status": validated?.validationStatus.rawValue ?? HarnessSkillScriptValidationStatus.validated.rawValue,
                "lastAcceptedTool": context.call.name
            ],
            metadata: [
                "scriptArtifactID": scriptID,
                "validationStatus": HarnessSkillScriptValidationStatus.validated.rawValue
            ]
        )
    }

    private static func scriptExecute(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices,
        executor: (@Sendable (HarnessGeneratedScriptArtifact, HarnessToolExecutionContext) async -> HarnessScriptExecutionOutcome)?
    ) async -> HarnessToolResult {
        guard let scriptID = trimmed(context.call.input["scriptID"] ?? context.call.input["scriptArtifactID"]) else {
            return invalidInput(context, "\(context.call.name) requires a scriptID or scriptArtifactID.")
        }
        guard let artifact = await services.generatedScripts.artifact(id: scriptID) else {
            return failed(context, "Script artifact was not found: \(scriptID)", reason: "scriptNotFound")
        }
        guard artifact.validationStatus == .validated else {
            return failed(context, "Script artifact must be validated before execution.", reason: "scriptNotValidated")
        }
        guard let executor else {
            return failed(context, "No guarded script execution backend is configured.", reason: "missingScriptExecutionBackend")
        }

        let outcome = await executor(artifact, context)
        let status: HarnessToolResultStatus = outcome.succeeded ? .succeeded : .failed
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: status,
            summary: outcome.summary,
            observations: HarnessObservationDelta(
                facts: [
                    "script.executed.id": scriptID,
                    "script.executed.succeeded": String(outcome.succeeded),
                    "script.executed.output": bounded(outcome.output, limit: 500),
                    "lastAcceptedTool": context.call.name
                ]
            ),
            metadata: outcome.metadata.merging([
                "scriptArtifactID": scriptID,
                "executor": "guardedScriptBackend"
            ]) { current, _ in current }
        )
    }

    private static func appSearch(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) -> HarnessToolResult {
        guard let query = trimmed(context.call.input["query"] ?? context.call.input["target"]) else {
            return invalidInput(context, "app.search requires a non-empty query.")
        }
        let queryTokens = tokens(in: query)
        let appMatches = services.appEntries
            .filter { entry in
                Self.matches(
                    tokens: queryTokens,
                    values: [entry.id, entry.name, entry.bundleIdentifier ?? "", entry.path ?? ""] + Array(entry.metadata.values)
                )
            }
            .prefix(10)
        let facts = Dictionary<String, String>(
            uniqueKeysWithValues: appMatches.map { entry in
                ("app.search.match.\(entry.id)", entry.name)
            }
        )
        return success(
            context,
            summary: "Found \(appMatches.count) app/item match(es).",
            facts: facts.merging([
                "app.search.query": query,
                "app.search.ids": appMatches.map(\.id).joined(separator: ","),
                "lastAcceptedTool": context.call.name
            ]) { current, _ in current },
            metadata: [
                "resultCount": String(appMatches.count),
                "targetIDs": appMatches.map(\.id).joined(separator: ",")
            ]
        )
    }

    private static func appOpenOrFocus(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) -> HarnessToolResult {
        guard let targetID = trimmed(context.call.input["targetID"]) else {
            return invalidInput(context, "app.openOrFocus requires a targetID.")
        }
        guard let target = services.appEntries.first(where: { appMatchesTarget($0, targetID: targetID) }) else {
            return failed(context, "App/item target was not found: \(targetID)", reason: "targetNotFound")
        }
        guard target.isInstalled else {
            return failed(context, "App/item target is not installed: \(target.name)", reason: "targetUnavailable")
        }
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .succeeded,
            summary: "Focused \(target.name).",
            observations: HarnessObservationDelta(
                focusedApp: target.name,
                facts: [
                    "focusedApp.id": target.id,
                    "focusedApp.bundleIdentifier": target.bundleIdentifier ?? "",
                    "lastAcceptedTool": context.call.name
                ]
            ),
            metadata: target.metadata.merging([
                "targetID": target.id,
                "bundleIdentifier": target.bundleIdentifier ?? "",
                "path": target.path ?? ""
            ]) { current, _ in current }
        )
    }

    private static func screenObserve(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        let hasEvidence = context.worldModel.focusedApp != nil
            || context.worldModel.focusedWindowTitle != nil
            || !context.worldModel.visibleText.isEmpty
            || !context.worldModel.elements.isEmpty
        var facts = context.worldModel.facts
        facts["screen.observe.hasPriorEvidence"] = String(hasEvidence)
        facts["screen.observe.elementCount"] = String(context.worldModel.elements.count)
        facts["lastAcceptedTool"] = context.call.name

        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .succeeded,
            summary: hasEvidence ? "Observed current world-model screen evidence." : "No screen evidence is currently available.",
            observations: HarnessObservationDelta(
                focusedApp: context.worldModel.focusedApp,
                focusedWindowTitle: context.worldModel.focusedWindowTitle,
                visibleText: context.worldModel.visibleText,
                elements: context.worldModel.elements,
                facts: facts,
                uncertainty: hasEvidence ? [] : ["screen evidence has not been captured by a desktop backend"]
            ),
            metadata: [
                "evidenceSource": "worldModel",
                "elementCount": String(context.worldModel.elements.count)
            ]
        )
    }

    private static func elementsGet(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        let elements = scopedElements(context)
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .succeeded,
            summary: "Returned \(elements.count) element(s).",
            observations: HarnessObservationDelta(
                elements: elements,
                facts: [
                    "elements.get.count": String(elements.count),
                    "elements.get.scope": context.call.input["scope"] ?? "",
                    "lastAcceptedTool": context.call.name
                ]
            ),
            metadata: ["elementIDs": elements.map(\.id).joined(separator: ",")]
        )
    }

    private static func elementPerform(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        guard let elementID = trimmed(context.call.input["elementID"]) else {
            return invalidInput(context, "element.perform requires an elementID.")
        }
        guard let requestedAction = trimmed(context.call.input["action"]) else {
            return invalidInput(context, "element.perform requires an action.")
        }
        guard let element = context.worldModel.elements.first(where: { $0.id == elementID }) else {
            return failed(context, "Element was not found in the current world model.", reason: "elementNotFound")
        }
        guard element.isActionEligible else {
            return failed(context, "Element is not action eligible.", reason: "elementNotActionEligible")
        }
        guard actionAllowed(requestedAction, elementActions: element.actions) else {
            return failed(context, "Requested action is not allowed for this element.", reason: "actionNotAllowed")
        }

        return success(
            context,
            summary: "Performed guarded \(requestedAction) on \(element.label).",
            facts: [
                "element.perform.elementID": elementID,
                "element.perform.action": requestedAction,
                "element.perform.label": element.label,
                "lastAcceptedTool": context.call.name
            ],
            metadata: [
                "elementID": elementID,
                "action": requestedAction,
                "role": element.role
            ]
        )
    }

    private static func textEnter(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        guard let text = context.call.input["text"], !text.isEmpty else {
            return invalidInput(context, "text.enter requires non-empty text.")
        }
        if let elementID = trimmed(context.call.input["elementID"]) {
            guard let element = context.worldModel.elements.first(where: { $0.id == elementID }) else {
                return failed(context, "Text target element was not found.", reason: "elementNotFound")
            }
            guard element.isActionEligible else {
                return failed(context, "Text target element is not action eligible.", reason: "elementNotActionEligible")
            }
        } else if context.worldModel.focusedApp == nil {
            return failed(context, "Text input requires a focused app or explicit elementID.", reason: "missingFocusedTarget")
        }

        return success(
            context,
            summary: "Entered text through guarded input.",
            facts: [
                "text.enter.characterCount": String(text.count),
                "text.enter.elementID": context.call.input["elementID"] ?? "",
                "lastAcceptedTool": context.call.name
            ],
            metadata: [
                "characterCount": String(text.count),
                "elementID": context.call.input["elementID"] ?? ""
            ]
        )
    }

    private static func keyboardPress(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        guard let key = trimmed(context.call.input["key"]) else {
            return invalidInput(context, "keyboard.press requires a key.")
        }
        guard key.count <= 40 else {
            return invalidInput(context, "keyboard.press key is too long.")
        }
        guard context.worldModel.focusedApp != nil || context.call.input["targetID"] != nil else {
            return failed(context, "Keyboard input requires a focused target.", reason: "missingFocusedTarget")
        }

        return success(
            context,
            summary: "Pressed guarded keyboard input.",
            facts: [
                "keyboard.press.key": key,
                "lastAcceptedTool": context.call.name
            ],
            metadata: ["key": key]
        )
    }

    private static func appleScriptGenerate(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard trimmed(context.call.input["targetApp"]) != nil else {
            return invalidInput(context, "automation.applescript.generate requires a targetApp.")
        }
        guard trimmed(context.call.input["goal"]) != nil else {
            return invalidInput(context, "automation.applescript.generate requires a goal.")
        }
        var input = context.call.input
        input["language"] = HarnessGeneratedScriptLanguage.appleScript.rawValue
        input["purpose"] = context.call.input["goal"]
        let generatedContext = HarnessToolExecutionContext(
            taskID: context.taskID,
            call: HarnessToolCall(
                id: context.call.id,
                name: context.call.name,
                input: input,
                metadata: context.call.metadata
            ),
            descriptor: context.descriptor,
            worldModel: context.worldModel,
            grantedPermissions: context.grantedPermissions
        )
        return await scriptGenerate(generatedContext, services: services, ownerSkillID: nil)
    }

    private static func applicationLearningStart(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard let appName = trimmed(context.call.input["appName"] ?? context.call.input["targetApp"] ?? context.worldModel.focusedApp) else {
            return invalidInput(context, "application.learning.start requires a target app.")
        }
        let skillID = trimmed(context.call.input["skillID"]) ?? "learned-\(stableIDSeed(from: appName))"
        let draftID = trimmed(context.call.input["draftID"]) ?? "\(context.taskID)-\(skillID)"
        let learningGoal = trimmed(context.call.input["goal"]) ?? "Learn \(appName)."
        let policy = trimmed(context.call.input["explorationPolicy"])
            ?? "Safe exploration only: observe, inspect Accessibility elements, open reversible menus/tabs/fields, and ask before destructive, send, purchase, or save-overwrite actions."

        let draft = await services.applicationLearningStore.begin(
            draftID: draftID,
            taskID: context.taskID,
            skillID: skillID,
            appName: appName,
            bundleIdentifier: trimmed(context.call.input["bundleIdentifier"]),
            learningGoal: learningGoal,
            explorationPolicy: policy,
            metadata: [
                "createdBy": context.call.name,
                "safeExploration": "true"
            ]
        )

        return success(
            context,
            summary: "Started application learning draft for \(appName).",
            facts: [
                "application.learning.draftID": draft.id,
                "application.learning.skillID": draft.skillID,
                "application.learning.appName": draft.appName,
                "application.learning.explorationPolicy": draft.explorationPolicy,
                "lastAcceptedTool": context.call.name
            ],
            metadata: [
                "draftID": draft.id,
                "skillID": draft.skillID,
                "appName": draft.appName,
                "bundleIdentifier": draft.bundleIdentifier ?? ""
            ]
        )
    }

    private static func applicationLearningCaptureState(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard let draftID = trimmed(context.call.input["draftID"] ?? context.worldModel.facts["application.learning.draftID"]) else {
            return invalidInput(context, "application.learning.captureState requires a learning draftID.")
        }
        guard await services.applicationLearningStore.draft(id: draftID) != nil else {
            return failed(context, "Application learning draft was not found: \(draftID)", reason: "learningDraftNotFound")
        }

        let stateID = trimmed(context.call.input["stateID"])
            ?? "state-\(stableIDSeed(from: context.call.input["title"] ?? context.worldModel.focusedWindowTitle ?? UUID().uuidString))"
        let title = trimmed(context.call.input["title"])
            ?? context.worldModel.focusedWindowTitle
            ?? context.worldModel.focusedApp
            ?? stateID
        let observation = HarnessApplicationLearningObservation(
            id: stateID,
            title: title,
            focusedApp: context.worldModel.focusedApp,
            focusedWindowTitle: context.worldModel.focusedWindowTitle,
            screenshotArtifactURL: trimmed(
                context.call.input["screenshotArtifactURL"]
                    ?? context.worldModel.facts["screenshotArtifactURL"]
                    ?? context.worldModel.facts["screen.observe.screenshotArtifactURL"]
            ),
            accessibilityArtifactURL: trimmed(
                context.call.input["accessibilityArtifactURL"]
                    ?? context.worldModel.facts["accessibilityArtifactURL"]
                    ?? context.worldModel.facts["screen.observe.accessibilityArtifactURL"]
            ),
            visibleText: context.worldModel.visibleText,
            elements: context.worldModel.elements,
            navigationPath: listValues(context.call.input["navigationPath"]),
            changedFromPrevious: context.call.input["changedFromPrevious"] ?? "",
            safetyNotes: listValues(context.call.input["safetyNotes"]),
            metadata: [
                "capturedBy": context.call.name,
                "elementCount": String(context.worldModel.elements.count),
                "visibleTextRegionCount": String(context.worldModel.visibleText.count)
            ]
        )

        guard let draft = await services.applicationLearningStore.record(
            draftID: draftID,
            observation: observation
        ) else {
            return failed(context, "Application learning draft was not found: \(draftID)", reason: "learningDraftNotFound")
        }

        return success(
            context,
            summary: "Captured learned app state \(observation.title).",
            facts: [
                "application.learning.draftID": draft.id,
                "application.learning.lastStateID": observation.id,
                "application.learning.observationCount": String(draft.observations.count),
                "application.learning.lastStateElementCount": String(observation.elements.count),
                "lastAcceptedTool": context.call.name
            ],
            metadata: [
                "draftID": draft.id,
                "stateID": observation.id,
                "observationCount": String(draft.observations.count),
                "screenshotArtifactURL": observation.screenshotArtifactURL ?? "",
                "accessibilityArtifactURL": observation.accessibilityArtifactURL ?? ""
            ]
        )
    }

    private static func applicationLearningProposeExploration(
        _ context: HarnessToolExecutionContext
    ) -> HarnessToolResult {
        let candidates = context.worldModel.elements.compactMap { element -> String? in
            guard element.isActionEligible,
                  let action = safeExplorationAction(for: element)
            else {
                return nil
            }
            return "\(element.id):\(action)"
        }
        let approvalCandidates = context.worldModel.elements.compactMap { element -> String? in
            guard element.isActionEligible,
                  safeExplorationAction(for: element) == nil,
                  !element.actions.isEmpty
            else {
                return nil
            }
            return element.id
        }

        return success(
            context,
            summary: "Proposed \(candidates.count) safe exploration candidate(s).",
            facts: [
                "application.learning.safeExplorationCandidateCount": String(candidates.count),
                "application.learning.safeExplorationCandidates": candidates.joined(separator: ","),
                "application.learning.requiresApprovalCandidateIDs": approvalCandidates.joined(separator: ","),
                "lastAcceptedTool": context.call.name
            ],
            metadata: [
                "safeCandidateCount": String(candidates.count),
                "safeCandidates": candidates.joined(separator: ","),
                "requiresApprovalCandidateIDs": approvalCandidates.joined(separator: ",")
            ]
        )
    }

    private static func applicationLearningDistill(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard let draftID = trimmed(context.call.input["draftID"] ?? context.worldModel.facts["application.learning.draftID"]) else {
            return invalidInput(context, "application.learning.distill requires a learning draftID.")
        }
        let workflowName = trimmed(context.call.input["workflowName"]) ?? "Safe inspection"
        let workflowSummary = trimmed(context.call.input["workflowSummary"])
            ?? "Use learned observations to inspect the application before taking guarded action."
        let recipe = HarnessApplicationWorkflowRecipe(
            id: stableIDSeed(from: workflowName),
            name: workflowName,
            summary: workflowSummary,
            verificationCriteria: listValues(context.call.input["verificationCriteria"]),
            metadata: ["createdBy": context.call.name]
        )
        let scriptIDs = listValues(context.call.input["scriptIDs"])
        guard let profile = await services.applicationLearningStore.distill(
            draftID: draftID,
            workflowRecipes: [recipe],
            generatedScriptIDs: scriptIDs,
            safetyNotes: listValues(context.call.input["safetyNotes"]),
            metadata: ["distilledBy": context.call.name]
        ) else {
            return failed(context, "Application learning draft has no observations to distill.", reason: "learningDraftNotReady")
        }

        return success(
            context,
            summary: "Distilled learned app profile for \(profile.appName).",
            facts: [
                "application.learning.draftID": draftID,
                "application.learning.skillID": profile.skillID,
                "application.learning.profile.appName": profile.appName,
                "application.learning.profile.observationCount": String(profile.observations.count),
                "application.learning.profile.workflowCount": String(profile.workflowRecipes.count),
                "lastAcceptedTool": context.call.name
            ],
            metadata: [
                "draftID": draftID,
                "skillID": profile.skillID,
                "observationCount": String(profile.observations.count),
                "workflowCount": String(profile.workflowRecipes.count)
            ]
        )
    }

    private static func applicationLearningSaveSkillPack(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard let draftID = trimmed(context.call.input["draftID"] ?? context.worldModel.facts["application.learning.draftID"]) else {
            return invalidInput(context, "application.learning.saveSkillPack requires a learning draftID.")
        }
        guard let draft = await services.applicationLearningStore.draft(id: draftID) else {
            return failed(context, "Application learning draft was not found: \(draftID)", reason: "learningDraftNotFound")
        }
        let profile: HarnessApplicationProfile
        if let existingProfile = draft.profile {
            profile = existingProfile
        } else if let distilledProfile = await services.applicationLearningStore.distill(draftID: draftID) {
            profile = distilledProfile
        } else {
            return failed(context, "Application learning draft has no observations to save.", reason: "learningDraftNotReady")
        }

        let requestedScriptIDs = Set(listValues(context.call.input["scriptIDs"]))
        let ownerScripts = await services.generatedScripts.artifacts(ownerSkillID: profile.skillID)
        let extraScripts = requestedScriptIDs.isEmpty
            ? []
            : await services.generatedScripts.artifacts().filter { requestedScriptIDs.contains($0.id) }
        let scripts = Array(
            Dictionary(uniqueKeysWithValues: (ownerScripts + extraScripts).map { ($0.id, $0) })
                .values
        )
        .sorted { $0.id < $1.id }
        let writer = services.applicationSkillPackWriter
            ?? HarnessApplicationSkillPackWriter(rootDirectory: HarnessApplicationSkillPackWriter.defaultRootDirectory())

        do {
            let result = try writer.save(profile: profile, scripts: scripts)
            await services.skillRegistry?.register(result.skill)

            return success(
                context,
                summary: "Saved learned application skill pack for \(profile.appName).",
                facts: [
                    "application.learning.skillID": result.skill.id,
                    "application.learning.skillDirectory": result.directoryPath,
                    "application.learning.writtenFileCount": String(result.writtenFiles.count),
                    "application.learning.validatedScriptCount": String(result.scriptCount),
                    "lastAcceptedTool": context.call.name
                ],
                metadata: [
                    "skillID": result.skill.id,
                    "directory": result.directoryPath,
                    "writtenFiles": result.writtenFiles.joined(separator: "\n"),
                    "scriptCount": String(result.scriptCount)
                ]
            )
        } catch {
            return failed(context, "Failed to save learned application skill pack: \(error)", reason: "skillPackWriteFailed")
        }
    }

    private static func stateVerify(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        guard let criteria = trimmed(context.call.input["criteria"]) else {
            return invalidInput(context, "state.verify requires criteria.")
        }
        let evidence = (
            context.worldModel.facts.map { "\($0.key): \($0.value)" }
                + context.worldModel.visibleText.map { "\($0.key): \($0.value)" }
                + context.worldModel.attemptedToolCalls.map { "\($0.call.name): \($0.summary)" }
        ).joined(separator: "\n")
        let verified = evidenceMatches(criteria: criteria, evidence: evidence)
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: verified ? .succeeded : .failed,
            summary: verified ? "Verification succeeded." : "Verification did not find matching evidence.",
            observations: HarnessObservationDelta(
                facts: [
                    "state.verify.criteria": criteria,
                    "state.verify.verified": String(verified),
                    "lastAcceptedTool": context.call.name
                ],
                uncertainty: verified ? [] : ["verification evidence did not satisfy criteria"]
            ),
            metadata: ["verified": String(verified)]
        )
    }

    private static func lifecycle(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        success(
            context,
            summary: "Lifecycle operation accepted: \(context.call.name).",
            facts: [
                "lifecycle.lastOperation": context.call.name,
                "lifecycle.reason": context.call.input["reason"] ?? "",
                "lastAcceptedTool": context.call.name
            ],
            metadata: ["lifecycleOperation": context.call.name]
        )
    }

    private static func success(
        _ context: HarnessToolExecutionContext,
        summary: String,
        facts: [String: String],
        metadata: [String: String] = [:]
    ) -> HarnessToolResult {
        HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .succeeded,
            summary: summary,
            observations: HarnessObservationDelta(facts: facts),
            metadata: metadata.merging(["executor": "builtInGeneric"]) { current, _ in current }
        )
    }

    private static func failed(
        _ context: HarnessToolExecutionContext,
        _ summary: String,
        reason: String
    ) -> HarnessToolResult {
        HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .failed,
            summary: summary,
            metadata: [
                "executor": "builtInGeneric",
                "reason": reason
            ]
        )
    }

    private static func invalidInput(
        _ context: HarnessToolExecutionContext,
        _ summary: String
    ) -> HarnessToolResult {
        HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .invalidInput,
            summary: summary,
            metadata: [
                "executor": "builtInGeneric",
                "reason": "invalidInput"
            ]
        )
    }

    private static func scopedElements(_ context: HarnessToolExecutionContext) -> [HarnessWorldElement] {
        guard let scope = trimmed(context.call.input["scope"]) else {
            return context.worldModel.elements
        }
        let scopeTokens = tokens(in: scope)
        guard !scopeTokens.isEmpty else { return context.worldModel.elements }
        return context.worldModel.elements.filter { element in
            matches(tokens: scopeTokens, values: [element.id, element.label, element.role] + Array(element.metadata.values))
        }
    }

    private static func appMatchesTarget(_ entry: HarnessAppLookupEntry, targetID: String) -> Bool {
        [entry.id, entry.name, entry.bundleIdentifier ?? "", entry.path ?? ""]
            .contains { normalized($0) == normalized(targetID) }
    }

    private static func actionAllowed(_ action: String, elementActions: [String]) -> Bool {
        let normalizedAction = normalized(action)
        let aliases: [String: Set<String>] = [
            "press": ["press", "axpress"],
            "click": ["click", "press", "axpress"],
            "focus": ["focus", "axraise"],
            "setvalue": ["setvalue", "axsetvalue"],
            "scroll": ["scroll", "axscroll"]
        ]
        let accepted = aliases[normalizedAction] ?? [normalizedAction]
        let available = Set(elementActions.map(normalized))
        return !accepted.isDisjoint(with: available)
    }

    private static func safeExplorationAction(for element: HarnessWorldElement) -> String? {
        let safety = normalized(element.metadata["learning.explorationSafety"] ?? element.metadata["safetyClass"] ?? "")
        if ["destructive", "sensitive", "requiresapproval"].contains(safety) {
            return nil
        }
        let actions = Set(element.actions.map(normalized))
        if safety == "safe" || safety == "reversible" || safety == "readonly" {
            if !actions.isDisjoint(with: ["focus", "axraise"]) { return "focus" }
            if !actions.isDisjoint(with: ["press", "axpress"]) { return "press" }
            if !actions.isDisjoint(with: ["scroll", "axscroll"]) { return "scroll" }
        }

        let role = normalized(element.role)
        let reversibleRoles: Set<String> = [
            "axmenu",
            "axmenubaritem",
            "axmenuitem",
            "axpopupbutton",
            "axtab",
            "axtabgroup",
            "axdisclosuretriangle"
        ]
        if reversibleRoles.contains(role),
           !actions.isDisjoint(with: ["press", "axpress"]) {
            return "press"
        }
        if !actions.isDisjoint(with: ["focus", "axraise"]) {
            return "focus"
        }
        if !actions.isDisjoint(with: ["scroll", "axscroll"]) {
            return "scroll"
        }
        return nil
    }

    private static func evidenceMatches(criteria: String, evidence: String) -> Bool {
        let normalizedCriteria = normalized(criteria)
        let normalizedEvidence = normalized(evidence)
        guard !normalizedCriteria.isEmpty, !normalizedEvidence.isEmpty else { return false }
        if normalizedEvidence.contains(normalizedCriteria) { return true }
        let criteriaTokens = tokens(in: criteria)
        guard !criteriaTokens.isEmpty else { return false }
        return criteriaTokens.allSatisfy { normalizedEvidence.contains($0) }
    }

    private static func matches(tokens: [String], values: [String]) -> Bool {
        guard !tokens.isEmpty else { return true }
        let haystack = normalized(values.joined(separator: " "))
        return tokens.allSatisfy { haystack.contains($0) }
    }

    private static func generatedLanguage(_ value: String?) -> HarnessGeneratedScriptLanguage? {
        switch normalized(value ?? "") {
        case "applescript", "apple script":
            return .appleScript
        case "shell", "bash", "sh":
            return .shell
        case "javascript", "js":
            return .javaScript
        case "python", "py":
            return .python
        case "swift":
            return .swift
        default:
            return nil
        }
    }

    private static func stableIDSeed(from value: String) -> String {
        let slug = normalized(value)
            .split(separator: " ")
            .prefix(6)
            .joined(separator: "-")
        return slug.isEmpty ? UUID().uuidString : slug
    }

    private static func listValues(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .split { character in
                character == "," || character == "\n" || character == ";"
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func tokens(in value: String) -> [String] {
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

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit))
    }
}
