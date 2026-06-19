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

    /// Runs a browser task and returns the formatted text plus whether the run actually succeeded, so
    /// the executor reports `.failed` (keeping the text as the failure message) on anything but a
    /// genuine success. `succeeded == false` covers a nil result (the backend errored/timed out) as
    /// well as a run the backend reports did not complete the task.
    public func run(_ request: HarnessWebAutomateRequest) async -> HarnessWebAutomateOutcome {
        guard let result = try? await backend.runBrowserTask(
            task: request.task,
            startURL: request.startURL,
            structuredOutputSchemaJSON: request.structuredOutputSchemaJSON
        ) else {
            return HarnessWebAutomateOutcome(
                text: "The browser task did not complete (the run could not be reached).",
                succeeded: false
            )
        }
        return HarnessWebAutomateOutcome(text: format(result), succeeded: result.isTaskSuccessful == true)
    }

    private func format(_ status: RemoteBrowserRunStatus) -> String {
        var lines: [String] = []
        // The run is only a success when the backend explicitly reports `isTaskSuccessful == true`; a
        // nil (backend sent null on error/timeout/stop) or false is surfaced as "did not fully succeed".
        let state = status.isTaskSuccessful == true
            ? "completed (\(status.status))"
            : "did not fully succeed (\(status.status))"
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
