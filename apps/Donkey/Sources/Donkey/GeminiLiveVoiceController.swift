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

    init(
        configuration: GeminiLiveConfiguration = .fromEnvironment(),
        systemInstruction: String = GeminiLiveVoiceController.defaultSystemInstruction
    ) {
        self.configuration = configuration
        self.systemInstruction = systemInstruction
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
            let toolCall = HarnessToolCall(id: call.id, name: call.name, input: call.arguments)
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
            // Surface a clarification gate (e.g. music.play asking what to play)
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
        try? await session.sendToolResults(results)
    }

    // MARK: - Auth

    /// Vertex AI: the backend mints a short-lived OAuth token from its
    /// service-account credentials and returns the websocket endpoint + model
    /// path. Re-invoked on every (re)connect so the token stays fresh.
    private static func makeConnectionProvider() -> @Sendable () async throws -> GeminiLiveConnection {
        return {
            let backend = DonkeyBackendInferenceClient(
                configuration: try DonkeyBackendInferenceConfiguration.fromEnvironment()
            )
            let minted = try await backend.mintLiveConnection()
            guard let url = URL(string: minted.websocketUrl) else {
                throw GeminiLiveError.invalidURL
            }
            return GeminiLiveConnection(url: url, bearerToken: minted.token, model: minted.model)
        }
    }

    // Cross-tool policy only. Each tool's purpose, parameters, examples, and
    // safety constraints live in its registered function declaration (see
    // CommandLayerFunctionDeclarations / DonkeyCommandLayer), not here.
    static let defaultSystemInstruction = """
    You are Donkey, a fast macOS assistant. Act directly and immediately with the \
    registered tools, preferring shell_exec for anything the more specific tools \
    don't cover. Discover before guessing rather than inventing names or values. \
    Read each tool's returned output and retry or adjust on failure. Only look at \
    the screen when a task depends on what is currently visible. Keep replies short.
    """
}
