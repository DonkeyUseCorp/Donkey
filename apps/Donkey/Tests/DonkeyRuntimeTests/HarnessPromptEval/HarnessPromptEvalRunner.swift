import DonkeyAI
import DonkeyContracts
import DonkeyHarness
import DonkeyRuntime
import Foundation

/// Prompt/planner evaluation harness: run the REAL agent loop end to end against the REAL hosted model,
/// with the UI and the system stubbed out, and capture the tool calls the model chooses. It exists to
/// answer one question per scenario — given this user turn, what does input → LLM → output actually
/// produce? — so a change to the doctrine, the understanding boundary, a tool descriptor, or a skill can
/// be evaluated, not eyeballed in the running app.
///
/// What is real: the request-understanding boundary, the per-step planner, every prompt and tool
/// descriptor, and the full `GenericHarnessRuntime` loop (planning, stall guards, completion-evidence
/// gate). What is stubbed: the executors. No command runs, no file is touched, no app is driven — each
/// tool hands the planner a scripted observation instead, so the loop keeps moving and we record the plan.
///
/// These tests hit the network and cost model tokens, so they are opt-in via `DONKEY_PROMPT_EVAL=1` (a
/// plain `swift test` skips them). The backend defaults to `http://localhost:3000`; set
/// `DONKEY_WEB_BASE_URL` only to point elsewhere. Run with:
///
///     env DONKEY_PROMPT_EVAL=1 DONKEY_DEV_AUTH_BYPASS=1 \
///       DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       swift test --filter PromptEval
///
/// This file is the shared engine for the `HarnessPromptEval/` folder. Add a category by dropping a new
/// `<Category>PromptEvalTests.swift` beside it with its own `@Suite` and one `@Test` per scenario, each
/// building a `HarnessEvalScenario`; the runner is generic over the prompt and the scripted replies.

/// A scripted reply a stubbed tool hands back to the planner. The system is stubbed, so a tool never
/// touches the real Mac — it returns the observation the scenario wants the model to see next.
struct HarnessEvalStub: Sendable {
    var status: HarnessToolResultStatus = .succeeded
    var summary: String
    var facts: [String: String] = [:]
    var visibleText: [String: String] = [:]

    static func ok(
        _ summary: String,
        facts: [String: String] = [:],
        visibleText: [String: String] = [:]
    ) -> HarnessEvalStub {
        HarnessEvalStub(status: .succeeded, summary: summary, facts: facts, visibleText: visibleText)
    }

    static func failed(_ summary: String) -> HarnessEvalStub {
        HarnessEvalStub(status: .failed, summary: summary)
    }
}

/// One prompt-eval scenario: a user turn plus scripted tool replies. `respond` returns a scripted reply
/// for a given tool call, or nil to fall back to the runner's default (which serves the real built-in
/// skill content for skill lookups and a generic success otherwise). Scenarios are data — add them
/// freely; the runner does not change.
struct HarnessEvalScenario: Sendable {
    var name: String
    var prompt: String
    var frontmostApp: String
    /// Runaway backstop. Each step is a real model call, so keep it modest; the loop normally ends when
    /// the planner calls `run.complete`.
    var maxSteps: Int
    /// Scripted reply for a tool call. The second argument is the files the agent already knows exist —
    /// the static disk plus everything earlier steps produced — so a discovery/probe stub can surface an
    /// output a prior step created, not just the fixture's declared inputs.
    var respond: @Sendable (HarnessToolCall, [String]) -> HarnessEvalStub?

    init(
        name: String,
        prompt: String,
        frontmostApp: String = "Finder",
        maxSteps: Int = 16,
        respond: @escaping @Sendable (HarnessToolCall, [String]) -> HarnessEvalStub? = { _, _ in nil }
    ) {
        self.name = name
        self.prompt = prompt
        self.frontmostApp = frontmostApp
        self.maxSteps = maxSteps
        self.respond = respond
    }
}

/// The captured outcome of a scenario: what the model understood, the ordered tool calls it chose, and
/// the final lifecycle status — input → LLM → output, ready to assert on.
struct HarnessEvalRun {
    var understanding: HarnessRequestUnderstanding?
    var records: [HarnessToolCallRecord]
    var finalStatus: HarnessAgentStatus

