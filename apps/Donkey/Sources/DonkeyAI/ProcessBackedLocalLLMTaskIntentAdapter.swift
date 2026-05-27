import DonkeyContracts
import DonkeyRuntime
import Foundation

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
            skillSnippets: request.skillSnippets,
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
    var skillSnippets: [String]
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
