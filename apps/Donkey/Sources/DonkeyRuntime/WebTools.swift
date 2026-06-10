import Foundation

/// Concrete web capabilities behind the `web.search` and `web.fetch` harness tools: a Google
/// Programmable Search query and a plain HTTP page read. Both return readable text the planner can
/// use as evidence (find a current fact, then read the page). Network egress, so they are read-only
/// and never run state-changing requests.
public struct WebTools: Sendable {
    private let apiKey: String?
    private let searchEngineID: String?
    private let session: URLSession

    /// Credentials come from the environment so no key is compiled into the app:
    /// `GOOGLE_SEARCH_API_KEY` and `GOOGLE_SEARCH_ENGINE_ID` (the Programmable Search Engine `cx`).
    public init(environment: [String: String] = ProcessInfo.processInfo.environment, session: URLSession = .shared) {
        self.apiKey = environment["GOOGLE_SEARCH_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
        self.searchEngineID = environment["GOOGLE_SEARCH_ENGINE_ID"].flatMap { $0.isEmpty ? nil : $0 }
        self.session = session
    }

    public var isSearchConfigured: Bool { apiKey != nil && searchEngineID != nil }

    /// Google Programmable Search: returns up to `count` results as "title — url\nsnippet" blocks.
    public func search(_ query: String, count: Int = 5) async -> String? {
        guard let apiKey, let searchEngineID else { return nil }
        var components = URLComponents(string: "https://www.googleapis.com/customsearch/v1")
        components?.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "cx", value: searchEngineID),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "num", value: String(min(max(count, 1), 10)))
        ]
        guard let url = components?.url else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else {
            return nil
        }
        let blocks = items.compactMap { item -> String? in
            let title = (item["title"] as? String) ?? ""
            let link = (item["link"] as? String) ?? ""
            let snippet = (item["snippet"] as? String) ?? ""
            guard !title.isEmpty || !link.isEmpty else { return nil }
            return "\(title) — \(link)\n\(snippet)"
        }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }

    /// Fetch a URL and return its readable text (tags and scripts stripped, whitespace collapsed).
    public func fetch(_ urlString: String) async -> String? {
        guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh) Donkey/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        return Self.readableText(fromHTML: html)
    }

    /// Strip script/style blocks and HTML tags to readable text. Deliberately simple (no DOM): good
    /// enough to give the model the page's words without pulling in a parser dependency.
    public static func readableText(fromHTML html: String) -> String {
        var text = html
        for pattern in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<!--[\\s\\S]*?-->"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        // Turn block-level closes into newlines so paragraphs survive, then drop remaining tags.
        text = text.replacingOccurrences(of: "</(p|div|li|h[1-6]|br|tr)>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = decodeEntities(text)
        // Collapse runs of whitespace, keeping line breaks.
        text = text.replacingOccurrences(of: "[ \\t\\x0B\\f\\r]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n\\s*\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (entity, value) in entities {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result
    }
}
