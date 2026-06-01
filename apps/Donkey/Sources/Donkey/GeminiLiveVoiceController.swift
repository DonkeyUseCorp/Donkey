import DonkeyAI
import DonkeyContracts
import DonkeyHarness
import DonkeyRuntime
import Foundation

/// Drives the always-on Gemini Live session for the app: streams text (and
/// optionally audio) into the session, executes the model's tool calls against
/// the Donkey Command Layer, and surfaces anything the model didn't handle with
/// a tool call back to the normal command pipeline.
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

    /// Invoked for transcripts/requests the model did not satisfy with a tool
    /// call (e.g. a complex request). Wire this to the overlay's submit path.
    var onComplexRequest: ((String) -> Void)?
    /// Invoked after a Command Layer tool runs, with a short status summary, so
    /// the UI can reflect that the model acted.
    var onActed: ((String) -> Void)?
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
        systemInstruction: String = GeminiLiveVoiceController.defaultSystemInstruction,
        visionAuthProvider: @escaping @Sendable () async throws -> GeminiVertexVisionPlanner.VertexAuth = {
            try await GeminiVertexVisionPlanner.mintAuth(
                backend: DonkeyBackendInferenceClient(configuration: try DonkeyBackendInferenceConfiguration.fromEnvironment())
            )
        }
    ) {
        self.configuration = configuration
        self.systemInstruction = systemInstruction
        self.visionAuthProvider = visionAuthProvider
        let services = HarnessBuiltInToolServices(commandExecutor: DonkeyCommandBackends.makeExecutor())
        self.registry = HarnessToolRegistry(
            tools: BuiltInHarnessToolExecutors.tools(
                descriptors: DonkeyCommandLayer.descriptors,
                services: services
            )
        )
    }

    func start() async {
        guard configuration.enabled, session == nil else { return }
        let session = GeminiLiveSession(
            systemInstruction: systemInstruction,
            functionDescriptors: DonkeyCommandLayer.descriptors + [Self.visionControlDescriptor],
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
        case .finalTranscript(let text):
            onComplexRequest?(text)
        case .closed:
            isConnected = false
            updateAudioStreaming()
        default:
            break
        }
    }

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
            let toolCall = HarnessToolCall(id: call.id, name: toolName, input: call.arguments)
            let result = await registry.execute(
                toolCall,
                taskID: "gemini-live",
                worldModel: HarnessWorldModel(),
                grantedPermissions: [.appControl, .input, .appLookup]
            )
            onActed?(result.summary)
            // Forward the full execution detail (stdout/stderr/exitCode/reason,
            // plus tool-specific facts) so the model can read output and
            // self-correct on failure. `executor` is internal noise.
            var response = result.metadata
            response.removeValue(forKey: "executor")
            response["status"] = result.status.rawValue
            response["summary"] = result.summary
            // Surface a clarification gate (e.g. music_play asking what to play)
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

    /// Run the vision escalation in a separate task (NOT the event-consumer task)
    /// and answer the model's `vision_control` call when the drive completes.
    private func launchVision(_ call: AIRealtimeToolCall) {
        let app = (call.arguments["app"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = (call.arguments["goal"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configuration.visionModel
        let useBox = configuration.visionBoxEnabled
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
                // Box and single-point drivers are independent (separate Outcome
                // types), so read the two fields we need from each branch locally.
                let completed: Bool
                let turns: Int
                if useBox {
                    let outcome = await VertexVisionBoxDriver.drive(
                        appName: app, bundleIdentifier: nil, goal: goal, auth: auth, model: model
                    )
                    completed = outcome.completed
                    turns = outcome.turns
                } else {
                    let outcome = await VertexVisionDriver.drive(
                        appName: app, bundleIdentifier: nil, goal: goal, auth: auth, model: model
                    )
                    completed = outcome.completed
                    turns = outcome.turns
                }
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
        summary: "Operate an app by looking at the screen (a vision agent clicks/types). Use ONLY when a task must happen inside a specific app the fast tools can't drive — e.g. searching for and playing something in Spotify (music_play controls Apple Music only).",
        inputSchema: [
            "app": "The app to operate, e.g. Spotify.",
            "goal": "What to accomplish in the app, e.g. play Coldplay's most popular song."
        ],
        requiredPermissions: [.input, .screenCapture],
        safetyClass: .guardedInput
    )

    // Cross-tool policy only. Each tool's purpose, parameters, examples, and
    // safety constraints live in its registered function declaration (see
    // CommandLayerFunctionDeclarations / DonkeyCommandLayer), not here.
    static let defaultSystemInstruction = """
    You are Donkey, a fast macOS assistant. Act directly and immediately with the \
    registered tools, preferring shell_exec for anything the more specific tools \
    don't cover. music_play controls Apple Music only — it CANNOT control Spotify. \
    When a task must happen in a specific app that no fast tool can operate (e.g. \
    searching for and playing a song in Spotify), call vision_control with the app \
    and goal; a vision agent will operate the screen. Discover before guessing rather \
    than inventing names or values. Read each tool's returned output and retry or \
    adjust on failure. Keep replies short.
    """
}
