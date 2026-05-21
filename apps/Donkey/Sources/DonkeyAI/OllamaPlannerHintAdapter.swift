import DonkeyContracts
import DonkeyRuntime
import Foundation

public struct OllamaPlannerHintAdapter: Sendable {
    public static let schemaID = "planner_hint_v1"

    public var router: AIModelRouter
    public var httpClient: any AIHTTPClient
    public var memoryStore: SQLiteAgentMemoryStore?

    public init(
        router: AIModelRouter = AIModelRouter(registry: .defaultHybridPlanner),
        httpClient: any AIHTTPClient = URLSessionAIHTTPClient(),
        memoryStore: SQLiteAgentMemoryStore? = .shared
    ) {
        self.router = router
        self.httpClient = httpClient
        self.memoryStore = memoryStore
    }

    public func generatePlannerHint(
        _ request: PlannerHintAdapterRequest
    ) async -> PlannerHintAdapterResult {
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
                        "local.provider": "ollama"
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
        adapterRequest: PlannerHintAdapterRequest
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
        adapterRequest: PlannerHintAdapterRequest
    ) -> [String: Any] {
        [
            "model": entry.modelID,
            "prompt": promptText(for: adapterRequest),
            "stream": false,
            "format": PlannerHintWireCodec.jsonSchema(),
            "options": [
                "num_predict": 512
            ]
        ]
    }

    private func promptText(for request: PlannerHintAdapterRequest) -> String {
        [
            "Return strict JSON with a planner hint and memoryWriteProposals. Hints are advisory and never direct input.",
            "goal: \(request.context.userGoal)",
            "target: \(request.context.targetID)",
            "runtime: \(request.context.runtimeProfile)",
            "latest_state: \(request.context.latestWorldState?.summary ?? "none")",
            "source_state_id: \(request.sourceStateID ?? "none")",
            "valid_hints: \(request.context.activeHints.map(\.summary).joined(separator: " | "))",
            "recent_failures: \(request.context.recentFailures.map(\.summary).joined(separator: " | "))",
            "semantic_memory: \(semanticMemoryText(for: request.context.semanticMemoryResults))"
        ]
        .joined(separator: "\n")
    }

    private func semanticMemoryText(for results: [RunMemorySemanticResult]) -> String {
        guard !results.isEmpty else { return "none" }
        return results.map { result in
            "\(result.record.id)(\(String(format: "%.2f", result.relevance))): \(result.record.value)"
        }
        .joined(separator: " | ")
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
            provider: entry?.provider ?? .ollama,
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

public struct ProviderBackedSlowPlannerHintGenerator: SlowPlannerHintGenerating {
    public var localAdapter: OllamaPlannerHintAdapter
    public var onlineAdapter: OpenAIPlannerHintAdapter
    public var providerOrder: [AIModelProvider]

    public init(
        localAdapter: OllamaPlannerHintAdapter = OllamaPlannerHintAdapter(),
        onlineAdapter: OpenAIPlannerHintAdapter = OpenAIPlannerHintAdapter(),
        providerOrder: [AIModelProvider] = [.ollama, .openAI]
    ) {
        self.localAdapter = localAdapter
        self.onlineAdapter = onlineAdapter
        self.providerOrder = providerOrder
    }

    public func generatePlannerHint(
        snapshot: SlowPlannerSnapshot
    ) async -> SlowPlannerHintGenerationResult {
        let request = PlannerHintAdapterRequest(
            context: snapshot.context,
            sourceTraceID: snapshot.latestWorldState.traceID,
            sourceFrameID: snapshot.latestWorldState.frameID,
            sourceStateID: snapshot.latestWorldState.id,
            now: snapshot.latestWorldState.observedAt,
            routeRequest: AIModelRouteRequest(
                jobType: .plannerHint,
                privacyMode: .privacySensitive,
                latencyTolerance: .background
            )
        )
        var metadata: [String: String] = [
            "providerOrder": providerOrder.map(\.rawValue).joined(separator: ",")
        ]

        for provider in providerOrder {
            let result: PlannerHintAdapterResult
            switch provider {
            case .localRuntime:
                metadata["\(provider.rawValue).status"] = "unsupportedForPlanner"
                metadata["\(provider.rawValue).validationStatus"] = "notAttempted"
                metadata["lastProvider"] = provider.rawValue
                continue
            case .ollama:
                result = await localAdapter.generatePlannerHint(request)
            case .openAI:
                result = await onlineAdapter.generatePlannerHint(request)
            }

            metadata["\(provider.rawValue).status"] = result.trace.status.rawValue
            metadata["\(provider.rawValue).validationStatus"] = result.trace.validationStatus
            metadata["lastProvider"] = provider.rawValue

            if let hint = result.hint,
               result.trace.status == .completed {
                metadata["selectedProvider"] = provider.rawValue
                metadata["selectedModelID"] = result.trace.modelID
                metadata["selectedModelCallID"] = result.trace.id
                return SlowPlannerHintGenerationResult(hint: hint, metadata: metadata)
            }
        }

        metadata["selectedProvider"] = "none"
        return SlowPlannerHintGenerationResult(hint: nil, metadata: metadata)
    }
}

private struct OllamaGenerateResponse: Decodable {
    var response: String?
}

private extension OllamaPlannerHintAdapter {
    static func outputText(from data: Data) throws -> String? {
        try JSONDecoder().decode(OllamaGenerateResponse.self, from: data).response
    }
}
