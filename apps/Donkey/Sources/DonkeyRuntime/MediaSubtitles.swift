import DonkeyHarness
import Foundation

/// A single subtitle cue: a time span (milliseconds) and its text. Built from precise on-device per-word
/// timings; the text can be replaced by a translation while the timing stays exact.
public struct SubtitleCue: Sendable {
    public var startMS: Int
    public var endMS: Int
    public var text: String

    public init(startMS: Int, endMS: Int, text: String) {
        self.startMS = startMS
        self.endMS = endMS
        self.text = text
    }
}

/// Shared subtitle and media-time helpers for the deterministic media pipelines (shorts, caption).
///
/// Building the SRT in CODE from precise on-device timings is the point: a captioning run that hands SRT
/// authoring to the model falls into a cleanup loop — the model emits a messy SRT (stray prose, wrong
/// language, broken cues), so the planner re-cleans it, writes a Python filter, re-runs it, and so on, a
/// fresh LLM round-trip each time. Code that groups timed words into valid cues never produces that mess.
public enum MediaSubtitles {
    /// Group per-word timings into cues of up to ~7 words / ~3.2s, breaking early on a long pause or a
    /// sentence-ending punctuation mark.
    public static func cues(from words: [HarnessTranscriptionWord]) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var current: [HarnessTranscriptionWord] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { cues.append(SubtitleCue(startMS: first.startMS, endMS: last.endMS, text: text)) }
            current = []
        }
        for word in words {
            if let last = current.last, word.startMS - last.endMS > 700 { flush() }
            current.append(word)
            let durationMS = (current.last?.endMS ?? 0) - (current.first?.startMS ?? 0)
            let endsSentence = word.text.last.map { ".!?".contains($0) } ?? false
            if current.count >= 7 || durationMS >= 3200 || endsSentence { flush() }
        }
        flush()
        return cues
    }

    /// Render cues as a valid SRT document: 1-based indices, `HH:MM:SS,mmm` timestamps.
    public static func srt(from cues: [SubtitleCue]) -> String {
        var out = ""
        for (index, cue) in cues.enumerated() {
            out += "\(index + 1)\n\(srtTime(cue.startMS)) --> \(srtTime(cue.endMS))\n\(cue.text)\n\n"
        }
        return out
    }

    /// `HH:MM:SS,mmm` SRT timestamp.
    public static func srtTime(_ ms: Int) -> String {
        let total = max(0, ms)
        return String(
            format: "%02d:%02d:%02d,%03d",
            total / 3_600_000, (total % 3_600_000) / 60_000, (total % 60_000) / 1000, total % 1000
        )
    }

    /// ffmpeg accepts a bare-seconds time spec for `-ss`/`-t`; three decimals is well under frame precision.
    public static func seconds(_ value: Double) -> String { String(format: "%.3f", max(0, value)) }
}
