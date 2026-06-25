import Foundation

public enum UserQueryConversationStatus: String, Codable, Equatable, Sendable {
    case chatting
    case running
    case paused
    case completed
    case waitingForClarification
    case waitingForPermission
    case waitingForReview
    case interrupted
    case needsAttention
    case failed
    case timedOut
}

public extension UserQueryConversationStatus {
    /// The agent is blocked asking the user to respond (a clarification or a review). These are the only
    /// states that surface a dedicated Reply button, since only here is the agent actively asking. Every
    /// state is repliable by tapping the row (a running/permission-gated thread takes the reply as a
    /// queued follow-up, the rest resume), so there is no separate "repliable" predicate — only this.
    var isAwaitingUserResponse: Bool {
        self == .waitingForClarification || self == .waitingForReview
    }
}

/// Who started a conversation. `user` is the default — anything the person typed, spoke, or resumed,
/// and which they own (stop, resume, reply, dismiss). `system` is started by the app itself (e.g. the
/// first-run download of the bundled CLI tools): the person watches its progress like any other
/// conversation, but it runs to completion under the app's control and is never user-stoppable or
/// -dismissable. The distinction is typed rather than inferred so the "can't touch it" rule holds by
/// construction everywhere — the row controls, the lifecycle methods, follow-up routing, and restore.
public enum UserQueryConversationOrigin: String, Codable, Equatable, Sendable {
    case user
    case system
}

public struct UserQueryConversation: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    /// The conversation's latest line — the one thing the collapsed chin renders (see `chinDisplayText`).
    /// It is MONOTONIC by construction: once it holds a real line, any write that would blank it
    /// self-reverts, so the chin can never regress to the `title` fallback (the original prompt) after the
    /// conversation has moved on. This is the structural guarantee behind "always show the latest text" —
    /// enforced here, in the data model, so no call site (a stray empty `liveDetail`, a cleared stream,
    /// a future writer) can reintroduce the stale-prompt bug. Empty survives ONLY as the value set in
    /// `init` — the genuine "no line yet" bootstrap, where `title` IS the latest line.
    public var detail: String {
        didSet {
            if detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                detail = oldValue
            }
        }
    }
    public var commandText: String
    public var status: UserQueryConversationStatus
    public var accentIndex: Int
    public var origin: UserQueryConversationOrigin
    /// When the conversation was first created. A stable timestamp — never restamped — used for ordering and
    /// age. It is NOT the elapsed-time anchor; that is `runningSince`. Keeping the two separate is what makes
    /// the cumulative timer impossible to corrupt (see `activeSeconds`).
    public var createdAt: Date
    public var updatedAt: Date
    /// The two fields that, together, define elapsed time — and the reason the clock can't regress. Active
    /// time is `accumulatedActiveSeconds` (every stretch already closed) plus the open stretch since
    /// `runningSince` while running. Both are `private(set)`: the ONLY ways to change them are
    /// `openRunningStretch` / `closeRunningStretch`, which are individually safe and order-independent. No
    /// call site can restamp the clock or drop a stretch, so the "timer resets mid-run" bug is structurally
    /// impossible — the same doctrine `detail` uses for the chin. Both decode tolerantly so conversations
    /// persisted before they existed still load.
    ///
    /// `runningSince` is non-nil exactly when a stretch is open (normally while `status == .running`).
    public private(set) var accumulatedActiveSeconds: Double
    public private(set) var runningSince: Date?
    public var metadata: [String: String]

    public init(
        id: String,
        title: String,
        detail: String,
        commandText: String = "",
        status: UserQueryConversationStatus,
        accentIndex: Int,
        origin: UserQueryConversationOrigin = .user,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        accumulatedActiveSeconds: Double = 0,
        runningSince: Date? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.commandText = commandText
        self.status = status
        self.accentIndex = accentIndex
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.accumulatedActiveSeconds = accumulatedActiveSeconds
        // A conversation born running has an open stretch from creation, unless a caller (decode, store
        // load) supplies the persisted anchor explicitly. This keeps "create a running conversation" a
        // single step — no caller has to remember to open the stretch.
        self.runningSince = runningSince ?? (status == .running ? createdAt : nil)
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, detail, commandText, status, accentIndex, origin
        case createdAt, updatedAt, accumulatedActiveSeconds, runningSince, metadata
    }

    // Custom decode so a conversation persisted before the elapsed-time fields existed still loads (its JSON
    // has no such keys) instead of failing and dropping the row. Every pre-existing field is decoded exactly
    // as the synthesized initializer did; the elapsed-time fields default tolerantly.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        detail = try c.decode(String.self, forKey: .detail)
        commandText = try c.decode(String.self, forKey: .commandText)
        status = try c.decode(UserQueryConversationStatus.self, forKey: .status)
        accentIndex = try c.decode(Int.self, forKey: .accentIndex)
        origin = try c.decode(UserQueryConversationOrigin.self, forKey: .origin)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        accumulatedActiveSeconds = try c.decodeIfPresent(Double.self, forKey: .accumulatedActiveSeconds) ?? 0
        runningSince = try c.decodeIfPresent(Date.self, forKey: .runningSince) ?? (status == .running ? createdAt : nil)
        metadata = try c.decode([String: String].self, forKey: .metadata)
    }
}

