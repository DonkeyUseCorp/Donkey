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

public struct OllamaTaskIntentAdapter: Sendable {
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
                    sourceModelCallID: "model-call-\(request.sourceTraceID)"
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
        [
            "model": entry.modelID,
            "prompt": promptText(for: adapterRequest),
            "stream": false,
            "format": TaskIntentWireCodec.jsonSchema(
                taskTypes: adapterRequest.taskDefinitions.map(\.taskType),
                appNames: adapterRequest.taskDefinitions.map(\.targetApp.appName)
            ),
            "options": [
                "num_predict": 512
            ]
        ]
    }

    private func promptText(for request: TaskIntentAdapterRequest) -> String {
        let tasks = request.taskDefinitions.map { definition in
            let entities = definition.entityRules.map { rule in
                "\(rule.name) required=\(rule.required) markers=\(rule.markers.joined(separator: ",")) aliases=\(rule.aliases.keys.sorted().joined(separator: ","))"
            }
            .joined(separator: "; ")

            return [
                "task_type=\(definition.taskType)",
                "app=\(definition.targetApp.appName)",
                "bundle=\(definition.targetApp.bundleIdentifier ?? "unknown")",
                "triggers=\(definition.triggerTerms.joined(separator: ","))",
                "entities=\(entities)"
            ]
            .joined(separator: " | ")
        }
        .joined(separator: "\n")

        return [
            "Return exactly one local app task intent as strict JSON.",
            "Use only the provided task definitions. Do not invent apps, task types, entities, or actions.",
            "If a required entity is missing, set needsConfirmation=true and include missingEntity in metadata.",
            "Command: \(request.command)",
            "Task definitions:",
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
    public var adapter: OllamaTaskIntentAdapter

    public init(
        catalog: LocalAppTaskCatalog,
        adapter: OllamaTaskIntentAdapter = OllamaTaskIntentAdapter()
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
                    status: .unsupportedCommand,
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
    static func jsonSchema(taskTypes: [String], appNames: [String]) -> [String: Any] {
        [
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
                "taskType": ["type": "string", "enum": Array(Set(taskTypes)).sorted()],
                "targetAppName": ["type": "string", "enum": Array(Set(appNames)).sorted()],
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
        sourceModelCallID: String
    ) throws -> TaskIntent? {
        let data = Data(outputText.utf8)
        let wire = try JSONDecoder().decode(TaskIntentWire.self, from: data)
        guard let definition = definitions.first(where: {
            $0.taskType == wire.taskType && $0.targetApp.appName == wire.targetAppName
        }) else {
            return nil
        }

        let normalizedEntities = normalizedEntities(from: wire, definition: definition)
        let missingRequiredEntity = definition.entityRules.first { rule in
            rule.required && normalizedEntities[rule.name] == nil
        }
        var metadata = wire.metadata.merging(definition.metadata) { current, _ in current }
        metadata["parser"] = "ollama-task-intent-v1"
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
            targetApp: definition.targetApp,
            entities: wire.entities,
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
