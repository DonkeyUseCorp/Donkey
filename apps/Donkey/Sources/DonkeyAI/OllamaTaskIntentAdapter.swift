import DonkeyContracts
import DonkeyRuntime
import Foundation

public struct TaskIntentAdapterRequest: Equatable, Sendable {
    public var command: String
    public var taskDefinitions: [LocalAppTaskDefinition]
    public var sourceTraceID: String
    public var routeRequest: AIModelRouteRequest

    public init(
        command: String,
        taskDefinitions: [LocalAppTaskDefinition],
        sourceTraceID: String,
        routeRequest: AIModelRouteRequest = AIModelRouteRequest(
            jobType: .taskIntent,
            privacyMode: .privacySensitive,
            latencyTolerance: .interactive
        )
    ) {
        self.command = command
        self.taskDefinitions = taskDefinitions
        self.sourceTraceID = sourceTraceID
        self.routeRequest = routeRequest
    }
}

public struct TaskIntentAdapterResult: Equatable, Sendable {
    public var intent: TaskIntent?
    public var trace: AIModelCallTrace

    public init(intent: TaskIntent?, trace: AIModelCallTrace) {
        self.intent = intent
        self.trace = trace
    }
}

public protocol TaskIntentParsingAdapter: Sendable {
    func parseTaskIntent(_ request: TaskIntentAdapterRequest) async -> TaskIntentAdapterResult
}

public struct ProcessBackedLocalLLMTaskIntentAdapter: TaskIntentParsingAdapter {
    public static let schemaID = "task_intent_v1"

    public var router: AIModelRouter
    public var sidecarRunner: any LocalJSONSidecarRunning
    public var encoder: JSONEncoder
    public var decoder: JSONDecoder

    public init(
        router: AIModelRouter = AIModelRouter(registry: .defaultHybridPlanner),
        sidecarRunner: any LocalJSONSidecarRunning = ProcessBackedLocalJSONSidecarRunner(),
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.router = router
        self.sidecarRunner = sidecarRunner
        self.encoder = encoder
        self.decoder = decoder
    }

    public func parseTaskIntent(
        _ request: TaskIntentAdapterRequest
    ) async -> TaskIntentAdapterResult {
        let entry: AIModelRegistryEntry
        do {
            entry = try router.route(request.routeRequest.limitingProviders([.localRuntime]))
        } catch {
            return result(
                entry: nil,
                request: request,
                status: .invalidOutput,
                validationStatus: "routingFailed",
                latencyMS: nil,
                metadata: ["error": String(describing: error)]
            )
        }

        let input = LocalLLMTaskIntentSidecarRequest(
            command: request.command,
            taskDefinitions: request.taskDefinitions,
            sourceTraceID: request.sourceTraceID,
            modelID: entry.modelID,
            metadata: [
                "schemaID": Self.schemaID,
                "promptVersion": entry.promptVersion
            ]
        )
        let result = await sidecarRunner.run(
            LocalJSONSidecarRequest(
                environmentVariableName: "DONKEY_LOCAL_LLM_RUNNER",
                inputData: (try? encoder.encode(input)) ?? Data(),
                timeoutMS: entry.timeoutMS,
                metadata: [
                    "sidecar.role": "taskIntent",
                    "modelID": entry.modelID
                ]
            )
        )

        guard result.status == .completed else {
            return self.result(
                entry: entry,
                request: request,
                status: result.status == .timedOut ? .timeout : .providerOutage,
                validationStatus: "notValidated",
                latencyMS: result.latencyMS,
                metadata: result.metadata.merging([
                    "sidecar.stderr": result.stderrText
                ]) { current, _ in current }
            )
        }

        do {
            let response = try decoder.decode(LocalLLMTaskIntentSidecarResponse.self, from: result.outputData)
            guard let intent = try TaskIntentWireCodec.decodeIntent(
                response.outputText,
                definitions: request.taskDefinitions,
                sourceModelCallID: "model-call-\(request.sourceTraceID)",
                parserName: "local-llm-sidecar-v1"
            ) else {
                return self.result(
                    entry: entry,
                    request: request,
                    status: .invalidOutput,
                    validationStatus: "invalid",
                    latencyMS: result.latencyMS,
                    metadata: result.metadata.merging(response.metadata) { current, _ in current }
                )
            }

            return TaskIntentAdapterResult(
                intent: intent,
                trace: trace(
                    entry: entry,
                    request: request,
                    status: .completed,
                    validationStatus: "schemaDecoded",
                    latencyMS: result.latencyMS,
                    metadata: result.metadata.merging(response.metadata) { current, _ in current }
                )
            )
        } catch {
            return self.result(
                entry: entry,
                request: request,
                status: .invalidOutput,
                validationStatus: "invalid",
                latencyMS: result.latencyMS,
                metadata: result.metadata.merging([
                    "error": String(describing: error)
                ]) { current, _ in current }
            )
        }
    }

