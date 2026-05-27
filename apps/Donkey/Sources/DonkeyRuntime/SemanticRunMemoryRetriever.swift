import DonkeyContracts
import Foundation

public protocol RunMemoryEmbeddingProviding: Sendable {
    func embedding(for text: String) async -> [Double]
}

public struct LexicalRunMemoryEmbeddingProvider: RunMemoryEmbeddingProviding {
    public init() {}

    public func embedding(for text: String) async -> [Double] {
        let tokens = Set(Self.tokens(in: text))
        return Self.vocabulary.map { tokens.contains($0) ? 1 : 0 }
    }

    private static let vocabulary = [
        "app", "button", "field", "form", "input", "open", "play", "search", "submit", "text"
    ]

    fileprivate static func tokens(in text: String) -> [String] {
        text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}

public struct SemanticRunMemoryRetriever: Sendable {
    public var embeddingProvider: any RunMemoryEmbeddingProviding
    public var embeddingModelID: String

    public init(
        embeddingProvider: any RunMemoryEmbeddingProviding = LexicalRunMemoryEmbeddingProvider(),
        embeddingModelID: String = "local-semantic-memory-embedding-contract-v1"
    ) {
        self.embeddingProvider = embeddingProvider
        self.embeddingModelID = embeddingModelID
    }

    public func retrieve(
        query: RunMemorySemanticQuery,
        records: [RunMemoryRecord]
    ) async -> [RunMemorySemanticResult] {
        let filtered = records.filter { record in
            if let scope = query.scope, record.scope != scope { return false }
            if let targetID = query.targetID, record.targetID != targetID { return false }
            return true
        }
        let queryEmbedding = await embeddingProvider.embedding(for: query.text)
        let scored: [RunMemorySemanticResult] = await filtered.asyncMap { record in
            let recordEmbedding = await embeddingProvider.embedding(for: record.value)
            let relevance = cosineSimilarity(queryEmbedding, recordEmbedding)
            return RunMemorySemanticResult(
                record: record,
                relevance: relevance,
                embeddingModelID: embeddingModelID,
                metadata: [
                    "retriever": "semantic-run-memory",
                    "budget.maxRecords": String(query.budget.maxRecords),
                    "budget.maxPromptCharacters": String(query.budget.maxPromptCharacters)
                ]
            )
        }

        var promptCharacters = 0
        var results: [RunMemorySemanticResult] = []
        for result in scored
            .filter({ $0.relevance >= query.budget.minRelevance })
            .sorted(by: { $0.relevance > $1.relevance })
        {
            guard results.count < query.budget.maxRecords else { break }
            let nextCharacters = promptCharacters + result.record.value.count
            guard nextCharacters <= query.budget.maxPromptCharacters else { break }
            promptCharacters = nextCharacters
            results.append(result)
        }
        return results
    }

    private func cosineSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        let dot = zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
        let lhsMagnitude = sqrt(lhs.reduce(0) { $0 + $1 * $1 })
        let rhsMagnitude = sqrt(rhs.reduce(0) { $0 + $1 * $1 })
        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return 0 }
        return dot / (lhsMagnitude * rhsMagnitude)
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)
        for element in self {
            values.append(await transform(element))
        }
        return values
    }
}
