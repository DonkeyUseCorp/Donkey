import Foundation

/// A half-open time span `[start, end)` in seconds.
public struct MediaTimeSpan: Equatable, Sendable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var length: Double { max(0, end - start) }
}

/// Deterministic span math for cutting filler words and silence out of a media file and rejoining the
/// kept parts — the engine Descript / auto-editor implement in code rather than leaving to a model.
///
/// Given the spans to REMOVE and the file's duration it computes the exact spans to KEEP and the ffmpeg
/// filtergraph that stitches them back together, frame-accurate with audio and video in lockstep. Every
/// function here is pure: no ffmpeg, no IO, no clock, no randomness, so the same inputs always produce
/// the same cut. The IO (running ffmpeg/ffprobe) lives in `MediaCutEngine`; this is the part that has to
/// be exactly right, and it is unit-tested directly.
public enum MediaCutPlanner {
    /// Tunables, with defaults grounded in how auto-editor / Descript behave: a small outward pad on each
    /// filler so its trailing breath goes too, a natural pause left at each end of a removed silence so
    /// speech doesn't sound clipped, and floors that keep the edit from making cuts too small to be worth
    /// the seam.
    public struct Parameters: Equatable, Sendable {
        /// Expand each filler span outward by this much (seconds) so the word's edges/breath are removed.
        public var fillerPadSec: Double
        /// Leave this much silence (seconds) at each end of a removed silence, so the cut sounds natural.
        public var keepPauseSec: Double
        /// Merge two removals whose gap is at most this (seconds) into one — avoids a pointless micro-keep.
        public var mergeGapSec: Double
        /// Ignore a removal shorter than this (seconds): a cut this small is more jarring than the content.
        public var minRemovalSec: Double
        /// Drop a kept sliver shorter than this (seconds) rather than emit a frame or two of footage.
        public var minKeepSec: Double

        public init(
            fillerPadSec: Double = 0.03,
            keepPauseSec: Double = 0.15,
            mergeGapSec: Double = 0.04,
            minRemovalSec: Double = 0.05,
            minKeepSec: Double = 0.02
        ) {
            self.fillerPadSec = max(0, fillerPadSec)
            self.keepPauseSec = max(0, keepPauseSec)
            self.mergeGapSec = max(0, mergeGapSec)
            self.minRemovalSec = max(0, minRemovalSec)
            self.minKeepSec = max(0, minKeepSec)
        }
    }

    /// The default unambiguous filler lexicon. Words like "like" / "you know" are deliberately absent:
    /// they are filler only sometimes, so removing them is a judgment call the caller passes as explicit
    /// spans, not a blanket lexicon match.
    public static let defaultFillerLexicon: Set<String> = ["um", "uh", "uhm", "umm", "erm", "er", "ah", "hmm", "mhm", "mm"]

    // MARK: - Building removal spans from each source

