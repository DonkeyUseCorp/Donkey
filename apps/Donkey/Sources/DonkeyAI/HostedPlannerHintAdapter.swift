import DonkeyContracts
import DonkeyRuntime
import Foundation

public enum AIModelCallStatus: String, Codable, Equatable, Sendable {
    case completed
    case timeout
    case cancelled
    case rateLimited
    case invalidOutput
    case providerOutage
    case missingCredentials
}

public struct AIModelCallTrace: Codable, Equatable, Sendable {
    public var id: String
    public var role: AIModelRole
    public var provider: AIModelProvider
    public var modelID: String
    public var promptVersion: String
    public var schemaID: String
    public var latencyMS: Double?
    public var timeoutMS: Int
    public var status: AIModelCallStatus
    public var validationStatus: String
    public var sourceTraceID: String
    public var sourceStateID: String?
    public var metadata: [String: String]

    public init(
        id: String,
        role: AIModelRole,
        provider: AIModelProvider,
        modelID: String,
        promptVersion: String,
        schemaID: String,
        latencyMS: Double?,
        timeoutMS: Int,
        status: AIModelCallStatus,
        validationStatus: String,
        sourceTraceID: String,
        sourceStateID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.role = role
        self.provider = provider
        self.modelID = modelID
        self.promptVersion = promptVersion
        self.schemaID = schemaID
        self.latencyMS = latencyMS
        self.timeoutMS = timeoutMS
        self.status = status
        self.validationStatus = validationStatus
        self.sourceTraceID = sourceTraceID
        self.sourceStateID = sourceStateID
        self.metadata = metadata
    }
}

public struct PlannerHintAdapterRequest: Equatable, Sendable {
    public var context: RunContextPackage
    public var sourceTraceID: String
    public var sourceFrameID: String?
    public var sourceStateID: String?
    public var now: RunTraceTimestamp
    public var routeRequest: AIModelRouteRequest

    public init(
        context: RunContextPackage,
        sourceTraceID: String,
        sourceFrameID: String? = nil,
        sourceStateID: String? = nil,
        now: RunTraceTimestamp,
        routeRequest: AIModelRouteRequest = AIModelRouteRequest(jobType: .plannerHint)
    ) {
        self.context = context
        self.sourceTraceID = sourceTraceID
        self.sourceFrameID = sourceFrameID
        self.sourceStateID = sourceStateID
        self.now = now
        self.routeRequest = routeRequest
    }
}

public struct PlannerHintAdapterResult: Equatable, Sendable {
    public var hint: StructuredPlannerHint?
    public var trace: AIModelCallTrace
    public var memoryWriteDecisions: [RunMemoryWriteDecision]

    public init(
        hint: StructuredPlannerHint?,
        trace: AIModelCallTrace,
        memoryWriteDecisions: [RunMemoryWriteDecision] = []
    ) {
        self.hint = hint
        self.trace = trace
        self.memoryWriteDecisions = memoryWriteDecisions
    }
}

public protocol AIHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionAIHTTPClient: AIHTTPClient {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIHTTPClientError.invalidHTTPResponse
        }
        return (data, httpResponse)
    }
}

public enum AIHTTPClientError: Error, Equatable, Sendable {
    case invalidHTTPResponse
}

public struct HostedPlannerHintAdapter: Sendable {
    public static let schemaID = "planner_hint_v1"

    public var router: AIModelRouter
    public var configuration: DonkeyBackendInferenceConfiguration?
    public var httpClient: any AIHTTPClient
    public var environment: [String: String]
    public var memoryStore: SQLiteAgentMemoryStore?

    public init(
        router: AIModelRouter = AIModelRouter(registry: .defaultBackendRoutes),
        configuration: DonkeyBackendInferenceConfiguration? = nil,
        httpClient: any AIHTTPClient = URLSessionAIHTTPClient(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        memoryStore: SQLiteAgentMemoryStore? = .shared
    ) {
        self.router = router
        self.configuration = configuration
        self.httpClient = httpClient
        self.environment = environment
        self.memoryStore = memoryStore
    }

    public func generatePlannerHint(
        _ request: PlannerHintAdapterRequest
    ) async -> PlannerHintAdapterResult {
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
                    latencyMS: latencyMS
                )
            }

