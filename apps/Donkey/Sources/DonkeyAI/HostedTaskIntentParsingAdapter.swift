import DonkeyContracts
import DonkeyRuntime
import Foundation

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

            var decodeFailureMetadata: [String: String] = [:]
            do {
                if let intent = try TaskIntentWireCodec.decodeHostedPlanningIntent(
                    outputText,
                    definitions: request.taskDefinitions,
                    originalCommand: request.command,
                    appFinderCatalog: request.appFinderCatalog,
                    sourceModelCallID: "model-call-\(request.sourceTraceID)",
                    parserName: "hosted-responses-v1",
                    parserSource: .onlineModel
                ) {
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
                }
            } catch {
                decodeFailureMetadata = Self.planningDecodeFailureMetadata(error)
            }

            let baseMetadata = Self.outputDiagnostics(for: outputText)
                .merging([
                    "provider": "donkeyBackend",
                    "privacy.store": "false"
                ]) { current, _ in current }
                .merging(decodeFailureMetadata) { current, _ in current }
            if let noTaskMetadata = try? TaskIntentWireCodec.hostedPlanningNoTaskMetadata(
                outputText,
                parserName: "hosted-responses-v1"
            ) {
                return result(
                    entry: entry,
                    request: request,
                    status: .completed,
                    validationStatus: "noTaskIntent",
                    latencyMS: latencyMS,
                    metadata: baseMetadata.merging(noTaskMetadata) { _, new in new }
                )
            }

            if let repairSeed = try? TaskIntentWireCodec.hostedPlanningInvalidLocalTaskMetadata(
                outputText,
                parserName: "hosted-responses-v1"
            ) {
                return await repairHostedPlanningIntent(
                    entry: entry,
                    backend: backend,
                    request: request,
                    previousOutputText: outputText,
                    previousMetadata: baseMetadata.merging(repairSeed) { current, _ in current },
                    previousFailure: "The previous localAppTask JSON decoded but failed runtime validation, so it cannot be executed.",
                    startedAt: startedAt
                )
            }

            if !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return await repairHostedPlanningIntent(
                    entry: entry,
                    backend: backend,
                    request: request,
                    previousOutputText: outputText,
                    previousMetadata: baseMetadata.merging([
                        "reason": "hostedPlanningSchemaDecodeFailed",
                        "validation.failure": "hostedPlanningSchemaDecodeFailed",
                        "planner.repairable": "true"
                    ]) { current, _ in current },
                    previousFailure: "The previous planner output did not decode as the required generic_harness_planning schema, so it cannot be executed.",
                    startedAt: startedAt
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

    private static func planningDecodeFailureMetadata(_ error: Error) -> [String: String] {
        [
            "reason": "hostedPlanningSchemaDecodeFailed",
            "detail": String(describing: error)
        ]
    }

    private func responseRequest(
        entry: AIModelRegistryEntry,
        adapterRequest: TaskIntentAdapterRequest,
        repairContext: HostedPlanningRepairContext? = nil
    ) -> RemoteInferenceResponseCreateRequest {
        RemoteInferenceResponseCreateRequest(
            input: .array([
                .object([
                    "role": .string("user"),
                    "content": .array([
                        .object([
                            "type": .string("input_text"),
                            "text": .string(promptText(for: adapterRequest, repairContext: repairContext))
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
                    "schema": Self.jsonValue(TaskIntentWireCodec.genericHarnessPlanningJsonSchema(
                        taskDefinitions: adapterRequest.taskDefinitions,
                        availableToolNames: adapterRequest.availableToolNames
                    ))
                ])
            ],
            metadata: [
                "source_trace_id": adapterRequest.sourceTraceID,
                "prompt_version": entry.promptVersion,
                "repair_attempt": repairContext == nil ? "false" : "true"
            ],
            parameters: [
                "instructions": .string(Self.instructions),
                "temperature": .number(0)
            ]
        )
    }

    private func promptText(
        for request: TaskIntentAdapterRequest,
        repairContext: HostedPlanningRepairContext? = nil
    ) -> String {
        let definitions = (try? JSONEncoder().encode(request.taskDefinitions))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let appFinderCatalog = taskIntentAppFinderCatalogJSON(request.appFinderCatalog)
        let skillGuidance = request.skillSnippets
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(8)
            .joined(separator: "\n\n")
        var sections = [
            "Command: \(request.command)",
            "Relevant local cache:",
            request.contextSnippets.joined(separator: "\n"),
            "Available harness tools:",
            request.availableToolNames.joined(separator: "\n"),
            "App skill guidance:",
            skillGuidance,
            "App finder catalog JSON:",
            appFinderCatalog,
            "Supported task definitions JSON:",
            definitions
        ]
        if let repairContext {
            sections.append(contentsOf: [
                "Runtime validation feedback:",
                repairContext.feedback,
                "Previous invalid planner JSON:",
                repairContext.previousOutputText
            ])
        }
        return sections.joined(separator: "\n")
    }

    private func repairHostedPlanningIntent(
        entry: AIModelRegistryEntry,
        backend: DonkeyBackendInferenceClient,
        request: TaskIntentAdapterRequest,
        previousOutputText: String,
        previousMetadata: [String: String],
        previousFailure: String,
        startedAt: TimeInterval
    ) async -> TaskIntentAdapterResult {
        do {
            let response = try await backend.createResponse(
                responseRequest(
                    entry: entry,
                    adapterRequest: request,
                    repairContext: HostedPlanningRepairContext(
                        previousOutputText: previousOutputText,
                        previousFailure: previousFailure
                    )
                )
            )
            let latencyMS = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            guard let repairOutputText = Self.outputText(from: response) else {
                return result(
                    entry: entry,
                    request: request,
                    status: .invalidOutput,
                    validationStatus: "invalid",
                    latencyMS: latencyMS,
                    metadata: Self.repairMetadata(
                        previousMetadata: previousMetadata,
                        repairOutputText: nil,
                        status: "empty"
                    )
                )
            }

            return decodeOutputText(
                repairOutputText,
                entry: entry,
                request: request,
                latencyMS: latencyMS,
                modelCallIDSuffix: "-repair",
                metadataBuilder: { status in
                    Self.repairMetadata(
                        previousMetadata: previousMetadata,
                        repairOutputText: repairOutputText,
                        status: status
                    )
                }
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
                metadata: Self.repairMetadata(
                    previousMetadata: previousMetadata,
                    repairOutputText: nil,
                    status: "requestFailed"
                ).merging(Self.errorMetadata(error)) { current, _ in current }
            )
        }
    }

    private func decodeOutputText(
        _ outputText: String,
        entry: AIModelRegistryEntry,
        request: TaskIntentAdapterRequest,
        latencyMS: Double,
        modelCallIDSuffix: String = "",
        metadataBuilder: (String) -> [String: String]
    ) -> TaskIntentAdapterResult {
        var decodeFailureMetadata: [String: String] = [:]
        do {
            if let intent = try TaskIntentWireCodec.decodeHostedPlanningIntent(
                outputText,
                definitions: request.taskDefinitions,
                originalCommand: request.command,
                appFinderCatalog: request.appFinderCatalog,
                sourceModelCallID: "model-call-\(request.sourceTraceID)\(modelCallIDSuffix)",
                parserName: "hosted-responses-v1",
                parserSource: .onlineModel
            ) {
                return TaskIntentAdapterResult(
                    intent: intent,
                    trace: trace(
                        entry: entry,
                        request: request,
                        status: .completed,
                        validationStatus: "schemaDecoded",
                        latencyMS: latencyMS,
                        metadata: metadataBuilder("schemaDecoded")
                    )
                )
            }
        } catch {
            decodeFailureMetadata = Self.planningDecodeFailureMetadata(error)
        }

        if let noTaskMetadata = try? TaskIntentWireCodec.hostedPlanningNoTaskMetadata(
            outputText,
            parserName: "hosted-responses-v1"
        ) {
            return result(
                entry: entry,
                request: request,
                status: .completed,
                validationStatus: "noTaskIntent",
                latencyMS: latencyMS,
                metadata: metadataBuilder("noTaskIntent").merging(noTaskMetadata) { _, new in new }
            )
        }

        return result(
            entry: entry,
            request: request,
            status: .invalidOutput,
            validationStatus: "invalid",
            latencyMS: latencyMS,
            metadata: metadataBuilder("invalid").merging(decodeFailureMetadata) { current, _ in current }
        )
    }

    private static let instructions = [
        "You are the first model boundary for Donkey's generic agent harness: decide how the harness should handle the user turn before any tool-specific executor is selected. Fill every field per the schema and its field descriptions.",
        "Donkey is a capable Mac agent that can operate any application and item on the Mac. Default to acting: be broad in what you accept and specific in what you do, and prefer acting via a tool path over clarification whenever the action is safe and reversible. For an under-specified but low-risk, reversible request, resolve the vagueness yourself with concrete, reasonable specifics and proceed — use loaded app skill guidance to choose (for example a representative song for \"play some coldplay\") — rather than asking for details you can sensibly decide.",
        "Apply App skill guidance for app-specific workflows, control strategies, required metadata, and output shapes. Do not invent task types, entities, tools, app scripts, or app-specific behavior absent from task definitions, catalog data, memory, or loaded skill guidance. If no supported capability fits, use route conversation with a helpful assistantResponse rather than a generic local-action failure.",
        "Build planSteps as the generic harness plan: each executable step names one available toolName with toolInputs filled from structured entities and the tool schema; non-executable reasoning steps use an empty toolName. Only localAppTask carries executable steps.",
        "For local_app_interaction, prefer a loaded app skill's validated script (skill.load then skill.script.execute with structured toolInputs) over repeated screenshot-driven keyboard fallback.",
        "When automation.applescript.generate is available and a supported app action is better handled through AppleScript than UI input, use it only for a small doable target-app operation, not a full pipeline. Plan separate steps — automation.applescript.generate, automation.applescript.validate, automation.applescript.execute, then app.observe and an app.verifyCommand or app.verifyVisibleText step — reusing one stable toolInputs.scriptArtifactID across generate/validate/execute. The generate step includes targetApp, bundleIdentifier when known, goal, entities as JSON text, allowedActions, and verification. Never put script source in planner output. If AppleScript is not clearly doable, use observation, Accessibility, screenshot, or UI tools instead.",
        "Use ui.clickTarget (semantic or observed visual target id in controlID) to click or submit a visible control instead of pressing Return. When ui.setText is present, entities.query and normalizedEntities.query must be non-empty and inputEntity is usually query. Use agent.path.visualize only with grounded app/window/control/action evidence for every waypoint; it is visual-only (describe the AI path with stepsJSON) and never replaces real AX, AppleScript, keyboard, or guarded coordinate actions.",
        "Verification may be several verifier steps: app.verifyCommand for guarded command evidence, app.verifyVisibleText for observed result text; include both when both kinds of evidence are needed."
    ].joined(separator: " ")

    private static func repairMetadata(
        previousMetadata: [String: String],
        repairOutputText: String?,
        status: String
    ) -> [String: String] {
        var metadata = previousMetadata.merging([
            "provider": "donkeyBackend",
            "privacy.store": "false",
            "planner.repairAttempted": "true",
            "planner.repairStatus": status
        ]) { _, new in new }
        if let repairOutputText {
            let repairDiagnostics = Dictionary(
                uniqueKeysWithValues: Self.outputDiagnostics(for: repairOutputText).map {
                    ("repair.\($0.key)", $0.value)
                }
            )
            metadata = metadata.merging(repairDiagnostics) { _, new in new }
        } else {
            metadata["repair.modelOutput.empty"] = "true"
        }
        return metadata
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

    private static func outputText(from value: RemoteInferenceJSONValue) -> String? {
        RemoteInferenceResponseHelpers.outputText(from: value)
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
        RemoteInferenceResponseHelpers.jsonValue(value)
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

private struct HostedPlanningRepairContext {
    var previousOutputText: String
    var previousFailure: String

    var feedback: String {
        [
            previousFailure,
            "Return one corrected strict JSON object using the same schema.",
            "If no supported executable action is possible, return a conversation or clarification route.",
            "Use the relevant app skill and catalog metadata to repair app-specific workflow fields instead of inventing unsupported behavior."
        ].joined(separator: " ")
    }
}