    /// Parse ffmpeg `silencedetect` output (it logs to stderr) into the spans to remove, each shrunk by
    /// `keepPauseSec` at both ends so a natural pause survives the cut. A `silence_start` with no matching
    /// `silence_end` (silence running to EOF) yields an open end (`+inf`); `keepSegments` clamps it to the
    /// real duration.
    public static func silenceSpans(fromSilenceDetect text: String, keepPauseSec: Double) -> [MediaTimeSpan] {
        var starts: [Double] = []
        var ends: [Double] = []
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            if let value = number(after: "silence_start:", in: line) {
                starts.append(value)
            }
            // `silence_end: 19.43 | silence_duration: 0.9` — take the value right after the key.
            if let value = number(after: "silence_end:", in: line) {
                ends.append(value)
            }
        }
        let pause = max(0, keepPauseSec)
        var spans: [MediaTimeSpan] = []
        for (index, start) in starts.enumerated() {
            let rawEnd = index < ends.count ? ends[index] : Double.greatestFiniteMagnitude
            let shrunkStart = start + pause
            let shrunkEnd = rawEnd == Double.greatestFiniteMagnitude ? rawEnd : rawEnd - pause
            if shrunkEnd > shrunkStart {
                spans.append(MediaTimeSpan(start: shrunkStart, end: shrunkEnd))
            }
        }
        return spans
    }

    /// Parse a transcript JSON (the `{ "words": [{ "text", "start", "end" }] }` shape `transcribe`
    /// writes) into the spans for every word whose normalized text is in `lexicon`, each padded outward by
    /// `padSec`. Times are in seconds. Malformed JSON yields no spans.
    public static func fillerSpans(fromTranscriptJSON data: Data, lexicon: Set<String>, padSec: Double) -> [MediaTimeSpan] {
        struct Word: Decodable { var text: String; var start: Double; var end: Double }
        struct Transcript: Decodable { var words: [Word] }
        guard let transcript = try? JSONDecoder().decode(Transcript.self, from: data) else { return [] }
        let pad = max(0, padSec)
        let normalizedLexicon = Set(lexicon.map { normalize($0) })
        return transcript.words.compactMap { word in
            guard normalizedLexicon.contains(normalize(word.text)), word.end > word.start else { return nil }
            return MediaTimeSpan(start: word.start - pad, end: word.end + pad)
        }
    }

    /// Parse an explicit removal list, `"1.2-3.4, 5-6.0"` (seconds), into spans. Whitespace and a trailing
    /// `s` unit are tolerated; malformed entries are skipped. Used for caller-judged removals (a discourse
    /// "like", a flubbed take) that no lexicon should decide.
    public static func explicitSpans(fromList list: String) -> [MediaTimeSpan] {
        list.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" }).compactMap { piece in
            let parts = piece.split(separator: "-", maxSplits: 1).map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t s"))
            }
            guard parts.count == 2, let start = Double(parts[0]), let end = Double(parts[1]), end > start else {
                return nil
            }
            return MediaTimeSpan(start: start, end: end)
        }
    }

    // MARK: - The core: removals -> kept segments

    /// Turn the spans to remove into the spans to KEEP across `[0, duration]`. Clamps to the real
    /// duration, drops removals shorter than `minRemovalSec`, merges removals within `mergeGapSec`,
    /// inverts to the gaps between them, and drops kept slivers shorter than `minKeepSec`. The result is
    /// the ordered, non-overlapping footage to stitch back together. With no removals it is the whole
    /// file; with removals covering everything it is empty.
    public static func keepSegments(
        removing removals: [MediaTimeSpan],
        duration: Double,
        parameters: Parameters = Parameters()
    ) -> [MediaTimeSpan] {
        guard duration > 0 else { return [] }

        let cleaned = removals
            .map { MediaTimeSpan(start: clamp($0.start, 0, duration), end: clamp($0.end, 0, duration)) }
            .filter { $0.length >= parameters.minRemovalSec }
            .sorted { $0.start < $1.start }

        var merged: [MediaTimeSpan] = []
        for span in cleaned {
            if var last = merged.last, span.start <= last.end + parameters.mergeGapSec {
                last.end = max(last.end, span.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(span)
            }
        }

        var keeps: [MediaTimeSpan] = []
        var cursor = 0.0
        for removal in merged {
            // A removal at the cursor (e.g. one starting at t=0) leaves no lead segment — never emit a
            // zero-length keep, which would feed ffmpeg an empty trim.
            let lead = removal.start - cursor
            if lead > 0, lead >= parameters.minKeepSec {
                keeps.append(MediaTimeSpan(start: cursor, end: removal.start))
            }
            cursor = max(cursor, removal.end)
        }
        let tail = duration - cursor
        if tail > 0, tail >= parameters.minKeepSec {
            keeps.append(MediaTimeSpan(start: cursor, end: duration))
        }
        return keeps
    }

    // MARK: - Rendering the kept segments

    /// The ffmpeg `filter_complex` that trims each kept span and concatenates them back into one stream,
    /// re-stamping timestamps so there are no gaps. `trim`/`atrim` cut on exact frame/sample boundaries
    /// and the same span list drives both, so video and audio stay in lockstep. Returns `""` when there is
    /// nothing to keep or neither stream is present.
    public static func filterGraph(keeping keeps: [MediaTimeSpan], hasVideo: Bool, hasAudio: Bool) -> String {
        guard !keeps.isEmpty, hasVideo || hasAudio else { return "" }
        var lines: [String] = []
        var concatInputs = ""
        for (index, keep) in keeps.enumerated() {
            let start = format(keep.start)
            let end = format(keep.end)
            if hasVideo {
                lines.append("[0:v]trim=start=\(start):end=\(end),setpts=PTS-STARTPTS[v\(index)]")
                concatInputs += "[v\(index)]"
            }
            if hasAudio {
                lines.append("[0:a]atrim=start=\(start):end=\(end),asetpts=PTS-STARTPTS[a\(index)]")
                concatInputs += "[a\(index)]"
            }
        }
        let videoFlag = hasVideo ? 1 : 0
        let audioFlag = hasAudio ? 1 : 0
        var outputs = ""
        if hasVideo { outputs += "[v]" }
        if hasAudio { outputs += "[a]" }
        lines.append("\(concatInputs)concat=n=\(keeps.count):v=\(videoFlag):a=\(audioFlag)\(outputs)")
        return lines.joined(separator: ";\n")
    }

    // MARK: - Helpers

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    /// The first decimal number appearing after `key` in `line`, or nil. Tolerates the bracketed
    /// `[silencedetect @ 0x..]` prefix and a trailing `| silence_duration: ..` on the same line.
    private static func number(after key: String, in line: Substring) -> Double? {
        guard let range = line.range(of: key) else { return nil }
        let rest = line[range.upperBound...]
        var token = ""
        for character in rest {
            if character == " " || character == "\t" { if token.isEmpty { continue } else { break } }
            if character.isNumber || character == "." || character == "-" || character == "+" {
                token.append(character)
            } else if !token.isEmpty {
                break
            }
        }
        return Double(token)
    }

    /// Lowercase and strip surrounding punctuation so `"Um,"` matches the lexicon entry `"um"`.
    private static func normalize(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    /// Fixed 3-decimal seconds (millisecond precision) so the filtergraph is deterministic and never uses
    /// scientific notation for a large timestamp.
    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
