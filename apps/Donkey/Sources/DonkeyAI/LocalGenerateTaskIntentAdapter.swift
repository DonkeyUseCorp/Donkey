import DonkeyContracts
import DonkeyRuntime
import Foundation

public struct TaskIntentAdapterRequest: Equatable, Sendable {
    public var command: String
    public var taskDefinitions: [LocalAppTaskDefinition]
    public var contextSnippets: [String]
    public var appFinderCatalog: [LocalAppFinderCatalogEntry]
    public var sourceTraceID: String
    public var routeRequest: AIModelRouteRequest

    public init(
        command: String,
        taskDefinitions: [LocalAppTaskDefinition],
        contextSnippets: [String] = [],
        appFinderCatalog: [LocalAppFinderCatalogEntry] = [],
        sourceTraceID: String,
        routeRequest: AIModelRouteRequest = AIModelRouteRequest(
            jobType: .taskIntent,
            privacyMode: .privacySensitive,
            latencyTolerance: .interactive
        )
    ) {
        self.command = command
        self.taskDefinitions = taskDefinitions
        self.contextSnippets = TaskIntentModelContextCompactor.compact(contextSnippets)
        self.appFinderCatalog = appFinderCatalog
        self.sourceTraceID = sourceTraceID
        self.routeRequest = routeRequest
    }
}

public struct TaskIntentModelContextCompactor: Equatable, Sendable {
    public var maxSnippets: Int
    public var maxSnippetCharacters: Int
    public var maxTotalCharacters: Int

    public init(
        maxSnippets: Int = 8,
        maxSnippetCharacters: Int = 1_200,
        maxTotalCharacters: Int = 4_800
    ) {
        self.maxSnippets = max(0, maxSnippets)
        self.maxSnippetCharacters = max(80, maxSnippetCharacters)
        self.maxTotalCharacters = max(80, maxTotalCharacters)
    }

    public func compact(_ snippets: [String]) -> [String] {
        var usedCharacters = 0
        var compacted: [String] = []

        for snippet in snippets.prefix(maxSnippets) {
            let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let boundedSnippet = bounded(trimmed, maxCharacters: maxSnippetCharacters)
            let remainingCharacters = maxTotalCharacters - usedCharacters
            guard remainingCharacters > 0 else { break }

            let totalBoundedSnippet = bounded(boundedSnippet, maxCharacters: remainingCharacters)
            usedCharacters += totalBoundedSnippet.count
            compacted.append(totalBoundedSnippet)
        }

        return compacted
    }

    public static func compact(_ snippets: [String]) -> [String] {
        TaskIntentModelContextCompactor().compact(snippets)
    }

    private func bounded(_ value: String, maxCharacters: Int) -> String {
        guard value.count > maxCharacters else { return value }
        let marker = "\n...[compacted]...\n"
        guard maxCharacters > marker.count + 2 else {
            return String(value.suffix(maxCharacters))
        }

        let contentCharacters = maxCharacters - marker.count
        let prefixCharacters = contentCharacters / 2
        let suffixCharacters = contentCharacters - prefixCharacters
        let prefixEnd = value.index(value.startIndex, offsetBy: prefixCharacters)
        let suffixStart = value.index(value.endIndex, offsetBy: -suffixCharacters)
        return String(value[..<prefixEnd]) + marker + String(value[suffixStart...])
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
            contextSnippets: request.contextSnippets,
            appFinderCatalog: request.appFinderCatalog,
            sourceTraceID: request.sourceTraceID,
            modelID: entry.modelID,
            cacheDirectory: LocalModelRuntimeExecutableResolver().modelCacheDirectoryPath(
                environmentVariableName: "DONKEY_LOCAL_LLM_RUNNER"
            ),
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
            let responseMetadata = result.metadata
                .merging(response.metadata) { current, _ in current }
                .merging(Self.outputDiagnostics(for: response.outputText)) { current, _ in current }
            if response.outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               response.metadata["reason"] != nil {
                return self.result(
                    entry: entry,
                    request: request,
                    status: .providerOutage,
                    validationStatus: "notValidated",
                    latencyMS: result.latencyMS,
                    metadata: responseMetadata
                )
            }

            guard let intent = try TaskIntentWireCodec.decodeIntent(
                response.outputText,
                definitions: request.taskDefinitions,
                originalCommand: request.command,
                appFinderCatalog: request.appFinderCatalog,
                sourceModelCallID: "model-call-\(request.sourceTraceID)",
                parserName: "local-llm-sidecar-v1"
            ) else {
                if let noTaskMetadata = try? TaskIntentWireCodec.noTaskMetadata(
                    response.outputText,
                    parserName: "local-llm-sidecar-v1"
                ) {
                    return self.result(
                        entry: entry,
                        request: request,
                        status: .completed,
                        validationStatus: "noTaskIntent",
                        latencyMS: result.latencyMS,
                        metadata: responseMetadata.merging(noTaskMetadata) { _, new in new }
                    )
                }
                return self.result(
                    entry: entry,
                    request: request,
                    status: .invalidOutput,
                    validationStatus: "invalid",
                    latencyMS: result.latencyMS,
                    metadata: responseMetadata
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
                    metadata: responseMetadata
                )
            )
        } catch {
            if let sidecarError = decodeSidecarError(
                result.outputData,
                entry: entry,
                request: request,
                sidecarResult: result,
                decodeError: error
            ) {
                return sidecarError
            }

            return self.result(
                entry: entry,
                request: request,
                status: .invalidOutput,
                validationStatus: "invalid",
                latencyMS: result.latencyMS,
                metadata: result.metadata.merging([
                    "error": String(describing: error),
                    "sidecar.outputPreview": Self.preview(result.outputData, maxCharacters: 240)
                ]) { current, _ in current }
            )
        }
    }

    private func decodeSidecarError(
        _ data: Data,
        entry: AIModelRegistryEntry,
        request: TaskIntentAdapterRequest,
        sidecarResult: LocalJSONSidecarResult,
        decodeError: Error
    ) -> TaskIntentAdapterResult? {
        guard let errorResponse = try? decoder.decode(LocalLLMTaskIntentSidecarErrorResponse.self, from: data),
              errorResponse.status == "error" || errorResponse.metadata["reason"] != nil
        else {
            return nil
        }

        return result(
            entry: entry,
            request: request,
            status: .providerOutage,
            validationStatus: "notValidated",
            latencyMS: sidecarResult.latencyMS,
            metadata: sidecarResult.metadata.merging(
                errorResponse.metadata.merging([
                    "sidecar.status": errorResponse.status,
                    "decode.error": String(describing: decodeError)
                ]) { current, _ in current }
            ) { current, _ in current }
        )
    }

    private static func outputDiagnostics(for outputText: String) -> [String: String] {
        let trimmed = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ["modelOutput.empty": "true"]
        }

        return [
            "modelOutput.empty": "false",
            "modelOutput.preview": preview(trimmed, maxCharacters: 240)
        ]
    }

    private static func preview(_ data: Data, maxCharacters: Int) -> String {
        preview(String(decoding: data, as: UTF8.self), maxCharacters: maxCharacters)
    }

    private static func preview(_ value: String, maxCharacters: Int) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        guard singleLine.count > maxCharacters else { return singleLine }
        return String(singleLine.prefix(maxCharacters))
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
    var contextSnippets: [String]
    var appFinderCatalog: [LocalAppFinderCatalogEntry]
    var sourceTraceID: String
    var modelID: String
    var cacheDirectory: String?
    var metadata: [String: String]
}

