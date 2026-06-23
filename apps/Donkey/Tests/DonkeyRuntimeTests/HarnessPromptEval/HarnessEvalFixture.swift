import DonkeyAI
import DonkeyContracts
import DonkeyHarness
import Foundation

/// A prompt-eval scenario stored as data on disk instead of inline Swift, so a scenario is a folder you can
/// read, edit, and fill with realistic inputs — a `prompt.txt`, a `scenario.json`, and any data files the
/// task operates on (a CSV, a form's data, a captured web page). The loader turns each folder into a
/// `HarnessEvalScenario` whose stub serves that real data back to the model as observations; nothing runs
/// and nothing on the Mac is touched, so the data can be as representative as we like.
///
/// Layout (under `Fixtures/HarnessEval/<name>/`, shipped to the test bundle by `.copy("Fixtures")`):
///   - `prompt.txt`     — the user's turn (required).
///   - `scenario.json`  — frontmost app, step budget, the disk the task sees, scripted tool replies, and
///                        the expectations to assert (all optional; see the structs below).
///   - any other files  — referenced by `contentFile` / `summaryFile` so a stub can hand back real bytes
///                        (e.g. the markdown a `web.fetch` returns, or a data file the plan reads).
///
/// Add a scenario by dropping a new folder in; `FixturePromptEvalTests` discovers and runs it automatically.

/// The disk a scenario's task operates on: files the model can discover and read before it produces
/// anything. `files.describe` lists these, a read command (`cat`, `head`, `lit`, …) of one returns its
/// content, and a discovery command (`find`, `mdfind`, `ls`) returns the paths.
struct HarnessEvalDiskEntry: Decodable, Sendable {
    var path: String
    /// One-line description surfaced by `files.describe`. Defaults to a generic "file" when omitted.
    var describe: String?
    /// A sibling file in the fixture folder whose bytes are returned when the plan reads `path`.
    var contentFile: String?
    /// Inline content returned when the plan reads `path` (takes precedence over `contentFile`).
    var content: String?

    func resolvedContent(in dir: URL) -> String? {
        if let content { return content }
        guard let contentFile else { return nil }
        return try? String(contentsOf: dir.appendingPathComponent(contentFile), encoding: .utf8)
    }
}

/// A scripted reply for a tool call, matched in order — the first rule whose `tool` and `contains` match
/// wins. `tool` nil matches any tool; `contains` matches the shell command (for `shell_exec`) or any input
/// value (for other tools), case-insensitively. The reply's summary is `summary`, or the bytes of
/// `summaryFile` (e.g. the page a `web.fetch` returns); `produces` marks files now existing so later steps
/// see them, and `status: "failed"` drives the recovery path.
struct HarnessEvalResponseRule: Decodable, Sendable {
    var tool: String?
    var contains: [String]?
    var summary: String?
    var summaryFile: String?
    var facts: [String: String]?
    var produces: [String]?
    var status: String?

    func matches(_ call: HarnessToolCall) -> Bool {
        if let tool, tool != call.name { return false }
        guard let contains, !contains.isEmpty else { return true }
        let haystack = call.name == "shell_exec"
            ? (call.input["command"] ?? "")
            : call.input.values.joined(separator: " ")
        return contains.allSatisfy { haystack.range(of: $0, options: .caseInsensitive) != nil }
    }

    func stub(in dir: URL) -> HarnessEvalStub {
        let body = summaryFile
            .flatMap { try? String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }
            ?? summary
            ?? "ran."
        if status == "failed" { return .failed(body) }
        var resolved = facts ?? [:]
        for file in produces ?? [] { resolved[file] = "exists" }
        return .ok(body, facts: resolved)
    }
}

/// What the produced plan should look like — every field optional, so a scenario asserts only what is
/// meaningful and deterministic for it (turn kind and skill surfacing land reliably; deep-pipeline tails do
/// not). Mirrors the assertions the hand-written category tests make, expressed as data.
struct HarnessEvalExpect: Decodable, Sendable {
    /// "act" | "converse" | "clarify".
    var turnKind: String?
    /// Skill IDs that must all be surfaced.
    var skills: [String]?
    /// Skill IDs of which at least one must be surfaced.
    var skillsAny: [String]?
    /// Each inner group: a single shell command containing all of its substrings must exist.
    var shellAll: [[String]]?
    /// At least one inner group must be satisfied by some shell command.
    var shellAny: [[String]]?
    var used: [String]?
    var notUsed: [String]?
    var completed: Bool?
}

