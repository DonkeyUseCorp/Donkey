import CoreGraphics
import Foundation
import ImageIO
import Vision

/// On-device OCR of a screenshot's pixels into text lines, in reading order. This is the read path for
/// content that is drawn rather than exposed in the Accessibility tree — a chat transcript's bubbles, a
/// canvas, a custom list. It reads the actual visible text, which the
/// UI-element detector does not: that detector finds controls (buttons, fields), so it returns a window's
/// chrome and misses the message text sitting between the controls. Native Vision framework, so it runs
/// without a network round-trip and reads whatever language is on screen.
public enum ScreenTextRecognizer {
    /// Recognized lines from PNG-encoded screenshot bytes, ordered top-to-bottom then left-to-right — the
    /// reading order a transcript or feed needs. Empty when the image can't be decoded or holds no legible
    /// text (a photo, an icon grid).
    public static func recognizeLines(inPNG pngData: Data) -> [String] {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return []
        }
        return recognizeLines(in: image)
    }

    /// Recognized lines from a decoded image, in reading order.
    public static func recognizeLines(in image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Let Vision pick the language from the pixels instead of pinning one, so a chat that mixes Korean
        // and English (or any other script) reads correctly without the caller naming languages per app.
        if #available(macOS 13.0, *) {
            request.automaticallyDetectsLanguage = true
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        // Vision returns observations in no guaranteed order. The bounding box origin is bottom-left and
        // normalized, so a larger y sits higher on screen. Quantize y into normalized bands and sort by
        // band (descending, top first) then x (ascending, left first): bands group the fragments of one
        // visual line together left-to-right, and comparing integer bands is a TOTAL order — a raw
        // near-equal-y threshold is intransitive (A~B, B~C, but A≁C) and lets the sort scramble lines.
        return (request.results ?? [])
            .sorted { lhs, rhs in
                let lband = (lhs.boundingBox.origin.y * 100).rounded()
                let rband = (rhs.boundingBox.origin.y * 100).rounded()
                if lband != rband { return lband > rband }
                return lhs.boundingBox.origin.x < rhs.boundingBox.origin.x
            }
            .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
