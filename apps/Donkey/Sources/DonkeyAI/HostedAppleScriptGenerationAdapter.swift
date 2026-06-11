import DonkeyContracts
import DonkeyHarness
import Foundation

public struct HostedAppleScriptGenerationAdapter: Sendable {
    public static let schemaID = "dynamic_applescript_generation_v2"

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

    public func generateAppleScript(
        _ request: HarnessScriptGenerationRequest
    ) async -> HarnessScriptGenerationOutcome {
        guard request.language == .appleScript else {
            return HarnessScriptGenerationOutcome(
                succeeded: false,
                summary: "Only AppleScript generation is supported by this adapter.",
                metadata: ["reason": "unsupportedLanguage"]
            )
        }

        let entry: AIModelRegistryEntry
        do {
            entry = try router.route(
                AIModelRouteRequest(
                    jobType: .taskIntent,
                    risk: .medium,
                    privacyMode: .privacySensitive,
                    latencyTolerance: .interactive
                )
                .limitingProviders([.donkeyBackend])
            )
        } catch {
            return HarnessScriptGenerationOutcome(
                succeeded: false,
                summary: "Dynamic AppleScript generation could not route a model.",
                metadata: ["reason": "routingFailed", "error": String(describing: error)]
            )
        }

        let backend: DonkeyBackendInferenceClient
        do {
            backend = DonkeyBackendInferenceClient(
                configuration: try configuration ?? DonkeyBackendInferenceConfiguration.fromEnvironment(environment),
                httpClient: httpClient
            )
        } catch {
            return HarnessScriptGenerationOutcome(
                succeeded: false,
                summary: "Dynamic AppleScript generation is missing backend configuration.",
                metadata: [
                    "reason": "missingCredentials",
                    "credential": DonkeyBackendInferenceConfiguration.baseURLConfigurationDescription,
                    "error": String(describing: error)
                ]
            )
        }

        do {
            let response = try await backend.createResponse(
                responseRequest(entry: entry, request: request)
            )
            guard let outputText = Self.outputText(from: response),
                  let data = outputText.data(using: .utf8)
            else {
                return HarnessScriptGenerationOutcome(
                    succeeded: false,
                    summary: "Dynamic AppleScript generation returned empty output.",
                    metadata: ["reason": "emptyModelOutput"]
                )
            }

            let wire = try JSONDecoder().decode(AppleScriptGenerationWire.self, from: data)
            guard wire.canGenerate else {
                return HarnessScriptGenerationOutcome(
                    succeeded: false,
                    summary: wire.blockedReason.isEmpty
                        ? "Dynamic AppleScript generation decided the task is not doable as a small script."
                        : wire.blockedReason,
                    metadata: [
                        "reason": "appleScriptTaskNotDoable",
                        "blockedReason": wire.blockedReason
                    ]
                )
            }
            let source = wire.scriptSource.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else {
                return HarnessScriptGenerationOutcome(
                    succeeded: false,
                    summary: "Dynamic AppleScript generation returned an empty script.",
                    metadata: [
                        "reason": "emptyScriptSource",
                        "modelOutput.preview": String(outputText.prefix(800))
                    ]
                )
            }

            return HarnessScriptGenerationOutcome(
                succeeded: true,
                source: source,
                summary: wire.summary,
                metadata: [
                    "generator": "hostedDynamicAppleScript",
                    "schemaID": Self.schemaID,
                    "provider": entry.provider.rawValue,
                    "modelEntryID": entry.id,
                    "safetyNotes": wire.safetyNotes.joined(separator: "\n"),
                    "expectedOutput": wire.expectedOutput,
                    "usedCommands": wire.usedCommands.joined(separator: "\n"),
                    "parameterBindings": wire.parameterBindings.joined(separator: "\n")
                ]
            )
        } catch is CancellationError {
            return HarnessScriptGenerationOutcome(
                succeeded: false,
                summary: "Dynamic AppleScript generation was cancelled.",
                metadata: ["reason": "cancelled"]
            )
        } catch {
            return HarnessScriptGenerationOutcome(
                succeeded: false,
                summary: "Dynamic AppleScript generation failed.",
                metadata: ["reason": "requestFailed", "error": String(describing: error)]
            )
        }
    }

