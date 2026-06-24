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
        let body: String
        if let summaryFile,
           let contents = try? String(contentsOf: dir.appendingPathComponent(summaryFile), encoding: .utf8) {
            body = contents
        } else {
            // A summary often stands in for a command's OUTPUT (e.g. an `osascript` POSIX path, an `mdfind`
            // result). Those are absolute in reality, so expand the home-relative `~/` the fixture stores
            // (kept tilde so no real username is committed) to the live home — a tilde where a tool would
            // print a full path reads as wrong and makes the planner re-query instead of proceeding.
            body = (summary ?? "ran.").replacingOccurrences(of: "~/", with: NSHomeDirectory() + "/")
        }
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

    /// Build the runnable scenario. The stub serves in priority order: a TARGETED response rule (one that
    /// names command substrings — it models a specific command's result), then the filesystem simulation
    /// (`files.describe`, a file read, a discovery listing), then a CATCH-ALL response rule (one with no
    /// `contains` — it models the scenario's work command), then the runner's generic default.
    ///
    /// The filesystem sim deliberately sits BEFORE the catch-all: a catch-all rule answers "the work is
    /// done" for any command, so if it ran ahead of discovery a mere `find`/`ls` would be told the job
    /// already finished, and the planner would loop trying to verify output that was never produced (the
    /// loop several of these scenarios used to hit). Targeted rules still win first, so a scripted
    /// `pdfinfo`/failed-download response keeps its authority.
    func scenario() -> HarnessEvalScenario {
        let dir = self.dir
        let disk = spec.disk ?? []
        let responses = spec.responses ?? []
        let targetedRules = responses.filter { $0.contains?.isEmpty == false }
        let catchAllRules = responses.filter { $0.contains?.isEmpty ?? true }
        return HarnessEvalScenario(
            name: name,
            prompt: prompt,
            frontmostApp: spec.frontmostApp ?? "Finder",
            maxSteps: spec.maxSteps ?? 16
        ) { call in
            if let rule = targetedRules.first(where: { $0.matches(call) }) {
                return rule.stub(in: dir)
            }
            if call.name == "files.describe", !disk.isEmpty {
                return .ok(
                    disk.map { "\($0.path) — \($0.describe ?? "file")" }.joined(separator: "; "),
                    facts: Self.existenceFacts(for: disk)
                )
            }
            if call.name == "shell_exec", let command = call.input["command"] {
                let lower = command.lowercased()
                if lower.range(of: "(^| )(cat|head|tail|less|open|lit|pdftotext)( |$)", options: .regularExpression) != nil {
                    for entry in disk where command.contains(entry.path) || command.contains((entry.path as NSString).lastPathComponent) {
                        if let content = entry.resolvedContent(in: dir) { return .ok(content) }
                    }
                }
                if !disk.isEmpty,
                   lower.range(of: "(^| )(find|mdfind|ls|stat)( |$)", options: .regularExpression) != nil {
                    let listing = Self.discoveryListing(command: command, disk: disk)
                    return .ok(listing.text, facts: listing.facts)
                }
            }
            if let rule = catchAllRules.first(where: { $0.matches(call) }) {
                return rule.stub(in: dir)
            }
            return nil
        }
    }

    /// What a discovery command (`find`/`mdfind`/`ls`/`stat`) returns for this disk, plus the existence
    /// facts to record. An `ls`/`stat` naming a declared directory lists that directory's CONTENTS — the
    /// entries declared beneath it — so the planner sees the files it must operate on instead of the folder
    /// path echoed back at it. Anything else returns every declared path. Either way each returned path is
    /// marked `exists`: without that fact a successful discovery changes nothing in the world model, so the
    /// runtime scores it as no progress and the planner re-searches the same paths until the duplicate/stall
    /// guard fails the run — the loop these evals kept hitting. The fact carries the located file forward so
    /// the planner moves on to the real work tool.
    private static func discoveryListing(
        command: String,
        disk: [HarnessEvalDiskEntry]
    ) -> (text: String, facts: [String: String]) {
        // Match whether the command names the declared path as written (`~/Desktop/x`) or already expanded
        // (`/Users/<home>/Desktop/x`) — discovery output from an earlier step comes back expanded.
        for entry in disk where command.contains(entry.path) || command.contains(displayPath(entry.path)) {
            let children = disk.filter { $0.path != entry.path && $0.path.hasPrefix(entry.path + "/") }
            if !children.isEmpty {
                return (listingText(for: children), existenceFacts(for: children))
            }
        }
        return (listingText(for: disk), existenceFacts(for: disk))
    }

    /// The text a discovery command prints: one ABSOLUTE path per line. A real `find`/`mdfind` prints full
    /// paths, so echoing back the bare declared name (often identical to the query) reads to the planner as
    /// "not actually located" and it keeps trying search variants. `displayPath` gives the planner the
    /// concrete path it needs to move on to the real work.
    private static func listingText(for entries: [HarnessEvalDiskEntry]) -> String {
        entries.map { displayPath($0.path) }.joined(separator: "\n")
    }

    /// The absolute path a discovery command prints for a declared entry. Fixture paths are stored
    /// home-relative (`~/…`, or a bare name) so no real username is committed; this expands `~`/roots a
    /// bare name at the live home directory ONLY at runtime, so the output is a real absolute path with no
    /// hard-coded user in the fixture files.
    private static func displayPath(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        if path == "~" { return NSHomeDirectory() }
        if path.hasPrefix("~/") { return NSHomeDirectory() + String(path.dropFirst(1)) }
        return NSHomeDirectory() + "/" + path
    }

    /// `path -> "exists"` for each entry, the shape the runner's world model and default file-probe reply
    /// already use to mean "this file is present."
    private static func existenceFacts(for disk: [HarnessEvalDiskEntry]) -> [String: String] {
        Dictionary(disk.map { ($0.path, "exists") }, uniquingKeysWith: { current, _ in current })
    }
}