    var calls: [HarnessToolCall] { records.map(\.call) }
    var toolNames: [String] { calls.map(\.name) }
    var shellCommands: [String] { calls.filter { $0.name == "shell_exec" }.compactMap { $0.input["command"] } }
    var completed: Bool { finalStatus == .completed }

    func used(_ tool: String) -> Bool { toolNames.contains(tool) }

    /// The inputs of every call to a given tool — so a GUI/vision scenario can assert WHERE an action
    /// landed (e.g. the `elementID` a `vision.click` targeted), not merely that the tool was used.
    func inputs(for tool: String) -> [[String: String]] {
        calls.filter { $0.name == tool }.map(\.input)
    }

    /// True if some `shell_exec` command contains all of the given substrings (case-insensitive) — the
    /// usual shape of a plan assertion (e.g. a yt-dlp call that also passes `--download-sections`).
    func anyShellMatches(_ needles: String...) -> Bool {
        shellCommands.contains { command in
            needles.allSatisfy { command.range(of: $0, options: .caseInsensitive) != nil }
        }
    }

    /// A compact, human-readable transcript of the plan, for `swift test` output so a developer can eyeball
    /// what the model did even when every assertion passes.
    var transcript: String {
        let lines = records.enumerated().map { index, record -> String in
            let input = record.call.input
                .sorted { $0.key < $1.key }
                .map { key, value in "\(key)=\(value.count > 140 ? String(value.prefix(140)) + "…" : value)" }
                .joined(separator: " ")
            let suffix = input.isEmpty ? "" : "  { \(input) }"
            return "  \(index + 1). \(record.call.name) → \(String(describing: record.resultStatus))\(suffix)"
        }
        return lines.joined(separator: "\n")
    }
}

enum HarnessEvalRunner {
    struct Config: Sendable {
        var baseURL: URL
        var clientID: String
        var devAuthBypass: Bool
    }

    /// The dev backend the eval drives when nothing else is configured — the same value the dev build's
    /// Info.plist and `run-donkey-dev.sh` use, so a developer with the local site up can run the eval
    /// without exporting `DONKEY_WEB_BASE_URL`.
    static let defaultBaseURL = URL(string: "http://localhost:3000")!

    /// Returns the live config, or nil when the eval is not opted into. A nil result means the caller
    /// should return early (skip): the single opt-in is `DONKEY_PROMPT_EVAL=1`, because these tests reach
    /// the real model and must never run by accident in a plain `swift test`. The backend URL is resolved
    /// the way the app does — env `DONKEY_WEB_BASE_URL`, then the baked Info.plist `DonkeyWebBaseURL` — and
    /// falls back to the dev default, so it no longer has to be passed by hand.
    static func configFromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Config? {
        guard environment["DONKEY_PROMPT_EVAL"] == "1" else { return nil }
        let baseURL = (try? DonkeyBackendInferenceConfiguration.fromEnvironment(environment))?.baseURL
            ?? defaultBaseURL
        return Config(
            baseURL: baseURL,
            clientID: environment["DONKEY_CLIENT_ID"] ?? "prompt-eval",
            devAuthBypass: environment["DONKEY_DEV_AUTH_BYPASS"] == "1"
        )
    }