    private func responseRequest(
        entry: AIModelRegistryEntry,
        request: HarnessScriptGenerationRequest
    ) -> RemoteInferenceResponseCreateRequest {
        RemoteInferenceResponseCreateRequest(
            input: .array([
                .object([
                    "role": .string("user"),
                    "content": .array([
                        .object([
                            "type": .string("input_text"),
                            "text": .string(promptText(for: request))
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
                    "schema": Self.jsonValue(Self.schema())
                ])
            ],
            metadata: [
                "source_trace_id": request.sourceTraceID ?? "",
                "prompt_version": "dynamic-applescript-generation-v2",
                "privacy.store": "false",
                "model_entry_id": entry.id
            ],
            parameters: [
                "instructions": .string(Self.instructions),
                "temperature": .number(0)
            ]
        )
    }

    private func promptText(for request: HarnessScriptGenerationRequest) -> String {
        let payload = AppleScriptGenerationPromptPayload(
            targetApp: request.targetApp,
            bundleIdentifier: request.bundleIdentifier ?? "",
            goal: request.goal,
            entities: request.entities,
            allowedActions: request.allowedActions,
            verification: request.verification,
            scriptingDictionary: request.scriptingDictionaryDigest,
            worldFacts: request.worldFacts,
            metadata: request.metadata
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = (try? encoder.encode(payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "Generate one bounded AppleScript for this structured local-app task JSON:\n\(json)"
    }

    private static let instructions = [
        "You generate AppleScript for Donkey's guarded local-app harness.",
        "Generate only a small AppleScript for one bounded operation or a very small sequence inside the requested target app.",
        "Do not build a full automation pipeline; Donkey handles observation, clicking, recovery, and verification as separate harness steps.",
        "Use only the provided entities and allowed actions.",
        "Do not use shell commands, System Events, keystrokes, key codes, file deletion, quitting apps, network calls, credential access, or unrelated applications.",
        "When the task JSON includes a scriptingDictionary digest, it is the app's real declared vocabulary: use ONLY command, parameter, class, property, and enumeration names that appear in it, with their exact spelling. Never invent terminology that is not in the digest. If the goal cannot be expressed with the digest's commands, set canGenerate to false with a blockedReason instead of guessing.",
        "Provide a concrete value for every required parameter of every command you use; never leave placeholders or template tokens in the script.",
        "List every dictionary command the script uses in usedCommands, and every parameter you bound in parameterBindings as name=value entries.",
        "Return a concise structured text result with key=value fields when possible.",
        "Do not execute anything. The harness will validate, permission-gate, execute, observe, and verify separately."
    ].joined(separator: " ")

    private static func schema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["canGenerate", "blockedReason", "scriptSource", "summary", "safetyNotes", "expectedOutput", "usedCommands", "parameterBindings"],
            "properties": [
                "canGenerate": [
                    "type": "boolean",
                    "description": "False when the request is not doable as a small scoped AppleScript."
                ],
                "blockedReason": [
                    "type": "string",
                    "description": "Why generation is not possible, or empty when canGenerate is true."
                ],
                "scriptSource": [
                    "type": "string",
                    "description": "Small AppleScript source for one bounded target-app operation, or empty when canGenerate is false."
                ],
                "summary": [
                    "type": "string",
                    "description": "Short description of what the script does."
                ],
                "safetyNotes": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Brief notes about the safety boundaries followed."
                ],
                "expectedOutput": [
                    "type": "string",
                    "description": "Expected key=value style output or observation that should verify success."
                ],
                "usedCommands": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Every scripting-dictionary command name the script uses, exactly as declared in the provided digest."
                ],
                "parameterBindings": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Every parameter the script binds, as name=value entries, so the harness can verify no required parameter was left out."
                ]
            ]
        ]
    }

    private static func jsonValue(_ value: Any) -> RemoteInferenceJSONValue {
        RemoteInferenceResponseHelpers.jsonValue(value)
    }

    private static func outputText(from value: RemoteInferenceJSONValue) -> String? {
        RemoteInferenceResponseHelpers.outputText(from: value)
    }
}

private struct AppleScriptGenerationWire: Decodable {
    var canGenerate: Bool
    var blockedReason: String
    var scriptSource: String
    var summary: String
    var safetyNotes: [String]
    var expectedOutput: String
    var usedCommands: [String]
    var parameterBindings: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Only `canGenerate` is essential. Models routinely omit the string/array fields when they
        // don't apply (e.g. no `blockedReason` when `canGenerate` is true), so tolerate their
        // absence instead of failing the whole generation.
        canGenerate = try container.decode(Bool.self, forKey: .canGenerate)
        blockedReason = try container.decodeIfPresent(String.self, forKey: .blockedReason) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        safetyNotes = try container.decodeIfPresent([String].self, forKey: .safetyNotes) ?? []
        expectedOutput = try container.decodeIfPresent(String.self, forKey: .expectedOutput) ?? ""
        usedCommands = try container.decodeIfPresent([String].self, forKey: .usedCommands) ?? []
        parameterBindings = try container.decodeIfPresent([String].self, forKey: .parameterBindings) ?? []
        // Models name the script field inconsistently (`scriptSource`, `appleScript`, `script`,
        // `source`). Accept any of them so a correct script isn't dropped over a key name.
        scriptSource = try container.decodeIfPresent(String.self, forKey: .scriptSource)
            ?? container.decodeIfPresent(String.self, forKey: .appleScript)
            ?? container.decodeIfPresent(String.self, forKey: .script)
            ?? container.decodeIfPresent(String.self, forKey: .source)
            ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case canGenerate, blockedReason, scriptSource, summary, safetyNotes, expectedOutput
        case usedCommands, parameterBindings
        case appleScript, script, source
    }
}

private struct AppleScriptGenerationPromptPayload: Encodable {
    var targetApp: String
    var bundleIdentifier: String
    var goal: String
    var entities: [String: String]
    var allowedActions: String
    var verification: String
    var scriptingDictionary: String
    var worldFacts: [String: String]
    var metadata: [String: String]
}
