import DonkeyContracts
import DonkeyRuntime
import Foundation

func taskIntentAppFinderCatalogJSON(_ entries: [LocalAppFinderCatalogEntry]) -> String {
    let compactEntries = entries.map { entry -> [String: Any] in
        var value: [String: Any] = [
            "appID": entry.appID,
            "appName": entry.appName,
            "description": entry.description,
            "supportStatus": entry.supportStatus.rawValue
        ]
        if let bundleIdentifier = entry.bundleIdentifier, !bundleIdentifier.isEmpty {
            value["bundleIdentifier"] = bundleIdentifier
        }
        if entry.capabilities.isEmpty == false {
            value["capabilities"] = entry.capabilities.map { capability -> [String: Any] in
                [
                    "id": capability.id,
                    "summary": capability.summary,
                    "controlProfiles": capability.controlProfiles,
                    "requiredEntities": capability.requiredEntities
                ]
            }
        }
        if let denyReason = entry.denyReason, !denyReason.isEmpty {
            value["denyReason"] = denyReason
        }
        return value
    }
    guard compactEntries.isEmpty == false,
          let data = try? JSONSerialization.data(withJSONObject: compactEntries),
          let text = String(data: data, encoding: .utf8)
    else {
        return "[]"
    }
    return text
}

enum TaskIntentWireCodec {
    static let defaultConversationAssistantResponse = "I'm here. What would you like to work on?"

