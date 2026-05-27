import DonkeyContracts
import DonkeyRuntime
import Foundation

public struct LocalModelTaskIntentResolver: Sendable {
    public var catalog: LocalAppTaskCatalog
    public var adapter: any TaskIntentParsingAdapter

    public init(
        catalog: LocalAppTaskCatalog,
        adapter: any TaskIntentParsingAdapter = HostedTaskIntentParsingAdapter()
    ) {
        self.catalog = catalog
        self.adapter = adapter
    }

    public func resolve(
        command: String,
        contextSnippets: [String] = [],
        sourceTraceID: String
    ) async -> (resolution: LocalAppTaskCatalogResolution, trace: AIModelCallTrace) {
        let request = TaskIntentAdapterRequest(
            command: command,
            taskDefinitions: catalog.taskDefinitions,
            contextSnippets: contextSnippets,
            appFinderCatalog: catalog.appFinderCatalogEntries(),
            sourceTraceID: sourceTraceID
        )
        let result = await adapter.parseTaskIntent(request)

        guard let intent = result.intent else {
            let unavailableReason = result.trace.provider == .donkeyBackend
                ? "hostedModelIntentUnavailable"
                : "localModelIntentUnavailable"
            var metadata = [
                "reason": unavailableReason,
                "modelCallStatus": result.trace.status.rawValue,
                "modelValidationStatus": result.trace.validationStatus
            ]
            if result.trace.validationStatus == "noTaskIntent" {
                metadata["reason"] = "noSupportedTaskIntent"
                metadata["responseMode"] = "conversation"
                metadata["assistantResponse"] = TaskIntentWireCodec.defaultConversationAssistantResponse
            }
            for key in ["responseMode", "assistantResponse"] {
                if let value = result.trace.metadata[key], !value.isEmpty {
                    metadata[key] = value
                }
            }
            for key in [
                "reason",
                "detail",
                "error",
                "backend.provider",
                "http.status",
                "http.bodyPreview",
                "modelOutput.empty",
                "modelOutput.preview",
                "sidecar.outputPreview",
                "fallback.status",
                "fallback.validation",
                "fallback.reason",
                "fallback.http.status",
                "fallback.http.bodyPreview",
                "provider",
                "privacy.store"
            ] {
                if let value = result.trace.metadata[key], !value.isEmpty {
                    metadata["model.\(key)"] = value
                }
            }
            return (
                LocalAppTaskCatalogResolution(
                    status: .needsConfirmation,
                    metadata: metadata
                ),
                result.trace
            )
        }

        return (catalog.resolve(intent: intent), result.trace)
    }
}
