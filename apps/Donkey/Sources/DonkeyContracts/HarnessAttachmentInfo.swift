import Foundation

/// A file the user attached to their turn, described for the understanding boundary so the turn is read
/// against it ("turn THIS into a headshot", "summarize THESE") instead of being misclassified. Only the
/// name and type travel here — never the bytes — because the planner reads or acts on the file at its
/// path through general tools (`files.describe`, `image.edit`, the data/pdf skills). Several attachments
/// at once are normal; this is one entry per file.
public struct HarnessAttachmentInfo: Sendable, Equatable {
    public var displayName: String
    public var contentType: String

    public init(displayName: String, contentType: String) {
        self.displayName = displayName
        self.contentType = contentType
    }
}