    private func result(
        entry: AIModelRegistryEntry?,
        request: TaskIntentAdapterRequest,
        status: AIModelCallStatus,
        validationStatus: String,
        latencyMS: Double?,
        metadata: [String: String] = [:]
    ) -> TaskIntentAdapterResult {
        TaskIntentAdapterResult(
            intent: nil,
            trace: trace(
                entry: entry,
                request: request,
                status: status,
                validationStatus: validationStatus,
                latencyMS: latencyMS,
                metadata: metadata
            )
        )
    }

    private func trace(
        entry: AIModelRegistryEntry?,
        request: TaskIntentAdapterRequest,
        status: AIModelCallStatus,
        validationStatus: String,
        latencyMS: Double?,
        metadata: [String: String] = [:]
    ) -> AIModelCallTrace {
        AIModelCallTrace(
            id: "model-call-\(request.sourceTraceID)",
            role: entry?.role ?? .taskIntent,
            provider: entry?.provider ?? .localRuntime,
            modelID: entry?.modelID ?? "unrouted",
            promptVersion: entry?.promptVersion ?? "unrouted",
            schemaID: Self.schemaID,
            latencyMS: latencyMS,
            timeoutMS: entry?.timeoutMS ?? 0,
            status: status,
            validationStatus: validationStatus,
            sourceTraceID: request.sourceTraceID,
            metadata: metadata
        )
    }
}

private struct LocalLLMTaskIntentSidecarRequest: Codable, Equatable, Sendable {
    var command: String
    var taskDefinitions: [LocalAppTaskDefinition]
    var sourceTraceID: String
    var modelID: String
    var metadata: [String: String]
}

private struct LocalLLMTaskIntentSidecarResponse: Codable, Equatable, Sendable {
    var outputText: String
    var metadata: [String: String]
}

public struct OllamaTaskIntentAdapter: TaskIntentParsingAdapter {
    public static let schemaID = "task_intent_v1"

    public var router: AIModelRouter
    public var httpClient: any AIHTTPClient

    public init(
        router: AIModelRouter = AIModelRouter(registry: .defaultHybridPlanner),
        httpClient: any AIHTTPClient = URLSessionAIHTTPClient()
    ) {
        self.router = router
        self.httpClient = httpClient
    }

    public func parseTaskIntent(
        _ request: TaskIntentAdapterRequest
    ) async -> TaskIntentAdapterResult {
        let entry: AIModelRegistryEntry
        do {
            entry = try router.route(request.routeRequest.limitingProviders([.ollama]))
        } catch {
            return result(
                entry: nil,
                request: request,
                status: .invalidOutput,
                validationStatus: "routingFailed",
                latencyMS: nil,
                metadata: ["error": String(describing: error)]
            )
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            let urlRequest = try makeURLRequest(entry: entry, adapterRequest: request)
            let (data, response) = try await httpClient.send(urlRequest)
            let latencyMS = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000

            if response.statusCode == 429 {
                return result(entry: entry, request: request, status: .rateLimited, validationStatus: "notValidated", latencyMS: latencyMS)
            }

            if response.statusCode >= 500 {
                return result(entry: entry, request: request, status: .providerOutage, validationStatus: "notValidated", latencyMS: latencyMS)
            }

            guard (200..<300).contains(response.statusCode),
                  let outputText = try Self.outputText(from: data),
                  let intent = try TaskIntentWireCodec.decodeIntent(
                    outputText,
                    definitions: request.taskDefinitions,
                    sourceModelCallID: "model-call-\(request.sourceTraceID)",
                    parserName: "ollama-task-intent-v1"
                  )
            else {
                return result(entry: entry, request: request, status: .invalidOutput, validationStatus: "invalid", latencyMS: latencyMS)
            }

            return TaskIntentAdapterResult(
                intent: intent,
                trace: trace(
                    entry: entry,
                    request: request,
                    status: .completed,
                    validationStatus: "schemaDecoded",
                    latencyMS: latencyMS,
                    metadata: [
                        "http.status": String(response.statusCode),
                        "local.provider": "ollama"
                    ]
                )
            )
        } catch is CancellationError {
            return result(entry: entry, request: request, status: .cancelled, validationStatus: "notValidated", latencyMS: nil)
        } catch {
            let latencyMS = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            let status: AIModelCallStatus = (error as NSError).code == NSURLErrorTimedOut ? .timeout : .providerOutage
            return result(
                entry: entry,
                request: request,
                status: status,
                validationStatus: "notValidated",
                latencyMS: latencyMS,
                metadata: ["error": String(describing: error)]
            )
        }
    }

