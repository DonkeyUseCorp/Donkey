import DonkeyContracts
import DonkeyHarness
import Foundation

/// The backend's web-page reader response: the page's main content as clean markdown plus its title.
public struct RemoteWebFetchResult: Codable, Sendable {
    public var title: String
    public var markdown: String
    public var author: String?
    public var published: String?
    public var wordCount: Int?

    public init(
        title: String,
        markdown: String,
        author: String? = nil,
        published: String? = nil,
        wordCount: Int? = nil
    ) {
        self.title = title
        self.markdown = markdown
        self.author = author
        self.published = published
        self.wordCount = wordCount
    }
}

/// Backs the `web.fetch` harness tool by calling the Donkey backend's reader endpoint, where the
/// fetch and HTML→markdown cleanup run server-side. Returns a single text block — a title line, any
/// byline/date, then the article as markdown — for the agent to read, summarize, or save into a note.
public struct HostedWebFetch: Sendable {
    private let backend: DonkeyBackendInferenceClient
    private let timeoutSeconds: TimeInterval

    public init(backend: DonkeyBackendInferenceClient, timeoutSeconds: TimeInterval = 30) {
        self.backend = backend
        self.timeoutSeconds = timeoutSeconds
    }

    public func fetch(_ url: String) async -> String? {
        let backend = self.backend
        guard let result = try? await AIDeadline.enforce(seconds: timeoutSeconds, {
            try await backend.fetchWeb(url: url)
        }) else {
            return nil
        }
        let markdown = result.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else {
            return nil
        }
        var lines: [String] = []
        let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            lines.append("# \(title)")
        }
        var byline: [String] = []
        if let author = result.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            byline.append(author)
        }
        if let published = result.published?.trimmingCharacters(in: .whitespacesAndNewlines), !published.isEmpty {
            byline.append(published)
        }
        if !byline.isEmpty {
            lines.append("_\(byline.joined(separator: " · "))_")
        }
        if !lines.isEmpty {
            lines.append("")
        }
        lines.append(markdown)
        return lines.joined(separator: "\n")
    }
}
