import Foundation

/// A single file the agent produced for a conversation, recorded the moment a file-producing tool
/// reported success. Captured from the tool result's typed metadata only — never from user text.
public struct ConversationWorkspaceDeliverable: Codable, Equatable, Sendable {
    /// Absolute, standardized path on disk.
    public var path: String
    /// The tool that produced it (the result's `toolName`), e.g. `files.write`, `image_render`.
    public var kind: String
    public var producedAt: Date
    public var byteCount: Int?

    public init(path: String, kind: String, producedAt: Date, byteCount: Int? = nil) {
        self.path = path
        self.kind = kind
        self.producedAt = producedAt
        self.byteCount = byteCount
    }
}

/// A file the USER provided for the conversation (an attachment), recorded the moment a turn carries one
/// so the planner sees it every step and can read or act on it at its path. The mirror of a deliverable:
/// a deliverable is what the agent produced, an attachment is what the user supplied. Captured from typed
/// asset metadata only — never from user text.
public struct ConversationWorkspaceAttachment: Codable, Equatable, Sendable {
    /// Absolute, standardized path on disk.
    public var path: String
    public var displayName: String
    public var contentType: String
    public var byteCount: Int?
    public var addedAt: Date

    public init(path: String, displayName: String, contentType: String, byteCount: Int? = nil, addedAt: Date) {
        self.path = path
        self.displayName = displayName
        self.contentType = contentType
        self.byteCount = byteCount
        self.addedAt = addedAt
    }
}

/// The durable memory of what a conversation has produced and where, so the planner reorganizes loose
/// files into a folder as a task grows instead of scattering them. This is pure data with deterministic
/// field updates: it RECORDS what the planner did (from typed tool metadata) and never decides naming,
/// structure, or placement — those are the planner's per-step judgments, composed from general tools
/// (`files.write`, `shell_exec mkdir`/`mv`). The filesystem is ground truth; this is a memory aid the
/// planner reconciles with `ls` when unsure.
///
/// The canonical copy lives in `HarnessConversation.metadata["workspace"]` (keyed by conversation, so a
/// new root agent in the same conversation reuses it) and is projected into `worldModel.facts` each step
/// so it survives context compaction.
public struct ConversationWorkspace: Codable, Equatable, Sendable {
    /// Where loose deliverables land before promotion — seeded from the parent directory of the first
    /// deliverable (the base the planner chose). Stable for the conversation.
    public var anchorBase: String?
    /// The named project folder once the planner has grouped files into a subfolder of `anchorBase`.
    /// `nil` means deliverables are still loose at `anchorBase`.
    public var folderPath: String?
    /// Everything produced, in order of first creation.
    public var deliverables: [ConversationWorkspaceDeliverable]
    /// Files the user attached, in order received. The planner's inputs, surfaced alongside its outputs.
    public var attachments: [ConversationWorkspaceAttachment]
    public var updatedAt: Date

    public init(
        anchorBase: String? = nil,
        folderPath: String? = nil,
        deliverables: [ConversationWorkspaceDeliverable] = [],
        attachments: [ConversationWorkspaceAttachment] = [],
        updatedAt: Date = Date()
    ) {
        self.anchorBase = anchorBase
        self.folderPath = folderPath
        self.deliverables = deliverables
        self.attachments = attachments
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case anchorBase, folderPath, deliverables, attachments, updatedAt
    }

