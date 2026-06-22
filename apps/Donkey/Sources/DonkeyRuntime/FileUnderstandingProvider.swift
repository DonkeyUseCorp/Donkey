import CoreGraphics
import DonkeyHarness
import Foundation
import ImageIO
import PDFKit
import Vision

/// The runtime side of the file-understanding layer (behind the harness `fileUnderstanding` hook).
/// It starts from the deterministic Foundation understanding and enriches the richer modalities:
/// images get Vision OCR plus pixel dimensions, PDFs get their text. Audio and video are recognized
/// as kinds but not yet transcribed — that branch is where transcription/keyframe work will plug in.
///
/// Results are cached per file identity (path + size + modification date) in a shared actor, so the
/// expensive step (OCR) runs once and every later ask — describe, then rename — reuses it.
public enum FileUnderstandingProvider {
    static let characterLimit = FileUnderstandingEngine.textContentCharLimit

    public static func understand(_ url: URL) async -> FileUnderstanding? {
        let identity = FileUnderstandingCache.identity(for: url)
        if let identity, let cached = await FileUnderstandingCache.shared.value(for: identity) {
            return cached
        }
        let understanding = await Task.detached(priority: .utility) { enrichedUnderstanding(url) }.value
        if let identity {
            await FileUnderstandingCache.shared.store(understanding, for: identity)
        }
        return understanding
    }

    static func enrichedUnderstanding(_ url: URL) -> FileUnderstanding {
        var understanding = FileUnderstandingEngine.foundationUnderstanding(for: url)
        switch understanding.kind {
        case .image:
            if let dimensions = imageDimensions(url) {
                understanding.attributes["dimensions"] = dimensions
            }
            if let text = recognizeText(in: url) {
                understanding.textContent = text
            }
        case .pdf:
            if let text = pdfText(in: url) {
                understanding.textContent = text
            }
        case .text, .audio, .video, .binary, .unknown:
            break
        }
        understanding.summary = FileUnderstandingEngine.summaryLine(
            kind: understanding.kind,
            fileExtension: understanding.fileExtension,
            byteSize: understanding.byteSize,
            hasText: !understanding.textContent.isEmpty,
            attributes: understanding.attributes
        )
        return understanding
    }

    static func imageDimensions(_ url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }
        return "\(width)x\(height)"
    }

    /// On-device OCR of an image. Returns recognized lines, or nil when the image has no readable text
    /// (e.g. a photo) so understanding falls back to dimensions/metadata rather than empty text.
    static func recognizeText(in url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        let text = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(characterLimit))
    }

    static func pdfText(in url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        var collected = ""
        for index in 0..<document.pageCount {
            if let page = document.page(at: index), let pageText = page.string {
                collected += pageText + "\n"
            }
            if collected.count >= characterLimit { break }
        }
        let trimmed = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(characterLimit))
    }
}

/// Shared session cache so understanding (OCR especially) is computed once per file and reused across
/// every ask. Keyed on path + size + modification date, so editing a file invalidates its entry.
actor FileUnderstandingCache {
    static let shared = FileUnderstandingCache()
    private static let maxEntries = 500

    struct Identity: Hashable {
        var path: String
        var size: Int
        var modified: TimeInterval
    }

    private var entries: [Identity: FileUnderstanding] = [:]
    private var order: [Identity] = []

    static func identity(for url: URL) -> Identity? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              let modified = attrs[.modificationDate] as? Date
        else {
            return nil
        }
        return Identity(path: url.path, size: size, modified: modified.timeIntervalSince1970)
    }

    func value(for identity: Identity) -> FileUnderstanding? {
        entries[identity]
    }

    func store(_ understanding: FileUnderstanding, for identity: Identity) {
        if entries[identity] == nil {
            order.append(identity)
            if order.count > Self.maxEntries {
                let evicted = order.removeFirst()
                entries[evicted] = nil
            }
        }
        entries[identity] = understanding
    }
}
