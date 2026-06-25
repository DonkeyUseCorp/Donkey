import DonkeyAI
import DonkeyContracts
import DonkeyHarness
import DonkeyRuntime
import Foundation

/// A shell command the Live model wants to run that needs the user's consent
/// (allow once / always allow) before it can execute.
struct GeminiLiveShellConsentRequest: Equatable, Sendable {
    var command: String
    var signature: String
    var tier: String
    var allowAlways: Bool
    var summary: String
}

/// Drives the always-on Gemini Live session for the app: streams text (and
/// optionally audio) into the session, executes the model's tool calls against
/// the Donkey Command Layer, and surfaces the model's answers and delegations
/// back to the overlay.
///
/// Entirely gated by `GeminiLiveConfiguration.enabled`; when disabled, nothing
/// here runs and the existing pipeline is unchanged.
@MainActor
final class GeminiLiveVoiceController {
    private let configuration: GeminiLiveConfiguration
    private let systemInstruction: String
    private let registry: HarnessToolRegistry
    private var session: GeminiLiveSession?
    private var eventTask: Task<Void, Never>?
    /// The model's in-flight text answer, accumulated across `.textOut` chunks
    /// and flushed to `onResponse` when the turn completes.
    private var pendingResponseText = ""
    /// The audio-mode answer transcription, used when no text parts arrived.
    private var pendingResponseTranscript = ""
    /// A consent-gated tool call held until the user decides in the notch UI.
    private var pendingConsent: (call: HarnessToolCall, liveCall: AIRealtimeToolCall, session: GeminiLiveSession)?

    /// Invoked when the model explicitly delegates a task it can't do with the
    /// fast tools (the `agent_run` function call), with the structured goal.
    /// Wire this to the overlay's local-pipeline submit path.
    var onComplexRequest: ((String) -> Void)?
    /// Invoked after a Command Layer tool runs, with a short status summary, so
    /// the UI can reflect that the model acted.
    var onActed: ((String) -> Void)?
    /// Invoked with the model's completed answer for the current turn.
    var onResponse: ((String) -> Void)?
    /// Invoked when a shell command needs allow-once / always-allow consent.
    /// The decision comes back through `resolvePendingConsent`.
    var onConsentNeeded: ((GeminiLiveShellConsentRequest) -> Void)?
    /// Invoked when optional microphone streaming should start (`true`) or stop
    /// (`false`). Always paired — a `true` is always followed by a `false` when
    /// the session disconnects or stops — so the mic owner never gets stuck on.
    var onAudioStreamingChanged: ((Bool) -> Void)?

    var isEnabled: Bool { configuration.enabled }
    var isAudioEnabled: Bool { configuration.audioEnabled }
    /// True once the session is live and accepting input.
    private(set) var isConnected = false
    private var isAudioStreaming = false

    /// Mints the Vertex auth for the vision escalation. Defaults to the backend
    /// token-mint path; injectable for tests.
    private let visionAuthProvider: @Sendable () async throws -> GeminiVertexVisionPlanner.VertexAuth

