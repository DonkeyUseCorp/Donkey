import DonkeyAI
import DonkeyContracts
import DonkeyHarness
import DonkeyRuntime
import Foundation

/// FUNCTIONAL evaluation harness — the counterpart to the prompt/planner eval. Where the prompt eval stubs
/// every executor and grades the *plan*, the functional eval wires the REAL tool executors and grades the
/// *result*: it runs the actual agent loop, lets `shell_exec` / `files.describe` / the bundled CLI tools
/// (`lit`, `pdf-fill`, `qpdf`, `ffmpeg`, …) really run, and asserts on the files they produce.
///
/// Safety is by construction, not by trust:
///   - It runs only in a throwaway sandbox under the user's home (shell's cwd is hard-anchored to home, so a
///     sandbox there is the one place a relative or discovered path lands). Inputs are copied in; the prompt
///     names that directory explicitly so the agent never reaches for the user's real files.
///   - It pre-authorizes each shell command headlessly by computing the same signature the consent gate
///     uses and granting it once — so a reversible write runs without a UI prompt, but nothing is silently
///     made a standing rule.
///   - It is opt-in behind `DONKEY_FUNCTIONAL_EVAL=1` AND the same hosted-backend env the prompt eval needs,
///     so a plain `swift test` never executes anything. Run with:
///
///     env DONKEY_FUNCTIONAL_EVAL=1 DONKEY_PROMPT_EVAL=1 DONKEY_WEB_BASE_URL=http://localhost:3000 \
///       DONKEY_DEV_AUTH_BYPASS=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///       swift test --filter FunctionalEval
struct FunctionalEvalConfig: Sendable {
    var baseURL: URL
    var clientID: String
    var devAuthBypass: Bool
}

/// The captured outcome of a functional run: what the model understood, the tool calls it made, the final
/// status, and the sandbox the work happened in (so assertions can inspect the real output files).
struct FunctionalEvalRun {
    var understanding: HarnessRequestUnderstanding?
    var records: [HarnessToolCallRecord]
    var finalStatus: HarnessAgentStatus
    var sandbox: URL

    var calls: [HarnessToolCall] { records.map(\.call) }
    var toolNames: [String] { calls.map(\.name) }
    var shellCommands: [String] { calls.filter { $0.name == "shell_exec" }.compactMap { $0.input["command"] } }
    var completed: Bool { finalStatus == .completed }

    var transcript: String {
        records.enumerated().map { index, record in
            let input = record.call.input
                .sorted { $0.key < $1.key }
                .map { key, value in "\(key)=\(value.count > 160 ? String(value.prefix(160)) + "…" : value)" }
                .joined(separator: " ")
            let suffix = input.isEmpty ? "" : "  { \(input) }"
            var line = "  \(index + 1). \(record.call.name) → \(String(describing: record.resultStatus))\(suffix)"
            // Surface the result summary for anything that did not plainly succeed: that text carries WHY a
            // tool failed (e.g. the orchestrator's "could not map" / "no form file"), invisible otherwise.
            if record.resultStatus != .succeeded, !record.summary.isEmpty {
                let reason = record.summary.count > 240 ? String(record.summary.prefix(240)) + "…" : record.summary
                line += "\n       ↳ \(reason)"
            }
            return line
        }.joined(separator: "\n")
    }
}

enum FunctionalEvalRunner {
    /// Live config, or nil when not opted in (the caller then returns early — these tests both reach the real
    /// model and really execute tools, so they must never run by accident).
    static func configFromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> FunctionalEvalConfig? {
        guard environment["DONKEY_FUNCTIONAL_EVAL"] == "1" else { return nil }
        guard let raw = environment["DONKEY_WEB_BASE_URL"], !raw.isEmpty, let url = URL(string: raw) else {
            return nil
        }
        return FunctionalEvalConfig(
            baseURL: url,
            clientID: environment["DONKEY_CLIENT_ID"] ?? "functional-eval",
            devAuthBypass: environment["DONKEY_DEV_AUTH_BYPASS"] == "1"
        )
    }