    /// Run one scenario: real understanding, real planner, real descriptors, stub executors. Returns the
    /// captured plan. `@MainActor` because the hosted planner and understanding boundary are main-actor
    /// isolated (as they are in the app).
    @MainActor
    static func run(_ scenario: HarnessEvalScenario, config: Config) async -> HarnessEvalRun {
        var configuration = DonkeyBackendInferenceConfiguration(
            baseURL: config.baseURL,
            clientID: config.clientID,
            devAuthBypass: config.devAuthBypass
        )
        let conversationID = "prompt-eval-\(UUID().uuidString)"
        configuration.conversationID = conversationID
        let backend = DonkeyBackendInferenceClient(configuration: configuration)

        // Real one-shot understanding of the turn (turnKind, restated goal, target app, parameters, and the
        // skills it should follow). Feed it the same skill catalog production does so it can pick.
        let skillCatalog = BuiltInLocalAppSkillPacks.skillSelectionCatalog()
        let understanding = await HostedHarnessRequestUnderstanding(backend: backend)
            .understand(
                command: scenario.prompt,
                frontmostAppName: scenario.frontmostApp,
                skillCatalog: skillCatalog
            )

        // Preload the guides for the skills the understanding picked — mirrors production so the eval tests
        // the real surfacing path, not a stub of it.
        let preloadedSkillGuides: [String] = (understanding?.relevantSkillIDs ?? [])
            .prefix(2)
            .compactMap { BuiltInLocalAppSkillPacks.skillGuidance(forID: $0) }

        // Real tool surface; stub executors so the planner sees the true descriptors but nothing executes.
        let descriptors = plannerToolDescriptors()
        let respond = scenario.respond
        let tools = descriptors.map { descriptor in
            HarnessTool(descriptor: descriptor) { context in
                let knownFiles = context.worldModel.facts.compactMap { $0.value == "exists" ? $0.key : nil }.sorted()
                let reply = respond(context.call, knownFiles) ?? defaultReply(for: context.call, knownFiles: knownFiles)
                return HarnessToolResult(
                    callID: context.call.id,
                    toolName: context.call.name,
                    status: reply.status,
                    summary: reply.summary,
                    observations: HarnessObservationDelta(
                        visibleText: reply.visibleText,
                        facts: shellStampedFacts(reply, call: context.call)
                    ),
                    metadata: ["evalStub": "true"]
                )
            }
        }
        let registry = HarnessToolRegistry(tools: tools)

        let coordinator = HarnessAgentCoordinator()
        let goal = (understanding?.restatedGoal).flatMap { $0.isEmpty ? nil : $0 } ?? scenario.prompt
        let agent = await coordinator.createAgent(
            conversationID: conversationID,
            goal: goal,
            grantedPermissions: Set(HarnessPermission.allCases)
        )

        let planner = HostedHarnessStepPlanner(
            backend: backend,
            descriptors: descriptors,
            appName: understanding?.targetAppName ?? "",
            appGuidance: nil,
            understanding: understanding,
            preloadedSkillGuides: preloadedSkillGuides
        )

        let runtime = GenericHarnessRuntime(coordinator: coordinator, registry: registry)
        _ = await runtime.run(agentID: agent.id, planner: planner, maxSteps: scenario.maxSteps)

        let final = await coordinator.agent(id: agent.id)
        return HarnessEvalRun(
            understanding: understanding,
            records: final?.toolHistory ?? [],
            finalStatus: final?.status ?? .failedSafe
        )
    }

    /// The tool surface the planner SEES, assembled the way production does in `UserQueryCommandHandler`:
    /// the built-in catalog with the placeholder see/act tools removed, plus the real AX, vision, and
    /// pointer see/act DESCRIPTORS (and the native music tools). Execution is stubbed either way, but the
    /// planner must read the SAME tool NAMES the app gives it — `ax.observe` / `ax.click` / `vision.capture`
    /// / `vision.click` — or a GUI/vision scenario would exercise a screen surface the model never gets and
    /// every grounding assertion would be meaningless. Deduped by name (first wins, so a non-replaced
    /// built-in keeps its place) in case two providers ever advertise the same tool.
    @MainActor
    static func plannerToolDescriptors() -> [HarnessToolDescriptor] {
        // The placeholders the providers below supersede — same set production strips before registering
        // the real see/act tools, so the planner is never offered both a placeholder and its replacement.
        let replaced: Set<String> = ["screen.observe", "elements.get", "element.perform", "text.enter", "keyboard.press"]
        let base = BuiltInHarnessToolCatalog.descriptors.filter { !replaced.contains($0.name) }
        let seeAct = AXComputerUseToolProvider.descriptors
            + VisionComputerUseToolProvider.descriptors
            + PointerComputerUseToolProvider.descriptors
            + MusicPlaybackToolProvider.descriptors
        var seen = Set<String>()
        return (base + seeAct).filter { seen.insert($0.name).inserted }
    }

