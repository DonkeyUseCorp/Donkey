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
        "You are the first model boundary for Donkey's generic agent harness. Decide how the harness should handle the user turn before any tool-specific executor is selected.",
        "Return strict JSON only using the generic harness planning schema.",
        "Donkey is a capable Mac agent that can operate any application and item on the Mac. Default to acting: be broad in what you accept and specific in what you do. For an under-specified but low-risk, reversible request, choose reasonable, concrete specifics yourself and proceed — do not ask the user to fill in details you can sensibly decide.",
        "First decide whether Command should be answered conversationally, should ask a clarification, or should use a supported tool path. Prefer acting via a tool path over clarification whenever the action is safe and reversible.",
        "Choose conversation for greetings, questions, brainstorming, explanations, status requests, malformed requests, or any turn that does not require external action.",
        "Choose guidance when the user wants to be SHOWN where something is or how to do something without Donkey changing any state (e.g. \"show me where X is\", \"how do I X\", \"point me to X\"). Set route guidance, targetAppName to the app, needsConfirmation false, and list the on-screen controls to point at, in order, in metadata.guidanceTargets as semicolon-separated `label::query` pairs (label is shown to the user, query is the control's on-screen text). Set metadata.assistantResponse to a brief, natural spoken narration of what you are pointing at (this is shown to the user). Do not plan any acting tools for guidance.",
        "Choose clarification only when acting could be destructive, irreversible, costly, or sent/shared externally AND the user's intent is genuinely ambiguous, or when a required target is unknown and cannot be reasonably inferred. Never ask for clarification merely because a request is casual, broad, or under-specified (for example \"play some coldplay\", \"open my notes\", \"make it bigger\") — resolve those by picking concrete specifics and acting.",
        "Choose localAppTask whenever the user wants Donkey to operate a local app or item and you can identify the action and a target app or item. If payload specifics are under-specified (which song, which note, which result), pick concrete, reasonable defaults and proceed rather than requiring the user to supply every detail.",
        "Always fill structuredIntent, ambiguityRisk, contextNeeds, planSteps, verificationCriteria, fallbacks, clarificationPolicy, and metadata.",
        "If Command is conversation, set structuredIntent.route conversation, taskType \"none\", targetAppName \"none\", empty entities and normalizedEntities, confidence 0, needsConfirmation false, no planSteps with toolName values, and metadata.responseMode \"conversation\" with metadata.assistantResponse containing a brief natural-language reply.",
        "If Command genuinely needs clarification (only per the narrow criteria above), set structuredIntent.route clarification, taskType \"none\", targetAppName \"none\" unless a target is already known, needsConfirmation true, ambiguityRisk.shouldAskBeforeActing true, clarificationPolicy.shouldAsk true, and include one specific question naming exactly what you need.",
        "For supported local app actions, set structuredIntent.route localAppTask, choose only a provided taskType and target app, and fill entities and normalizedEntities with the concrete values needed by required entity rules.",
        "Use the generic local_app_interaction task type for executable local app requests that need a model-planned app workflow and do not have a more specific provided task type.",
        "Use ambiguityRisk to classify the action. Set structuredIntent.needsConfirmation true, ambiguityRisk.shouldAskBeforeActing true, and clarificationPolicy.shouldAsk true with a specific question ONLY for genuinely dangerous, destructive, irreversible, costly, or externally-sent actions whose intent is ambiguous. For safe, reversible actions — including broad or casual ones — set needsConfirmation false and act.",
        "When a request is broad or casual but the action is low-risk and reversible, resolve the vagueness yourself with a concrete, specific choice and act: set structuredIntent.route localAppTask and structuredIntent.needsConfirmation false. Use loaded app skill guidance to make the choice when present (for example pick a representative song for \"play some coldplay\"). Do not treat resolvable vagueness as a missing required detail.",
        "Use contextNeeds for app lookup, memory lookup, screen observation, element discovery, or skill lookup needed before or during execution.",
        "Use planSteps for the generic harness plan. Each executable step must name one available toolName, with toolInputs filled from structured entities and tool schemas. Keep inputEntity/controlID/focusKey for local UI compatibility when those tools need them. Non-executable reasoning steps should use an empty toolName.",
        "Use verificationCriteria for what proves success, fallbacks for safe recovery choices, and clarificationPolicy for when Donkey should stop and ask.",
        "Apply App skill guidance for app-specific workflows, control strategies, required metadata, and output shapes. Do not invent app-specific behavior that is absent from task definitions, catalog data, memory, or loaded skill guidance.",
        "When App finder catalog JSON is non-empty and you use local_app_interaction, choose the target app only from a catalog entry with supportStatus supported and a matching capability. Set metadata.appFinder.selectedAppID to the exact appID, metadata.appFinder.selectedCapabilityID to the capability id, and metadata.appFinder.controlProfile to one declared control profile. Never select candidate, unsupported, or denied entries for execution.",
        "For local_app_interaction, select the most likely local app, set targetAppName and entities.appName to the human app name, set entities.goal, and when text must be entered set entities.query plus normalizedEntities.query.",
        "For local_app_interaction, use available local UI tools for UI workflows and available skill tools for skill-backed workflows. When a loaded app skill provides a validated script for the selected capability, prefer skill.load then skill.script.execute with structured toolInputs over repeated screenshot-driven keyboard fallback.",
        "When automation.applescript.generate is available and a supported app action is better handled through AppleScript than UI input, use it only for a small doable target-app operation, not a full automation pipeline. Plan dynamic AppleScript as separate steps: automation.applescript.generate, automation.applescript.validate, automation.applescript.execute, then app.observe and an app.verifyCommand or app.verifyVisibleText step. Use the same stable toolInputs.scriptArtifactID on generate, validate, and execute. The generate step should include targetApp, bundleIdentifier when known, goal, entities as JSON text, allowedActions, and verification. Never put script source in planner output; the child generation tool creates the source artifact. If AppleScript is not clearly doable for that small operation, use observation, Accessibility, screenshot, or UI tools instead.",
        "Use agent.path.visualize only when you have grounded app/window/control/action evidence for every pointer waypoint. It is visual-only: it must describe the AI path with stepsJSON and must never replace real AX, AppleScript, keyboard, or guarded coordinate actions.",
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