    /// Run one functional scenario end to end with real executors against a sandbox. `@MainActor` because
    /// the hosted planner and understanding boundary are main-actor isolated, as in the app.
    @MainActor
    static func run(
        prompt: String,
        frontmostApp: String,
        maxSteps: Int,
        sandbox: URL,
        config: FunctionalEvalConfig
    ) async -> FunctionalEvalRun {
        var configuration = DonkeyBackendInferenceConfiguration(
            baseURL: config.baseURL,
            clientID: config.clientID,
            devAuthBypass: config.devAuthBypass
        )
        let conversationID = "functional-eval-\(UUID().uuidString)"
        configuration.conversationID = conversationID
        let backend = DonkeyBackendInferenceClient(configuration: configuration)

        // Real one-shot understanding, fed the production skill catalog so it surfaces the right skill.
        let skillCatalog = BuiltInLocalAppSkillPacks.skillSelectionCatalog()
        let understanding = await HostedHarnessRequestUnderstanding(backend: backend)
            .understand(command: prompt, frontmostAppName: frontmostApp, skillCatalog: skillCatalog, conversationContext: nil)
        let preloadedSkillGuides: [String] = (understanding?.relevantSkillIDs ?? [])
            .prefix(2)
            .compactMap { BuiltInLocalAppSkillPacks.skillGuidance(forID: $0) }

        // REAL executors — the same services the app wires — but with the shell command executor wrapped so
        // each command is pre-authorized headlessly. The wrapper computes the consent gate's own signature
        // and grants it once before delegating, so a reversible write (e.g. `pdf-fill set … -o out.pdf`)
        // runs without a UI prompt while high-risk commands still get only a single, non-standing grant.
        var services = LocalAppUserQueryHarnessServices.builtInSkillBackedServices()
        if let realCommandExecutor = services.commandExecutor {
            services.commandExecutor = { context in
                if context.call.name == "shell_exec",
                   let command = context.call.input["command"] ?? context.call.input["cmd"] {
                    let classification = ShellCommandClassifier.classify(command)
                    await ShellPermissionPolicyStore.shared.grantOnce(
                        agentID: context.agentID,
                        signature: classification.signature
                    )
                }
                return await realCommandExecutor(context)
            }
        }
        // Wire pdf.fill exactly as production does, using the eval's backend, so the forced-apply form
        // pipeline runs headlessly. Without this, services.formFiller is nil and pdf.fill reports unavailable.
        let formMapper = HostedFormMapper(backend: backend)
        let formOrchestrator = FormFillOrchestrator(mapper: { form, data in await formMapper.map(formText: form, dataText: data) })
        services.formFiller = { request in await formOrchestrator.fill(request) }
        let registry = BuiltInHarnessToolCatalog.registryWithBuiltInExecutors(services: services)
        let descriptors = BuiltInHarnessToolCatalog.descriptors

        // Wire a hermetic conversation store, as the app does (it passes a FileHarnessConversationStore). The
        // coordinator no-ops its whole workspace subsystem without one — `ensureWorkspaceRoot` seeds the
        // per-conversation working directory only when a store is present, deliverables are tracked through
        // the store, and the small-file context fact reads off the resulting baseDir. A store-less eval
        // therefore never exercises any of that and the agent falls back to writing in $HOME, which is NOT
        // how production runs. The store file lives inside the sandbox so it is cleaned up with it.
        let storeURL = sandbox
            .appendingPathComponent(".harness-store", isDirectory: true)
            .appendingPathComponent("conversations.json")
        let coordinator = HarnessAgentCoordinator(conversationStore: FileHarnessConversationStore(storeURL: storeURL))
        let goal = (understanding?.restatedGoal).flatMap { $0.isEmpty ? nil : $0 } ?? prompt
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
        _ = await runtime.run(agentID: agent.id, planner: planner, maxSteps: maxSteps, compactor: nil)

        let final = await coordinator.agent(id: agent.id)
        return FunctionalEvalRun(
            understanding: understanding,
            records: final?.toolHistory ?? [],
            finalStatus: final?.status ?? .failedSafe,
            sandbox: sandbox
        )
    }
}
