import DonkeyContracts
import DonkeyRuntime
import Foundation

public struct TaskIntentAdapterRequest: Equatable, Sendable {
    public var command: String
    public var taskDefinitions: [LocalAppTaskDefinition]
    public var contextSnippets: [String]
    public var skillSnippets: [String]
    public var appFinderCatalog: [LocalAppFinderCatalogEntry]
    public var sourceTraceID: String
    public var routeRequest: AIModelRouteRequest

    public init(
        command: String,
        taskDefinitions: [LocalAppTaskDefinition],
        contextSnippets: [String] = [],
        skillSnippets: [String]? = nil,
        appFinderCatalog: [LocalAppFinderCatalogEntry] = [],
        sourceTraceID: String,
        routeRequest: AIModelRouteRequest = AIModelRouteRequest(
            jobType: .taskIntent,
            privacyMode: .privacySensitive,
            latencyTolerance: .interactive
        )
    ) {
        self.command = command
        self.taskDefinitions = taskDefinitions
        self.contextSnippets = TaskIntentModelContextCompactor.compact(contextSnippets)
        self.appFinderCatalog = appFinderCatalog
        self.skillSnippets = TaskIntentModelContextCompactor(
            maxSnippets: 8,
            maxSnippetCharacters: 1_200,
            maxTotalCharacters: 6_400
        ).compact(
            skillSnippets ?? LocalAppTaskSkillContext.defaultContext(
                taskDefinitions: taskDefinitions,
                appFinderCatalog: appFinderCatalog
            ).snippets
        )
        self.sourceTraceID = sourceTraceID
        self.routeRequest = routeRequest
    }
}

public struct TaskIntentModelContextCompactor: Equatable, Sendable {
    public var maxSnippets: Int
    public var maxSnippetCharacters: Int
    public var maxTotalCharacters: Int

    public init(
        maxSnippets: Int = 8,
        maxSnippetCharacters: Int = 1_200,
        maxTotalCharacters: Int = 4_800
    ) {
        self.maxSnippets = max(0, maxSnippets)
        self.maxSnippetCharacters = max(80, maxSnippetCharacters)
        self.maxTotalCharacters = max(80, maxTotalCharacters)
    }

    public func compact(_ snippets: [String]) -> [String] {
        var usedCharacters = 0
        var compacted: [String] = []

        for snippet in snippets.prefix(maxSnippets) {
            let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let boundedSnippet = bounded(trimmed, maxCharacters: maxSnippetCharacters)
            let remainingCharacters = maxTotalCharacters - usedCharacters
            guard remainingCharacters > 0 else { break }

            let totalBoundedSnippet = bounded(boundedSnippet, maxCharacters: remainingCharacters)
            usedCharacters += totalBoundedSnippet.count
            compacted.append(totalBoundedSnippet)
        }

        return compacted
    }

    public static func compact(_ snippets: [String]) -> [String] {
        TaskIntentModelContextCompactor().compact(snippets)
    }

    private func bounded(_ value: String, maxCharacters: Int) -> String {
        guard value.count > maxCharacters else { return value }
        let marker = "\n...[compacted]...\n"
        guard maxCharacters > marker.count + 2 else {
            return String(value.suffix(maxCharacters))
        }

        let contentCharacters = maxCharacters - marker.count
        let prefixCharacters = contentCharacters / 2
        let suffixCharacters = contentCharacters - prefixCharacters
        let prefixEnd = value.index(value.startIndex, offsetBy: prefixCharacters)
        let suffixStart = value.index(value.endIndex, offsetBy: -suffixCharacters)
        return String(value[..<prefixEnd]) + marker + String(value[suffixStart...])
    }
}

public struct TaskIntentAdapterResult: Equatable, Sendable {
    public var intent: TaskIntent?
    public var trace: AIModelCallTrace

    public init(intent: TaskIntent?, trace: AIModelCallTrace) {
        self.intent = intent
        self.trace = trace
    }
}

public protocol TaskIntentParsingAdapter: Sendable {
    func parseTaskIntent(_ request: TaskIntentAdapterRequest) async -> TaskIntentAdapterResult
}