/// The decoded `scenario.json`. Every field is optional with a sensible default so a folder needs nothing
/// beyond `prompt.txt` to run.
struct HarnessEvalScenarioSpec: Decodable, Sendable {
    var frontmostApp: String?
    var maxSteps: Int?
    var disk: [HarnessEvalDiskEntry]?
    var responses: [HarnessEvalResponseRule]?
    var expect: HarnessEvalExpect?

    init() {}
}

/// One loaded fixture: its folder name, the prompt, the decoded spec, and the directory to resolve data
/// files against. `Sendable` and `CustomTestStringConvertible` so it can drive a parameterized `@Test`.
struct HarnessEvalFixture: Sendable, CustomStringConvertible {
    var name: String
    var prompt: String
    var spec: HarnessEvalScenarioSpec
    var dir: URL

    var description: String { name }

    /// Every fixture folder under `Fixtures/HarnessEval/`, sorted by name. Empty when the resource bundle is
    /// absent — the parameterized test then simply has no cases.
    static func all() -> [HarnessEvalFixture] {
        guard let root = Bundle.module.resourceURL?.appendingPathComponent("Fixtures/HarnessEval") else {
            return []
        }
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        var fixtures = dirs.compactMap(load).sorted { $0.name < $1.name }
        // Optional single-fixture focus: `DONKEY_EVAL_ONLY=korean-clip-overlay` runs just the fixtures whose
        // name contains that substring, so one scenario can be exercised without the whole suite hitting the
        // real model. Empty/unset runs everything.
        if let only = ProcessInfo.processInfo.environment["DONKEY_EVAL_ONLY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !only.isEmpty {
            fixtures = fixtures.filter { $0.name.localizedCaseInsensitiveContains(only) }
        }
        return fixtures
    }

    private static func load(_ dir: URL) -> HarnessEvalFixture? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        guard let rawPrompt = try? String(contentsOf: dir.appendingPathComponent("prompt.txt"), encoding: .utf8) else {
            return nil
        }
        let spec = (try? Data(contentsOf: dir.appendingPathComponent("scenario.json")))
            .flatMap { try? JSONDecoder().decode(HarnessEvalScenarioSpec.self, from: $0) }
            ?? HarnessEvalScenarioSpec()
        return HarnessEvalFixture(
            name: dir.lastPathComponent,
            prompt: rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            spec: spec,
            dir: dir
        )
    }

    /// Build the runnable scenario. The stub serves, in order: a matching scripted response, the disk for
    /// `files.describe`, real file content for a read command, and the disk paths for a discovery command —
    /// then falls back to the runner's generic default.
    func scenario() -> HarnessEvalScenario {
        let dir = self.dir
        let disk = spec.disk ?? []
        let responses = spec.responses ?? []
        return HarnessEvalScenario(
            name: name,
            prompt: prompt,
            frontmostApp: spec.frontmostApp ?? "Finder",
            maxSteps: spec.maxSteps ?? 16
        ) { call in
            if let rule = responses.first(where: { $0.matches(call) }) {
                return rule.stub(in: dir)
            }
            if call.name == "files.describe", !disk.isEmpty {
                return .ok(disk.map { "\($0.path) — \($0.describe ?? "file")" }.joined(separator: "; "))
            }
            guard call.name == "shell_exec", let command = call.input["command"] else { return nil }
            let lower = command.lowercased()
            if lower.range(of: "(^| )(cat|head|tail|less|open|lit|pdftotext)( |$)", options: .regularExpression) != nil {
                for entry in disk where command.contains(entry.path) || command.contains((entry.path as NSString).lastPathComponent) {
                    if let content = entry.resolvedContent(in: dir) { return .ok(content) }
                }
            }
            if !disk.isEmpty,
               lower.range(of: "(^| )(find|mdfind|ls|stat)( |$)", options: .regularExpression) != nil {
                return .ok(disk.map(\.path).joined(separator: "\n"))
            }
            return nil
        }
    }
}
