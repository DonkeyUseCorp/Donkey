import Foundation
import UniformTypeIdentifiers

/// A modality-agnostic, structured description of one file — the output of the file-understanding
/// layer that every file "ask" (rename, tag, sort, summarize, …) consumes. Understanding is the hard,
/// reusable half of working with files; the ask is the cheap, swappable half. Keeping them separate
/// means a new ask reuses this verbatim, and a new modality (audio, video) only extends the router
/// that fills this in.
///
/// `textContent` is bounded extracted text — file body, OCR, or (later) a transcript — and may be
/// empty for content with no readable text. `summary` is a short line safe to show or feed a model
/// even when there is no text. Richer fields land in `attributes` (dimensions, duration, dates).
public struct FileUnderstanding: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case text, image, pdf, audio, video, binary, unknown
    }

    public var path: String
    public var fileName: String
    public var fileExtension: String
    public var kind: Kind
    public var byteSize: Int?
    public var textContent: String
    public var summary: String
    public var attributes: [String: String]

    public init(
        path: String,
        fileName: String,
        fileExtension: String,
        kind: Kind,
        byteSize: Int? = nil,
        textContent: String = "",
        summary: String = "",
        attributes: [String: String] = [:]
    ) {
        self.path = path
        self.fileName = fileName
        self.fileExtension = fileExtension
        self.kind = kind
        self.byteSize = byteSize
        self.textContent = textContent
        self.summary = summary
        self.attributes = attributes
    }

    /// The bounded signal an ask hands to a model: the extracted text when there is any, otherwise the
    /// deterministic summary so even a text-free file (a photo, an archive) still carries something to
    /// reason about.
    public func contentForReasoning(limit: Int) -> String {
        let body = textContent.isEmpty ? summary : textContent
        guard body.count > limit else { return body }
        return String(body.prefix(limit))
    }
}

/// The file-understanding router's deterministic, always-available core: classify a file by modality
/// and build a Foundation-only understanding (text body for text files, metadata for everything else).
/// Richer modality work — OCR for images, text for PDFs, later transcription for audio/video — is
/// supplied by the runtime through the tool's `fileUnderstanding` hook, which starts from this base
/// and enriches it. Routing lives here so the set of modalities is one obvious place to extend.
public enum FileUnderstandingEngine {
    static let textReadByteLimit = 64 * 1024
    public static let textContentCharLimit = 1_500

    /// Modality from the extension, resolved through the OS Uniform Type registry rather than a
    /// hand-maintained list: `UTType` already knows that `.heic` is an image and `.mkv` is a movie,
    /// and stays correct as the system learns new types. An extensionless or unrecognized file falls
    /// through to content sniffing in `foundationUnderstanding`. This is type detection, not semantic
    /// intent — a typed-field lookup, never a model call.
    public static func classify(fileExtension: String) -> FileUnderstanding.Kind {
        guard let type = UTType(filenameExtension: fileExtension.lowercased()) else {
            return .unknown
        }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .text) { return .text }
        return .unknown
    }

    public static func foundationUnderstanding(
        for url: URL,
        fileManager: FileManager = .default
    ) -> FileUnderstanding {
        let ext = url.pathExtension
        var kind = classify(fileExtension: ext)
        let attrs = try? fileManager.attributesOfItem(atPath: url.path)
        let byteSize = (attrs?[.size] as? NSNumber)?.intValue
        var attributes: [String: String] = [:]
        if let modified = attrs?[.modificationDate] as? Date {
            attributes["modified"] = ISO8601DateFormatter().string(from: modified)
        }

        var textContent = ""
        if kind == .text || kind == .unknown {
            if let data = readBounded(url), let text = decodeText(data) {
                textContent = boundedText(text)
                kind = .text
            } else if kind == .unknown {
                kind = .binary
            }
        }

        return FileUnderstanding(
            path: url.path,
            fileName: url.lastPathComponent,
            fileExtension: ext,
            kind: kind,
            byteSize: byteSize,
            textContent: textContent,
            summary: summaryLine(kind: kind, fileExtension: ext, byteSize: byteSize, hasText: !textContent.isEmpty, attributes: attributes),
            attributes: attributes
        )
    }

    public static func summaryLine(
        kind: FileUnderstanding.Kind,
        fileExtension: String,
        byteSize: Int?,
        hasText: Bool,
        attributes: [String: String]
    ) -> String {
        var parts = ["\(kind.rawValue)\(fileExtension.isEmpty ? "" : " (.\(fileExtension.lowercased()))")"]
        if let dimensions = attributes["dimensions"] { parts.append(dimensions) }
        if let duration = attributes["duration"] { parts.append(duration) }
        if let byteSize { parts.append("\(byteSize) bytes") }
        if !hasText, kind != .text { parts.append("no readable text content") }
        return parts.joined(separator: ", ")
    }

    static func readBounded(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: textReadByteLimit)
    }

    /// Text, or nil for binary. A NUL byte in the sampled prefix is the reliable binary tell; UTF-8
    /// then Latin-1 (which never fails) is the fallback only after that check rules out true binary.
    static func decodeText(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if data.prefix(8_000).contains(0) { return nil }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        return String(data: data, encoding: .isoLatin1)
    }

    public static func boundedText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > textContentCharLimit else { return trimmed }
        return String(trimmed.prefix(textContentCharLimit))
    }
}
