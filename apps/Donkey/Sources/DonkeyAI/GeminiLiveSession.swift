import DonkeyHarness
import Foundation

public enum GeminiLiveError: Error, Equatable, Sendable {
    case invalidURL
    case notConnected
    case missingAuthToken
}

/// Everything needed to open one Gemini Live websocket: the endpoint URL (with
/// any auth query param already applied), an optional OAuth bearer token, and the
/// model id/path. Built per-connect so OAuth tokens stay fresh across reconnects.
public struct GeminiLiveConnection: Equatable, Sendable {
    public var url: URL
    public var bearerToken: String?
    public var model: String

    public init(url: URL, bearerToken: String?, model: String) {
        self.url = url
        self.bearerToken = bearerToken
        self.model = model
    }
}

/// Decoded response from the backend `POST /api/inference/live-token/` route.
public struct RemoteLiveConnection: Codable, Equatable, Sendable {
    public var token: String
    public var websocketUrl: String
    public var model: String
    public var expiresAt: String?
    public var project: String?
    public var location: String?
}

/// Always-on Gemini Live session over `URLSessionWebSocketTask`.
///
/// Connects directly to Google. Text input is always available; audio/image are
/// optional streamed inputs. Tool calls surface as `AIRealtimeEvent.toolCalls`
/// for the controller to execute against the Command Layer. Handles session
/// resumption and `goAway`-driven reconnects transparently.
public actor GeminiLiveSession: AIRealtimeSession {
    public nonisolated let events: AsyncStream<AIRealtimeEvent>
    private let continuation: AsyncStream<AIRealtimeEvent>.Continuation

    private let systemInstruction: String
    private let functionDescriptors: [HarnessToolDescriptor]
    private let connectionProvider: @Sendable () async throws -> GeminiLiveConnection
    private let urlSession: URLSession

    private var task: URLSessionWebSocketTask?
    private var resumptionHandle: String?
    private var isClosed = false
    private var generation = 0
    private var isReconnecting = false
    private var reconnectAttempts = 0
    private static let maxReconnectAttempts = 6

    public init(
        systemInstruction: String,
        functionDescriptors: [HarnessToolDescriptor] = DonkeyCommandLayer.descriptors,
        connectionProvider: @escaping @Sendable () async throws -> GeminiLiveConnection,
        urlSession: URLSession = .shared
    ) {
        self.systemInstruction = systemInstruction
        self.functionDescriptors = functionDescriptors
        self.connectionProvider = connectionProvider
        self.urlSession = urlSession
        (events, continuation) = AsyncStream<AIRealtimeEvent>.makeStream()
    }

    public func connect() async throws {
        isClosed = false
        try await openSocket()
    }

    public func sendText(_ text: String) async throws {
        try await send(GeminiLiveProtocol.clientTextMessage(text))
    }

    public func sendAudioChunk(_ pcm16: Data) async throws {
        try await send(GeminiLiveProtocol.realtimeMediaMessage(
            base64Data: pcm16.base64EncodedString(),
            mimeType: GeminiLiveProtocol.inputAudioMimeType
        ))
    }

    public func sendImage(_ jpeg: Data) async throws {
        try await send(GeminiLiveProtocol.realtimeMediaMessage(
            base64Data: jpeg.base64EncodedString(),
            mimeType: GeminiLiveProtocol.imageMimeType
        ))
    }

    public func sendToolResults(_ results: [AIRealtimeToolResult]) async throws {
        try await send(GeminiLiveProtocol.toolResponseMessage(results))
    }

    public func close() async {
        isClosed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        continuation.yield(.closed(reason: nil))
        continuation.finish()
    }

    // MARK: - Connection lifecycle

    private func openSocket() async throws {
        guard !isClosed else { throw GeminiLiveError.notConnected }
        // Built fresh each connect so OAuth tokens stay valid across reconnects.
        let connection = try await connectionProvider()
        guard !isClosed else { throw GeminiLiveError.notConnected }

        var request = URLRequest(url: connection.url)
        if let bearer = connection.bearerToken, !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }

        // Tear down any prior socket before replacing it so it can't leak or
        // keep a half-open connection alive.
        task?.cancel(with: .goingAway, reason: nil)

        generation += 1
        let myGeneration = generation
        let socket = urlSession.webSocketTask(with: request)
        task = socket
        socket.resume()

        let setup = GeminiLiveProtocol.setupMessage(
            model: connection.model,
            systemInstruction: systemInstruction,
            functionDeclarations: CommandLayerFunctionDeclarations.declarations(from: functionDescriptors),
            includeAudioResponse: false,
            resumptionHandle: resumptionHandle
        )
        try await socket.send(.data(setup))

        Task { [weak self] in await self?.receiveLoop(generation: myGeneration) }
    }

    private func receiveLoop(generation myGeneration: Int) async {
        while !isClosed, generation == myGeneration, let socket = task {
            do {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .data(let payload):
                    data = payload
                case .string(let text):
                    data = Data(text.utf8)
                @unknown default:
                    continue
                }
                for event in GeminiLiveProtocol.parseServerEvents(data) {
                    handle(event)
                }
            } catch {
                if !isClosed, generation == myGeneration {
                    await handleDisconnect(reason: error.localizedDescription)
                }
                return
            }
        }
    }

    private func handle(_ event: AIRealtimeEvent) {
        switch event {
        case .connected:
            // A successful handshake clears the reconnect backoff.
            reconnectAttempts = 0
        case .resumptionHandle(let handle):
            resumptionHandle = handle
        case .goAway:
            Task { [weak self] in await self?.handleDisconnect(reason: "goAway") }
        default:
            break
        }
        continuation.yield(event)
    }

    /// Reconnect transparently with exponential backoff, reusing the stored
    /// resumption handle. A single reconnect runs at a time; after a bounded
    /// number of failed attempts the session closes instead of looping forever.
    private func handleDisconnect(reason: String) async {
        guard !isClosed, !isReconnecting else { return }
        isReconnecting = true
        defer { isReconnecting = false }

        while !isClosed {
            if reconnectAttempts >= Self.maxReconnectAttempts {
                isClosed = true
                continuation.yield(.closed(reason: "reconnect limit reached after \(reason)"))
                continuation.finish()
                return
            }
            try? await Task.sleep(nanoseconds: Self.reconnectDelayNanoseconds(attempt: reconnectAttempts))
            reconnectAttempts += 1
            guard !isClosed else { return }
            do {
                try await openSocket()
                return // connected; reconnectAttempts resets when `.connected` arrives
            } catch {
                continue // back off and retry
            }
        }
    }

    private static func reconnectDelayNanoseconds(attempt: Int) -> UInt64 {
        let seconds = min(0.5 * pow(2.0, Double(attempt)), 30.0) + Double.random(in: 0...0.3)
        return UInt64(seconds * 1_000_000_000)
    }

    private func send(_ data: Data) async throws {
        guard let socket = task else { throw GeminiLiveError.notConnected }
        try await socket.send(.data(data))
    }
}
