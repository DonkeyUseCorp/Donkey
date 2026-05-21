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
            throw OpenAIPlannerHintAdapterError.invalidHTTPResponse
        }
        return (data, httpResponse)
    }
}

public enum OpenAIPlannerHintAdapterError: Error, Equatable, Sendable {
    case invalidHTTPResponse
}

public struct OpenAIPlannerHintAdapter: Sendable {
    public static let schemaID = "planner_hint_v1"

    public var router: AIModelRouter
    public var httpClient: any AIHTTPClient
    public var environment: [String: String]
    public var memoryStore: SQLiteAgentMemoryStore?

    public init(
        router: AIModelRouter = AIModelRouter(),
        httpClient: any AIHTTPClient = URLSessionAIHTTPClient(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        memoryStore: SQLiteAgentMemoryStore? = .shared
    ) {
        self.router = router
        self.httpClient = httpClient
        self.environment = environment
        self.memoryStore = memoryStore
    }

    public func generatePlannerHint(
        _ request: PlannerHintAdapterRequest
    ) async -> PlannerHintAdapterResult {
        let entry: AIModelRegistryEntry
        do {
            entry = try router.route(request.routeRequest.limitingProviders([.openAI]))
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

        guard let apiKey = environment["OPENAI_API_KEY"], !apiKey.isEmpty else {
            return result(
                entry: entry,
                request: request,
                status: .missingCredentials,
                validationStatus: "notValidated",
                latencyMS: nil,
                metadata: ["credential": "OPENAI_API_KEY"]
            )
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            let urlRequest = try makeURLRequest(
                entry: entry,
                adapterRequest: request,
                apiKey: apiKey
            )
            let (data, response) = try await httpClient.send(urlRequest)
            let latencyMS = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000

            if response.statusCode == 429 {
                return result(entry: entry, request: request, status: .rateLimited, validationStatus: "notValidated", latencyMS: latencyMS)
            }

            if response.statusCode >= 500 {
                return result(entry: entry, request: request, status: .providerOutage, validationStatus: "notValidated", latencyMS: latencyMS)
            }

            guard (200..<300).contains(response.statusCode),
                  let outputText = try Self.outputText(from: data)
            else {
                return result(entry: entry, request: request, status: .invalidOutput, validationStatus: "invalid", latencyMS: latencyMS)
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
                        "http.status": String(response.statusCode),
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
        adapterRequest: PlannerHintAdapterRequest,
        apiKey: String
    ) throws -> URLRequest {
        var request = URLRequest(url: entry.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Double(entry.timeoutMS) / 1_000
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(entry: entry, adapterRequest: adapterRequest))
        return request
    }

    private func requestBody(
        entry: AIModelRegistryEntry,
        adapterRequest: PlannerHintAdapterRequest
    ) -> [String: Any] {
        [
            "model": entry.modelID,
            "store": false,
            "instructions": "Return strict JSON with a planner hint and memoryWriteProposals. Hints are advisory and never direct input. Leave memoryWriteProposals empty unless a source-linked target memory should be proposed.",
            "input": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": promptText(for: adapterRequest)
                        ]
                    ]
                ]
            ],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": Self.schemaID,
                    "strict": true,
                    "schema": plannerHintJSONSchema()
                ]
            ],
            "metadata": [
                "source_trace_id": adapterRequest.sourceTraceID,
                "prompt_version": entry.promptVersion
            ]
        ]
    }

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
            provider: entry?.provider ?? request.routeRequest.allowedProviders?.first ?? .openAI,
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
}

private struct OpenAIResponseEnvelope: Decodable {
    var id: String?
    var outputText: String?
    var output: [OpenAIResponseOutput]?

    enum CodingKeys: String, CodingKey {
        case id
        case outputText = "output_text"
        case output
    }
}

private struct OpenAIResponseOutput: Decodable {
    var content: [OpenAIResponseContent]?
}

private struct OpenAIResponseContent: Decodable {
    var type: String?
    var text: String?
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

private extension OpenAIPlannerHintAdapter {
    static func outputText(from data: Data) throws -> String? {
        let envelope = try JSONDecoder().decode(OpenAIResponseEnvelope.self, from: data)
        if let outputText = envelope.outputText {
            return outputText
        }

        return envelope.output?
            .flatMap { $0.content ?? [] }
            .first { $0.type == "output_text" }?
            .text
    }

    static func decodeHint(
        _ text: String,
        sourceTraceID: String,
        sourceFrameID: String?,
        sourceStateID: String?,
        modelCallID: String,
        now: RunTraceTimestamp
    ) throws -> StructuredPlannerHint? {
        try PlannerHintWireCodec.decodeHint(
            text,
            sourceTraceID: sourceTraceID,
            sourceFrameID: sourceFrameID,
            sourceStateID: sourceStateID,
            modelCallID: modelCallID,
            now: now
        )
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
