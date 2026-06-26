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
    /// The dedicated working directory created for this conversation up front (e.g. `~/Downloads/<slug>/`),
    /// the agent's own sandbox. It is the DEFAULT base a relative path and the shell's working directory
    /// resolve against, so a task's intermediate and output files land here instead of loose in the
    /// user's home. Stable for the conversation; the planner may still write to an absolute path the user
    /// named, which wins over this default via `anchorBase`.
    public var root: String?
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
        root: String? = nil,
        anchorBase: String? = nil,
        folderPath: String? = nil,
        deliverables: [ConversationWorkspaceDeliverable] = [],
        attachments: [ConversationWorkspaceAttachment] = [],
        updatedAt: Date = Date()
    ) {
        self.root = root
        self.anchorBase = anchorBase
        self.folderPath = folderPath
        self.deliverables = deliverables
        self.attachments = attachments
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case root, anchorBase, folderPath, deliverables, attachments, updatedAt
    }

    /// Tolerant decode so a workspace persisted before a field existed still loads (e.g. its JSON has no
    /// `root` or `attachments` key) instead of failing and dropping the conversation's whole workspace record.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = try c.decodeIfPresent(String.self, forKey: .root)
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
    /// Fact key for the inlined contents of the small text files in the working directory, surfaced to the
    /// planner every step so it never re-opens its own small inputs (the data file it copied in, a map it
    /// wrote). Sorts right after `workspace`, so it reads as part of the workspace block.
    public static let fileContentsFactKey = "workspace.files"
    /// Metadata key under which the encoded record is stored on `HarnessConversation`.
    public static let metadataKey = "workspace"

    /// The directory a relative path (and the shell's working directory) should resolve against right now:
    /// the promoted folder if there is one, else the base the planner chose by writing there, else the
    /// dedicated working directory seeded for the conversation. `nil` only before a root has been seeded.
    ///
    /// A bare scatter root (the top of Downloads/Desktop/Documents or the home root) is never a real base —
    /// it is where loose files litter, not where the task's folder lives. A shell tool that wrote its output
    /// straight into Downloads (yt-dlp, ffmpeg — the one producer path `files.write`'s re-rooting can't
    /// intercept, since an arbitrary command's args can't be safely rewritten) would otherwise migrate the
    /// whole workspace there through `anchorBase` and abandon the dedicated `root`. So a scatter-root
    /// `anchorBase` yields to `root` whenever a root exists; a named subfolder the planner grouped into
    /// (`folderPath`, or a non-scatter `anchorBase`) is still honored. This mirrors `resolveWritePath`'s rule.
    public var currentBaseDirectory: String? {
        if let folderPath, !folderPath.isEmpty { return folderPath }
        if let anchorBase, !anchorBase.isEmpty,
           !(Self.isScatterRoot(URL(fileURLWithPath: anchorBase)) && (root?.isEmpty == false)) {
            return anchorBase
        }
        return root
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
        } else if let base = currentBaseDirectory, !base.isEmpty {
            // Name the exact folder to put created files in (the same base `currentBaseDirectory` resolves,
            // so the prompt and the shell's cwd never disagree). Just give the path — no steering about
            // relative vs absolute; with the destination stated the model writes there.
            body = "folder=\(Self.abbreviate(base)); put intermediate and output files you create in this "
                + "folder (\(base)). produced: \(produced)\(more)."
        } else {
            body = "folder=<none yet>; produced: \(produced)\(more)."
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

    /// UserDefaults key that lets the user choose where task folders are created. The value is one of the
    /// tokens `"downloads"`, `"desktop"`, `"documents"`, or a custom absolute (or `~`-relative) path; an
    /// empty or unrecognized value falls back to the default. This is the "user can decide" knob a settings
    /// control writes to — the runtime only reads it.
    public static let outputLocationDefaultsKey = "donkey.workspace.outputLocation"

    /// The parent that holds every conversation's task folder — one visible folder per task in a standard
    /// location rather than files scattered loose. Resolution order: the `DONKEY_WORKSPACE_DIR` env override
    /// (tests/eval route working directories into a hermetic temp area; also a power-user escape hatch)
    /// wins; then the user's chosen location from `outputLocationDefaultsKey`; otherwise the default, the
    /// user's Downloads folder — the OS's "an app made this for you" drop point, where the user already
    /// looks and which iCloud does not sync.
    public static func workspaceParentDirectory(
        defaults: UserDefaults = .standard,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        // Read live via getenv: `ProcessInfo.processInfo.environment` is a snapshot taken at process start,
        // so a test that `setenv`s this after launch would not be seen.
        if let raw = getenv("DONKEY_WORKSPACE_DIR") {
            let override = String(cString: raw)
            if !override.isEmpty {
                return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
            }
        }
        return preferredParentDirectory(defaults: defaults, home: home)
    }

    /// The user-chosen (or default) task-folder parent, with no environment override. Split out from
    /// `workspaceParentDirectory` so the preference resolution is unit-testable without the env var.
    static func preferredParentDirectory(defaults: UserDefaults, home: URL) -> URL {
        let choice = (defaults.string(forKey: outputLocationDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch choice.lowercased() {
        case "", "downloads": return home.appendingPathComponent("Downloads", isDirectory: true)
        case "desktop": return home.appendingPathComponent("Desktop", isDirectory: true)
        case "documents": return home.appendingPathComponent("Documents", isDirectory: true)
        default:
            // A custom path the user set; only an absolute (or ~-expanded) path is honored, else Downloads.
            let expanded = (choice as NSString).expandingTildeInPath
            return expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded, isDirectory: true)
                : home.appendingPathComponent("Downloads", isDirectory: true)
        }
    }

    /// The shared top-level locations a careless write litters: the home root and the top level of the
    /// user's Downloads/Desktop/Documents. A file aimed DIRECTLY at one of these — not at a named subfolder
    /// inside it — is re-rooted into the conversation's task folder, so a task's outputs always group into
    /// one folder instead of scattering across these shared directories. A genuinely user-named subfolder
    /// (`~/Documents/Taxes/2024`) is NOT a scatter root and is left exactly where it was aimed.
    public static func isScatterRoot(
        _ directory: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        // Compare normalized path STRINGS, not URLs: `URL ==` is sensitive to a trailing slash / the
        // isDirectory hint, so `file:///x/Downloads` and `file:///x/Downloads/` would wrongly differ.
        let dirPath = directory.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path
        if dirPath == homePath { return true }
        for name in ["Downloads", "Desktop", "Documents"] {
            if dirPath == (homePath as NSString).appendingPathComponent(name) { return true }
        }
        return false
    }

    /// The dedicated working-directory path for a conversation: `<parent>/<goal-slug>-<short-id>/`, where
    /// `<parent>` is the user's chosen output location (Downloads by default). The goal slug makes the
    /// folder recognizable; the short conversation id keeps two similar goals apart. Pure (string math on
    /// the parent path); the caller creates the directory on disk.
    public static func defaultRootPath(goal: String, conversationID: String, suggestedFolderName: String? = nil) -> String {
        let name: String
        if let suggestedFolderName = suggestedFolderName, !suggestedFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = suggestedFolderName
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: "\0", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let slug = self.slug(goal)
            let shortID = conversationID
                .lowercased()
                .filter { $0.isLetter || $0.isNumber }
                .prefix(8)
            name = slug.isEmpty ? "task-\(shortID)" : "\(slug)-\(shortID)"
        }
        return workspaceParentDirectory().appendingPathComponent(name, isDirectory: true).path
    }

    /// A short, filesystem-safe slug from free text: lowercase, alphanumerics kept, every run of other
    /// characters collapsed to a single `-`, trimmed, capped so the folder name stays readable.
    static func slug(_ text: String, maxLength: Int = 40) -> String {
        var out = ""
        var lastWasDash = false
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                out.append(character)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(maxLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
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
