import Foundation

/// The result of one deterministic pipeline step that runs a bundled tool and expects an output file.
/// `.ok` carries the produced file; `.failed` carries a human-readable reason drawn from the tool's own
/// stderr — no model call is needed to interpret it.
public enum MediaStepResult: Sendable {
    case ok(producedPath: String)
    case failed(reason: String)
}

/// The result of one fanned-out item's sub-pipeline: the files it produced, or a reason it could not
/// finish. A plain enum rather than `Result` because the failure is a human-readable string, not an Error.
public enum PipelineItemOutcome: Sendable {
    case produced([String])
    case failed(reason: String)
}

/// Shared machinery for deterministic capability pipelines (shorts today, more later): run a fixed
/// sequence of bundled-tool steps with NO planner round-trip between them, and fan a sub-pipeline out over
/// a list while isolating per-item failures. The model is called only at the few genuine decision points
/// the orchestrator owns — never to advance from one fixed step to the next, which is what turns a
/// dozens-of-calls planner loop into a single decision plus local rendering.
public enum MediaPipeline {
    /// A bundled-tool runner: name + args + working directory in, the process result out. Defaults to
    /// `DonkeyCommandBackends.runBundledTool`; injectable so a pipeline's control flow is unit-testable
    /// without real ffmpeg/reframe on the machine.
    public typealias ToolRunner = @Sendable (
        _ name: String,
        _ arguments: [String],
        _ workingDirectory: String?
    ) -> (exitCode: Int32, stdout: String, stderr: String)

    /// A production runner confined by `policy`: the `runBundledTool` path with each spawned tool inside the
    /// seatbelt jail. An orchestrator builds its policy (workspace folder + its source input) once per run
    /// and gets a runner from this; a `nil` policy runs the tool unconfined. The default `makeRunTool`
    /// injection point, so production jails and a test stub still slots in unchanged.
    public static let sandboxedRunner: @Sendable (SandboxPolicy?) -> ToolRunner = { policy in
        { name, arguments, workingDirectory in
            DonkeyCommandBackends.runBundledTool(name, arguments, workingDirectory: workingDirectory, policy: policy)
        }
    }

    /// Run a bundled tool and confirm it produced `outputPath` on disk. A non-zero exit or a missing file
    /// is a clean `.failed` carrying the tool's stderr (or stdout when stderr is empty), so the caller
    /// short-circuits in code instead of handing the failure back to the planner to interpret.
    public static func runStep(
        _ tool: String,
        _ arguments: [String],
        workingDirectory: String?,
        expecting outputPath: String,
        using run: ToolRunner
    ) -> MediaStepResult {
        let result = run(tool, arguments, workingDirectory)
        guard result.exitCode == 0 else {
            let why = result.stderr.isEmpty ? result.stdout : result.stderr
            return .failed(reason: "\(tool) exited \(result.exitCode): \(lastLines(why))")
        }
        guard FileManager.default.fileExists(atPath: outputPath) else {
            return .failed(reason: "\(tool) reported success but wrote no file at \(outputPath)")
        }
        return .ok(producedPath: outputPath)
    }

    /// Run `body` for each item in order, isolating failures: one item's reason is recorded and the rest
    /// still run, so a 3-clip job where clip 2 fails still delivers clips 1 and 3. Returns every produced
    /// file path and a per-item note for whatever failed.
    public static func fanOut<Item: Sendable>(
        _ items: [Item],
        _ body: @Sendable (_ index: Int, _ item: Item) async -> PipelineItemOutcome
    ) async -> (produced: [String], failures: [String]) {
        var produced: [String] = []
        var failures: [String] = []
        for (index, item) in items.enumerated() {
            switch await body(index, item) {
            case .produced(let paths): produced.append(contentsOf: paths)
            case .failed(let reason): failures.append(reason)
            }
        }
        return (produced, failures)
    }

    /// The last couple of non-empty lines of a tool's output, bounded — enough to explain a failure in the
    /// trace without dumping a full ffmpeg log.
    static func lastLines(_ text: String) -> String {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let tail = lines.suffix(2).joined(separator: " ")
        return tail.count > 240 ? String(tail.suffix(240)) : tail
    }
}
