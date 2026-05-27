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
                "verification"
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
                "verification": [
                    "type": "string",
                    "enum": LocalAppActionPlanVerification.allCases.map(\.rawValue)
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
                "needsConfirmation": ["type": "boolean"],
                "actionPlan": actionPlanSchema,
                "metadata": [
                    "type": "object",
                    "additionalProperties": ["type": "string"]
                ]
            ]
        ]
    }

    static func genericHarnessPlanningJsonSchema(taskDefinitions: [LocalAppTaskDefinition]) -> [String: Any] {
        let allowsDynamicTargets = taskDefinitions.contains { definition in
            definition.metadata["dynamicTarget"] == "true"
        }
        let taskTypes = (Array(Set(taskDefinitions.map(\.taskType))) + ["none"]).sorted()
        let appNames = (Array(Set(taskDefinitions.map(\.targetApp.appName))) + ["none"]).sorted()
        let targetAppNameSchema: [String: Any] = allowsDynamicTargets
            ? ["type": "string"]
            : ["type": "string", "enum": appNames]
        let toolNames = [""] + LocalAppActionPlanTool.allCases.map(\.rawValue)
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
                "expectedObservation"
            ],
            "properties": [
                "id": ["type": "string"],
                "summary": ["type": "string"],
                "toolName": ["type": "string", "enum": toolNames],
                "inputEntity": ["type": "string"],
                "controlID": ["type": "string"],
                "focusKey": ["type": "string"],
                "expectedObservation": ["type": "string"]
            ]
        ]

        return [
            "type": "object",
            "additionalProperties": false,
            "required": [
                "schemaVersion",
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
                "schemaVersion": ["type": "string", "enum": ["generic_harness_planning"]],
                "structuredIntent": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": [
                        "route",
                        "goal",
                        "taskType",
                        "targetAppName",
                        "entities",
                        "normalizedEntities",
                        "confidence",
                        "needsConfirmation"
                    ],
                    "properties": [
                        "route": [
                            "type": "string",
                            "enum": ["localAppTask", "conversation", "clarification"]
                        ],
                        "goal": ["type": "string"],
                        "taskType": ["type": "string", "enum": taskTypes],
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
                        "needsConfirmation": ["type": "boolean"]
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
                        "shouldAskBeforeActing": ["type": "boolean"]
                    ]
                ],
                "contextNeeds": [
                    "type": "array",
                    "maxItems": 8,
                    "items": ["type": "string"]
                ],
                "planSteps": [
                    "type": "array",
                    "maxItems": 12,
                    "items": planStepSchema
                ],
                "verificationCriteria": [
                    "type": "array",
                    "maxItems": 8,
                    "items": ["type": "string"]
                ],
                "fallbacks": [
                    "type": "array",
                    "maxItems": 8,
                    "items": ["type": "string"]
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
                        "shouldAsk": ["type": "boolean"],
                        "questions": [
                            "type": "array",
                            "maxItems": 4,
                            "items": ["type": "string"]
                        ],
                        "policy": ["type": "string"]
                    ]
                ],
                "metadata": [
                    "type": "object",
                    "additionalProperties": ["type": "string"]
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

        guard mediaSelectionIsValidIfRequired(
            definition: definition,
            metadata: metadata,
            normalizedEntities: normalizedEntities
        ) else {
            return nil
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

        var confidence = wire.confidence
        var needsConfirmation = wire.needsConfirmation || missingRequiredEntity != nil
        var actionPlan = wire.actionPlan.tools.isEmpty ? nil : wire.actionPlan
        if definition.metadata["modelPlanned"] == "true",
           let modelActionPlan = actionPlan {
            let repairedPlan = repairedModelActionPlan(
                modelActionPlan,
                normalizedEntities: normalizedEntities
            )
            if repairedPlan != modelActionPlan {
                metadata["modelPlan.repaired"] = "true"
                actionPlan = repairedPlan
            }
        }
        if let tableRepair = repairedSpreadsheetQueryIfNeeded(
            actionPlan: actionPlan,
            normalizedEntities: normalizedEntities,
            wire: wire
        ) {
            entities[tableRepair.entityName] = tableRepair.text
            normalizedEntities[tableRepair.entityName] = tableRepair.text
            metadata["modelPlan.repairedTableText"] = "true"
        }
        if let conversationReason = textInputConversationReason(
            actionPlan: actionPlan,
            normalizedEntities: normalizedEntities
        ) ?? documentConversationReason(
            actionPlan: actionPlan,
            normalizedEntities: normalizedEntities,
            originalCommand: originalCommand
        ) {
            confidence = min(confidence, 0.2)
            needsConfirmation = false
            actionPlan = nil
            metadata["responseMode"] = "conversation"
            metadata["assistantResponse"] = "I can help, but I need a clearer thing to write before opening an app."
            metadata["notActionableReason"] = conversationReason
        }
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
        metadata["reason"] = nonEmpty(metadata["reason"]) ?? "noSupportedTaskIntent"
        metadata["responseMode"] = "conversation"
        metadata["assistantResponse"] = nonEmpty(metadata["assistantResponse"])
            ?? defaultConversationAssistantResponse
        metadata["taskType"] = "none"
        metadata["targetApp"] = wire.structuredIntent.targetAppName
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
        let tools = wire.planSteps.compactMap { step -> LocalAppActionPlanTool? in
            let toolName = step.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !toolName.isEmpty else { return nil }
            return LocalAppActionPlanTool(rawValue: toolName)
        }
        let inputEntity = firstNonEmpty(wire.planSteps.map(\.inputEntity)) ?? ""
        let controlID = firstNonEmpty(wire.planSteps.map(\.controlID)) ?? ""
        let focusKey = firstNonEmpty(wire.planSteps.map(\.focusKey)) ?? ""
        let verification: LocalAppActionPlanVerification = wire.planSteps.contains { step in
            step.toolName == LocalAppActionPlanTool.verifyVisibleText.rawValue
        } || wire.verificationCriteria.contains { criterion in
            criterion.localizedCaseInsensitiveContains("visible")
        } ? .visibleText : .commandAttempted

        return LocalAppActionPlan(
            tools: tools,
            inputEntity: inputEntity,
            controlID: controlID,
            focusKey: focusKey,
            verification: verification
        )
    }

    private static func hostedPlanningMetadata(from wire: GenericHarnessPlanningWire) -> [String: String] {
        var metadata = wire.metadata
        metadata["genericHarness.schemaVersion"] = wire.schemaVersion
        metadata["genericHarness.intent.route"] = wire.structuredIntent.route
        metadata["genericHarness.intent.goal"] = wire.structuredIntent.goal
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
            if let alias = rule.aliases[rawValue] ?? rule.aliases[LocalAppTaskIntentParser.normalizedPhrase(rawValue)] {
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

    private static func repairedModelActionPlan(
        _ actionPlan: LocalAppActionPlan,
        normalizedEntities: [String: String]
    ) -> LocalAppActionPlan {
        var plan = actionPlan
        if plan.inputEntity.isEmpty {
            plan.inputEntity = "query"
        }
        if plan.controlID.isEmpty {
            plan.controlID = defaultControlID(for: plan.tools)
        }
        if plan.focusKey.isEmpty {
            plan.focusKey = defaultFocusKey(for: plan.tools)
        }

        let inputValue = normalizedEntities[plan.inputEntity] ?? normalizedEntities["query"] ?? ""
        guard !plan.isExecutable,
              !inputValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return plan
        }

        if plan.tools.contains(.newDocument) || plan.tools.contains(.focusTextEntry) {
            return LocalAppActionPlan(
                tools: repairedTools(
                    from: plan.tools,
                    appending: [.setText, .verifyCommand]
                ),
                inputEntity: plan.inputEntity,
                controlID: plan.controlID,
                focusKey: plan.focusKey,
                verification: plan.verification
            )
        }

        if plan.tools.contains(.focusAddressBar) {
            return LocalAppActionPlan(
                tools: repairedTools(
                    from: plan.tools,
                    appending: [.setText, .pressReturn, .verifyCommand]
                ),
                inputEntity: plan.inputEntity,
                controlID: plan.controlID,
                focusKey: plan.focusKey,
                verification: plan.verification
            )
        }

        return LocalAppActionPlan(
            tools: LocalAppActionPlan.defaultSearchSubmitPlan.tools,
            inputEntity: plan.inputEntity,
            controlID: plan.controlID,
            focusKey: plan.focusKey,
            verification: plan.verification
        )
    }

    private static func defaultControlID(for tools: [LocalAppActionPlanTool]) -> String {
        if tools.contains(.focusAddressBar) {
            return "addressBar"
        }
        if tools.contains(.focusTextEntry) || tools.contains(.newDocument) {
            return "editor"
        }
        return "search"
    }

    private static func defaultFocusKey(for tools: [LocalAppActionPlanTool]) -> String {
        if tools.contains(.focusAddressBar) {
            return "Command+L"
        }
        if tools.contains(.focusTextEntry) || tools.contains(.newDocument) {
            return ""
        }
        return "Command+F"
    }

    private static func repairedTools(
        from tools: [LocalAppActionPlanTool],
        appending repairTools: [LocalAppActionPlanTool]
    ) -> [LocalAppActionPlanTool] {
        var repaired = tools
        for tool in repairTools where !repaired.contains(tool) {
            repaired.append(tool)
        }
        return repaired
    }

    private static func repairedSpreadsheetQueryIfNeeded(
        actionPlan: LocalAppActionPlan?,
        normalizedEntities: [String: String],
        wire: TaskIntentWire
    ) -> (entityName: String, text: String)? {
        guard let actionPlan,
              actionPlan.tools.contains(.newDocument),
              actionPlan.tools.contains(.setText)
        else {
            return nil
        }

        let appName = normalizedEntities["appName"] ?? wire.entities["appName"] ?? wire.targetAppName
        guard LocalAppTaskIntentParser.normalizedPhrase(appName) == "numbers" else {
            return nil
        }

        let entityName = actionPlan.inputEntity.isEmpty ? "query" : actionPlan.inputEntity
        let query = (normalizedEntities[entityName] ?? normalizedEntities["query"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              !query.contains("\n"),
              !query.contains("\t")
        else {
            return nil
        }

        let subject = query
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else { return nil }

        let clippedSubject = String(subject.prefix(160))
        return (
            entityName,
            "Request\tStatus\n\(clippedSubject)\tNeeds table data"
        )
    }

    private static func textInputConversationReason(
        actionPlan: LocalAppActionPlan?,
        normalizedEntities: [String: String]
    ) -> String? {
        guard let actionPlan,
              actionPlan.requiresTextInput
        else {
            return nil
        }

        let entityName = actionPlan.inputEntity.isEmpty ? "query" : actionPlan.inputEntity
        let query = (normalizedEntities[entityName] ?? normalizedEntities["query"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return "missingTextPayload"
        }
        if isCopiedPromptPlaceholder(query) {
            return "promptPlaceholderPayload"
        }

        return nil
    }

    private static func mediaSelectionIsValidIfRequired(
        definition: LocalAppTaskDefinition,
        metadata: [String: String],
        normalizedEntities: [String: String]
    ) -> Bool {
        let capabilityID = metadata["appFinder.selectedCapabilityID"]
            ?? metadata["selectedCapabilityID"]
            ?? ""
        let requiresMediaSelection = capabilityID == "play_media"
            || definition.metadata["verificationMode"] == "playbackCommandAttempted"
        guard requiresMediaSelection else { return true }

        guard let kind = nonEmpty(metadata["mediaSelection.kind"])?.lowercased() else {
            return false
        }
        let blockedKinds: Set<String> = [
            "artist",
            "artist_only",
            "artist_page",
            "browse_artist"
        ]
        guard !blockedKinds.contains(kind) else { return false }

        let queryEntity = definition.verificationEntityName ?? "query"
        guard let query = nonEmpty(normalizedEntities[queryEntity] ?? normalizedEntities["query"]) else {
            return false
        }

        if let seed = nonEmpty(metadata["mediaSelection.seed"]),
           LocalAppTaskIntentParser.normalizedPhrase(query) == LocalAppTaskIntentParser.normalizedPhrase(seed) {
            return false
        }

        if kind.contains("representative") {
            return nonEmpty(metadata["mediaSelection.selectedTitle"]) != nil
        }

        return true
    }

    private static func documentConversationReason(
        actionPlan: LocalAppActionPlan?,
        normalizedEntities: [String: String],
        originalCommand: String
    ) -> String? {
        guard let actionPlan,
              actionPlan.tools.contains(.newDocument),
              actionPlan.tools.contains(.setText),
              !actionPlan.tools.contains(.pressReturn)
        else {
            return nil
        }

        let entityName = actionPlan.inputEntity.isEmpty ? "query" : actionPlan.inputEntity
        let query = (normalizedEntities[entityName] ?? normalizedEntities["query"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              !commandContainsQuoted(query, originalCommand: originalCommand),
              !query.contains("\n"),
              !query.contains("\t"),
              query.rangeOfCharacter(from: CharacterSet(charactersIn: ".?!:;,")) == nil
        else {
            return nil
        }

        let words = LocalAppTaskIntentParser.normalizedPhrase(query)
            .split(separator: " ")
        return words.count <= 5 ? "insufficientDocumentPayload" : nil
    }

    private static func isCopiedPromptPlaceholder(_ query: String) -> Bool {
        let normalizedQuery = LocalAppTaskIntentParser.normalizedPhrase(query)
        guard !normalizedQuery.isEmpty else { return false }

        return copiedPromptPayloadPhrases.contains { phrase in
            normalizedQuery.contains(LocalAppTaskIntentParser.normalizedPhrase(phrase))
        }
    }

    private static let copiedPromptPayloadPhrases = [
        "complete piece of text generated for the user writing request",
        "complete piece of text generated for the user's writing request",
        "generated for the user writing request",
        "the actual final text to type",
        "tab separated rows for the requested table",
        "column a column b row label value or data needed note"
    ]

    private static func commandContainsQuoted(
        _ query: String,
        originalCommand: String
    ) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return false }
        let quotedPatterns = [
            "\"\(trimmedQuery)\"",
            "'\(trimmedQuery)'",
            "`\(trimmedQuery)`"
        ]
        return quotedPatterns.contains { originalCommand.localizedCaseInsensitiveContains($0) }
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
                LocalAppTaskIntentParser.normalizedPhrase(candidate)
                    == LocalAppTaskIntentParser.normalizedPhrase(entry.appName)
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
        LocalAppTaskIntentParser.normalizedPhrase(value)
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
}

private struct GenericHarnessAmbiguityRiskWire: Decodable {
    var ambiguityClass: String
    var riskLevel: String
    var missingInformation: [String]
    var shouldAskBeforeActing: Bool
}

private struct GenericHarnessPlanStepWire: Decodable {
    var id: String
    var summary: String
    var toolName: String
    var inputEntity: String
    var controlID: String
    var focusKey: String
    var expectedObservation: String
}

private struct GenericHarnessClarificationPolicyWire: Decodable {
    var shouldAsk: Bool
    var questions: [String]
    var policy: String
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
