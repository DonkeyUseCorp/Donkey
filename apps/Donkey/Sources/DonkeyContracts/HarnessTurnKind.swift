import Foundation

/// What a user turn fundamentally is, decided once by the request-understanding boundary before any
/// action machinery is touched. This is the first-class routing fact behind "conversations first":
/// a turn becomes a conversation, an action, or a clarifying question — and only `.act` is ever allowed
/// to reach the action planner and the Mac.
///
/// Like ``ExecutionPreference``, this is a typed field the model sets — never inferred by matching the
/// user's words. Deterministic code branches on this enum, never on the raw string. A greeting or a
/// plain question classifies as `.converse` and is answered by a responder that holds no action tools,
/// so a misread can never run a shell command.
public enum HarnessTurnKind: String, Codable, Equatable, Sendable {
    /// A greeting, acknowledgement, small talk, or a question answerable in words without driving the
    /// Mac. Routed to the conversational responder; no action loop, no tools, no permission gate.
    case converse
    /// A request to actually do something on the machine (open, play, find, change, send, write a file,
    /// operate an app). The only kind that enters the guarded action loop.
    case act
    /// Actionable in spirit but too ambiguous or missing a critical, user-owned detail to proceed
    /// safely. The turn asks one specific question before doing anything.
    case clarify
}
