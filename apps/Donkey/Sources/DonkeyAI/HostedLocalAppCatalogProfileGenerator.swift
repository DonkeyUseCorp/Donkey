import DonkeyContracts
import DonkeyRuntime
import Foundation

public struct HostedLocalAppCatalogProfileGenerator: LocalAppCatalogProfileGenerating {
    public static let schemaID = "local_app_catalog_profile_v1"

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

    public func generateProfiles(
        for applications: [LocalApplicationCatalogCandidate],
        existingProfiles: [LocalAppFinderCatalogEntry],
        sourceTraceID: String
    ) async -> LocalAppCatalogProfileGenerationResult {
        guard !applications.isEmpty else {
            return LocalAppCatalogProfileGenerationResult(
                generatedEntries: [],
                attemptedApplicationIDs: [],
                metadata: ["reason": "noNewApplications"]
            )
        }

        let entry: AIModelRegistryEntry
        do {
            entry = try router.route(AIModelRouteRequest(
                jobType: .localAppCatalogProfile,
                privacyMode: .privacySensitive,
                latencyTolerance: .background
            ).limitingProviders([.donkeyBackend]))
        } catch {
            return LocalAppCatalogProfileGenerationResult(
                generatedEntries: [],
                attemptedApplicationIDs: [],
                metadata: [
                    "status": "routingFailed",
                    "error": String(describing: error)
                ]
            )
        }

        let backend: DonkeyBackendInferenceClient
        do {
            backend = DonkeyBackendInferenceClient(
                configuration: try configuration ?? DonkeyBackendInferenceConfiguration.fromEnvironment(environment),
                httpClient: httpClient
            )
        } catch {
            return LocalAppCatalogProfileGenerationResult(
                generatedEntries: [],
                attemptedApplicationIDs: [],
                metadata: [
                    "status": "missingCredentials",
                    "credential": DonkeyBackendInferenceConfiguration.baseURLConfigurationDescription,
                    "error": String(describing: error)
                ]
            )
        }

        do {
            let response = try await backend.createResponse(responseRequest(
                entry: entry,
                applications: applications,
                existingProfiles: existingProfiles,
                sourceTraceID: sourceTraceID
            ))
            guard let outputText = Self.outputText(from: response),
                  let data = outputText.data(using: .utf8)
            else {
                return LocalAppCatalogProfileGenerationResult(
                    generatedEntries: [],
                    attemptedApplicationIDs: [],
                    metadata: ["status": "emptyOutput"]
                )
            }

            let output = try JSONDecoder().decode(ProfileWireOutput.self, from: data)
            let validEntries = output.entries.filter { generatedEntry in
                Self.matchesInputApplication(generatedEntry, applications: applications)
            }
            return LocalAppCatalogProfileGenerationResult(
                generatedEntries: validEntries,
                attemptedApplicationIDs: Set(applications.map(\.catalogID)),
                metadata: [
                    "status": "schemaDecoded",
                    "provider": "donkeyBackend",
                    "privacy.store": "false",
                    "profileEntryCount": String(validEntries.count)
                ].merging(output.metadata) { current, _ in current }
            )
        } catch {
            return LocalAppCatalogProfileGenerationResult(
                generatedEntries: [],
                attemptedApplicationIDs: [],
                metadata: Self.errorMetadata(error)
            )
        }
    }

