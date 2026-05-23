import DonkeyContracts
import DonkeyRuntime
import Foundation

public struct PointerPromptFollowUpCandidate: Codable, Equatable, Sendable {
    public var taskID: String
    public var title: String
    public var detail: String
    public var commandText: String
    public var status: PointerPromptTaskStatus
    public var updatedAt: Date
    public var recentEvents: [String]
    public var assetNames: [String]

    public init(
        taskID: String,
        title: String,
        detail: String,
        commandText: String,
        status: PointerPromptTaskStatus,
        updatedAt: Date,
        recentEvents: [String] = [],
        assetNames: [String] = []
    ) {
        self.taskID = taskID
        self.title = title
        self.detail = detail
        self.commandText = commandText
        self.status = status
        self.updatedAt = updatedAt
        self.recentEvents = recentEvents
        self.assetNames = assetNames
    }
}

public struct PointerPromptFollowUpResolverRequest: Equatable, Sendable {
    public var text: String
    public var candidates: [PointerPromptFollowUpCandidate]
    public var sourceTraceID: String
    public var routeRequest: AIModelRouteRequest

    public init(
        text: String,
        candidates: [PointerPromptFollowUpCandidate],
        sourceTraceID: String,
        routeRequest: AIModelRouteRequest = AIModelRouteRequest(
            jobType: .taskIntent,
            privacyMode: .privacySensitive,
            latencyTolerance: .interactive
        )
    ) {
        self.text = text
        self.candidates = candidates
        self.sourceTraceID = sourceTraceID
        self.routeRequest = routeRequest
    }
}

public struct PointerPromptFollowUpResolverResult: Equatable, Sendable {
    public var taskID: String?
    public var confidence: Double
    public var reason: String
    public var trace: AIModelCallTrace

    public init(taskID: String?, confidence: Double, reason: String, trace: AIModelCallTrace) {
        self.taskID = taskID
        self.confidence = confidence
        self.reason = reason
        self.trace = trace
    }
}

public protocol PointerPromptFollowUpResolving: Sendable {
    func resolveFollowUp(_ request: PointerPromptFollowUpResolverRequest) async -> PointerPromptFollowUpResolverResult
}

public struct ProcessBackedLocalLLMTaskFollowUpResolver: PointerPromptFollowUpResolving {
    public static let schemaID = "task_followup_resolution_v1"

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

