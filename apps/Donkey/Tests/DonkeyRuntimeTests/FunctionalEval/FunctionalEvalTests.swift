import DonkeyAI
import DonkeyContracts
import DonkeyHarness
import Foundation
import Testing

/// Functional evals — run the REAL agent loop with REAL executors against a sandbox, then assert on the
/// files the agent actually produced. Each case is a folder under `Fixtures/FunctionalEval/` (prompt +
/// inputs/generate.sh + expect.json); this one test runs them all. Opt-in behind `DONKEY_FUNCTIONAL_EVAL=1`
/// plus the hosted-backend env, so a plain `swift test` returns early. Run with:
///
///     env DONKEY_FUNCTIONAL_EVAL=1 DONKEY_WEB_BASE_URL=http://localhost:3000 DONKEY_DEV_AUTH_BYPASS=1 \
///       DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       swift test --filter FunctionalEval
///
/// Add a case by dropping a new folder — no Swift change needed.
@Suite(.serialized)
@MainActor
struct FunctionalEvalTests {
    /// Append a line to `DONKEY_EVAL_RESULT_FILE` when set. swift-testing's console reporter is invisible
    /// in a headless/redirected run, so this is how a CI step (or a developer) reads the eval's actual
    /// outcome — entry, final status, produced files, per-check pass/fail — out of band from stdout.
    private static func note(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["DONKEY_EVAL_RESULT_FILE"], !path.isEmpty else { return }
        let data = Data((line + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    @Test(arguments: FunctionalEvalFixture.all())
    func scenario(_ fixture: FunctionalEvalFixture) async throws {
        Self.note("ENTER \(fixture.name)")
        guard let config = FunctionalEvalRunner.configFromEnvironment() else {
            Self.note("SKIP \(fixture.name): not opted in (DONKEY_FUNCTIONAL_EVAL/DONKEY_WEB_BASE_URL)")
            return
        }

        // Run the SAME bundled toolchain as production (lit + pdfium + pdf-fill + ffmpeg from the repo's
        // vendor dir). Fail loudly if it isn't staged — a "real pipeline" eval must not pass while silently
        // missing its tools.
        guard FunctionalEvalToolchain.ensure() != nil else {
            Self.note("FAIL \(fixture.name): bundled tools not found")
            Issue.record("Bundled tools not found. Run scripts/fetch-bundled-tools.sh (stages vendor/donkey-tools, including libpdfium.dylib).")
            return
        }

        let sandbox = try fixture.makeSandbox()
        // Route the agent's per-conversation working directory inside this sandbox (as prod routes it under
        // ~/Donkey), so its output — written into that working dir — is captured by the produced-files scan
        // and cleaned up with the sandbox. Serialized suite, so this process-wide setting can't race.
        // Restore it after the scenario: the sandbox is deleted on success, and `workspaceParentDirectory`
        // reads this live via getenv, so a leaked value would point a later test's workspace at a dead path.
        let priorWorkspaceDir = ProcessInfo.processInfo.environment["DONKEY_WORKSPACE_DIR"]
        setenv("DONKEY_WORKSPACE_DIR", sandbox.path, 1)
        defer {
            if let priorWorkspaceDir {
                setenv("DONKEY_WORKSPACE_DIR", priorWorkspaceDir, 1)
            } else {
                unsetenv("DONKEY_WORKSPACE_DIR")
            }
        }
        let afterSetup = FunctionalEvalFixture.fileNames(in: sandbox)

        let run = await FunctionalEvalRunner.run(
            prompt: fixture.resolvedPrompt(sandbox: sandbox),
            frontmostApp: fixture.expect.frontmostApp ?? "Finder",
            maxSteps: fixture.expect.maxSteps ?? 24,
            sandbox: sandbox,
            config: config
        )

        // Whatever appeared in the sandbox that wasn't there after setup is what the agent produced.
        let produced = FunctionalEvalFixture.fileNames(in: sandbox)
            .subtracting(afterSetup)
            .map { sandbox.appendingPathComponent($0) }

        print(
            "\n=== functional eval: \(fixture.name) (final: \(String(describing: run.finalStatus))) ===\n"
                + "sandbox: \(sandbox.path)\nproduced: \(produced.map(\.lastPathComponent))\n"
                + "selected skills: \(run.understanding?.relevantSkillIDs ?? [])\n\(run.transcript)\n"
        )

        // Evaluate every check first, so cleanup can depend on whether they all passed.
        let outcomes = (fixture.expect.expectProduced ?? []).map { check in
            FunctionalEvalVerifier.verify(check, producedFiles: produced, sandbox: sandbox)
        }
        Self.note(
            "RESULT \(fixture.name): final=\(String(describing: run.finalStatus)) "
                + "produced=\(produced.map(\.lastPathComponent)) "
                + "checks=\(outcomes.map { $0.ok ? "ok" : "FAIL(\($0.detail))" })"
        )
        for outcome in outcomes {
            #expect(outcome.ok, "[\(fixture.name)] \(outcome.detail)")
        }

        if outcomes.allSatisfy(\.ok) {
            try? FileManager.default.removeItem(at: sandbox)
        } else {
            print("[\(fixture.name)] sandbox kept for inspection: \(sandbox.path)")
        }
    }
}
