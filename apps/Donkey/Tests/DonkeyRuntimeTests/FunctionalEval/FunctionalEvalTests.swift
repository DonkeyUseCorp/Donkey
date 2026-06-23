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
@Suite
@MainActor
struct FunctionalEvalTests {
    @Test(arguments: FunctionalEvalFixture.all())
    func scenario(_ fixture: FunctionalEvalFixture) async throws {
        guard let config = FunctionalEvalRunner.configFromEnvironment() else { return }

        let sandbox = try fixture.makeSandbox()
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