    public func resolveFollowUp(
        _ request: PointerPromptFollowUpResolverRequest
    ) async -> PointerPromptFollowUpResolverResult {
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

        let input = LocalLLMTaskFollowUpSidecarRequest(
            command: request.text,
            candidates: request.candidates,
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
        let sidecarResult = await sidecarRunner.run(
            LocalJSONSidecarRequest(
                environmentVariableName: "DONKEY_LOCAL_LLM_RUNNER",
                inputData: (try? encoder.encode(input)) ?? Data(),
                timeoutMS: entry.timeoutMS,
                metadata: [
                    "sidecar.role": "taskFollowUpResolution",
                    "modelID": entry.modelID
                ]
            )
        )

        guard sidecarResult.status == .completed else {
            return result(
                entry: entry,
                request: request,
                status: sidecarResult.status == .timedOut ? .timeout : .providerOutage,
                validationStatus: "notValidated",
                latencyMS: sidecarResult.latencyMS,
                metadata: sidecarResult.metadata.merging([
                    "sidecar.stderr": sidecarResult.stderrText
                ]) { current, _ in current }
            )
        }

        do {
            let response = try decoder.decode(LocalLLMTaskFollowUpSidecarResponse.self, from: sidecarResult.outputData)
            let decisionData = Data(response.outputText.utf8)
            let decision = try decoder.decode(LocalLLMTaskFollowUpDecision.self, from: decisionData)
            let validCandidateIDs = Set(request.candidates.map(\.taskID))
            let taskID = decision.isFollowUp && validCandidateIDs.contains(decision.taskID) ? decision.taskID : nil
            return PointerPromptFollowUpResolverResult(
                taskID: taskID,
                confidence: min(max(decision.confidence, 0), 1),
                reason: decision.reason,
                trace: trace(
                    entry: entry,
                    request: request,
                    status: .completed,
                    validationStatus: taskID == nil ? "newTask" : "matchedTask",
                    latencyMS: sidecarResult.latencyMS,
                    metadata: sidecarResult.metadata.merging(response.metadata) { current, _ in current }
                )
            )
        } catch {
            return result(
                entry: entry,
                request: request,
                status: .invalidOutput,
                validationStatus: "invalid",
                latencyMS: sidecarResult.latencyMS,
                metadata: sidecarResult.metadata.merging([
                    "error": String(describing: error)
                ]) { current, _ in current }
            )
        }
    }

    private func result(
        entry: AIModelRegistryEntry?,
        request: PointerPromptFollowUpResolverRequest,
        status: AIModelCallStatus,
        validationStatus: String,
        latencyMS: Double?,
        metadata: [String: String] = [:]
    ) -> PointerPromptFollowUpResolverResult {
        PointerPromptFollowUpResolverResult(
            taskID: nil,
            confidence: 0,
            reason: metadata["error"] ?? metadata["reason"] ?? "",
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
        request: PointerPromptFollowUpResolverRequest,
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

public struct HostedTaskFollowUpResolver: PointerPromptFollowUpResolving {
    public static let schemaID = "task_followup_resolution_v1"

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

    public func resolveFollowUp(
        _ request: PointerPromptFollowUpResolverRequest
    ) async -> PointerPromptFollowUpResolverResult {
        guard !request.candidates.isEmpty else {
            return result(
                entry: nil,
                request: request,
                status: .completed,
                validationStatus: "noCandidates",
                latencyMS: nil
            )
        }

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
                    "credential": "DONKEY_BACKEND_URL",
                    "error": String(describing: error)
                ]
            )
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            let response = try await backend.createResponse(
                responseRequest(entry: entry, resolverRequest: request)
            )
            let latencyMS = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            guard let outputText = Self.outputText(from: response),
                  let decisionData = outputText.data(using: .utf8)
            else {
                return result(entry: entry, request: request, status: .invalidOutput, validationStatus: "invalid", latencyMS: latencyMS)
            }

            let decision = try JSONDecoder().decode(LocalLLMTaskFollowUpDecision.self, from: decisionData)
            let validCandidateIDs = Set(request.candidates.map(\.taskID))
            let taskID = decision.isFollowUp && validCandidateIDs.contains(decision.taskID) ? decision.taskID : nil
            return PointerPromptFollowUpResolverResult(
                taskID: taskID,
                confidence: min(max(decision.confidence, 0), 1),
                reason: decision.reason,
                trace: trace(
                    entry: entry,
                    request: request,
                    status: .completed,
                    validationStatus: taskID == nil ? "newTask" : "matchedTask",
                    latencyMS: latencyMS,
                    metadata: [
                        "provider": "donkeyBackend",
                        "privacy.store": "false"
                    ]
                )
            )
        } catch is CancellationError {
            return result(entry: entry, request: request, status: .cancelled, validationStatus: "notValidated", latencyMS: nil)
        } catch {
            let latencyMS = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            return result(
                entry: entry,
                request: request,
                status: Self.status(for: error),
                validationStatus: "notValidated",
                latencyMS: latencyMS,
                metadata: Self.errorMetadata(error)
            )
        }
    }

    private func responseRequest(
        entry: AIModelRegistryEntry,
        resolverRequest request: PointerPromptFollowUpResolverRequest
    ) -> RemoteInferenceResponseCreateRequest {
        let candidates = (try? JSONEncoder().encode(request.candidates))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let prompt = [
            "turn: \(request.text)",
            "candidates: \(candidates)"
        ].joined(separator: "\n")

        return RemoteInferenceResponseCreateRequest(
            input: .array([
                .object([
                    "role": .string("user"),
                    "content": .array([
                        .object([
                            "type": .string("input_text"),
                            "text": .string(prompt)
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
                    "schema": Self.schema(for: request.candidates)
                ])
            ],
            metadata: [
                "source_trace_id": request.sourceTraceID,
                "prompt_version": entry.promptVersion
            ],
            parameters: [
                "instructions": .string(Self.instructions),
                "temperature": .number(0)
            ]
        )
    }

    private static let instructions = "Decide whether the current turn continues one of the candidate Donkey task threads. Return strict JSON only. Set isFollowUp false and taskID empty when the turn should start a new task."

    private static func schema(for candidates: [PointerPromptFollowUpCandidate]) -> RemoteInferenceJSONValue {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array([
                .string("isFollowUp"),
                .string("taskID"),
                .string("confidence"),
                .string("reason")
            ]),
            "properties": .object([
                "isFollowUp": .object(["type": .string("boolean")]),
                "taskID": .object([
                    "type": .string("string"),
                    "enum": .array((candidates.map(\.taskID) + [""]).map(RemoteInferenceJSONValue.string))
                ]),
                "confidence": .object([
                    "type": .string("number"),
                    "minimum": .number(0),
                    "maximum": .number(1)
                ]),
                "reason": .object(["type": .string("string")])
            ])
        ])
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

    private func result(
        entry: AIModelRegistryEntry?,
        request: PointerPromptFollowUpResolverRequest,
        status: AIModelCallStatus,
        validationStatus: String,
        latencyMS: Double?,
        metadata: [String: String] = [:]
    ) -> PointerPromptFollowUpResolverResult {
        PointerPromptFollowUpResolverResult(
            taskID: nil,
            confidence: 0,
            reason: metadata["error"] ?? metadata["reason"] ?? "",
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
        request: PointerPromptFollowUpResolverRequest,
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

private struct LocalLLMTaskFollowUpSidecarRequest: Codable, Equatable, Sendable {
    var command: String
    var candidates: [PointerPromptFollowUpCandidate]
    var sourceTraceID: String
    var modelID: String
    var cacheDirectory: String?
    var metadata: [String: String]
}

private struct LocalLLMTaskFollowUpSidecarResponse: Codable, Equatable, Sendable {
    var outputText: String
    var metadata: [String: String]
}

private struct LocalLLMTaskFollowUpDecision: Codable, Equatable, Sendable {
    var isFollowUp: Bool
    var taskID: String
    var confidence: Double
    var reason: String
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
