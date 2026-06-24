import DonkeyRuntime
import Foundation

/// A functional-eval scenario on disk: a folder under `Fixtures/FunctionalEval/<name>/` whose inputs the
/// agent really operates on, plus the result-level checks.
///
/// Layout:
///   - `prompt.txt`   — the task; `{DIR}` is replaced with the sandbox path so the prompt names exactly where
///                      the inputs are and where output should go.
///   - `inputs/`      — committed real files copied into a fresh sandbox before the run (e.g. the IRS form, a
///                      CSV). Use this for artifacts that can't be generated.
///   - `generate.sh`  — optional; run inside the sandbox after `inputs/` is copied, to materialize binary
///                      inputs with installed tools (images, video, PDFs) so they don't bloat the repo.
///   - `expect.json`  — the checks (see `FunctionalEvalExpect`).
struct FunctionalEvalExpect: Decodable, Sendable {
    var frontmostApp: String?
    var maxSteps: Int?
    /// Result checks, each evaluated against the files the AGENT produced (anything in the sandbox that was
    /// not there after setup). A check passes if SOME produced file satisfies it; the run passes if all do.
    var expectProduced: [FunctionalEvalCheck]?
}

/// One result check. `kind` selects which tool reads the produced file; the other fields parameterize it.
struct FunctionalEvalCheck: Decodable, Sendable {
    /// "pdfPageCount" | "imageWidth" | "audio" | "pdfFields" | "jsonMinRecords" | "fileExists".
    var kind: String
    var pageCount: Int?
    var width: Int?
    var minRecords: Int?
    var ext: String?
    /// For "pdfFields": each group is acceptable alternatives; every group must match some field value.
    var containsAll: [[String]]?

    enum CodingKeys: String, CodingKey {
        case kind, pageCount, width, minRecords, containsAll
        case ext = "extension"
    }
}

struct FunctionalEvalFixture: Sendable, CustomStringConvertible {
    var name: String
    var prompt: String
    var expect: FunctionalEvalExpect
    var dir: URL

    var description: String { name }

    /// Every functional fixture folder, sorted by name. Empty when the resource bundle is absent.
    static func all() -> [FunctionalEvalFixture] {
        guard let root = Bundle.module.resourceURL?.appendingPathComponent("Fixtures/FunctionalEval") else {
            return []
        }
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        var fixtures = dirs.compactMap(load).sorted { $0.name < $1.name }
        // Optional single-fixture focus: `DONKEY_EVAL_ONLY=comic-book-epub` runs just the fixtures whose name
        // contains that substring — the same knob the prompt eval honors, so one expensive real-execution
        // scenario can be run alone. Empty/unset runs everything.
        if let only = ProcessInfo.processInfo.environment["DONKEY_EVAL_ONLY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !only.isEmpty {
            fixtures = fixtures.filter { $0.name.localizedCaseInsensitiveContains(only) }
        }
        return fixtures
    }

    static func load(_ dir: URL) -> FunctionalEvalFixture? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        guard let rawPrompt = try? String(contentsOf: dir.appendingPathComponent("prompt.txt"), encoding: .utf8) else {
            return nil
        }
        let expect = (try? Data(contentsOf: dir.appendingPathComponent("expect.json")))
            .flatMap { try? JSONDecoder().decode(FunctionalEvalExpect.self, from: $0) }
            ?? FunctionalEvalExpect()
        return FunctionalEvalFixture(
            name: dir.lastPathComponent,
            prompt: rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            expect: expect,
            dir: dir
        )
    }

    /// Create a fresh sandbox under the user's home (where the shell tool's hard-anchored cwd can reach it),
    /// copy any committed `inputs/`, then run `generate.sh` (if present) to materialize binary inputs. The
    /// caller removes the sandbox after the run.
    func makeSandbox() throws -> URL {
        let sandbox = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".donkey-functional-eval", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

        let inputsDir = dir.appendingPathComponent("inputs")
        if FileManager.default.fileExists(atPath: inputsDir.path) {
            for input in (try? FileManager.default.contentsOfDirectory(at: inputsDir, includingPropertiesForKeys: nil)) ?? [] {
                try FileManager.default.copyItem(at: input, to: sandbox.appendingPathComponent(input.lastPathComponent))
            }
        }

        let generate = dir.appendingPathComponent("generate.sh")
        if FileManager.default.fileExists(atPath: generate.path),
           let script = try? String(contentsOf: generate, encoding: .utf8) {
            _ = ShellHelper.run(script, in: sandbox)
        }
        return sandbox
    }

    /// The prompt with `{DIR}` resolved to the sandbox path.
    func resolvedPrompt(sandbox: URL) -> String {
        prompt.replacingOccurrences(of: "{DIR}", with: sandbox.path)
    }

    /// The file names directly in `directory` — used to snapshot the sandbox after setup so the verifier can
    /// tell which files the agent produced.
    static func fileNames(in directory: URL) -> Set<String> {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(entries)
    }
}

/// Runs a shell snippet through a login zsh (so Homebrew tools resolve) with the bundled donkey-tools dir
/// appended to PATH (so `pdf-fill` / `lit` resolve). Used for input generation and result verification —
/// the trusted test side, never the agent. Returns combined stdout (trimmed).
enum ShellHelper {
    @discardableResult
    static func run(_ command: String, in directory: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        let toolsPath = BundledTools.installDirectory.path
        environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin:/opt/homebrew/bin") + ":" + toolsPath
        process.environment = environment
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }
}