    /// Default stubbed reply when a scenario does not script the call. Skill lookups get the REAL built-in
    /// `SKILL.md` (so the eval exercises the same guidance the planner reads in production), and everything
    /// else gets a generic success carrying a fact so the step counts as progress and the loop advances.
    private static func defaultReply(for call: HarnessToolCall, knownFiles: [String]) -> HarnessEvalStub {
        switch call.name {
        case "skill.search":
            return .ok(
                "Matching skills: media (audio/video — yt-dlp download, ffmpeg transcode/trim/subtitle), "
                    + "pdf (forms — pdf-fill, lit, qpdf), system-tools (safe shell technique). Load one for its full guide.",
                facts: ["skills.found": "media,pdf,system-tools"]
            )
        case "skill.load", "app_skill", "skill_run":
            let id = call.input["id"] ?? call.input["skill"] ?? call.input["name"] ?? call.input["app"] ?? ""
            if let content = builtInSkill(matching: id) {
                return .ok(content, facts: ["skill.loaded": id])
            }
            return .ok("Loaded.", facts: ["skill.loaded": id])
        case "files.describe":
            let listing = knownFiles.isEmpty
                ? "The directory is empty."
                : knownFiles.map { "\($0) — present" }.joined(separator: "; ")
            return .ok(listing)
        default:
            // A read-only discovery/verify command (find, ls, stat, ffprobe…) is the model confirming an
            // output it just produced. The system is stubbed, so every prior write SUCCEEDED: when the
            // probe names concrete output path(s), confirm those EXACT paths — whatever the model chose to
            // call them — and record them present, so a verify of the file it just made resolves on the
            // first try instead of being handed a fixture's hardcoded name and re-checking until the
            // duplicate-call guard fails the run. A path-less probe (bare `ls`, `pwd`) or a discovery over
            // a directory/glob still reports the files prior steps created.
            if let command = call.input["command"], isFileProbe(command) {
                let probed = probedPaths(in: command)
                if !probed.isEmpty {
                    return .ok(
                        probed.joined(separator: "\n"),
                        facts: Dictionary(probed.map { ($0, "exists") }, uniquingKeysWith: { current, _ in current })
                    )
                }
                return .ok(knownFiles.isEmpty ? "(no matching files)" : knownFiles.joined(separator: "\n"))
            }
            return .ok("\(call.name) ran.", facts: ["lastStub": call.name])
        }
    }

    /// The observation facts a stubbed reply carries, with the same `lastShellExitCode` the REAL shell
    /// executor stamps on every successful `shell_exec` (DonkeyCommandBackends). Production attaches it
    /// unconditionally, which is what makes a read-only shell command (a `lit parse`, a `cat`) count as
    /// progress in the runtime's stall accounting; a stub that returned content with no fact scored as
    /// no-progress and tripped the stall guard mid-task — a false failure the real app never hits. Mirror
    /// production so the eval measures the plan, not a missing fact.
    private static func shellStampedFacts(_ reply: HarnessEvalStub, call: HarnessToolCall) -> [String: String] {
        guard call.name == "shell_exec", reply.status == .succeeded else { return reply.facts }
        var facts = reply.facts
        facts["lastShellExitCode"] = facts["lastShellExitCode"] ?? "0"
        return facts
    }

    /// True for a read-only command whose job is to look at the filesystem — so the stub answers with the
    /// known files rather than a content-free success.
    private static func isFileProbe(_ command: String) -> Bool {
        let lowered = command.lowercased()
        let probes = ["find ", "ls ", "ls\n", "stat ", "test ", "file ", "ffprobe", "du ", "wc ", "realpath", "pwd"]
        return lowered == "ls" || probes.contains { lowered.contains($0) }
    }

    /// The concrete file paths a probe command names — a token with a path separator and a filename
    /// extension, not a flag and not a glob. Those are the outputs the model is verifying; in a stubbed
    /// world they all exist, so the probe confirms exactly the paths asked about, regardless of the name
    /// the model picked. A directory or glob (`~/Downloads`, `*.mp4`) yields nothing, so a discovery
    /// listing falls through to the known-files reply.
    private static func probedPaths(in command: String) -> [String] {
        command
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\"`")) }
            .filter { token in
                guard token.contains("/"), !token.hasPrefix("-") else { return false }
                guard !token.contains(where: { "*?[]".contains($0) }) else { return false }
                return (token as NSString).lastPathComponent.contains(".")
            }
    }

    /// Best-effort load of a built-in `SKILL.md` from the DonkeyRuntime resource bundle by a loose id
    /// match, so the planner sees the real media/pdf/system-tools guidance. Returns nil for an unknown id.
    private static func builtInSkill(matching id: String) -> String? {
        let key = id.lowercased()
        let known = ["media", "pdf", "system-tools", "documents", "images", "data", "web-capture"]
        guard let match = known.first(where: { key.contains($0) }) else { return nil }
        guard let url = DonkeyResourceBundle.runtime?.url(
            forResource: "SKILL",
            withExtension: "md",
            subdirectory: "BuiltInSkills/\(match)"
        ) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