            let providerOutput = try PlannerHintWireCodec.decodeProviderOutput(
                outputText,
                sourceTraceID: request.sourceTraceID,
                sourceFrameID: request.sourceFrameID,
                sourceStateID: request.sourceStateID,
                modelCallID: "model-call-\(request.sourceTraceID)",
                now: request.now
            )
            guard let hint = providerOutput.hint else {
                return result(entry: entry, request: request, status: .invalidOutput, validationStatus: "invalid", latencyMS: latencyMS)
            }

            let proposalProcessing = await ProviderDecodedMemoryProposalHandler.process(
                proposals: providerOutput.memoryWriteProposals,
                decidedAt: request.now,
                memoryStore: memoryStore
            )

            return PlannerHintAdapterResult(
                hint: hint,
                trace: trace(
                    entry: entry,
                    request: request,
                    status: .completed,
                    validationStatus: "schemaDecoded",
                    latencyMS: latencyMS,
                    metadata: [
                        "provider": "donkeyBackend",
                        "privacy.store": "false"
                    ]
                    .merging(providerOutput.metadata) { current, _ in current }
                    .merging(proposalProcessing.metadata) { current, _ in current }
                ),
                memoryWriteDecisions: proposalProcessing.decisions
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
        adapterRequest: PlannerHintAdapterRequest
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
                    "schema": Self.jsonValue(plannerHintJSONSchema())
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

    private static let instructions = "Return strict JSON with a planner hint and memoryWriteProposals. Hints are advisory and never direct input. Leave memoryWriteProposals empty unless a source-linked target memory should be proposed."

    private func promptText(for request: PlannerHintAdapterRequest) -> String {
        [
            "goal: \(request.context.userGoal)",
            "target: \(request.context.targetID)",
            "runtime: \(request.context.runtimeProfile)",
            "latest_state: \(request.context.latestWorldState?.summary ?? "none")",
            "source_state_id: \(request.sourceStateID ?? "none")",
            "valid_hints: \(request.context.activeHints.map(\.summary).joined(separator: " | "))",
            "recent_failures: \(request.context.recentFailures.map(\.summary).joined(separator: " | "))",
            "memory: \(memoryText(for: request.context.memorySnapshot))",
            "semantic_memory: \(semanticMemoryText(for: request.context.semanticMemoryResults))"
        ]
        .joined(separator: "\n")
    }

    private func memoryText(for snapshot: RunMemorySnapshot?) -> String {
        guard let snapshot else { return "none" }

        let parts = [
            snapshot.currentGoal.map { "goal=\($0)" },
            snapshot.recentStates.last.map { "latestMemoryState=\($0.summary)" },
            nonEmpty("instructions", snapshot.userInstructions.map(\.value)),
            nonEmpty("safetyStops", snapshot.safetyStops.map(\.value)),
            nonEmpty("target", snapshot.targetRecords.map(\.value))
        ]
        .compactMap { $0 }

        return parts.isEmpty ? "none" : parts.joined(separator: " | ")
    }

    private func nonEmpty(_ label: String, _ values: [String]) -> String? {
        guard !values.isEmpty else { return nil }
        return "\(label)=\(values.joined(separator: "; "))"
    }

    private func semanticMemoryText(for results: [RunMemorySemanticResult]) -> String {
        guard !results.isEmpty else { return "none" }
        return results.map { result in
            "\(result.record.id)(\(String(format: "%.2f", result.relevance))): \(result.record.value)"
        }
        .joined(separator: " | ")
    }

    private func plannerHintJSONSchema() -> [String: Any] {
        PlannerHintWireCodec.jsonSchema()
    }

    private func result(
        entry: AIModelRegistryEntry?,
        request: PlannerHintAdapterRequest,
        status: AIModelCallStatus,
        validationStatus: String,
        latencyMS: Double?,
        metadata: [String: String] = [:]
    ) -> PlannerHintAdapterResult {
        PlannerHintAdapterResult(
            hint: nil,
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
        request: PlannerHintAdapterRequest,
        status: AIModelCallStatus,
        validationStatus: String,
        latencyMS: Double?,
        metadata: [String: String] = [:]
    ) -> AIModelCallTrace {
        AIModelCallTrace(
            id: "model-call-\(request.sourceTraceID)",
            role: entry?.role ?? .plannerHint,
            provider: entry?.provider ?? .donkeyBackend,
            modelID: entry?.modelID ?? "unrouted",
            promptVersion: entry?.promptVersion ?? "unrouted",
            schemaID: Self.schemaID,
            latencyMS: latencyMS,
            timeoutMS: entry?.timeoutMS ?? 0,
            status: status,
            validationStatus: validationStatus,
            sourceTraceID: request.sourceTraceID,
            sourceStateID: request.sourceStateID,
            metadata: metadata
        )
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
}

struct PlannerHintWireOutput: Decodable {
    var id: String
    var goal: String
    var policyName: String
    var priorities: [String]
    var preferredActions: [String]
    var avoidActions: [String]
    var confidence: Double
    var expiryMilliseconds: UInt64
}

struct PlannerProviderWireOutput: Equatable, Sendable {
    var hint: StructuredPlannerHint?
    var memoryWriteProposals: [RunMemoryWriteProposal]
    var metadata: [String: String]
}

enum PlannerHintWireCodec {
    static func jsonSchema() -> [String: Any] {
        providerOutputJSONSchema()
    }

    static func providerOutputJSONSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["hint", "memoryWriteProposals"],
            "properties": [
                "hint": hintJSONSchema(),
                "memoryWriteProposals": [
                    "type": "array",
                    "items": memoryWriteProposalJSONSchema()
                ]
            ]
        ]
    }

    static func hintJSONSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["id", "goal", "policyName", "priorities", "preferredActions", "avoidActions", "confidence", "expiryMilliseconds"],
            "properties": [
                "id": ["type": "string"],
                "goal": ["type": "string"],
                "policyName": ["type": "string"],
                "priorities": ["type": "array", "items": ["type": "string"]],
                "preferredActions": ["type": "array", "items": ["type": "string", "enum": HotLoopActionKind.allCases.map(\.rawValue)]],
                "avoidActions": ["type": "array", "items": ["type": "string", "enum": HotLoopActionKind.allCases.map(\.rawValue)]],
                "confidence": ["type": "number"],
                "expiryMilliseconds": ["type": "integer"]
            ]
        ]
    }

    static func decodeProviderOutput(
        _ text: String,
        sourceTraceID: String,
        sourceFrameID: String?,
        sourceStateID: String?,
        modelCallID: String,
        now: RunTraceTimestamp
    ) throws -> PlannerProviderWireOutput {
        guard let data = text.data(using: .utf8) else {
            return PlannerProviderWireOutput(
                hint: nil,
                memoryWriteProposals: [],
                metadata: ["providerOutput.decodeStatus": "invalidUTF8"]
            )
        }

        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let hintObject = object["hint"] {
            let hintData = try JSONSerialization.data(withJSONObject: hintObject)
            let hint = try decodeHintData(
                hintData,
                sourceTraceID: sourceTraceID,
                sourceFrameID: sourceFrameID,
                sourceStateID: sourceStateID,
                modelCallID: modelCallID,
                now: now
            )
            var proposals: [RunMemoryWriteProposal] = []
            var metadata = [
                "providerOutput.shape": "hintWithMemoryProposals",
                "memoryProposal.decodeStatus": "notPresent"
            ]

            if let proposalsObject = object["memoryWriteProposals"] {
                let proposalData = try JSONSerialization.data(withJSONObject: proposalsObject)
                do {
                    proposals = try JSONDecoder().decode([RunMemoryWriteProposal].self, from: proposalData)
                    metadata["memoryProposal.decodeStatus"] = "decoded"
                } catch {
                    metadata["memoryProposal.decodeStatus"] = "invalid"
                    metadata["memoryProposal.decodeError"] = String(describing: error)
                }
            }

            return PlannerProviderWireOutput(
                hint: hint,
                memoryWriteProposals: proposals,
                metadata: metadata
            )
        }

        return PlannerProviderWireOutput(
            hint: try decodeHintData(
                data,
                sourceTraceID: sourceTraceID,
                sourceFrameID: sourceFrameID,
                sourceStateID: sourceStateID,
                modelCallID: modelCallID,
                now: now
            ),
            memoryWriteProposals: [],
            metadata: [
                "providerOutput.shape": "legacyHintOnly",
                "memoryProposal.decodeStatus": "notPresent"
            ]
        )
    }

    static func decodeHint(
        _ text: String,
        sourceTraceID: String,
        sourceFrameID: String?,
        sourceStateID: String?,
        modelCallID: String,
        now: RunTraceTimestamp
    ) throws -> StructuredPlannerHint? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try decodeHintData(
            data,
            sourceTraceID: sourceTraceID,
            sourceFrameID: sourceFrameID,
            sourceStateID: sourceStateID,
            modelCallID: modelCallID,
            now: now
        )
    }

    private static func decodeHintData(
        _ data: Data,
        sourceTraceID: String,
        sourceFrameID: String?,
        sourceStateID: String?,
        modelCallID: String,
        now: RunTraceTimestamp
    ) throws -> StructuredPlannerHint? {
        let wire = try JSONDecoder().decode(PlannerHintWireOutput.self, from: data)
        guard let preferredActions = actions(from: wire.preferredActions),
              let avoidActions = actions(from: wire.avoidActions)
        else {
            return nil
        }

        return StructuredPlannerHint(
            id: wire.id,
            goal: wire.goal,
            policyName: wire.policyName,
            priorities: wire.priorities,
            preferredActions: preferredActions,
            avoidActions: avoidActions,
            confidence: wire.confidence,
            createdAt: now,
            expiresAt: now.addingMilliseconds(wire.expiryMilliseconds),
            sourceTraceID: sourceTraceID,
            sourceFrameID: sourceFrameID,
            sourceStateID: sourceStateID,
            sourceModelCallID: modelCallID
        )
    }

    private static func memoryWriteProposalJSONSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["id", "proposedBy", "record", "rationale"],
            "properties": [
                "id": ["type": "string"],
                "proposedBy": ["type": "string", "enum": RunMemoryAuthor.allCasesRawValues],
                "record": memoryRecordJSONSchema(),
                "rationale": ["type": "string"]
            ]
        ]
    }

    private static func memoryRecordJSONSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": [
                "id",
                "scope",
                "kind",
                "targetID",
                "runID",
                "userID",
                "value",
                "createdAt",
                "expiresAt",
                "durable",
                "source",
                "metadata"
            ],
            "properties": [
                "id": ["type": "string"],
                "scope": ["type": "string", "enum": RunMemoryScope.allCasesRawValues],
                "kind": ["type": "string", "enum": RunMemoryKind.allCasesRawValues],
                "targetID": ["type": ["string", "null"]],
                "runID": ["type": ["string", "null"]],
                "userID": ["type": ["string", "null"]],
                "value": ["type": "string"],
                "createdAt": timestampJSONSchema(),
                "expiresAt": ["anyOf": [timestampJSONSchema(), ["type": "null"]]],
                "durable": ["type": "boolean"],
                "source": memorySourceJSONSchema(),
                "metadata": [
                    "type": "object",
                    "additionalProperties": ["type": "string"]
                ]
            ]
        ]
    }

    private static func memorySourceJSONSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": [
                "traceID",
                "frameID",
                "stateID",
                "actionID",
                "plannerHintID",
                "modelCallID",
                "eventSequence",
                "summary"
            ],
            "properties": [
                "traceID": ["type": ["string", "null"]],
                "frameID": ["type": ["string", "null"]],
                "stateID": ["type": ["string", "null"]],
                "actionID": ["type": ["string", "null"]],
                "plannerHintID": ["type": ["string", "null"]],
                "modelCallID": ["type": ["string", "null"]],
                "eventSequence": ["type": ["integer", "null"]],
                "summary": ["type": "string"]
            ]
        ]
    }

    private static func timestampJSONSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["wallClock", "monotonicUptimeNanoseconds"],
            "properties": [
                "wallClock": ["type": "number"],
                "monotonicUptimeNanoseconds": ["type": "integer"]
            ]
        ]
    }

    private static func actions(from rawValues: [String]) -> [HotLoopActionKind]? {
        var actions: [HotLoopActionKind] = []
        for rawValue in rawValues {
            guard let action = HotLoopActionKind(rawValue: rawValue) else {
                return nil
            }
            actions.append(action)
        }
        return actions
    }
}

private extension RunTraceTimestamp {
    func addingMilliseconds(_ milliseconds: UInt64) -> RunTraceTimestamp {
        RunTraceTimestamp(
            wallClock: wallClock.addingTimeInterval(Double(milliseconds) / 1_000),
            monotonicUptimeNanoseconds: monotonicUptimeNanoseconds + milliseconds * 1_000_000
        )
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

private extension RunMemoryAuthor {
    static var allCasesRawValues: [String] {
        ["deterministicRuntime", "user", "model"]
    }
}

private extension RunMemoryScope {
    static var allCasesRawValues: [String] {
        ["run", "target", "user"]
    }
}

private extension RunMemoryKind {
    static var allCasesRawValues: [String] {
        [
            "currentGoal",
            "activeHint",
            "recentState",
            "failure",
            "userInstruction",
            "safetyStop",
            "targetFact"
        ]
    }
}