    init(
        configuration: GeminiLiveConfiguration = .fromEnvironment(),
        systemInstruction: String = DonkeyPrompts.realtimeCommandSystemInstruction,
        visionAuthProvider: @escaping @Sendable () async throws -> GeminiVertexVisionPlanner.VertexAuth = {
            try await GeminiVertexVisionPlanner.mintAuth(
                backend: DonkeyBackendInferenceClient(configuration: try DonkeyBackendInferenceConfiguration.fromEnvironment())
            )
        }
    ) {
        self.configuration = configuration
        self.systemInstruction = systemInstruction
        self.visionAuthProvider = visionAuthProvider
        // Wire the generic LLM tool into the fast path too, so the Live model can compose/transform
        // text mid-task (a tracklist, a clean note body) through the hosted route.
        var services = HarnessBuiltInToolServices(commandExecutor: DonkeyCommandBackends.makeExecutor())
        if let backendConfiguration = try? DonkeyBackendInferenceConfiguration.fromEnvironment() {
            let backend = DonkeyBackendInferenceClient(configuration: backendConfiguration)
            let textGenerator = HostedTextGenerator(backend: backend)
            services.textGenerator = { await textGenerator.generate($0) }
            services.mediaGenerator = { prompt, fileURL, mimeType in
                await textGenerator.generate(prompt, attachmentPath: fileURL, mimeType: mimeType)
            }
            // Web research goes through the backend on the service-account credential: search uses
            // Google Search grounding; fetch returns the page as clean markdown (boilerplate stripped).
            let hostedWebSearch = HostedWebSearch(backend: backend)
            services.webSearcher = { await hostedWebSearch.search($0) }
            let hostedWebFetch = HostedWebFetch(backend: backend)
            services.webFetcher = { await hostedWebFetch.fetch($0) }
        }
        let extraToolNames: Set<String> = ["llm.generate", "web.search", "web.fetch"]
        let extraDescriptors = BuiltInHarnessToolCatalog.descriptors.filter { extraToolNames.contains($0.name) }
        let liveDescriptors = DonkeyCommandLayer.descriptors + extraDescriptors
        self.liveToolDescriptors = liveDescriptors
        self.registry = HarnessToolRegistry(
            tools: BuiltInHarnessToolExecutors.tools(
                descriptors: liveDescriptors,
                services: services
            )
        )
    }

    /// The harness-registered tools the Live session exposes (command layer + the generic LLM tool).
    /// Vision/agent escalation descriptors are added on top when the session starts.
    private let liveToolDescriptors: [HarnessToolDescriptor]

    func start() async {
        guard configuration.enabled, session == nil else { return }
        let session = GeminiLiveSession(
            systemInstruction: systemInstruction,
            functionDescriptors: liveToolDescriptors + [Self.visionControlDescriptor, Self.agentRunDescriptor],
            connectionProvider: Self.makeConnectionProvider()
        )
        self.session = session
        eventTask = Task { [weak self] in
            for await event in session.events {
                await self?.handle(event)
            }
        }
        do {
            try await session.connect()
            isConnected = true
            updateAudioStreaming()
        } catch {
            await stop()
        }
    }

    func stop() async {
        eventTask?.cancel()
        eventTask = nil
        await session?.close()
        session = nil
        isConnected = false
        updateAudioStreaming()
    }

    /// Drive the mic-owner callback from the single source of truth (connected +
    /// audio enabled), so continuous listening is always torn down on disconnect.
    private func updateAudioStreaming() {
        let shouldStream = isConnected && configuration.audioEnabled
        guard shouldStream != isAudioStreaming else { return }
        isAudioStreaming = shouldStream
        onAudioStreamingChanged?(shouldStream)
    }

    /// Send a typed/spoken text turn (the always-available input).
    func sendText(_ text: String) async {
        guard let session else { return }
        try? await session.sendText(text)
    }

    /// Stream optional microphone audio (resampled to the Live input format).
    func sendAudioFrames(_ samples: [Float], sampleRate: Double) async {
        guard configuration.audioEnabled, let session else { return }
        let pcm16 = GeminiLivePCM.pcm16Mono16k(from: samples, sourceRate: Int(sampleRate))
        guard !pcm16.isEmpty else { return }
        try? await session.sendAudioChunk(pcm16)
    }

    // MARK: - Event handling

    private func handle(_ event: AIRealtimeEvent) async {
        switch event {
        case .connected:
            isConnected = true
            updateAudioStreaming()
        case .toolCalls(let calls):
            await execute(calls)
        case .textOut(let text):
            pendingResponseText += text
        case .finalTranscript(let text):
            // The model's own answer transcription (audio mode). It is OUTPUT,
            // never a user request — surface it as the answer, don't re-run it.
            pendingResponseTranscript = text
        case .turnComplete:
            flushResponse()
        case .interrupted:
            pendingResponseText = ""
            pendingResponseTranscript = ""
        case .closed:
            isConnected = false
            updateAudioStreaming()
        default:
            break
        }
    }