private struct LocalLLMTaskIntentSidecarResponse: Codable, Equatable, Sendable {
    var outputText: String
    var metadata: [String: String]
}

private struct LocalLLMTaskIntentSidecarErrorResponse: Codable, Equatable, Sendable {
    var status: String
    var metadata: [String: String]
}

public struct LocalGenerateTaskIntentAdapter: TaskIntentParsingAdapter {
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
        return await parseTaskIntent(
            request,
            entry: entry,
            startedAt: startedAt,
            fallbackFromModelID: nil
        )
    }

    private func parseTaskIntent(
        _ request: TaskIntentAdapterRequest,
        entry: AIModelRegistryEntry,
        startedAt: Double,
        fallbackFromModelID: String?
    ) async -> TaskIntentAdapterResult {
        do {
            let urlRequest = try makeURLRequest(entry: entry, adapterRequest: request)
            let (data, response) = try await httpClient.send(urlRequest)
            let latencyMS = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000

            if response.statusCode == 404,
               fallbackFromModelID == nil,
               let fallbackModelID = try? await fallbackLocalGenerateModelID(
                for: entry,
                excluding: [entry.modelID]
               ),
               fallbackModelID != entry.modelID {
                var fallbackEntry = entry
                fallbackEntry.modelID = fallbackModelID
                fallbackEntry.metadata["modelFallback.originalModelID"] = entry.modelID
                fallbackEntry.metadata["modelFallback.reason"] = "requestedModelUnavailable"
                let fallbackResult = await parseTaskIntent(
                    request,
                    entry: fallbackEntry,
                    startedAt: startedAt,
                    fallbackFromModelID: entry.modelID
                )
                var trace = fallbackResult.trace
                trace.metadata["modelFallback.originalModelID"] = entry.modelID
                trace.metadata["modelFallback.selectedModelID"] = fallbackModelID
                trace.metadata["modelFallback.reason"] = "requestedModelUnavailable"
                return TaskIntentAdapterResult(intent: fallbackResult.intent, trace: trace)
            }

            if response.statusCode == 429 {
                return result(
                    entry: entry,
                    request: request,
                    status: .rateLimited,
                    validationStatus: "notValidated",
                    latencyMS: latencyMS,
                    metadata: httpMetadata(response: response, data: data, fallbackFromModelID: fallbackFromModelID)
                )
            }

            if response.statusCode >= 500 {
                return result(
                    entry: entry,
                    request: request,
                    status: .providerOutage,
                    validationStatus: "notValidated",
                    latencyMS: latencyMS,
                    metadata: httpMetadata(response: response, data: data, fallbackFromModelID: fallbackFromModelID)
                )
            }

            guard (200..<300).contains(response.statusCode),
                  let outputText = try Self.outputText(from: data)
            else {
                return result(
                    entry: entry,
                    request: request,
                    status: (200..<300).contains(response.statusCode) ? .invalidOutput : .providerOutage,
                    validationStatus: (200..<300).contains(response.statusCode) ? "invalid" : "notValidated",
                    latencyMS: latencyMS,
                    metadata: httpMetadata(response: response, data: data, fallbackFromModelID: fallbackFromModelID)
                )
            }

            let baseMetadata = httpMetadata(
                response: response,
                data: data,
                fallbackFromModelID: fallbackFromModelID
            )
            guard let intent = try TaskIntentWireCodec.decodeIntent(
                outputText,
                definitions: request.taskDefinitions,
                originalCommand: request.command,
                appFinderCatalog: request.appFinderCatalog,
                sourceModelCallID: "model-call-\(request.sourceTraceID)",
                parserName: "local-generate-task-intent-v1"
            ) else {
                if let noTaskMetadata = try? TaskIntentWireCodec.noTaskMetadata(
                    outputText,
                    parserName: "local-generate-task-intent-v1"
                ) {
                    return result(
                        entry: entry,
                        request: request,
                        status: .completed,
                        validationStatus: "noTaskIntent",
                        latencyMS: latencyMS,
                        metadata: baseMetadata
                            .merging(noTaskMetadata) { _, new in new }
                            .merging(["local.provider": "ollama"]) { current, _ in current }
                    )
                }
                return result(
                    entry: entry,
                    request: request,
                    status: .invalidOutput,
                    validationStatus: "invalid",
                    latencyMS: latencyMS,
                    metadata: baseMetadata
                )
            }

            return TaskIntentAdapterResult(
                intent: intent,
                trace: trace(
                    entry: entry,
                    request: request,
                    status: .completed,
                    validationStatus: "schemaDecoded",
                    latencyMS: latencyMS,
                    metadata: httpMetadata(
                        response: response,
                        data: data,
                        fallbackFromModelID: fallbackFromModelID
                    ).merging([
                        "local.provider": "ollama"
                    ]) { current, _ in current }
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

    private func fallbackLocalGenerateModelID(
        for entry: AIModelRegistryEntry,
        excluding excludedModelIDs: Set<String>
    ) async throws -> String? {
        var request = URLRequest(url: Self.localGenerateAPIURL(for: entry.endpoint, path: "tags"))
        request.httpMethod = "GET"
        request.timeoutInterval = min(Double(entry.timeoutMS) / 1_000, 2)
        let (data, response) = try await httpClient.send(request)
        guard (200..<300).contains(response.statusCode) else {
            return nil
        }

        let tags = try JSONDecoder().decode(LocalGenerateTagsResponse.self, from: data)
        return Self.preferredInstalledModelID(
            from: tags.models,
            excluding: excludedModelIDs
        )
    }

    private static func localGenerateAPIURL(for endpoint: URL, path: String) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.path = "/api/\(path)"
        components?.query = nil
        return components?.url ?? endpoint
    }

    private static func preferredInstalledModelID(
        from models: [LocalGenerateModelTag],
        excluding excludedModelIDs: Set<String>
    ) -> String? {
        let candidates = models
            .filter { model in
                !model.name.isEmpty
                    && !excludedModelIDs.contains(model.name)
                    && !model.name.contains(":cloud")
                    && (model.size ?? 1) > 0
            }
            .map(\.name)

        for prefix in fallbackModelPrefixes {
            if let match = candidates.first(where: { $0 == prefix || $0.hasPrefix("\(prefix):") }) {
                return match
            }
        }

        return candidates.first
    }

    private static let fallbackModelPrefixes = [
        "qwen3",
        "qwen2.5",
        "llama3.1",
        "llama3",
        "mistral",
        "gemma3",
        "gemma2"
    ]

    private func httpMetadata(
        response: HTTPURLResponse,
        data: Data,
        fallbackFromModelID: String?
    ) -> [String: String] {
        var metadata = [
            "http.status": String(response.statusCode),
            "http.bodyPreview": Self.preview(data, maxCharacters: 240)
        ]
        if let fallbackFromModelID {
            metadata["modelFallback.originalModelID"] = fallbackFromModelID
        }
        return metadata
    }

    private static func preview(_ data: Data, maxCharacters: Int) -> String {
        let singleLine = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        guard singleLine.count > maxCharacters else { return singleLine }
        return String(singleLine.prefix(maxCharacters))
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
                "num_predict": Self.maxGeneratedTokens,
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
            let modelPlan = definition.metadata["modelPlanned"] == "true"
                ? [
                    "model_plan=true",
                    "allowed_tools=\(definition.metadata["plan.allowedTools"] ?? "")",
                    "set_text_input_contract=\(definition.metadata["plan.setTextInputContract"] ?? "")",
                    "action_plan_required=true"
                ].joined(separator: " | ")
                : ""

            return [
                "task_type=\(definition.taskType)",
                "app=\(definition.targetApp.appName)",
                "bundle=\(definition.targetApp.bundleIdentifier ?? "unknown")",
                "capability=\(workflow)",
                "entities=\(entities)",
                automation,
                modelPlan
            ]
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        }
        .joined(separator: "\n")
        let context = request.contextSnippets
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(8)
            .joined(separator: "\n")
        let appFinderCatalog = taskIntentAppFinderCatalogJSON(request.appFinderCatalog)

        return [
            "You are Donkey's local task-intent boundary. Return strict JSON only; do not include reasoning.",
            "First decide whether Command is an executable local-app task or a conversation turn.",
            "Executable local-app task means all three are clear: action, destination or target app/item, and enough payload to execute safely.",
            "If Command is a question, greeting, conversation, malformed request, or lacks a real executable payload, do not invent one. Return taskType \"none\", targetAppName \"none\", empty entities and normalizedEntities, confidence 0, needsConfirmation=false, actionPlan.tools=[], and metadata.responseMode=conversation with metadata.assistantResponse containing a brief natural-language reply.",
            "If Command is an executable local task with one ordinary missing detail, set needsConfirmation=true and include missingEntity in metadata.",
            "If Command is executable, choose by capability and target app, not exact wording. Use only the provided task definitions; do not invent task types, unsupported entities, or actions.",
            "For play/listen media requests, treat the turn as executable when a supported play_media capability or media_playback task is available; choose Music or another supported media app, set query to the requested artist/song/album, and do not downgrade it to conversation.",
            "For every media playback request, include metadata.mediaSelection.kind. For explicit playable requests use explicit_song, explicit_album, or explicit_playlist. For vague artist-level media requests such as 'play some <artist>', do media-selection planning before returning JSON: pick one concrete playable song or album by that artist using model knowledge, set query to '<selected title> <artist>', and include metadata.mediaSelection.kind=representative_song or representative_album, metadata.mediaSelection.seed=<artist>, metadata.mediaSelection.selectedTitle=<title>, and metadata.mediaSelection.reason. Do not use an artist-only query unless the user explicitly asks to open the artist page, play an artist radio/station, or browse the artist.",
            "If visible search results are provided in context for a media request, choose the highest-confidence playable Song row whose artist matches the requested seed; skip Artist, Playlist, category, and different-artist rows.",
            "If no capability fits, choose conversation with taskType \"none\" and a helpful metadata.assistantResponse rather than a failed local-action message.",
            "For dynamic local-item capabilities, app/file/folder names may come from the request, relevant local cache, or default-app inference; the catalog will verify availability before execution.",
            "For write/create document requests: if the requested content is malformed or not meaningful enough to type, choose conversation; do not fabricate a document payload just to make the task executable.",
            "For local_app_interaction, select the most likely local app for the user's goal, set entities.goal, and when text must be entered set entities.query plus normalizedEntities.query.",
            "For local_app_interaction, fill actionPlan.tools with allowed tools only: app.openOrFocus, app.observe, ui.newDocument, ui.focusSearch, ui.focusAddressBar, ui.focusTextEntry, ui.setText, ui.pressReturn, app.verifyCommand, app.verifyVisibleText.",
            "For website navigation, choose Safari or the user's browser, set query to the URL, use ui.focusAddressBar with controlID=addressBar and focusKey=Command+L, then ui.setText and ui.pressReturn.",
            "For writing in Notes, choose Notes, create the requested prose in query, and use ui.newDocument followed by ui.setText.",
            "For generative writing requests, query must be the complete final text to type, not a single category label, restatement of the request, or placeholder copied from these instructions.",
            "If the writing type is clear but topic/details are sparse, compose a short generic piece that satisfies the requested writing type and put that complete text in query.",
            "For spreadsheet or table creation, choose Numbers, put compact tab-separated table content in query, and use ui.newDocument followed by ui.setText. If exact live data is unavailable, make a table-shaped brief with a data-needed note; do not output a single sentence.",
            "When ui.setText is present, entities.query and normalizedEntities.query must be non-empty.",
            "If you cannot produce non-empty text for ui.setText, choose conversation; never return ui.setText with an empty query.",
            "For sparse writing requests such as 'write a [form] in Notes', infer the requested form and write a short finished piece. If the requested object is malformed or nonsensical, choose conversation.",
            "Example malformed writing boundary: 'write a people in Notes' is not a meaningful writing form or payload, so choose conversation rather than writing a definition.",
            "entities.appName must be the human app name, such as Safari, Notes, Numbers, or Music; do not put a bundle identifier in appName.",
            "For local_app_interaction, set actionPlan.inputEntity to query when ui.setText should type the query, and set actionPlan.controlID/focusKey for the UI control strategy.",
            "actionPlan must be one nested object containing tools, inputEntity, controlID, focusKey, and verification. Do not put inputEntity, controlID, focusKey, or verification at the top level.",
            "The examples below show output structure only. Replace every example entity value with values inferred from Command and local cache; do not copy example query text unless the user asked for that exact text.",
            "Media playback output shape when media_playback is provided: taskType=media_playback, targetAppName=Music, entities.query=<concrete playable title plus artist>, normalizedEntities.query=<concrete playable title plus artist>, metadata.mediaSelection.* when the user gave only an artist/genre/seed.",
            "Media playback output shape for generic local_app_interaction: targetAppName=Music, entities.appName=Music, entities.goal=play media, entities.query=<concrete playable title plus artist>, actionPlan.tools=[app.openOrFocus, app.observe, ui.focusSearch, ui.setText, ui.pressReturn, app.verifyCommand], inputEntity=query, controlID=search, focusKey=Command+F, metadata.appFinder.selectedCapabilityID=play_media when selected from the app finder catalog, metadata.mediaSelection.* when the user gave only an artist/genre/seed.",
            "Example vague artist request output shape: {\"taskType\":\"local_app_interaction\",\"targetAppName\":\"Music\",\"entities\":{\"appName\":\"Music\",\"goal\":\"play media\",\"query\":\"Viva La Vida Coldplay\"},\"normalizedEntities\":{\"appName\":\"Music\",\"goal\":\"play media\",\"query\":\"Viva La Vida Coldplay\"},\"confidence\":0.9,\"needsConfirmation\":false,\"actionPlan\":{\"tools\":[\"app.openOrFocus\",\"app.observe\",\"ui.focusSearch\",\"ui.setText\",\"ui.pressReturn\",\"app.verifyCommand\"],\"inputEntity\":\"query\",\"controlID\":\"search\",\"focusKey\":\"Command+F\",\"verification\":\"commandAttempted\"},\"metadata\":{\"appFinder.selectedCapabilityID\":\"play_media\",\"mediaSelection.kind\":\"representative_song\",\"mediaSelection.seed\":\"Coldplay\",\"mediaSelection.selectedTitle\":\"Viva La Vida\",\"mediaSelection.reason\":\"User asked for some Coldplay, so choose a concrete well-known song instead of an artist-only search.\"}}",
            "Example website output shape: {\"taskType\":\"local_app_interaction\",\"targetAppName\":\"Safari\",\"entities\":{\"appName\":\"Safari\",\"goal\":\"open requested website\",\"query\":\"https://example.org\"},\"normalizedEntities\":{\"appName\":\"Safari\",\"goal\":\"open requested website\",\"query\":\"https://example.org\"},\"confidence\":0.9,\"needsConfirmation\":false,\"actionPlan\":{\"tools\":[\"app.openOrFocus\",\"app.observe\",\"ui.focusAddressBar\",\"ui.setText\",\"ui.pressReturn\",\"app.verifyCommand\"],\"inputEntity\":\"query\",\"controlID\":\"addressBar\",\"focusKey\":\"Command+L\",\"verification\":\"commandAttempted\"},\"metadata\":{}}",
            "Writing output shape: targetAppName=Notes, entities.appName=Notes, entities.goal=write requested text, entities.query=<the actual final text to type>, actionPlan.tools=[app.openOrFocus, app.observe, ui.newDocument, ui.setText, app.verifyCommand], inputEntity=query, controlID=editor.",
            "Table output shape: targetAppName=Numbers, entities.appName=Numbers, entities.goal=create requested table, entities.query=<tab-separated rows for the requested table>, actionPlan.tools=[app.openOrFocus, app.observe, ui.newDocument, ui.setText, app.verifyCommand], inputEntity=query, controlID=editor.",
            "Conversation output shape: {\"taskType\":\"none\",\"targetAppName\":\"none\",\"entities\":{},\"normalizedEntities\":{},\"confidence\":0,\"needsConfirmation\":false,\"actionPlan\":{\"tools\":[],\"inputEntity\":\"\",\"controlID\":\"\",\"focusKey\":\"\",\"verification\":\"commandAttempted\"},\"metadata\":{\"responseMode\":\"conversation\",\"assistantResponse\":\"Hi! What would you like to work on?\"}}",
            "Example malformed request output shape: {\"taskType\":\"none\",\"targetAppName\":\"none\",\"entities\":{},\"normalizedEntities\":{},\"confidence\":0,\"needsConfirmation\":false,\"actionPlan\":{\"tools\":[],\"inputEntity\":\"\",\"controlID\":\"\",\"focusKey\":\"\",\"verification\":\"commandAttempted\"},\"metadata\":{\"responseMode\":\"conversation\",\"assistantResponse\":\"I can help, but I need a clearer thing to write before opening an app.\"}}",
            "For every other task type, actionPlan.tools must be empty.",
            "For AppleScript-backed capabilities, include compact appleScript.source or appleScript.template metadata only when the provided action is insufficient; prefer task metadata and normalized entities for speed.",
            "App finder catalog entries are installed local apps with descriptions, support status, capabilities, and control profiles.",
            "When App finder catalog JSON is non-empty and you use local_app_interaction, choose the target app only from a catalog entry with supportStatus=supported and a matching capability.",
            "For local_app_interaction with an app finder choice, set targetAppName and entities.appName to the catalog appName, set metadata.appFinder.selectedAppID to the exact catalog appID, metadata.appFinder.selectedCapabilityID to the chosen capability id, and metadata.appFinder.controlProfile to one control profile from that capability.",
            "Never select catalog entries with supportStatus=candidate, unsupported, or denied for execution; if no supported app capability fits, choose conversation.",
            "Command: \(request.command)",
            "Relevant local cache:",
            context,
            "App finder catalog JSON:",
            appFinderCatalog,
            "Supported task capabilities:",
            tasks
        ]
        .joined(separator: "\n")
    }

    private static let maxGeneratedTokens = 512

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

public struct HostedTaskIntentParsingAdapter: TaskIntentParsingAdapter {
    public static let schemaID = "generic_harness_planning"

    public var router: AIModelRouter
    public var configuration: DonkeyBackendInferenceConfiguration?
    public var httpClient: any AIHTTPClient
    public var environment: [String: String]

    public init(
        router: AIModelRouter = AIModelRouter(registry: .defaultHybridPlanner),
        configuration: DonkeyBackendInferenceConfiguration? = nil,
        httpClient: any AIHTTPClient = URLSessionAIHTTPClient(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.router = router
        self.configuration = configuration
        self.httpClient = httpClient
        self.environment = environment
    }

    public func parseTaskIntent(
        _ request: TaskIntentAdapterRequest
    ) async -> TaskIntentAdapterResult {
        let entry: AIModelRegistryEntry
        do {
            entry = try router.route(request.routeRequest.limitingProviders([.donkeyBackend]))
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

        let backend: DonkeyBackendInferenceClient
        do {
            backend = DonkeyBackendInferenceClient(
                configuration: try configuration ?? DonkeyBackendInferenceConfiguration.fromEnvironment(environment),
                httpClient: httpClient
            )
        } catch {
            return result(
                entry: entry,
                request: request,
                status: .missingCredentials,
                validationStatus: "notValidated",
                latencyMS: nil,
                metadata: [
                    "credential": DonkeyBackendInferenceConfiguration.baseURLConfigurationDescription,
                    "error": String(describing: error)
                ]
            )
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            let response = try await backend.createResponse(
                responseRequest(entry: entry, adapterRequest: request)
            )
            let latencyMS = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            guard let outputText = Self.outputText(from: response) else {
                return result(
                    entry: entry,
                    request: request,
                    status: .invalidOutput,
                    validationStatus: "invalid",
                    latencyMS: latencyMS,
                    metadata: ["modelOutput.empty": "true"]
                )
            }

            guard let intent = try TaskIntentWireCodec.decodeHostedPlanningIntent(
                outputText,
                definitions: request.taskDefinitions,
                originalCommand: request.command,
                appFinderCatalog: request.appFinderCatalog,
                sourceModelCallID: "model-call-\(request.sourceTraceID)",
                parserName: "hosted-responses-v1",
                parserSource: .onlineModel
            ) else {
                let baseMetadata = Self.outputDiagnostics(for: outputText)
                    .merging([
                        "provider": "donkeyBackend",
                        "privacy.store": "false"
                    ]) { current, _ in current }
                guard let noTaskMetadata = try? TaskIntentWireCodec.hostedPlanningNoTaskMetadata(
                    outputText,
                    parserName: "hosted-responses-v1"
                ) else {
                    return result(
                        entry: entry,
                        request: request,
                        status: .invalidOutput,
                        validationStatus: "invalid",
                        latencyMS: latencyMS,
                        metadata: baseMetadata
                    )
                }
                return result(
                    entry: entry,
                    request: request,
                    status: .completed,
                    validationStatus: "noTaskIntent",
                    latencyMS: latencyMS,
                    metadata: baseMetadata.merging(noTaskMetadata) { _, new in new }
                )
            }

            return TaskIntentAdapterResult(
                intent: intent,
                trace: trace(
                    entry: entry,
                    request: request,
                    status: .completed,
                    validationStatus: "schemaDecoded",
                    latencyMS: latencyMS,
                    metadata: Self.outputDiagnostics(for: outputText).merging([
                        "provider": "donkeyBackend",
                        "privacy.store": "false"
                    ]) { current, _ in current }
                )
            )
        } catch is CancellationError {
            return result(entry: entry, request: request, status: .cancelled, validationStatus: "notValidated", latencyMS: nil)
        } catch {
            let latencyMS = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            let status = Self.status(for: error)
            return result(
                entry: entry,
                request: request,
                status: status,
                validationStatus: "notValidated",
                latencyMS: latencyMS,
                metadata: Self.errorMetadata(error)
            )
        }
    }

    private func responseRequest(
        entry: AIModelRegistryEntry,
        adapterRequest: TaskIntentAdapterRequest
    ) -> RemoteInferenceResponseCreateRequest {
        RemoteInferenceResponseCreateRequest(
            input: .array([
                .object([
                    "role": .string("user"),
                    "content": .array([
                        .object([
                            "type": .string("input_text"),
                            "text": .string(promptText(for: adapterRequest))
                        ])
                    ])
                ])
            ]),
            store: false,
            text: [
                "format": .object([
                    "type": .string("json_schema"),
                    "name": .string(Self.schemaID),
                    "strict": .bool(true),
                    "schema": Self.jsonValue(TaskIntentWireCodec.genericHarnessPlanningJsonSchema(taskDefinitions: adapterRequest.taskDefinitions))
                ])
            ],
            metadata: [
                "source_trace_id": adapterRequest.sourceTraceID,
                "prompt_version": entry.promptVersion
            ],
            parameters: [
                "instructions": .string(Self.instructions),
                "temperature": .number(0)
            ]
        )
    }

    private func promptText(for request: TaskIntentAdapterRequest) -> String {
        let definitions = (try? JSONEncoder().encode(request.taskDefinitions))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let appFinderCatalog = taskIntentAppFinderCatalogJSON(request.appFinderCatalog)
        return [
            "Command: \(request.command)",
            "Relevant local cache:",
            request.contextSnippets.joined(separator: "\n"),
            "App finder catalog JSON:",
            appFinderCatalog,
            "Supported task definitions JSON:",
            definitions
        ].joined(separator: "\n")
    }

    private static let instructions = [
        "Decide whether the user is asking Donkey to run one of the provided local app task definitions.",
        "Return strict JSON only using the generic harness planning schema.",
        "First decide whether Command is an executable local-app task or a conversation turn.",
        "Executable local-app task means all three are clear: action, destination or target app/item, and enough payload to execute safely.",
        "Always fill structuredIntent, ambiguityRisk, contextNeeds, planSteps, verificationCriteria, fallbacks, clarificationPolicy, and metadata.",
        "If Command is a greeting, conversation, question, malformed request, or lacks a real executable payload, set structuredIntent.route conversation, taskType \"none\", targetAppName \"none\", empty entities and normalizedEntities, confidence 0, needsConfirmation false, no planSteps with toolName values, and metadata.responseMode \"conversation\" with metadata.assistantResponse containing a brief natural-language reply.",
        "For supported actions, set structuredIntent.route localAppTask, choose only a provided taskType and target app, and fill entities and normalizedEntities with the concrete values needed by required entity rules.",
        "Use the generic local_app_interaction task type for executable local app requests that need a model-planned app workflow and do not have a more specific provided task type.",
        "Use ambiguityRisk for safe, recoverable, or dangerous ambiguity. Dangerous ambiguity and missing required details must set structuredIntent.needsConfirmation true, ambiguityRisk.shouldAskBeforeActing true, and clarificationPolicy.shouldAsk true with a specific question.",
        "Use contextNeeds for app lookup, memory lookup, screen observation, element discovery, or skill lookup needed before or during execution.",
        "Use planSteps for the generic harness plan. Each executable step must name one allowed toolName, with inputEntity/controlID/focusKey filled when that tool needs them. Non-executable reasoning steps should use an empty toolName.",
        "Use verificationCriteria for what proves success, fallbacks for safe recovery choices, and clarificationPolicy for when Donkey should stop and ask.",
        "For play/listen media requests, treat the turn as executable when a supported play_media capability or media_playback task is available; choose Music or another supported media app, set query to the requested artist/song/album, and do not downgrade it to conversation.",
        "For every media playback request, include metadata.mediaSelection.kind. For explicit playable requests use explicit_song, explicit_album, or explicit_playlist. For vague artist-level media requests such as 'play some <artist>', do media-selection planning before returning JSON: pick one concrete playable song or album by that artist using model knowledge, set query to '<selected title> <artist>', and include metadata.mediaSelection.kind=representative_song or representative_album, metadata.mediaSelection.seed=<artist>, metadata.mediaSelection.selectedTitle=<title>, and metadata.mediaSelection.reason. Do not use an artist-only query unless the user explicitly asks to open the artist page, play an artist radio/station, or browse the artist.",
        "If visible search results are provided in context for a media request, choose the highest-confidence playable Song row whose artist matches the requested seed; skip Artist, Playlist, category, and different-artist rows.",
        "When App finder catalog JSON is non-empty and you use local_app_interaction, choose the target app only from a catalog entry with supportStatus supported and a matching capability. Set metadata.appFinder.selectedAppID to the exact appID, metadata.appFinder.selectedCapabilityID to the capability id, and metadata.appFinder.controlProfile to one declared control profile. Never select candidate, unsupported, or denied entries for execution.",
        "For local_app_interaction, select the most likely local app, set targetAppName and entities.appName to the human app name, set entities.goal, and when text must be entered set entities.query plus normalizedEntities.query.",
        "For local_app_interaction, fill planSteps with allowed toolName values only: app.openOrFocus, app.observe, ui.newDocument, ui.focusSearch, ui.focusAddressBar, ui.focusTextEntry, ui.setText, ui.pressReturn, app.verifyCommand, app.verifyVisibleText.",
        "When ui.setText is present, entities.query and normalizedEntities.query must be non-empty, the step inputEntity should usually be query, and controlID/focusKey should describe the guarded UI strategy.",
        "For media playback when media_playback is provided, use taskType=media_playback, targetAppName=Music, entities.query=<concrete playable title plus artist>, normalizedEntities.query=<concrete playable title plus artist>, and metadata.mediaSelection.* when the user gave only an artist/genre/seed.",
        "For media playback through generic local_app_interaction, targetAppName=Music, entities.appName=Music, entities.goal=play media, entities.query=<concrete playable title plus artist>, planSteps should use app.openOrFocus, app.observe, ui.focusSearch, ui.setText, ui.pressReturn, app.verifyCommand with inputEntity=query, controlID=search, focusKey=Command+F, metadata.appFinder.selectedCapabilityID=play_media when selected from the app finder catalog, and metadata.mediaSelection.* when the user gave only an artist/genre/seed.",
        "For website navigation, choose Safari or the user's browser, set query to the URL, and use planSteps for ui.focusAddressBar, ui.setText, ui.pressReturn, app.verifyCommand.",
        "For writing in Notes, choose Notes, make query the complete text to type, and use planSteps for ui.newDocument, ui.setText, app.verifyCommand.",
        "For spreadsheet or table creation, choose Numbers, put compact tab-separated table content in query, and use planSteps for ui.newDocument, ui.setText, app.verifyCommand.",
        "For every other task type, planSteps should not contain executable toolName values.",
        "If no supported capability fits, set structuredIntent.route conversation and taskType \"none\" with a helpful conversational assistantResponse rather than a generic local-action failure.",
        "Do not invent task types, unsupported entities, unsupported tools, app scripts, or direct input outside the schema."
    ].joined(separator: " ")

    private static func outputDiagnostics(for outputText: String) -> [String: String] {
        let trimmed = outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ["modelOutput.empty": "true"]
        }
        return [
            "modelOutput.empty": "false",
            "modelOutput.preview": preview(trimmed, maxCharacters: 240)
        ]
    }

    private static func outputText(from value: RemoteInferenceJSONValue) -> String? {
        if let outputText = value.objectValue?["output_text"]?.stringValue,
           !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return outputText
        }

        guard let output = value.objectValue?["output"]?.arrayValue else {
            return nil
        }
        for item in output {
            guard let content = item.objectValue?["content"]?.arrayValue else { continue }
            for contentItem in content {
                guard contentItem.objectValue?["type"]?.stringValue == "output_text",
                      let text = contentItem.objectValue?["text"]?.stringValue,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    continue
                }
                return text
            }
        }
        return nil
    }

    private static func status(for error: Error) -> AIModelCallStatus {
        if case DonkeyBackendInferenceClientError.httpStatus(let status, _) = error {
            if status == 429 { return .rateLimited }
            if status >= 500 { return .providerOutage }
            return .invalidOutput
        }
        return (error as NSError).code == NSURLErrorTimedOut ? .timeout : .providerOutage
    }

    private static func errorMetadata(_ error: Error) -> [String: String] {
        if case DonkeyBackendInferenceClientError.httpStatus(let status, let message) = error {
            return [
                "http.status": String(status),
                "http.bodyPreview": preview(message, maxCharacters: 240)
            ]
        }
        return ["error": String(describing: error)]
    }

    private static func preview(_ value: String, maxCharacters: Int) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        guard singleLine.count > maxCharacters else { return singleLine }
        return String(singleLine.prefix(maxCharacters))
    }

    private static func jsonValue(_ value: Any) -> RemoteInferenceJSONValue {
        switch value {
        case let string as String:
            return .string(string)
        case let bool as Bool:
            return .bool(bool)
        case let int as Int:
            return .number(Double(int))
        case let double as Double:
            return .number(double)
        case let array as [Any]:
            return .array(array.map(jsonValue))
        case let object as [String: Any]:
            return .object(object.mapValues(jsonValue))
        default:
            return .null
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
            provider: entry?.provider ?? .donkeyBackend,
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
        adapter: any TaskIntentParsingAdapter = HostedTaskIntentParsingAdapter()
    ) {
        self.catalog = catalog
        self.adapter = adapter
    }

    public func resolve(
        command: String,
        contextSnippets: [String] = [],
        sourceTraceID: String
    ) async -> (resolution: LocalAppTaskCatalogResolution, trace: AIModelCallTrace) {
        let request = TaskIntentAdapterRequest(
            command: command,
            taskDefinitions: catalog.taskDefinitions,
            contextSnippets: contextSnippets,
            appFinderCatalog: catalog.appFinderCatalogEntries(),
            sourceTraceID: sourceTraceID
        )
        let result = await adapter.parseTaskIntent(request)

        guard let intent = result.intent else {
            let unavailableReason = result.trace.provider == .donkeyBackend
                ? "hostedModelIntentUnavailable"
                : "localModelIntentUnavailable"
            var metadata = [
                "reason": unavailableReason,
                "modelCallStatus": result.trace.status.rawValue,
                "modelValidationStatus": result.trace.validationStatus
            ]
            if result.trace.validationStatus == "noTaskIntent" {
                metadata["reason"] = "noSupportedTaskIntent"
                metadata["responseMode"] = "conversation"
                metadata["assistantResponse"] = TaskIntentWireCodec.defaultConversationAssistantResponse
            }
            for key in ["responseMode", "assistantResponse"] {
                if let value = result.trace.metadata[key], !value.isEmpty {
                    metadata[key] = value
                }
            }
            for key in [
                "reason",
                "detail",
                "error",
                "backend.provider",
                "http.status",
                "http.bodyPreview",
                "modelOutput.empty",
                "modelOutput.preview",
                "sidecar.outputPreview",
                "fallback.status",
                "fallback.validation",
                "fallback.reason",
                "fallback.http.status",
                "fallback.http.bodyPreview",
                "fallback.modelFallback.selectedModelID",
                "provider",
                "privacy.store"
            ] {
                if let value = result.trace.metadata[key], !value.isEmpty {
                    metadata["model.\(key)"] = value
                }
            }
            return (
                LocalAppTaskCatalogResolution(
                    status: .needsConfirmation,
                    metadata: metadata
                ),
                result.trace
            )
        }

        return (catalog.resolve(intent: intent), result.trace)
    }
}

private struct LocalGenerateTaskIntentResponse: Decodable {
    var response: String?
}

private struct LocalGenerateTagsResponse: Decodable {
    var models: [LocalGenerateModelTag]
}

private struct LocalGenerateModelTag: Decodable {
    var name: String
    var size: Int64?
}

private func taskIntentAppFinderCatalogJSON(_ entries: [LocalAppFinderCatalogEntry]) -> String {
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

private enum TaskIntentWireCodec {
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

private extension LocalGenerateTaskIntentAdapter {
    static func outputText(from data: Data) throws -> String? {
        try JSONDecoder().decode(LocalGenerateTaskIntentResponse.self, from: data).response
    }
}

private extension RemoteInferenceJSONValue {
    var objectValue: [String: RemoteInferenceJSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }

    var arrayValue: [RemoteInferenceJSONValue]? {
        if case .array(let value) = self {
            return value
        }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }
}