    private func makeURLRequest(
        entry: AIModelRegistryEntry,
        adapterRequest: TaskIntentAdapterRequest
    ) throws -> URLRequest {
        var request = URLRequest(url: entry.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Double(entry.timeoutMS) / 1_000
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(entry: entry, adapterRequest: adapterRequest))
        return request
    }

    private func requestBody(
        entry: AIModelRegistryEntry,
        adapterRequest: TaskIntentAdapterRequest
    ) -> [String: Any] {
        return [
            "model": entry.modelID,
            "prompt": promptText(for: adapterRequest),
            "stream": false,
            "format": TaskIntentWireCodec.jsonSchema(
                taskDefinitions: adapterRequest.taskDefinitions
            ),
            "options": [
                "num_ctx": 2048,
                "num_predict": 128,
                "temperature": 0,
                "top_p": 0.8
            ],
            "keep_alive": "10m"
        ]
    }

    private func promptText(for request: TaskIntentAdapterRequest) -> String {
        let tasks = request.taskDefinitions.map { definition in
            let entities = definition.entityRules.map { rule in
                "\(rule.name) required=\(rule.required)"
            }
            .joined(separator: "; ")
            let workflow = definition.workflowSteps
                .filter { $0.role != .parseIntent }
                .map(\.summary)
                .joined(separator: " -> ")
            let automation = [
                definition.metadata["automationBackend"].map { "automation_backend=\($0)" },
                definition.metadata["appleScript.action"].map { "apple_script_action=\($0)" },
                definition.metadata["appleScript.entityName"].map { "apple_script_entity=\($0)" }
            ]
            .compactMap(\.self)
            .joined(separator: " | ")

            return [
                "task_type=\(definition.taskType)",
                "app=\(definition.targetApp.appName)",
                "bundle=\(definition.targetApp.bundleIdentifier ?? "unknown")",
                "capability=\(workflow)",
                "entities=\(entities)",
                automation
            ]
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        }
        .joined(separator: "\n")

        return [
            "Classify the user's natural-language request into exactly one supported local app task intent, then return strict JSON.",
            "Choose by capability and target app, not by exact wording. The user should not need to remember command phrases.",
            "Do not include reasoning.",
            "Use only the provided task definitions. Do not invent apps, task types, entities, or actions.",
            "If no capability fits, return the closest supported task with confidence below 0.55.",
            "If a required entity is missing, set needsConfirmation=true and include missingEntity in metadata.",
            "For dynamic local-item capabilities, extract the requested local app/file/folder name into entities.appName and normalizedEntities.appName. Use targetAppName for the resolved item name when you know it.",
            "For AppleScript-backed capabilities, include compact appleScript.source or appleScript.template metadata only when the provided action is insufficient; prefer task metadata and normalized entities for speed.",
            "Command: \(request.command)",
            "Supported task capabilities:",
            tasks
        ]
        .joined(separator: "\n")
    }

    private func result(
        entry: AIModelRegistryEntry?,
        request: TaskIntentAdapterRequest,
        status: AIModelCallStatus,
        validationStatus: String,
        latencyMS: Double?,
        metadata: [String: String] = [:]
    ) -> TaskIntentAdapterResult {
        TaskIntentAdapterResult(
            intent: nil,
            trace: trace(
                entry: entry,
                request: request,
                status: status,
                validationStatus: validationStatus,
                latencyMS: latencyMS,
                metadata: metadata
            )
        )
    }

    private func trace(
        entry: AIModelRegistryEntry?,
        request: TaskIntentAdapterRequest,
        status: AIModelCallStatus,
        validationStatus: String,
        latencyMS: Double?,
        metadata: [String: String] = [:]
    ) -> AIModelCallTrace {
        AIModelCallTrace(
            id: "model-call-\(request.sourceTraceID)",
            role: entry?.role ?? .taskIntent,
            provider: entry?.provider ?? .ollama,
            modelID: entry?.modelID ?? "unrouted",
            promptVersion: entry?.promptVersion ?? "unrouted",
            schemaID: Self.schemaID,
            latencyMS: latencyMS,
            timeoutMS: entry?.timeoutMS ?? 0,
            status: status,
            validationStatus: validationStatus,
            sourceTraceID: request.sourceTraceID,
            metadata: metadata
        )
    }
}

public struct LocalModelTaskIntentResolver: Sendable {
    public var catalog: LocalAppTaskCatalog
    public var adapter: any TaskIntentParsingAdapter

    public init(
        catalog: LocalAppTaskCatalog,
        adapter: any TaskIntentParsingAdapter = PriorityQueuedTaskIntentParsingAdapter(
            base: ProcessBackedLocalLLMTaskIntentAdapter()
        )
    ) {
        self.catalog = catalog
        self.adapter = adapter
    }