    private func responseRequest(
        entry: AIModelRegistryEntry,
        applications: [LocalApplicationCatalogCandidate],
        existingProfiles: [LocalAppFinderCatalogEntry],
        sourceTraceID: String
    ) throws -> RemoteInferenceResponseCreateRequest {
        RemoteInferenceResponseCreateRequest(
            input: .array([
                .object([
                    "role": .string("user"),
                    "content": .array([
                        .object([
                            "type": .string("input_text"),
                            "text": .string(promptText(
                                applications: applications,
                                existingProfiles: existingProfiles
                            ))
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
                "source_trace_id": sourceTraceID,
                "prompt_version": entry.promptVersion
            ],
            parameters: [
                "instructions": .string(Self.instructions),
                "temperature": .number(0)
            ]
        )
    }

    private func promptText(
        applications: [LocalApplicationCatalogCandidate],
        existingProfiles: [LocalAppFinderCatalogEntry]
    ) -> String {
        let appRecords = applications.map { application -> [String: String] in
            [
                "appID": application.catalogID,
                "appName": application.appName,
                "bundleIdentifier": application.bundleIdentifier ?? "",
                "pathHint": application.path ?? ""
            ]
        }
        let existing = existingProfiles.map { entry -> [String: String] in
            [
                "appID": entry.appID,
                "appName": entry.appName,
                "bundleIdentifier": entry.bundleIdentifier ?? "",
                "supportStatus": entry.supportStatus.rawValue
            ]
        }
        let appsJSON = Self.jsonString(appRecords)
        let existingJSON = Self.jsonString(existing)
        return [
            "New installed applications JSON:",
            appsJSON,
            "Existing known profiles JSON:",
            existingJSON
        ].joined(separator: "\n")
    }

    private static let instructions = [
        "Generate local app catalog profiles for Donkey's guarded local-app task-intent boundary.",
        "Return one entry for each input application. Preserve the input appID, appName, and bundleIdentifier exactly; use an empty string when bundleIdentifier is absent.",
        "Supported means the app has a safe generic workflow through one of the allowed control profiles only.",
        "Use supported only for low-risk actions that fit one allowed profile with a clear user payload, such as search-and-submit, address-bar submission, or creating a new text-like document.",
        "Use candidate when the app might be automatable but a safe generic workflow is uncertain.",
        "Use unsupported when it is not meaningfully controllable through the allowed profiles.",
        "Use denied for password managers, credential/keychain tools, shells/terminals, system settings, process managers, logs/consoles, security tools, payment/finance tools, or anything where generic automation would be risky.",
        "Do not create scripts, hidden actions, app-specific private commands, personal data, or capabilities outside the allowed control profiles.",
        "Capabilities must be compact and require query when text/search/address input is needed."
    ].joined(separator: " ")

    private static func schema() -> [String: Any] {
        let capability: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["id", "summary", "controlProfiles", "requiredEntities"],
            "properties": [
                "id": ["type": "string"],
                "summary": ["type": "string"],
                "controlProfiles": [
                    "type": "array",
                    "description": "Allowed generic control profiles this capability supports.",
                    "items": [
                        "type": "string",
                        "enum": [
                            "search_then_enter",
                            "address_bar_submit",
                            "new_document_text"
                        ]
                    ]
                ],
                "requiredEntities": [
                    "type": "array",
                    "items": ["type": "string"]
                ]
            ]
        ]

        let entry: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": [
                "appID",
                "appName",
                "bundleIdentifier",
                "description",
                "supportStatus",
                "capabilities",
                "denyReason",
                "metadata"
            ],
            "properties": [
                "appID": ["type": "string"],
                "appName": ["type": "string"],
                "bundleIdentifier": ["type": "string"],
                "description": ["type": "string"],
                "supportStatus": [
                    "type": "string",
                    "enum": LocalAppFinderSupportStatus.allCases.map(\.rawValue)
                ],
                "capabilities": [
                    "type": "array",
                    "items": capability
                ],
                "denyReason": ["type": "string"],
                "metadata": [
                    "type": "object",
                    "additionalProperties": ["type": "string"]
                ]
            ]
        ]

        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["entries", "metadata"],
            "properties": [
                "entries": [
                    "type": "array",
                    "items": entry
                ],
                "metadata": [
                    "type": "object",
                    "additionalProperties": ["type": "string"]
                ]
            ]
        ]
    }

    private static func matchesInputApplication(
        _ entry: LocalAppFinderCatalogEntry,
        applications: [LocalApplicationCatalogCandidate]
    ) -> Bool {
        let entryID = LocalAppFinderProfileStore.catalogID(
            appName: entry.appName,
            bundleIdentifier: entry.bundleIdentifier
        )
        return applications.contains { application in
            application.catalogID == entry.appID
                || application.catalogID == entryID
                || application.bundleIdentifier == entry.bundleIdentifier
        }
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

    private static func errorMetadata(_ error: Error) -> [String: String] {
        if case DonkeyBackendInferenceClientError.httpStatus(let status, let message) = error {
            return [
                "status": status == 429 ? "rateLimited" : "httpError",
                "http.status": String(status),
                "http.bodyPreview": preview(message, maxCharacters: 240)
            ]
        }
        return [
            "status": "failed",
            "error": String(describing: error)
        ]
    }

    private static func preview(_ value: String, maxCharacters: Int) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        guard singleLine.count > maxCharacters else { return singleLine }
        return String(singleLine.prefix(maxCharacters))
    }

    private static func jsonString<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return string
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

private struct ProfileWireOutput: Decodable {
    var entries: [LocalAppFinderCatalogEntry]
    var metadata: [String: String]
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