    /// Deliver the model's completed answer for this turn, preferring text parts
    /// over the audio transcription when both arrived.
    private func flushResponse() {
        let answer = pendingResponseText.isEmpty ? pendingResponseTranscript : pendingResponseText
        pendingResponseText = ""
        pendingResponseTranscript = ""
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onResponse?(trimmed)
    }

    /// The task id consent grants and tool executions are keyed on for this
    /// session-wide Live "task".
    static let liveAgentID = "gemini-live"

    /// Permissions the Live session's Command Layer tools run with.
    static let liveGrantedPermissions: Set<HarnessPermission> = [.appControl, .input, .appLookup, .skillLookup]

    private func execute(_ calls: [AIRealtimeToolCall]) async {
        guard let session else { return }
        var results: [AIRealtimeToolResult] = []
        for call in calls {
            // Gemini sometimes namespaces the tool-call name (e.g. `default_<name>`);
            // dispatch on the canonical name (a structured field, not user text).
            let toolName = Self.canonicalToolName(call.name)
            // Escalation to vision: run OUTSIDE this event-consumer task (capture
            // hangs inside `for await session.events`) and answer the model when the
            // drive finishes.
            if toolName == Self.visionControlToolName {
                launchVision(call)
                continue
            }
            // Explicit delegation to the desktop agent: hand the structured goal
            // to the local pipeline (which has its own UI and reporting) and let
            // the Live turn finish immediately.
            if toolName == Self.agentRunToolName {
                let goal = (call.arguments["goal"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !goal.isEmpty else {
                    results.append(AIRealtimeToolResult(
                        id: call.id,
                        name: call.name,
                        response: ["status": "invalidInput", "summary": "agent_run needs a non-empty `goal`."]
                    ))
                    continue
                }
                onComplexRequest?(goal)
                results.append(AIRealtimeToolResult(
                    id: call.id,
                    name: call.name,
                    response: [
                        "status": "delegated",
                        "summary": "Handed off to the desktop agent; it reports its progress and result to the user directly. Tell the user it's underway."
                    ]
                ))
                continue
            }
            let toolCall = HarnessToolCall(id: call.id, name: toolName, input: call.arguments)
            let result = await registry.execute(
                toolCall,
                agentID: Self.liveAgentID,
                worldModel: HarnessWorldModel(),
                grantedPermissions: Self.liveGrantedPermissions
            )
            // Shell consent: hold the call, surface allow-once / always-allow in
            // the notch, and answer the session when the user decides — the same
            // gate the harness path uses, so nothing state-changing runs silently.
            if result.status == .waitingForPermission, result.metadata["gate"] == "shellConsent" {
                holdForConsent(call: toolCall, liveCall: call, session: session, result: result)
                continue
            }
            // Structural feedback loop: a tool that attempted an action but couldn't confirm it can
            // signal escalation with `escalate.app`/`escalate.goal` (e.g. the music script searched
            // but didn't start playback). Rather than trusting the fast model to retry, the controller
            // itself hands off to the vision observe-act loop, which sees the screen and finishes the
            // task. This makes the loop part of the system, not the prompt.
            if let escalateApp = result.metadata["escalate.app"]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !escalateApp.isEmpty {
                let escalateGoal = result.metadata["escalate.goal"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                onActed?("Adjusting — having the vision agent finish \"\(toolName)\" in \(escalateApp).")
                launchVision(AIRealtimeToolCall(
                    id: call.id,
                    name: Self.visionControlToolName,
                    arguments: ["app": escalateApp, "goal": (escalateGoal?.isEmpty == false ? escalateGoal! : result.summary)]
                ))
                continue
            }
            onActed?(result.summary)
            // Forward the full execution detail (stdout/stderr/exitCode/reason,
            // plus tool-specific facts) so the model can read output and
            // self-correct on failure. `executor` is internal noise.
            var response = result.metadata
            response.removeValue(forKey: "executor")
            response["status"] = result.status.rawValue
            response["summary"] = result.summary
            // Surface a clarification gate (e.g. a skill script asking for a missing detail)
            // so the model asks the user instead of guessing or stalling.
            if result.status == .waitingForUser, let question = result.question {
                response["needsUserInput"] = "true"
                response["question"] = question
            }
            results.append(AIRealtimeToolResult(
                id: call.id,
                name: call.name,
                response: response
            ))
        }
        if !results.isEmpty { try? await session.sendToolResults(results) }
    }

    // MARK: - Shell consent

    /// Park a consent-gated shell command and surface the decision UI. A newer
    /// gated command supersedes a parked one (the old call is answered as
    /// declined so the session never hangs on it).
    private func holdForConsent(
        call: HarnessToolCall,
        liveCall: AIRealtimeToolCall,
        session: GeminiLiveSession,
        result: HarnessToolResult
    ) {
        if let superseded = pendingConsent {
            answerConsent(superseded, status: "declined", summary: "Superseded by a newer command awaiting approval.")
        }
        pendingConsent = (call, liveCall, session)
        let request = GeminiLiveShellConsentRequest(
            command: result.metadata["shell.command"] ?? call.input["command"] ?? "",
            signature: result.metadata["shell.signature"] ?? "",
            tier: result.metadata["shell.tier"] ?? "",
            allowAlways: result.metadata["shell.allowAlways"] == "true",
            summary: result.summary
        )
        onConsentNeeded?(request)
    }

    /// The user decided on the parked command: grant (once or always) and
    /// re-execute it, or decline it, then answer the waiting Live tool call.
    func resolvePendingConsent(approved: Bool, alwaysAllow: Bool) async {
        guard let pending = pendingConsent else { return }
        pendingConsent = nil
        guard approved else {
            answerConsent(pending, status: "declined", summary: "The user declined to run the command.")
            return
        }
        let command = pending.call.input["command"] ?? pending.call.input["cmd"] ?? ""
        let classification = ShellCommandClassifier.classify(command)
        if alwaysAllow, classification.tier != .highRisk {
            await ShellPermissionPolicyStore.shared.allowAlways(classification.signature, tier: classification.tier)
        } else {
            await ShellPermissionPolicyStore.shared.grantOnce(agentID: Self.liveAgentID, signature: classification.signature)
        }
        let result = await registry.execute(
            pending.call,
            agentID: Self.liveAgentID,
            worldModel: HarnessWorldModel(),
            grantedPermissions: Self.liveGrantedPermissions
        )
        onActed?(result.summary)
        var response = result.metadata
        response.removeValue(forKey: "executor")
        response["status"] = result.status.rawValue
        response["summary"] = result.summary
        try? await pending.session.sendToolResults([
            AIRealtimeToolResult(id: pending.liveCall.id, name: pending.liveCall.name, response: response)
        ])
    }

    private func answerConsent(
        _ pending: (call: HarnessToolCall, liveCall: AIRealtimeToolCall, session: GeminiLiveSession),
        status: String,
        summary: String
    ) {
        let result = AIRealtimeToolResult(
            id: pending.liveCall.id,
            name: pending.liveCall.name,
            response: ["status": status, "summary": summary]
        )
        Task { try? await pending.session.sendToolResults([result]) }
    }

    /// Run the vision escalation in a separate task (NOT the event-consumer task)
    /// and answer the model's `vision_control` call when the drive completes.
    private func launchVision(_ call: AIRealtimeToolCall) {
        let app = (call.arguments["app"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = (call.arguments["goal"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configuration.visionModel
        let callID = call.id
        let toolName = call.name
        let provider = visionAuthProvider
        // Bind the result to the session that issued this call. A drive can run for
        // minutes; if `stop()`/`start()` replaces the session meanwhile, we must not
        // answer a fresh session that never made this call (it would leave the
        // original turn unanswered and could confuse the new one).
        let session = self.session

        // The model supplies `app`/`goal`; an empty `app` can't resolve a window, so
        // answer immediately asking for it instead of burning a no-op drive.
        guard !app.isEmpty else {
            let summary = "vision_control needs a non-empty `app` to operate; ask the user which app and retry."
            onActed?(summary)
            Task { try? await session?.sendToolResults([
                AIRealtimeToolResult(id: callID, name: toolName, response: ["status": "invalidInput", "summary": summary])
            ]) }
            return
        }

        Task { [weak self] in
            let status: String
            let summary: String
            do {
                let auth = try await provider()
                let outcome = await VertexVisionDriver.drive(
                    appName: app, bundleIdentifier: nil, goal: goal, auth: auth, model: model
                )
                let completed = outcome.completed
                let turns = outcome.turns
                status = completed ? "succeeded" : "incomplete"
                summary = "vision \(completed ? "completed" : "did not complete") \"\(goal)\" in \(app) over \(turns) turns"
            } catch {
                status = "failed"
                summary = "vision could not start (the screen-vision path needs the Vertex backend; check DONKEY_WEB_BASE_URL): \(error)"
            }
            self?.onActed?(summary)
            try? await session?.sendToolResults([
                AIRealtimeToolResult(id: callID, name: toolName, response: ["status": status, "summary": summary])
            ])
        }
    }

    // MARK: - Auth

    /// Connection provider chosen by configuration: the Developer-API key path
    /// when `GEMINI_API_KEY` is set, else the Vertex backend-mint path. Re-invoked
    /// on every (re)connect so Vertex OAuth tokens stay fresh.
    private static func makeConnectionProvider() -> @Sendable () async throws -> GeminiLiveConnection {
        GeminiLiveConnectionFactory.makeProvider()
    }

    /// Strip a Gemini name-spacing prefix (`default_api.`, `default_`) from a
    /// tool-call name so dispatch matches the declared name.
    static func canonicalToolName(_ raw: String) -> String {
        for prefix in ["default_api.", "default_api_", "default_"] where raw.hasPrefix(prefix) {
            return String(raw.dropFirst(prefix.count))
        }
        return raw
    }

    // MARK: - Agent delegation

    static let agentRunToolName = "agent_run"

    /// Explicit, typed escalation to the full desktop agent (the generic harness
    /// loop with understanding, planning, consent gates, and verification). The
    /// model calls this instead of guessing when the fast tools can't do the task.
    static let agentRunDescriptor = HarnessToolDescriptor(
        name: agentRunToolName,
        pluginID: "donkey.agent",
        summary: "Delegate a task to the full desktop agent, which plans multi-step work, drives app GUIs, and asks the user for consent when needed. Use when the fast tools can't complete the request — multi-step workflows, tasks inside an app's UI beyond a single command, or anything you cannot verify with the tools you have. Do not use it for questions you can answer directly or single commands shell_exec covers.",
        inputSchema: [
            "goal": "The task to accomplish, restated as one concrete imperative sentence carrying the user's specifics (titles, names, values)."
        ],
        requiredPermissions: [.appControl, .input],
        safetyClass: .guardedInput
    )

    // MARK: - Vision escalation

    static let visionControlToolName = "vision_control"

    /// The screen-last escalation tool: when no fast tool can operate an app, the
    /// model calls this and a vision agent (gemini-3.5) drives the app by sight.
    /// Not a `DonkeyCommandLayer` command — it's a Live-controller capability handled
    /// in `launchVision`, since its backend needs `DonkeyAI` (which `DonkeyRuntime`,
    /// where the Command Layer backends live, can't import).
    static let visionControlDescriptor = HarnessToolDescriptor(
        name: visionControlToolName,
        pluginID: "donkey.vision",
        summary: "Operate an app by looking at the screen (a vision agent clicks/types). Use ONLY when a task must happen inside a specific app the fast tools can't drive — typically when the app's skill (from app_skill) says it must be driven by vision, or when scripting it failed.",
        inputSchema: [
            "app": "The app to operate.",
            "goal": "What to accomplish in the app, stated concretely."
        ],
        requiredPermissions: [.input, .screenCapture],
        safetyClass: .guardedInput
    )

}
