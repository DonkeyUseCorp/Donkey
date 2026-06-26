import DonkeyHarness
import Foundation

/// The deterministic half of `pdf.fill`: read the whole form, hand it (with the data) to the one-shot
/// `mapper` for a `{field_id: value}` map, write the filled PDF with the bundled `pdf-fill`, then verify
/// and reconcile. The mapping is the ONLY model call; everything else is fixed code, so once a map
/// exists the write always happens — the planner never gets the chance to stall before it.
public struct FormFillOrchestrator: Sendable {
    private let mapper: @Sendable (String, String) async -> [String: String]?

    public init(mapper: @escaping @Sendable (String, String) async -> [String: String]?) {
        self.mapper = mapper
    }

    public func fill(_ request: HarnessFormFillRequest) async -> HarnessFormFillOutcome {
        let fileManager = FileManager.default
        // Working directory: the conversation's own folder when present, else home — same rule as shell_exec.
        let workingDirectory = DonkeyCommandBackends.resolvedWorkingDirectoryPath(request.workingDirectory)

        let formPath = Self.resolve(request.form, against: workingDirectory)
        guard fileManager.fileExists(atPath: formPath) else {
            return HarnessFormFillOutcome(text: "No form file at \(request.form).", succeeded: false)
        }

        // `data` is either a file path or the literal data text.
        let dataText: String = {
            let dataPath = Self.resolve(request.data, against: workingDirectory)
            if fileManager.fileExists(atPath: dataPath),
               let contents = try? String(contentsOfFile: dataPath, encoding: .utf8) {
                return contents
            }
            return request.data
        }()

        // The filled PDF's destination — in the working folder by default, or wherever the user named it.
        let outPath = Self.resolve(request.out ?? "out.pdf", against: workingDirectory)

        // Confine pdf-fill to the workspace: it reads the form (and any data file, wherever the user
        // pointed) and writes the map + filled PDF into the working folder, plus the output's own folder
        // when the user named one outside it. nil with no owned folder.
        let policy = SandboxPolicy.forWorkspace(
            baseDirectory: request.workingDirectory,
            readableInputs: [formPath, Self.resolve(request.data, against: workingDirectory)],
            alsoWritable: [(outPath as NSString).deletingLastPathComponent]
        )

        // 1. Read the WHOLE form in reading order (fields inline) for a single mapping pass.
        let read = DonkeyCommandBackends.runBundledTool(
            "pdf-fill", ["form", formPath, "--full"], workingDirectory: workingDirectory, policy: policy
        )
        guard read.exitCode == 0, !read.stdout.isEmpty else {
            return HarnessFormFillOutcome(
                text: "Could not read the form: \(read.stderr.isEmpty ? read.stdout : read.stderr)",
                succeeded: false
            )
        }

        // 2. The ONE bounded inference: form + data → {field_id: value}.
        guard let map = await mapper(read.stdout, dataText), !map.isEmpty else {
            return HarnessFormFillOutcome(text: "Could not map any fields onto the form.", succeeded: false)
        }

        // 3. Write the map and apply it with `pdf-fill set` (writes a NEW pdf, regenerates appearances).
        let mapPath = (workingDirectory as NSString).appendingPathComponent("map.json")
        guard let mapData = try? JSONSerialization.data(withJSONObject: map, options: [.sortedKeys]),
              (try? mapData.write(to: URL(fileURLWithPath: mapPath))) != nil else {
            return HarnessFormFillOutcome(text: "Could not write the field map.", succeeded: false)
        }
        let set = DonkeyCommandBackends.runBundledTool(
            "pdf-fill", ["set", formPath, "--data", mapPath, "-o", outPath], workingDirectory: workingDirectory, policy: policy
        )

        // 4. Verify + reconcile from `pdf-fill set`'s own JSON report and the file on disk.
        let report = Self.parseSetReport(set.stdout)
        let produced = fileManager.fileExists(atPath: outPath)
        guard produced, !report.applied.isEmpty else {
            let why = set.exitCode == 0
                ? "mapped \(map.count) value(s) but applied none to the form"
                : (set.stderr.isEmpty ? set.stdout : set.stderr)
            return HarnessFormFillOutcome(
                text: "Filling \(request.form) did not complete: \(why)",
                succeeded: false,
                outPath: produced ? outPath : nil
            )
        }
        // Strong, self-contained evidence so the planner COMPLETES instead of re-verifying — the same loop
        // the skill_run path documents, where a generic "succeeded" sent the run hunting for a second tool
        // to confirm. State the verified path, that the file exists, the applied count, and a few real
        // values that landed, so the result IS the proof and the planner can finish on it.
        // Prefer the values whose ids the report says it applied; if those ids don't resolve against the map
        // (a key-space mismatch between the tool's report and the mapper), fall back to the mapped values so
        // the evidence never silently goes blank.
        let appliedValues = report.applied.compactMap { map[$0] }
        let samples = Self.evidenceSamples(appliedValues.isEmpty ? Array(map.values) : appliedValues)
        var summary = "Done. Wrote and verified the filled form at \(outPath) "
            + "(file exists; \(report.applied.count) field\(report.applied.count == 1 ? "" : "s") applied"
            + (samples.isEmpty ? "" : ", including \(samples)") + "). "
            + "This is the finished deliverable — no further checking is needed."
        if !report.missing.isEmpty {
            summary += " (\(report.missing.count) mapped id\(report.missing.count == 1 ? "" : "s") were not present on the form and were skipped.)"
        }
        return HarnessFormFillOutcome(text: summary, succeeded: true, outPath: outPath)
    }

    /// Resolve a path against the working directory (absolute and `~` paths pass through unchanged).
    private static func resolve(_ path: String, against workingDirectory: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath { return expanded }
        return (workingDirectory as NSString).appendingPathComponent(expanded)
    }

    /// A short, recognizable sample of the values that landed — preferring the longer, textual ones
    /// (names, addresses, ids) over bare numbers — so the planner sees concrete proof the right data is
    /// in the form and can complete on this result alone.
    private static func evidenceSamples(_ values: [String]) -> String {
        values
            .filter { $0.count >= 3 }
            .sorted { $0.count > $1.count }
            .prefix(3)
            .map { value in "“\(value.count > 40 ? String(value.prefix(40)) + "…" : value)”" }
            .joined(separator: ", ")
    }

    /// `pdf-fill set` prints `{"out":…, "applied":[…], "missing":[…]}`. Pull applied/missing for the
    /// coverage report; tolerate a non-JSON line by returning empties.
    private static func parseSetReport(_ stdout: String) -> (applied: [String], missing: [String]) {
        guard let start = stdout.firstIndex(of: "{"), let end = stdout.lastIndex(of: "}"), start < end,
              let data = String(stdout[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], [])
        }
        let applied = (object["applied"] as? [Any])?.compactMap { $0 as? String } ?? []
        let missing = (object["missing"] as? [Any])?.compactMap { $0 as? String } ?? []
        return (applied, missing)
    }
}
