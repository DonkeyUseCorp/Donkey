import DonkeyContracts
import DonkeyHarness
import Foundation

/// The backend's web-search response: a grounded summary plus the source pages the answer used.
public struct RemoteWebSearchResult: Codable, Sendable {
    public struct Source: Codable, Sendable {
        public var title: String
        public var url: String
    }
    public var summary: String
    public var sources: [Source]

    public init(summary: String, sources: [Source]) {
        self.summary = summary
        self.sources = sources
    }
}

/// Backs the `web.search` harness tool by calling the Donkey backend's grounded-search endpoint,
/// where the Google credential lives. Returns a single text block — a short grounded answer followed
/// by the source pages — for the agent to read and follow up on with web.fetch.
public struct HostedWebSearch: Sendable {
    private let backend: DonkeyBackendInferenceClient
    private let timeoutSeconds: TimeInterval

    public init(backend: DonkeyBackendInferenceClient, timeoutSeconds: TimeInterval = 30) {
        self.backend = backend
        self.timeoutSeconds = timeoutSeconds
    }

    public func search(_ query: String) async -> String? {
        let backend = self.backend
        guard let result = try? await AIDeadline.enforce(seconds: timeoutSeconds, {
            try await backend.searchWeb(query: query)
        }) else {
            return nil
        }
        var lines: [String] = []
        let summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            lines.append(summary)
        }
        if !result.sources.isEmpty {
            lines.append("")
            lines.append("Sources:")
            for source in result.sources {
                lines.append("- \(source.title) — \(source.url)")
            }
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