    public func resolve(
        command: String,
        sourceTraceID: String
    ) async -> (resolution: LocalAppTaskCatalogResolution, trace: AIModelCallTrace) {
        let result = await adapter.parseTaskIntent(
            TaskIntentAdapterRequest(
                command: command,
                taskDefinitions: catalog.taskDefinitions,
                sourceTraceID: sourceTraceID
            )
        )

        guard let intent = result.intent else {
            return (
                LocalAppTaskCatalogResolution(
                    status: .needsConfirmation,
                    metadata: [
                        "reason": "localModelIntentUnavailable",
                        "modelCallStatus": result.trace.status.rawValue
                    ]
                ),
                result.trace
            )
        }

        return (catalog.resolve(intent: intent), result.trace)
    }
}

private struct OllamaTaskIntentResponse: Decodable {
    var response: String?
}

private enum TaskIntentWireCodec {
    static func jsonSchema(taskDefinitions: [LocalAppTaskDefinition]) -> [String: Any] {
        let allowsDynamicTargets = taskDefinitions.contains { definition in
            definition.metadata["dynamicTarget"] == "true"
        }
        let targetAppNameSchema: [String: Any] = allowsDynamicTargets
            ? ["type": "string"]
            : ["type": "string", "enum": Array(Set(taskDefinitions.map(\.targetApp.appName))).sorted()]

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
                "metadata"
            ],
            "properties": [
                "taskType": ["type": "string", "enum": Array(Set(taskDefinitions.map(\.taskType))).sorted()],
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
        sourceModelCallID: String,
        parserName: String
    ) throws -> TaskIntent? {
        let data = Data(outputText.utf8)
        let wire = try JSONDecoder().decode(TaskIntentWire.self, from: data)
        let exactDefinition = definitions.first(where: {
            $0.taskType == wire.taskType && $0.targetApp.appName == wire.targetAppName
        })
        let dynamicDefinition = definitions.first(where: {
            $0.taskType == wire.taskType && $0.metadata["dynamicTarget"] == "true"
        })
        guard let definition = exactDefinition ?? dynamicDefinition else {
            return nil
        }

        var entities = wire.entities
        var normalizedEntities = normalizedEntities(from: wire, definition: definition)
        if definition.metadata["dynamicTarget"] == "true",
           normalizedEntities["appName"] == nil,
           wire.targetAppName != definition.targetApp.appName {
            entities["appName"] = wire.targetAppName
            normalizedEntities["appName"] = wire.targetAppName
        }
        let missingRequiredEntity = definition.entityRules.first { rule in
            rule.required && normalizedEntities[rule.name] == nil
        }
        var metadata = wire.metadata.merging(definition.metadata) { current, _ in current }
        metadata["parser"] = parserName
        if definition.metadata["dynamicTarget"] == "true" {
            metadata["requestedItemName"] = normalizedEntities["appName"] ?? entities["appName"] ?? ""
        }
        if let missingRequiredEntity {
            metadata["missingEntity"] = missingRequiredEntity.name
        }

        let needsConfirmation = wire.needsConfirmation || missingRequiredEntity != nil
        let primaryEntity = definition.verificationEntityName
            .flatMap { normalizedEntities[$0] }
            ?? normalizedEntities.values.sorted().first
            ?? definition.taskType

        return TaskIntent(
            intentID: needsConfirmation
                ? "\(definition.taskType)-needs-\(missingRequiredEntity?.name ?? "confirmation")"
                : "\(definition.taskType)-\(slug(primaryEntity))",
            taskType: definition.taskType,
            targetApp: targetApp(from: wire, definition: definition),
            entities: entities,
            normalizedEntities: normalizedEntities,
            confidence: wire.confidence,
            parserSource: .localModel,
            needsConfirmation: needsConfirmation,
            sourceModelCallID: sourceModelCallID,
            metadata: metadata
        )
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

    private static func targetApp(
        from wire: TaskIntentWire,
        definition: LocalAppTaskDefinition
    ) -> LocalAppTarget {
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

    private static func slug(_ value: String) -> String {
        LocalAppTaskIntentParser.normalizedPhrase(value)
            .split(separator: " ")
            .joined(separator: "-")
    }
}

private struct TaskIntentWire: Decodable {
    var taskType: String
    var targetAppName: String
    var entities: [String: String]
    var normalizedEntities: [String: String]
    var confidence: Double
    var needsConfirmation: Bool
    var metadata: [String: String]
}

private extension OllamaTaskIntentAdapter {
    static func outputText(from data: Data) throws -> String? {
        try JSONDecoder().decode(OllamaTaskIntentResponse.self, from: data).response
    }
}