    static func jsonSchema(taskDefinitions: [LocalAppTaskDefinition]) -> [String: Any] {
        let allowsDynamicTargets = taskDefinitions.contains { definition in
            definition.metadata["dynamicTarget"] == "true"
        }
        let targetAppNameSchema: [String: Any] = allowsDynamicTargets
            ? ["type": "string"]
            : ["type": "string", "enum": (Array(Set(taskDefinitions.map(\.targetApp.appName))) + ["none"]).sorted()]
        let actionPlanSchema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": [
                "tools",
                "inputEntity",
                "controlID",
                "focusKey",
                "verificationTools"
            ],
            "properties": [
                "tools": [
                    "type": "array",
                    "maxItems": 8,
                    "items": [
                        "type": "string",
                        "enum": LocalAppActionPlanTool.allCases.map(\.rawValue)
                    ]
                ],
                "inputEntity": ["type": "string"],
                "controlID": ["type": "string"],
                "focusKey": ["type": "string"],
                "verificationTools": [
                    "type": "array",
                    "maxItems": 4,
                    "items": [
                        "type": "string",
                        "enum": [
                            LocalAppActionPlanTool.verifyCommand.rawValue,
                            LocalAppActionPlanTool.verifyVisibleText.rawValue
                        ]
                    ]
                ]
            ]
        ]

        return [
            "type": "object",
            "additionalProperties": false,
            "required": [
                "taskType",
                "targetAppName",
                "entities",
                "normalizedEntities",
                "confidence",
                "needsConfirmation",
                "actionPlan",
                "metadata"
            ],
            "properties": [
                "taskType": ["type": "string", "enum": (Array(Set(taskDefinitions.map(\.taskType))) + ["none"]).sorted()],
                "targetAppName": targetAppNameSchema,
                "entities": [
                    "type": "object",
                    "additionalProperties": ["type": "string"]
                ],
                "normalizedEntities": [
                    "type": "object",
                    "additionalProperties": ["type": "string"]
                ],
                "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                "needsConfirmation": [
                    "type": "boolean",
                    "description": "Set true ONLY when the action is destructive, irreversible, costly, or sent/shared externally AND its intent is ambiguous. Set false for safe, reversible actions — including broad or casual requests you resolved by choosing concrete specifics yourself (e.g. playing a representative song). Do not set true just because a request was casual or under-specified."
                ],
                "actionPlan": actionPlanSchema,
                "metadata": [
                    "type": "object",
                    "additionalProperties": ["type": "string"]
                ]
            ]
        ]
    }

    static func genericHarnessPlanningJsonSchema(
        taskDefinitions: [LocalAppTaskDefinition],
        availableToolNames: [String] = []
    ) -> [String: Any] {
        let allowsDynamicTargets = taskDefinitions.contains { definition in
            definition.metadata["dynamicTarget"] == "true"
        }
        let taskTypes = (Array(Set(taskDefinitions.map(\.taskType))) + ["none"]).sorted()
        let appNames = (Array(Set(taskDefinitions.map(\.targetApp.appName))) + ["none"]).sorted()
        let targetAppNameSchema: [String: Any] = allowsDynamicTargets
            ? ["type": "string"]
            : ["type": "string", "enum": appNames]
        let availableToolNameSet = Set(
            availableToolNames
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        let toolNames = [""] + Array(
            availableToolNameSet.isEmpty
                ? Set(LocalAppActionPlanTool.allCases.map(\.rawValue))
                : availableToolNameSet
        ).sorted()
        let planStepSchema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": [
                "id",
                "summary",
                "toolName",
                "inputEntity",
                "controlID",
                "focusKey",
                "toolInputs",
                "expectedObservation"
            ],
            "properties": [
                "id": ["type": "string"],
                "summary": ["type": "string"],
                "toolName": [
                    "type": "string",
                    "enum": toolNames,
                    "description": "One available tool name for an executable step; empty string for a non-executable reasoning step."
                ],
                "inputEntity": [
                    "type": "string",
                    "description": "Entity key feeding this step (usually query when text is entered); empty when unused."
                ],
                "controlID": [
                    "type": "string",
                    "description": "Semantic or observed visual target id for click/submit tools; empty when unused."
                ],
                "focusKey": ["type": "string"],
                "toolInputs": [
                    "type": "object",
                    "additionalProperties": ["type": "string"],
                    "description": "Inputs for the tool, filled from structured entities and the tool's schema."
                ],
                "expectedObservation": [
                    "type": "string",
                    "description": "What the harness should observe after this step."
                ]
            ]
        ]

        return [
            "type": "object",
            "additionalProperties": false,
            "required": [
                "structuredIntent",
                "ambiguityRisk",
                "contextNeeds",
                "planSteps",
                "verificationCriteria",
                "fallbacks",
                "clarificationPolicy",
                "metadata"
            ],
            "properties": [
                "structuredIntent": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": [
                        "route",
                        "taskType",
                        "needsConfirmation"
                    ],
                    "properties": [
                        "route": [
                            "type": "string",
                            "enum": ["localAppTask", "conversation", "clarification", "guidance"],
                            "description": "How the harness should handle the turn. localAppTask: operate a local app or item — the default for any safe, identifiable action, including broad or casual ones you resolve by choosing concrete specifics. conversation: greetings, questions, explanations, status, malformed input, or any turn needing no external action. guidance: SHOW where something is or how to do it without changing any state. clarification: only when acting would be destructive, irreversible, costly, or sent/shared externally AND intent is genuinely ambiguous, or a required target is unknown and cannot be inferred."
                        ],
                        "goal": [
                            "type": "string",
                            "description": "Concise restatement of what the user wants."
                        ],
                        "taskType": [
                            "type": "string",
                            "enum": taskTypes,
                            "description": "Provided task type to execute, or \"none\" for conversation, guidance, or clarification. Use local_app_interaction for an executable local-app request that needs a model-planned workflow and has no more specific provided task type."
                        ],
                        "targetAppName": targetAppNameSchema,
                        "entities": [
                            "type": "object",
                            "additionalProperties": ["type": "string"],
                            "description": "Concrete values required by the task's entity rules. For local_app_interaction set appName (human app name) and goal, plus query when text must be entered."
                        ],
                        "normalizedEntities": [
                            "type": "object",
                            "additionalProperties": ["type": "string"],
                            "description": "Normalized form of entities; mirror query here when text input is needed."
                        ],
                        "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                        "needsConfirmation": [
                            "type": "boolean",
                            "description": "Set true ONLY when the action is destructive, irreversible, costly, or sent/shared externally AND its intent is ambiguous. Set false for safe, reversible actions — including broad or casual requests you resolved by choosing concrete specifics yourself (e.g. playing a representative song). Do not set true just because a request was casual or under-specified."
                        ]
                    ]
                ],
                "ambiguityRisk": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": [
                        "ambiguityClass",
                        "riskLevel",
                        "missingInformation",
                        "shouldAskBeforeActing"
                    ],
                    "properties": [
                        "ambiguityClass": [
                            "type": "string",
                            "enum": ["safe", "recoverable", "dangerous"]
                        ],
                        "riskLevel": [
                            "type": "string",
                            "enum": ["low", "medium", "high"]
                        ],
                        "missingInformation": [
                            "type": "array",
                            "maxItems": 8,
                            "items": ["type": "string"]
                        ],
                        "shouldAskBeforeActing": [
                            "type": "boolean",
                            "description": "True only for dangerous, destructive, irreversible, costly, or externally-sent actions whose intent is ambiguous; false for safe, reversible actions, including broad or casual ones."
                        ]
                    ]
                ],
                "contextNeeds": [
                    "type": "array",
                    "maxItems": 8,
                    "items": ["type": "string"],
                    "description": "Lookups needed before or during execution: app lookup, memory lookup, screen observation, element discovery, or skill lookup."
                ],
                "planSteps": [
                    "type": "array",
                    "maxItems": 12,
                    "items": planStepSchema,
                    "description": "Generic harness plan. Empty for conversation, guidance, and clarification — those routes carry no executable steps."
                ],
                "verificationCriteria": [
                    "type": "array",
                    "maxItems": 8,
                    "items": ["type": "string"],
                    "description": "What proves the task succeeded."
                ],
                "fallbacks": [
                    "type": "array",
                    "maxItems": 8,
                    "items": ["type": "string"],
                    "description": "Safe recovery choices if the primary plan fails."
                ],
                "clarificationPolicy": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": [
                        "shouldAsk",
                        "questions",
                        "policy"
                    ],
                    "properties": [
                        "shouldAsk": [
                            "type": "boolean",
                            "description": "True only when route is clarification."
                        ],
                        "questions": [
                            "type": "array",
                            "maxItems": 4,
                            "items": ["type": "string"],
                            "description": "When asking, exactly one specific question naming what you need; otherwise empty."
                        ],
                        "policy": ["type": "string"]
                    ]
                ],
                "metadata": [
                    "type": "object",
                    "additionalProperties": ["type": "string"],
                    "description": "Free-form string map. conversation: set responseMode=\"conversation\" and assistantResponse=<brief natural-language reply>. guidance: set assistantResponse=<brief spoken narration> and guidanceTargets=<JSON array of {\"label\":\"...\",\"query\":\"...\"} controls to point at, in order; label is shown to the user, query is the control's on-screen text>. local_app_interaction with a non-empty app finder catalog: set appFinder.selectedAppID, appFinder.selectedCapabilityID, and appFinder.controlProfile from a catalog entry whose supportStatus is supported (never candidate, unsupported, or denied)."
                ]
            ]
        ]
    }

    static func decodeIntent(
        _ outputText: String,
        definitions: [LocalAppTaskDefinition],
        originalCommand: String,
        appFinderCatalog: [LocalAppFinderCatalogEntry] = [],
        sourceModelCallID: String,
        parserName: String,
        parserSource: TaskIntentParserSource = .localModel
    ) throws -> TaskIntent? {
        let wire = try decodeWire(from: outputText)
        return try decodeIntent(
            from: wire,
            definitions: definitions,
            originalCommand: originalCommand,
            appFinderCatalog: appFinderCatalog,
            sourceModelCallID: sourceModelCallID,
            parserName: parserName,
            parserSource: parserSource
        )
    }

    static func decodeHostedPlanningIntent(
        _ outputText: String,
        definitions: [LocalAppTaskDefinition],
        originalCommand: String,
        appFinderCatalog: [LocalAppFinderCatalogEntry] = [],
        sourceModelCallID: String,
        parserName: String,
        parserSource: TaskIntentParserSource
    ) throws -> TaskIntent? {
        let planningWire = try decodeHostedPlanningWire(from: outputText)
        guard planningWire.structuredIntent.route == "localAppTask",
              planningWire.structuredIntent.taskType != "none"
        else {
            return nil
        }

        let wire = TaskIntentWire(
            taskType: planningWire.structuredIntent.taskType,
            targetAppName: planningWire.structuredIntent.targetAppName,
            entities: planningWire.structuredIntent.entities,
            normalizedEntities: planningWire.structuredIntent.normalizedEntities,
            confidence: planningWire.structuredIntent.confidence,
            needsConfirmation: planningWire.structuredIntent.needsConfirmation
                || planningWire.ambiguityRisk.shouldAskBeforeActing
                || planningWire.clarificationPolicy.shouldAsk,
            actionPlan: actionPlan(from: planningWire),
            metadata: hostedPlanningMetadata(from: planningWire)
        )
        return try decodeIntent(
            from: wire,
            definitions: definitions,
            originalCommand: originalCommand,
            appFinderCatalog: appFinderCatalog,
            sourceModelCallID: sourceModelCallID,
            parserName: parserName,
            parserSource: parserSource
        )
    }

    private static func decodeIntent(
        from wire: TaskIntentWire,
        definitions: [LocalAppTaskDefinition],
        originalCommand: String,
        appFinderCatalog: [LocalAppFinderCatalogEntry],
        sourceModelCallID: String,
        parserName: String,
        parserSource: TaskIntentParserSource
    ) throws -> TaskIntent? {
        if wire.taskType == "none" {
            return nil
        }
        let exactDefinition = definitions.first(where: {
            $0.taskType == wire.taskType && $0.targetApp.appName == wire.targetAppName
        })
        let dynamicDefinition = definitions.first(where: {
            $0.taskType == wire.taskType && $0.metadata["dynamicTarget"] == "true"
        })
        guard let definition = exactDefinition ?? dynamicDefinition else {
            return nil
        }
        guard definition.metadata["modelPlanned"] == "true" || wire.actionPlan.tools.isEmpty else {
            return nil
        }

        var entities = wire.entities
        var normalizedEntities = normalizedEntities(from: wire, definition: definition)
        if definition.metadata["dynamicTarget"] == "true",
           normalizedEntities["appName"] == nil,
           let appName = dynamicAppName(from: wire, definition: definition) {
            entities["appName"] = appName
            normalizedEntities["appName"] = appName
        }
        var metadata = wire.metadata.merging(definition.metadata) { current, _ in current }
        metadata["parser"] = parserName

        let appFinderSelection = validatedAppFinderSelection(
            wire: wire,
            definition: definition,
            appFinderCatalog: appFinderCatalog
        )
        if definition.metadata["modelPlanned"] == "true",
           appFinderCatalog.isEmpty == false,
           appFinderSelection == nil {
            return nil
        }
        if let appFinderSelection {
            entities["appName"] = appFinderSelection.entry.appName
            normalizedEntities["appName"] = appFinderSelection.entry.appName
            metadata["appFinder.selectedAppID"] = appFinderSelection.entry.appID
            metadata["appFinder.selectedCapabilityID"] = appFinderSelection.capability.id
            metadata["appFinder.controlProfile"] = appFinderSelection.controlProfile
            metadata["appFinder.supportStatus"] = appFinderSelection.entry.supportStatus.rawValue
            metadata["appFinder.validated"] = "true"
        }

        let missingRequiredEntity = definition.entityRules.first { rule in
            rule.required && normalizedEntities[rule.name] == nil
        }
        if definition.metadata["dynamicTarget"] == "true" {
            metadata["requestedItemName"] = normalizedEntities["appName"] ?? entities["appName"] ?? ""
        }
        if let missingRequiredEntity {
            metadata["missingEntity"] = missingRequiredEntity.name
        }

        let confidence = wire.confidence
        let needsConfirmation = wire.needsConfirmation || missingRequiredEntity != nil
        let hasGenericExecutablePlan = metadata["genericHarness.planStepsJSON"]
            .map(Self.hasGenericExecutableTool) ?? false
        let actionPlan = wire.actionPlan.tools.isEmpty && !hasGenericExecutablePlan
            ? nil
            : wire.actionPlan
        let primaryEntity = definition.verificationEntityName
            .flatMap { normalizedEntities[$0] }
            ?? normalizedEntities.values.sorted().first
            ?? definition.taskType

        return TaskIntent(
            intentID: needsConfirmation
                ? "\(definition.taskType)-needs-\(missingRequiredEntity?.name ?? "confirmation")"
                : "\(definition.taskType)-\(slug(primaryEntity))",
            taskType: definition.taskType,
            targetApp: targetApp(from: wire, definition: definition, appFinderEntry: appFinderSelection?.entry),
            entities: entities,
            normalizedEntities: normalizedEntities,
            confidence: confidence,
            parserSource: parserSource,
            needsConfirmation: needsConfirmation,
            sourceModelCallID: sourceModelCallID,
            actionPlan: actionPlan,
            metadata: metadata
        )
    }

    static func hostedPlanningNoTaskMetadata(
        _ outputText: String,
        parserName: String
    ) throws -> [String: String]? {
        let wire = try decodeHostedPlanningWire(from: outputText)
        guard wire.structuredIntent.route != "localAppTask"
            || wire.structuredIntent.taskType == "none"
        else {
            return nil
        }

        var metadata = hostedPlanningMetadata(from: wire)
        metadata["parser"] = parserName
        let route = wire.structuredIntent.route
        if route == "clarification" || wire.clarificationPolicy.shouldAsk {
            metadata["reason"] = nonEmpty(metadata["reason"]) ?? "clarificationRequired"
            metadata["responseMode"] = "clarification"
            metadata["assistantResponse"] = nonEmpty(metadata["assistantResponse"])
                ?? wire.clarificationPolicy.questions.first(where: { nonEmpty($0) != nil })
                ?? defaultConversationAssistantResponse
        } else {
            metadata["reason"] = nonEmpty(metadata["reason"]) ?? "noSupportedTaskIntent"
            metadata["responseMode"] = "conversation"
            metadata["assistantResponse"] = nonEmpty(metadata["assistantResponse"])
                ?? defaultConversationAssistantResponse
        }
        metadata["taskType"] = "none"
        metadata["targetApp"] = wire.structuredIntent.targetAppName
        return metadata
    }

    static func hostedPlanningInvalidLocalTaskMetadata(
        _ outputText: String,
        parserName: String
    ) throws -> [String: String]? {
        let wire = try decodeHostedPlanningWire(from: outputText)
        guard wire.structuredIntent.route == "localAppTask",
              wire.structuredIntent.taskType != "none"
        else {
            return nil
        }

        var metadata = hostedPlanningMetadata(from: wire)
        metadata["parser"] = parserName
        metadata["reason"] = nonEmpty(metadata["reason"]) ?? "localAppTaskValidationFailed"
        metadata["validation.failure"] = "localAppTaskValidationFailed"
        metadata["taskType"] = wire.structuredIntent.taskType
        metadata["targetApp"] = wire.structuredIntent.targetAppName
        metadata["planner.repairable"] = "true"
        return metadata
    }

    static func noTaskMetadata(
        _ outputText: String,
        parserName: String
    ) throws -> [String: String]? {
        let wire = try decodeWire(from: outputText)
        guard wire.taskType == "none" else { return nil }

        var metadata = wire.metadata
        metadata["parser"] = parserName
        metadata["reason"] = nonEmpty(metadata["reason"]) ?? "noSupportedTaskIntent"
        metadata["responseMode"] = "conversation"
        metadata["assistantResponse"] = nonEmpty(metadata["assistantResponse"])
            ?? defaultConversationAssistantResponse
        metadata["taskType"] = "none"
        metadata["targetApp"] = wire.targetAppName
        return metadata
    }

    private static func decodeWire(from outputText: String) throws -> TaskIntentWire {
        var lastError: Error?
        for candidate in jsonObjectCandidates(in: outputText) {
            do {
                return try JSONDecoder().decode(TaskIntentWire.self, from: Data(candidate.utf8))
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: [],
                debugDescription: "No JSON object found in task intent model output"
            )
        )
    }

    private static func decodeHostedPlanningWire(from outputText: String) throws -> GenericHarnessPlanningWire {
        var lastError: Error?
        for candidate in jsonObjectCandidates(in: outputText) {
            do {
                return try JSONDecoder().decode(GenericHarnessPlanningWire.self, from: Data(candidate.utf8))
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: [],
                debugDescription: "No JSON object found in generic harness planning model output"
            )
        )
    }

    private static func jsonObjectCandidates(in outputText: String) -> [String] {
        let trimmed = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = trimmed.isEmpty ? [] : [trimmed]
        var objectStart: String.Index?
        var depth = 0
        var isInsideString = false
        var isEscaped = false
        var index = outputText.startIndex

        while index < outputText.endIndex {
            let character = outputText[index]
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else if character == "\"" {
                isInsideString = true
            } else if character == "{" {
                if depth == 0 {
                    objectStart = index
                }
                depth += 1
            } else if character == "}", depth > 0 {
                depth -= 1
                if depth == 0, let start = objectStart {
                    let objectEnd = outputText.index(after: index)
                    candidates.append(String(outputText[start..<objectEnd]))
                    objectStart = nil
                }
            }

            index = outputText.index(after: index)
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private static func actionPlan(from wire: GenericHarnessPlanningWire) -> LocalAppActionPlan {
        let planSteps = wire.planSteps
        let tools = planSteps.compactMap { step -> LocalAppActionPlanTool? in
            let toolName = step.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !toolName.isEmpty else { return nil }
            return LocalAppActionPlanTool(rawValue: toolName)
        }
        // Planners often carry the text to enter in a step's toolInputs (e.g. toolInputs.query)
        // and leave the per-step inputEntity blank. Fall back to the conventional "query" entity so
        // text-input plans still resolve their value from entities instead of looking up a blank key.
        let inputEntity = firstNonEmpty(planSteps.map(\.inputEntity)) ?? "query"
        let controlID = firstNonEmpty(planSteps.map(\.controlID)) ?? ""
        let focusKey = firstNonEmpty(planSteps.map(\.focusKey)) ?? ""
        var verificationTools = tools.filter(LocalAppActionPlan.isVerificationTool)
        if verificationTools.isEmpty {
            verificationTools = wire.verificationCriteria.contains { criterion in
                criterion.localizedCaseInsensitiveContains("visible")
            } ? [.verifyVisibleText] : [.verifyCommand]
        }

        return LocalAppActionPlan(
            tools: tools,
            inputEntity: inputEntity,
            controlID: controlID,
            focusKey: focusKey,
            verificationTools: verificationTools
        )
    }

    private static func hostedPlanningMetadata(from wire: GenericHarnessPlanningWire) -> [String: String] {
        var metadata = wire.metadata
        metadata["genericHarness.schemaVersion"] = wire.schemaVersion
        metadata["genericHarness.intent.route"] = wire.structuredIntent.route
        metadata["genericHarness.intent.goal"] = wire.structuredIntent.goal
        metadata["genericHarness.intent.targetApp"] = wire.structuredIntent.targetAppName
        metadata["genericHarness.ambiguity.class"] = wire.ambiguityRisk.ambiguityClass
        metadata["genericHarness.risk.level"] = wire.ambiguityRisk.riskLevel
        metadata["genericHarness.shouldAskBeforeActing"] = String(wire.ambiguityRisk.shouldAskBeforeActing)
        metadata["genericHarness.missingInformationJSON"] = jsonString(wire.ambiguityRisk.missingInformation)
        metadata["genericHarness.contextNeedsJSON"] = jsonString(wire.contextNeeds)
        metadata["genericHarness.planStepsJSON"] = jsonString(
            wire.planSteps.map { step in
                [
                    "id": step.id,
                    "summary": step.summary,
                    "toolName": step.toolName,
                    "inputEntity": step.inputEntity,
                    "controlID": step.controlID,
                    "focusKey": step.focusKey,
                    "toolInputs": step.toolInputs,
                    "expectedObservation": step.expectedObservation
                ]
            }
        )
        metadata["genericHarness.verificationCriteriaJSON"] = jsonString(wire.verificationCriteria)
        metadata["genericHarness.fallbacksJSON"] = jsonString(wire.fallbacks)
        metadata["genericHarness.clarification.shouldAsk"] = String(wire.clarificationPolicy.shouldAsk)
        metadata["genericHarness.clarification.questionsJSON"] = jsonString(wire.clarificationPolicy.questions)
        metadata["genericHarness.clarification.policy"] = wire.clarificationPolicy.policy
        return metadata
    }

    private static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys]
              ),
              let text = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return text
    }

    private static func hasGenericExecutableTool(_ planStepsJSON: String) -> Bool {
        guard let data = planStepsJSON.data(using: .utf8),
              let steps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return false
        }
        return steps.contains { step in
            guard let toolName = step["toolName"] as? String else { return false }
            return toolName == "skill.script.execute"
                || toolName == "automation.applescript.execute"
        }
    }

    private static func firstNonEmpty(_ values: [String]) -> String? {
        values.first { value in
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedEntities(
        from wire: TaskIntentWire,
        definition: LocalAppTaskDefinition
    ) -> [String: String] {
        var normalized = wire.normalizedEntities
        for rule in definition.entityRules {
            guard let rawValue = wire.entities[rule.name] ?? normalized[rule.name] else { continue }
            if let alias = rule.aliases[rawValue] ?? rule.aliases[LocalAppTextNormalizer.normalizedPhrase(rawValue)] {
                normalized[rule.name] = alias
            }
        }
        return normalized
    }

    private static func dynamicAppName(
        from wire: TaskIntentWire,
        definition: LocalAppTaskDefinition
    ) -> String? {
        let entityAppName = wire.normalizedEntities["appName"] ?? wire.entities["appName"]
        if let entityAppName,
           !entityAppName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return entityAppName
        }

        guard wire.targetAppName != definition.targetApp.appName else { return nil }
        return wire.targetAppName
    }

    private static func targetApp(
        from wire: TaskIntentWire,
        definition: LocalAppTaskDefinition,
        appFinderEntry: LocalAppFinderCatalogEntry? = nil
    ) -> LocalAppTarget {
        if let appFinderEntry {
            return LocalAppTarget(
                appName: appFinderEntry.appName,
                bundleIdentifier: appFinderEntry.bundleIdentifier,
                titleContains: appFinderEntry.appName,
                metadata: definition.targetApp.metadata
            )
        }
        guard definition.metadata["dynamicTarget"] == "true",
              wire.targetAppName != definition.targetApp.appName else {
            return definition.targetApp
        }

        return LocalAppTarget(
            appName: wire.targetAppName,
            bundleIdentifier: nil,
            titleContains: wire.targetAppName,
            metadata: definition.targetApp.metadata
        )
    }

    private struct AppFinderSelection {
        var entry: LocalAppFinderCatalogEntry
        var capability: LocalAppFinderCapability
        var controlProfile: String
    }

    private static func validatedAppFinderSelection(
        wire: TaskIntentWire,
        definition: LocalAppTaskDefinition,
        appFinderCatalog: [LocalAppFinderCatalogEntry]
    ) -> AppFinderSelection? {
        guard definition.metadata["modelPlanned"] == "true",
              appFinderCatalog.isEmpty == false
        else {
            return nil
        }

        guard let entry = appFinderEntry(from: wire, in: appFinderCatalog),
              entry.supportStatus == .supported,
              entry.capabilities.isEmpty == false
        else {
            return nil
        }

        let requestedCapabilityID = appFinderMetadataValue(
            "appFinder.selectedCapabilityID",
            fallback: "selectedCapabilityID",
            in: wire
        )
        let capability = requestedCapabilityID.flatMap { capabilityID in
            entry.capabilities.first { $0.id == capabilityID }
        } ?? (entry.capabilities.count == 1 ? entry.capabilities[0] : nil)
        guard let capability else {
            return nil
        }
        let requestedControlProfile = appFinderMetadataValue(
            "appFinder.controlProfile",
            fallback: "controlProfile",
            in: wire
        )
        let controlProfile = requestedControlProfile.flatMap { profile in
            capability.controlProfiles.contains(profile) ? profile : nil
        } ?? capability.controlProfiles.first
        guard let controlProfile else {
            return nil
        }

        return AppFinderSelection(
            entry: entry,
            capability: capability,
            controlProfile: controlProfile
        )
    }

    private static func appFinderEntry(
        from wire: TaskIntentWire,
        in appFinderCatalog: [LocalAppFinderCatalogEntry]
    ) -> LocalAppFinderCatalogEntry? {
        let selectedAppID = appFinderMetadataValue(
            "appFinder.selectedAppID",
            fallback: "selectedAppID",
            in: wire
        )
        let appNameCandidates = [
            wire.targetAppName,
            wire.normalizedEntities["appName"],
            wire.entities["appName"]
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        if let selectedAppID,
           let entry = appFinderCatalog.first(where: {
            $0.appID == selectedAppID || $0.bundleIdentifier == selectedAppID
           }) {
            return entry
        }

        return appFinderCatalog.first { entry in
            appNameCandidates.contains { candidate in
                LocalAppTextNormalizer.normalizedPhrase(candidate)
                    == LocalAppTextNormalizer.normalizedPhrase(entry.appName)
                    || candidate == entry.appID
                    || candidate == entry.bundleIdentifier
            }
        }
    }

    private static func appFinderMetadataValue(
        _ key: String,
        fallback: String,
        in wire: TaskIntentWire
    ) -> String? {
        let value = wire.metadata[key] ?? wire.metadata[fallback]
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func slug(_ value: String) -> String {
        LocalAppTextNormalizer.normalizedPhrase(value)
            .split(separator: " ")
            .joined(separator: "-")
    }
}

private struct GenericHarnessPlanningWire: Decodable {
    var schemaVersion: String
    var structuredIntent: GenericHarnessStructuredIntentWire
    var ambiguityRisk: GenericHarnessAmbiguityRiskWire
    var contextNeeds: [String]
    var planSteps: [GenericHarnessPlanStepWire]
    var verificationCriteria: [String]
    var fallbacks: [String]
    var clarificationPolicy: GenericHarnessClarificationPolicyWire
    var metadata: [String: String]

    private enum CodingKeys: String, CodingKey {
        case structuredIntent
        case ambiguityRisk
        case contextNeeds
        case planSteps
        case verificationCriteria
        case fallbacks
        case clarificationPolicy
        case metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = "generic_harness_planning"
        self.structuredIntent = try container.decode(GenericHarnessStructuredIntentWire.self, forKey: .structuredIntent)
        self.ambiguityRisk = try container.decodeIfPresent(GenericHarnessAmbiguityRiskWire.self, forKey: .ambiguityRisk)
            ?? GenericHarnessAmbiguityRiskWire(
                ambiguityClass: "safe",
                riskLevel: "low",
                missingInformation: [],
                shouldAskBeforeActing: false
            )
        self.contextNeeds = try container.decodeIfPresent(GenericHarnessStringListWire.self, forKey: .contextNeeds)?.values ?? []
        self.planSteps = try container.decodeIfPresent([GenericHarnessPlanStepWire].self, forKey: .planSteps) ?? []
        self.verificationCriteria = try container.decodeIfPresent(GenericHarnessStringListWire.self, forKey: .verificationCriteria)?.values ?? []
        self.fallbacks = try container.decodeIfPresent(GenericHarnessStringListWire.self, forKey: .fallbacks)?.values ?? []
        self.clarificationPolicy = try container.decodeIfPresent(GenericHarnessClarificationPolicyWire.self, forKey: .clarificationPolicy)
            ?? GenericHarnessClarificationPolicyWire(shouldAsk: false, questions: [], policy: "")
        self.metadata = try container.decodeIfPresent(GenericHarnessStringMapWire.self, forKey: .metadata)?.values ?? [:]
    }
}

private struct GenericHarnessStructuredIntentWire: Decodable {
    var route: String
    var goal: String
    var taskType: String
    var targetAppName: String
    var entities: [String: String]
    var normalizedEntities: [String: String]
    var confidence: Double
    var needsConfirmation: Bool

    private enum CodingKeys: String, CodingKey {
        case route
        case goal
        case taskType
        case targetAppName
        case entities
        case normalizedEntities
        case confidence
        case needsConfirmation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.route = try container.decode(String.self, forKey: .route)
        self.taskType = try container.decode(String.self, forKey: .taskType)
        self.entities = try container.decodeIfPresent(GenericHarnessStringMapWire.self, forKey: .entities)?.values ?? [:]
        self.normalizedEntities = try container.decodeIfPresent(GenericHarnessStringMapWire.self, forKey: .normalizedEntities)?.values ?? entities
        self.goal = try container.decodeIfPresent(String.self, forKey: .goal)
            ?? normalizedEntities["goal"]
            ?? entities["goal"]
            ?? ""
        self.targetAppName = try container.decodeIfPresent(String.self, forKey: .targetAppName)
            ?? normalizedEntities["appName"]
            ?? entities["appName"]
            ?? "none"
        self.confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.7
        self.needsConfirmation = try container.decodeIfPresent(Bool.self, forKey: .needsConfirmation) ?? false
    }
}

private struct GenericHarnessAmbiguityRiskWire: Decodable {
    var ambiguityClass: String
    var riskLevel: String
    var missingInformation: [String]
    var shouldAskBeforeActing: Bool

    init(
        ambiguityClass: String,
        riskLevel: String,
        missingInformation: [String],
        shouldAskBeforeActing: Bool
    ) {
        self.ambiguityClass = ambiguityClass
        self.riskLevel = riskLevel
        self.missingInformation = missingInformation
        self.shouldAskBeforeActing = shouldAskBeforeActing
    }

    private enum CodingKeys: String, CodingKey {
        case ambiguityClass
        case riskLevel
        case missingInformation
        case shouldAskBeforeActing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ambiguityClass = try container.decodeIfPresent(String.self, forKey: .ambiguityClass) ?? "safe"
        self.riskLevel = try container.decodeIfPresent(String.self, forKey: .riskLevel) ?? "low"
        self.missingInformation = try container.decodeIfPresent(GenericHarnessStringListWire.self, forKey: .missingInformation)?.values ?? []
        self.shouldAskBeforeActing = try container.decodeIfPresent(Bool.self, forKey: .shouldAskBeforeActing) ?? false
    }
}

private struct GenericHarnessPlanStepWire: Decodable {
    var id: String
    var summary: String
    var toolName: String
    var inputEntity: String
    var controlID: String
    var focusKey: String
    var toolInputs: [String: String]
    var expectedObservation: String

    private enum CodingKeys: String, CodingKey {
        case id
        case summary
        case toolName
        case inputEntity
        case controlID
        case focusKey
        case toolInputs
        case expectedObservation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.toolName = try container.decode(String.self, forKey: .toolName)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? toolName
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        self.inputEntity = try container.decodeIfPresent(String.self, forKey: .inputEntity) ?? ""
        self.controlID = try container.decodeIfPresent(String.self, forKey: .controlID) ?? ""
        self.focusKey = try container.decodeIfPresent(String.self, forKey: .focusKey) ?? ""
        self.toolInputs = try container.decodeIfPresent(GenericHarnessStringMapWire.self, forKey: .toolInputs)?.values ?? [:]
        self.expectedObservation = try container.decodeIfPresent(String.self, forKey: .expectedObservation) ?? ""
    }
}

private struct GenericHarnessClarificationPolicyWire: Decodable {
    var shouldAsk: Bool
    var questions: [String]
    var policy: String

    init(shouldAsk: Bool, questions: [String], policy: String) {
        self.shouldAsk = shouldAsk
        self.questions = questions
        self.policy = policy
    }

    private enum CodingKeys: String, CodingKey {
        case shouldAsk
        case questions
        case policy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.shouldAsk = try container.decodeIfPresent(Bool.self, forKey: .shouldAsk) ?? false
        self.questions = try container.decodeIfPresent(GenericHarnessStringListWire.self, forKey: .questions)?.values ?? []
        self.policy = try container.decodeIfPresent(String.self, forKey: .policy) ?? ""
    }
}

private struct GenericHarnessStringListWire: Decodable {
    var values: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let strings = try? container.decode([String].self) {
            self.values = strings
            return
        }
        if let string = try? container.decode(String.self) {
            self.values = string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [string]
            return
        }
        if let object = try? container.decode(GenericHarnessStringMapWire.self) {
            self.values = object.values
                .map { key, value in value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? key : value }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .sorted()
            return
        }
        self.values = []
    }
}

private struct GenericHarnessStringMapWire: Decodable {
    var values: [String: String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: GenericHarnessDynamicCodingKey.self)
        var values: [String: String] = [:]
        for key in container.allKeys {
            guard let value = try? container.decode(GenericHarnessStringValueWire.self, forKey: key),
                  !value.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                continue
            }
            values[key.stringValue] = value.value
        }
        self.values = values
    }
}

private struct GenericHarnessStringValueWire: Decodable {
    var value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self.value = string
        } else if let bool = try? container.decode(Bool.self) {
            self.value = String(bool)
        } else if let int = try? container.decode(Int.self) {
            self.value = String(int)
        } else if let double = try? container.decode(Double.self) {
            self.value = String(double)
        } else if let strings = try? container.decode([String].self) {
            self.value = strings.joined(separator: ", ")
        } else if let object = try? container.decode([String: String].self) {
            self.value = object
                .map { "\($0.key): \($0.value)" }
                .sorted()
                .joined(separator: ", ")
        } else {
            self.value = ""
        }
    }
}

private struct GenericHarnessDynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private struct TaskIntentWire: Decodable {
    var taskType: String
    var targetAppName: String
    var entities: [String: String]
    var normalizedEntities: [String: String]
    var confidence: Double
    var needsConfirmation: Bool
    var actionPlan: LocalAppActionPlan
    var metadata: [String: String]
}