public extension UserQueryConversation {
    /// Total active time as of `now`: every stretch already banked, plus the open stretch while one is
    /// running. The single source of "elapsed" for the UI — idle gaps between stretches are never counted
    /// because the clock only advances while `runningSince` is set.
    func activeSeconds(asOf now: Date) -> Double {
        accumulatedActiveSeconds + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    /// Begin counting a running stretch as of `now`. A NO-OP if a stretch is already open, so re-entering
    /// `.running` — a per-step narration update, an approved gate, a resumed loop — can never restart the
    /// clock or drop the stretch in flight. The clock only ever resumes from where it left off.
    mutating func openRunningStretch(asOf now: Date) {
        guard runningSince == nil else { return }
        runningSince = now
    }

    /// Stop the open stretch as of `endedAt`, banking its real duration into the cumulative total. A NO-OP
    /// if no stretch is open, so closing twice can't double-count. `endedAt` is normally now; a relaunch
    /// passes the last time the loop actually advanced so the app-closed gap is never banked.
    mutating func closeRunningStretch(asOf endedAt: Date) {
        guard let start = runningSince else { return }
        accumulatedActiveSeconds += max(0, endedAt.timeIntervalSince(start))
        runningSince = nil
    }
}

public extension UserQueryConversation {
    /// Whether the person may control this conversation — stop it, resume it, reply to it, or dismiss it.
    /// Only conversations they started are theirs to control; a system-driven one (tool setup) is watched,
    /// not operated. Every control surface and lifecycle hook gates on this, so the rule can't be missed.
    var isUserControllable: Bool { origin == .user }

    /// Whether the person may dismiss (close) this row. Their own conversations are always theirs to close;
    /// a system-driven one (tool setup) is the app's to run while it works, but once it has settled it is
    /// just a finished notice — so a completed or failed system row becomes dismissible too. A still-running
    /// system row stays untouchable until the app settles it. Broader than `isUserControllable` precisely
    /// because a finished system row is closeable without being otherwise operable.
    var isUserDismissible: Bool {
        switch origin {
        case .user:
            return true
        case .system:
            return status == .completed || status == .failed
        }
    }
}

public extension UserQueryConversation {
    /// The single line the collapsed chin shows for this task — always the latest line of the
    /// conversation. `detail` is the one field that carries it: the user's message the instant they send
    /// it, the agent's live step narration while it works, then the agent's reply. Each of those writes
    /// `detail` at its own source (see `UserQueryOverlayModel`), so the chin never reconstructs "what's
    /// newest" from the prompt, title, and status — it just renders this. Because `detail` is monotonic
    /// (it never blanks once set — see its declaration), this only reads `title` for a task that has no
    /// line yet, where `title` IS the latest line; it can never resurface the original prompt after the
    /// conversation has moved on. The chin renderer and the chin-band height measurement both read this,
    /// so the band is always sized to the exact line it renders.
    var chinDisplayText: String {
        detail.isEmpty ? title : detail
    }
}

public enum UserQueryConversationEventRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
    case system
    case tool
}

public struct UserQueryConversationEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var conversationID: String
    public var role: UserQueryConversationEventRole
    public var text: String
    public var sequence: Int
    public var createdAt: Date

    public init(
        id: String,
        conversationID: String,
        role: UserQueryConversationEventRole,
        text: String,
        sequence: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.text = text
        self.sequence = sequence
        self.createdAt = createdAt
    }
}

public enum UserQueryConversationAssetSource: String, Codable, Equatable, Sendable {
    case userUploaded
    case agentReturned
}

public struct UserQueryConversationAsset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var conversationID: String
    public var eventID: String?
    public var source: UserQueryConversationAssetSource
    public var displayName: String
    public var contentType: String
    public var urlString: String
    public var byteCount: Int64?
    public var createdAt: Date

    public init(
        id: String,
        conversationID: String,
        eventID: String? = nil,
        source: UserQueryConversationAssetSource,
        displayName: String,
        contentType: String,
        urlString: String,
        byteCount: Int64? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.eventID = eventID
        self.source = source
        self.displayName = displayName
        self.contentType = contentType
        self.urlString = urlString
        self.byteCount = byteCount
        self.createdAt = createdAt
    }
}

public struct UserQueryConversationAssetDraft: Codable, Equatable, Sendable {
    public var source: UserQueryConversationAssetSource
    public var displayName: String
    public var contentType: String
    public var urlString: String
    public var byteCount: Int64?

    public init(
        source: UserQueryConversationAssetSource = .userUploaded,
        displayName: String,
        contentType: String,
        urlString: String,
        byteCount: Int64? = nil
    ) {
        self.source = source
        self.displayName = displayName
        self.contentType = contentType
        self.urlString = urlString
        self.byteCount = byteCount
    }
}
