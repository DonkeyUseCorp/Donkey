import DonkeyAI
import DonkeyContracts
import DonkeyHarness
import Foundation
import Testing

/// Prompt/planner eval — DATA-DRIVEN scenarios. Each case is a folder under `Fixtures/HarnessEval/` holding
/// a `prompt.txt`, a `scenario.json`, and any realistic input data the task operates on (CSVs, form data, a
/// captured web page). The runner is the same as the hand-written category suites; only the scenario source
/// differs. Real model, stubbed system + UI; opt-in exactly like the others — a plain `swift test` returns
/// early. Run with:
///
///     env DONKEY_PROMPT_EVAL=1 DONKEY_WEB_BASE_URL=http://localhost:3000 DONKEY_DEV_AUTH_BYPASS=1 \
///       DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       swift test --filter PromptEval
///
/// Add a scenario by dropping a new folder under `Fixtures/HarnessEval/` — it is discovered automatically;
/// no Swift change needed.
@Suite
@MainActor
struct FixturePromptEvalTests {
    @Test(arguments: HarnessEvalFixture.all())
    func scenario(_ fixture: HarnessEvalFixture) async {
        guard let config = HarnessEvalRunner.configFromEnvironment() else { return }

        let run = await HarnessEvalRunner.run(fixture.scenario(), config: config)
        print(
            "\n=== eval: \(fixture.name) (final: \(String(describing: run.finalStatus))) ===\n"
                + "selected skills: \(run.understanding?.relevantSkillIDs ?? [])\n\(run.transcript)\n"
        )

        assertExpectations(fixture, run)
    }

    /// Assert the fixture's `expect` block against the produced plan. Each clause carries the fixture name so
    /// a failure points straight at the offending folder.
    private func assertExpectations(_ fixture: HarnessEvalFixture, _ run: HarnessEvalRun) {
        guard let expect = fixture.spec.expect else { return }
        let name = fixture.name
        let skills = run.understanding?.relevantSkillIDs ?? []

        if let turnKind = expect.turnKind {
            #expect(
                run.understanding?.turnKind.rawValue == turnKind,
                "[\(name)] turnKind expected \(turnKind), got \(String(describing: run.understanding?.turnKind))"
            )
        }
        for id in expect.skills ?? [] {
            #expect(skills.contains(id), "[\(name)] expected skill \(id); got \(skills)")
        }
        if let any = expect.skillsAny, !any.isEmpty {
            #expect(any.contains(where: skills.contains), "[\(name)] expected any of \(any); got \(skills)")
        }
        for group in expect.shellAll ?? [] {
            #expect(shellMatches(run, group), "[\(name)] expected a shell command matching all of \(group); shells: \(run.shellCommands)")
        }
        if let groups = expect.shellAny, !groups.isEmpty {
            #expect(groups.contains { shellMatches(run, $0) }, "[\(name)] expected a shell command matching any of \(groups); shells: \(run.shellCommands)")
        }
        for tool in expect.used ?? [] {
            #expect(run.used(tool), "[\(name)] expected tool \(tool) used; tools: \(run.toolNames)")
        }
        for tool in expect.notUsed ?? [] {
            #expect(!run.used(tool), "[\(name)] expected tool \(tool) NOT used; tools: \(run.toolNames)")
        }
        if let completed = expect.completed {
            #expect(run.completed == completed, "[\(name)] expected completed=\(completed), got \(run.completed)")
        }
    }

    /// True if some `shell_exec` command contains every substring in `needles` (case-insensitive) — the
    /// array form of `HarnessEvalRun.anyShellMatches`, for `shellAll` / `shellAny` groups.
    private func shellMatches(_ run: HarnessEvalRun, _ needles: [String]) -> Bool {
        run.shellCommands.contains { command in
            needles.allSatisfy { command.range(of: $0, options: .caseInsensitive) != nil }
        }
    }
}