    /// Tolerant decode so a workspace persisted before `attachments` existed still loads (its JSON has no
    /// `attachments` key) instead of failing and dropping the conversation's whole workspace record.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        anchorBase = try c.decodeIfPresent(String.self, forKey: .anchorBase)
        folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath)
        deliverables = try c.decodeIfPresent([ConversationWorkspaceDeliverable].self, forKey: .deliverables) ?? []
        attachments = try c.decodeIfPresent([ConversationWorkspaceAttachment].self, forKey: .attachments) ?? []
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    /// Fact key for the planner-facing summary, shown in the prompt's "Known state" block.
    public static let summaryFactKey = "workspace"
    /// Fact key for the machine-readable resolve directory, read by file-writing executors and hidden
    /// from the planner's prose facts dump.
    public static let baseDirFactKey = "workspace.baseDir"
    /// Metadata key under which the encoded record is stored on `HarnessConversation`.
    public static let metadataKey = "workspace"

    /// The directory a relative path should resolve against right now: the promoted folder if there is
    /// one, else the chosen base, else nil (caller keeps its own default).
    public var currentBaseDirectory: String? {
        folderPath ?? anchorBase
    }

    /// Record a produced file. Seeds `anchorBase` from the first deliverable's parent directory, and
    /// promotes `folderPath` the moment a file lands in a subfolder of `anchorBase` — that subfolder IS
    /// the workspace folder the planner created. Re-writing the same path updates it in place rather than
    /// duplicating. Pure: standardizes the path with string ops only, no filesystem access.
    public mutating func record(path rawPath: String, kind: String, byteCount: Int?, at date: Date) {
        let std = Self.standardize(rawPath)
        guard !std.isEmpty else { return }
        let parent = (std as NSString).deletingLastPathComponent

        if anchorBase == nil {
            anchorBase = parent
        } else if folderPath == nil,
                  let base = anchorBase,
                  parent != base,
                  parent.hasPrefix(base + "/") {
            // The planner wrote into a subfolder of the base — it has grouped its output. Adopt the
            // nearest subfolder of the base as the workspace folder.
            folderPath = Self.firstSubdirectory(of: base, containing: parent)
        }

        if let index = deliverables.firstIndex(where: { $0.path == std }) {
            deliverables[index].kind = kind
            deliverables[index].producedAt = date
            if let byteCount { deliverables[index].byteCount = byteCount }
        } else {
            deliverables.append(
                ConversationWorkspaceDeliverable(path: std, kind: kind, producedAt: date, byteCount: byteCount)
            )
        }
        updatedAt = date
    }

    /// Record a file the user attached. Dedupes by standardized path (a re-attach updates in place); pure,
    /// no filesystem access. Attachments are inputs, so they never seed `anchorBase`/`folderPath` — those
    /// track where the agent writes its OWN output.
    public mutating func recordAttachment(
        path rawPath: String,
        displayName: String,
        contentType: String,
        byteCount: Int?,
        at date: Date
    ) {
        let std = Self.standardize(rawPath)
        guard !std.isEmpty else { return }
        if let index = attachments.firstIndex(where: { $0.path == std }) {
            attachments[index].displayName = displayName
            attachments[index].contentType = contentType
            if let byteCount { attachments[index].byteCount = byteCount }
        } else {
            attachments.append(
                ConversationWorkspaceAttachment(
                    path: std, displayName: displayName, contentType: contentType, byteCount: byteCount, addedAt: date
                )
            )
        }
        updatedAt = date
    }

    /// A compact, planner-facing one-line summary rendered into the surfaced fact. Leads with any
    /// user-attached files (with full paths, so the planner can hand them straight to `image.edit` /
    /// `files.describe`), then the agent's own output.
    public func plannerSummary(maxDeliverables: Int = 12) -> String {
        let attachmentsClause: String
        if attachments.isEmpty {
            attachmentsClause = ""
        } else {
            let list = attachments
                .map { "\($0.displayName) [\($0.contentType)] at \($0.path)" }
                .joined(separator: "; ")
            attachmentsClause = "User attached \(attachments.count) file(s): \(list). "
                + "Read or act on them at these paths (files.describe, image.edit, the data/pdf skills). "
        }

        let shown = deliverables.suffix(maxDeliverables).map { deliverable -> String in
            "\((deliverable.path as NSString).lastPathComponent) (\(deliverable.kind))"
        }
        let more = deliverables.count > maxDeliverables
            ? " (+\(deliverables.count - maxDeliverables) earlier)"
            : ""
        let produced = shown.isEmpty ? "nothing yet" : shown.joined(separator: ", ")

        let body: String
        if let folder = folderPath, !folder.isEmpty {
            body = "folder=\(Self.abbreviate(folder)); \(deliverables.count) file(s) here: \(produced)\(more). "
                + "Keep adding to this folder; do not start another."
        } else {
            let base = anchorBase.map(Self.abbreviate) ?? "(none chosen yet)"
            body = "folder=<none yet — loose at \(base)>; produced: \(produced)\(more). "
                + "If you create a SECOND related file, first make a clearly-named folder here and move the earlier file(s) into it."
        }
        return attachmentsClause + body
    }

    public func encodedJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ json: String?) -> ConversationWorkspace? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ConversationWorkspace.self, from: data)
    }

    // MARK: - Pure helpers

    static func standardize(_ rawPath: String) -> String {
        let expanded = (rawPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    /// The immediate subdirectory of `base` on the way down to `descendant` (so deeply-nested writes
    /// still adopt the top-level project folder, e.g. base=`~/Downloads`, descendant=`~/Downloads/app/Sources`
    /// → `~/Downloads/app`).
    private static func firstSubdirectory(of base: String, containing descendant: String) -> String {
        let prefix = base + "/"
        guard descendant.hasPrefix(prefix) else { return descendant }
        let remainder = String(descendant.dropFirst(prefix.count))
        let firstComponent = remainder.split(separator: "/", maxSplits: 1).first.map(String.init) ?? remainder
        return prefix + firstComponent
    }

    private static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
