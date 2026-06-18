import DonkeyHarness
import Foundation

/// The result of a browser run. `structured` is the agent's structured output (when a schema was
/// requested) as a JSON string; otherwise the free-form `text` carries the result. Property names
/// match the backend JSON keys so this decodes directly.
public struct RemoteBrowserRunStatus: Codable, Sendable {
    public var status: String
    public var isTaskSuccessful: Bool?
    public var text: String?
    public var structured: String?
    public var recordingUrl: String?
    public var liveUrl: String?
    public var stepCount: Int
    public var lastStepSummary: String?
}

/// Backs the `web.automate` harness tool: runs a Browser Use Cloud task through the Donkey backend,
/// which executes it to completion server-side and returns the result, then formats it as a single
/// text block for the agent to read. Long-running by nature — the planner narrates a wait.
public struct HostedWebAutomate: Sendable {
    private let backend: DonkeyBackendInferenceClient

    public init(backend: DonkeyBackendInferenceClient) {
        self.backend = backend
    }

    public func run(_ request: HarnessWebAutomateRequest) async -> String? {
        guard let result = try? await backend.runBrowserTask(
            task: request.task,
            startURL: request.startURL,
            structuredOutputSchemaJSON: request.structuredOutputSchemaJSON
        ) else {
            return nil
        }
        return format(result)
    }

    private func format(_ status: RemoteBrowserRunStatus) -> String {
        var lines: [String] = []
        let state = status.isTaskSuccessful == false
            ? "did not fully succeed (\(status.status))"
            : "completed (\(status.status))"
        lines.append("Browser task \(state) after \(status.stepCount) steps.")
        if let structured = status.structured {
            lines.append("")
            lines.append(structured)
        } else if let text = status.text, !text.isEmpty {
            lines.append("")
            lines.append(text)
        } else if let summary = status.lastStepSummary, !summary.isEmpty {
            lines.append("")
            lines.append("Last step: \(summary)")
        }
        if let recording = status.recordingUrl {
            lines.append("")
            lines.append("Recording: \(recording)")
        }
        return lines.joined(separator: "\n")
    }
}
