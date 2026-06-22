import Foundation

/// A single tool/function call requested by a realtime model.
public struct AIRealtimeToolCall: Equatable, Sendable {
    public var id: String
    public var name: String
    public var arguments: [String: String]

    public init(id: String, name: String, arguments: [String: String]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// The client's response to a realtime tool call.
public struct AIRealtimeToolResult: Equatable, Sendable {
    public var id: String
    public var name: String
    public var response: [String: String]

    public init(id: String, name: String, response: [String: String]) {
        self.id = id
        self.name = name
        self.response = response
    }
}

/// Events streamed up from a realtime session.
public enum AIRealtimeEvent: Equatable, Sendable {
    case connected
    case partialTranscript(String)
    case finalTranscript(String)
    case toolCalls([AIRealtimeToolCall])
    /// A chunk of the model's text answer (text response modality).
    case textOut(String)
    case audioOut(Data)
    /// User barged in; discard any buffered output audio.
    case interrupted
    case generationComplete
    /// The model finished its turn; any buffered text/transcript is complete.
    case turnComplete
    /// Server will close the socket soon; reconnect within `timeLeftMS`.
    case goAway(timeLeftMS: Int)
    /// Opaque handle to resume this session after a reconnect.
    case resumptionHandle(String)
    case closed(reason: String?)
}

/// Transport-agnostic, bidirectional realtime session (parallel to the
/// request/response `AIHTTPClient`; this one is a persistent socket).
public protocol AIRealtimeSession: Sendable {
    /// Ordered stream of events from the session.
    var events: AsyncStream<AIRealtimeEvent> { get }

    func connect() async throws
    /// Stream a chunk of 16kHz mono PCM16 little-endian audio.
    func sendAudioChunk(_ pcm16: Data) async throws
    /// Send a text turn.
    func sendText(_ text: String) async throws
    /// Send a JPEG image (e.g. a screenshot) as in-band visual context.
    func sendImage(_ jpeg: Data) async throws
    /// Reply to one or more tool calls.
    func sendToolResults(_ results: [AIRealtimeToolResult]) async throws
    func close() async
}
