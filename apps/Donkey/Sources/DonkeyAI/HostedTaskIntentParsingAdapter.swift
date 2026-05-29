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

            var repairDecodeFailureMetadata: [String: String] = [:]
            do {
                if let intent = try TaskIntentWireCodec.decodeHostedPlanningIntent(
                    repairOutputText,
                    definitions: request.taskDefinitions,
                    originalCommand: request.command,
                    appFinderCatalog: request.appFinderCatalog,
                    sourceModelCallID: "model-call-\(request.sourceTraceID)-repair",
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
                            metadata: Self.repairMetadata(
                                previousMetadata: previousMetadata,
                                repairOutputText: repairOutputText,
                                status: "schemaDecoded"
                            )
                        )
                    )
                }
            } catch {
                repairDecodeFailureMetadata = Self.planningDecodeFailureMetadata(error)
            }

            if let noTaskMetadata = try? TaskIntentWireCodec.hostedPlanningNoTaskMetadata(
                repairOutputText,
                parserName: "hosted-responses-v1"
            ) {
                return result(
                    entry: entry,
                    request: request,
                    status: .completed,
                    validationStatus: "noTaskIntent",
                    latencyMS: latencyMS,
                    metadata: Self.repairMetadata(
                        previousMetadata: previousMetadata,
                        repairOutputText: repairOutputText,
                        status: "noTaskIntent"
                    ).merging(noTaskMetadata) { _, new in new }
                )
            }

            return result(
                entry: entry,
                request: request,
                status: .invalidOutput,
                validationStatus: "invalid",
                latencyMS: latencyMS,
                metadata: Self.repairMetadata(
                    previousMetadata: previousMetadata,
                    repairOutputText: repairOutputText,
                    status: "invalid"
                ).merging(repairDecodeFailureMetadata) { current, _ in current }
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

    private static let instructions = [
        "You are the first model boundary for Donkey's generic agent harness. Decide how the harness should handle the user turn before any tool-specific executor is selected.",
        "Return strict JSON only using the generic harness planning schema.",
        "First decide whether Command should be answered conversationally, should ask a clarification, or should use a supported tool path.",
        "Choose conversation for greetings, questions, brainstorming, explanations, status requests, malformed requests, or any turn that does not require external action.",
        "Choose clarification when the user wants action but a specific required detail is missing or the action is dangerously ambiguous.",
        "Choose localAppTask only when the user is asking Donkey to operate a supported local app or local item and all three are clear: action, destination or target app/item, and enough payload to execute safely.",
        "Always fill structuredIntent, ambiguityRisk, contextNeeds, planSteps, verificationCriteria, fallbacks, clarificationPolicy, and metadata.",
        "If Command is conversation, set structuredIntent.route conversation, taskType \"none\", targetAppName \"none\", empty entities and normalizedEntities, confidence 0, needsConfirmation false, no planSteps with toolName values, and metadata.responseMode \"conversation\" with metadata.assistantResponse containing a brief natural-language reply.",
        "If Command needs clarification before tool use, set structuredIntent.route clarification, taskType \"none\", targetAppName \"none\" unless a target is already known, needsConfirmation true, ambiguityRisk.shouldAskBeforeActing true, clarificationPolicy.shouldAsk true, and include one specific question.",
        "For supported local app actions, set structuredIntent.route localAppTask, choose only a provided taskType and target app, and fill entities and normalizedEntities with the concrete values needed by required entity rules.",
        "Use the generic local_app_interaction task type for executable local app requests that need a model-planned app workflow and do not have a more specific provided task type.",
        "Use ambiguityRisk for safe, recoverable, or dangerous ambiguity. Dangerous ambiguity and missing required details must set structuredIntent.needsConfirmation true, ambiguityRisk.shouldAskBeforeActing true, and clarificationPolicy.shouldAsk true with a specific question.",
        "Use contextNeeds for app lookup, memory lookup, screen observation, element discovery, or skill lookup needed before or during execution.",
        "Use planSteps for the generic harness plan. Each executable step must name one available toolName, with toolInputs filled from structured entities and tool schemas. Keep inputEntity/controlID/focusKey for local UI compatibility when those tools need them. Non-executable reasoning steps should use an empty toolName.",
        "Use verificationCriteria for what proves success, fallbacks for safe recovery choices, and clarificationPolicy for when Donkey should stop and ask.",
        "Apply App skill guidance for app-specific workflows, control strategies, required metadata, and output shapes. Do not invent app-specific behavior that is absent from task definitions, catalog data, memory, or loaded skill guidance.",
        "When App finder catalog JSON is non-empty and you use local_app_interaction, choose the target app only from a catalog entry with supportStatus supported and a matching capability. Set metadata.appFinder.selectedAppID to the exact appID, metadata.appFinder.selectedCapabilityID to the capability id, and metadata.appFinder.controlProfile to one declared control profile. Never select candidate, unsupported, or denied entries for execution.",
        "For local_app_interaction, select the most likely local app, set targetAppName and entities.appName to the human app name, set entities.goal, and when text must be entered set entities.query plus normalizedEntities.query.",
        "For local_app_interaction, use available local UI tools for UI workflows and available skill tools for skill-backed workflows. When a loaded app skill provides a validated script for the selected capability, prefer skill.load then skill.script.execute with structured toolInputs over repeated screenshot-driven keyboard fallback.",
        "When automation.applescript.generate is available and a supported app action is better handled through AppleScript than UI input, use it only for a small doable target-app operation, not a full automation pipeline. Plan dynamic AppleScript as separate steps: automation.applescript.generate, automation.applescript.validate, automation.applescript.execute, then app.observe and an app.verifyCommand or app.verifyVisibleText step. Use the same stable toolInputs.scriptArtifactID on generate, validate, and execute. The generate step should include targetApp, bundleIdentifier when known, goal, entities as JSON text, allowedActions, and verification. Never put script source in planner output; the child generation tool creates the source artifact. If AppleScript is not clearly doable for that small operation, use observation, Accessibility, screenshot, or UI tools instead.",
        "Use ui.clickTarget when the intended action is to click or submit a visible control by Accessibility or AI visual evidence instead of pressing Return. Put the semantic or observed visual target id in controlID.",
        "Verification may be a set of verifier steps. Use app.verifyCommand for guarded command evidence, app.verifyVisibleText for observed result text, and include both when both kinds of evidence are needed.",
        "When ui.setText is present, entities.query and normalizedEntities.query must be non-empty, the step inputEntity should usually be query, and controlID/focusKey should describe the guarded UI strategy.",
        "For every other task type, planSteps should not contain executable toolName values.",
        "If no supported capability fits, set structuredIntent.route conversation and taskType \"none\" with a helpful conversational assistantResponse rather than a generic local-action failure.",
        "Do not invent task types, unsupported entities, unsupported tools, app scripts, or direct input outside the schema."
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
