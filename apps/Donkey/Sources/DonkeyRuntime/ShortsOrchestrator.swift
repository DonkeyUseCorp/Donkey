import DonkeyHarness
import Foundation

/// One clip-worthy span of the source, in seconds, chosen by the single model call the shorts pipeline
/// makes. `title` is a short human label used only for the summary.
public struct MomentSpan: Sendable {
    public var startSec: Double
    public var endSec: Double
    public var title: String

    public init(startSec: Double, endSec: Double, title: String = "") {
        self.startSec = startSec
        self.endSec = endSec
        self.title = title
    }

    public var durationSec: Double { max(0, endSec - startSec) }
}

/// The deterministic pipeline behind `shorts.make`: source → ONE model call to pick the moments → per clip
/// cut, transcribe on-device, reframe to vertical, burn captions — all in fixed code. `selectMoments` is the
/// only model call; transcription is on-device and the cut/reframe/caption steps are bundled tools, so once
/// the moments are chosen the clips are produced without ever returning to the planner. That is what turns a
/// ~37-call, dollar-plus run into a single decision plus local rendering.
///
/// ```
///   resolve source (yt-dlp if URL)
///        → extract audio → transcribe whole source (on-device)
///        → selectMoments  ← the ONE model call
///        → fan out per moment, all deterministic:
///              cut span → transcribe clip → reframe 9:16 → burn captions
/// ```
public struct ShortsOrchestrator: Sendable {
    public typealias SelectMoments = @Sendable (_ timestampedTranscript: String, _ desiredCount: Int?) async -> [MomentSpan]?
    public typealias Transcribe = @Sendable (HarnessTranscriptionRequest) async -> HarnessTranscriptionResult?

    private let selectMoments: SelectMoments
    private let transcribe: Transcribe
    private let makeRunTool: @Sendable (SandboxPolicy?) -> MediaPipeline.ToolRunner

    public init(
        selectMoments: @escaping SelectMoments,
        transcribe: @escaping Transcribe,
        makeRunTool: @escaping @Sendable (SandboxPolicy?) -> MediaPipeline.ToolRunner = MediaPipeline.sandboxedRunner
    ) {
        self.selectMoments = selectMoments
        self.transcribe = transcribe
        self.makeRunTool = makeRunTool
    }

    public func make(_ request: HarnessShortsRequest) async -> HarnessShortsOutcome {
        // Working directory: the conversation's own folder when present, else home — same rule as shell_exec
        // and the form filler, so produced clips land beside the rest of the task's output.
        let workdir = DonkeyCommandBackends.resolvedWorkingDirectoryPath(request.workingDirectory)
        // Every bundled-tool spawn for this run is confined to the workspace (with the source readable).
        let runTool = makeRunTool(SandboxPolicy.forWorkspace(baseDirectory: request.workingDirectory, localSource: request.source))

        // 1. Resolve the source to a local file (download a URL with yt-dlp first). Resolve ONCE — a second
        //    call would re-download the URL.
        let sourcePath: String
        switch resolveSource(request.source, workdir: workdir, using: runTool) {
        case .ok(let resolved): sourcePath = resolved
        case .failed(let reason): return Self.fail(reason)
        }

        // 2. Extract compact audio and transcribe the whole source on-device — the timing the moment
        //    selection reads. Free and private; no model call.
        let sourceAudio = (workdir as NSString).appendingPathComponent("source_audio.mp3")
        let audioStep = MediaPipeline.runStep(
            "ffmpeg",
            ["-y", "-i", sourcePath, "-vn", "-ac", "1", "-c:a", "libmp3lame", "-b:a", "64k", sourceAudio],
            workingDirectory: workdir, expecting: sourceAudio, using: runTool
        )
        if case let .failed(reason) = audioStep {
            return Self.fail("Could not read audio from the source: \(reason)")
        }
        guard let fullTranscript = await transcribe(HarnessTranscriptionRequest(filePath: sourceAudio)),
              fullTranscript.failureReason == nil, !fullTranscript.words.isEmpty else {
            return Self.fail("Could not transcribe the source to choose moments.")
        }

        // 3. THE ONE MODEL CALL: choose the clip-worthy spans from the timestamped transcript.
        let timestamped = Self.timestampedTranscript(fullTranscript.words)
        guard let moments = await selectMoments(timestamped, request.desiredCount), !moments.isEmpty else {
            return Self.fail("Could not find clip-worthy moments in the source.")
        }
        let chosen = request.desiredCount.map { Array(moments.prefix(max(1, $0))) } ?? moments

        // 4. Per clip, all deterministic — no planner round-trip between any of these.
        let aspect = (request.aspect?.isEmpty == false) ? request.aspect! : "9:16"
        let reframeWanted = !["original", "keep", "none", "source"].contains(aspect.lowercased())
        let result = await MediaPipeline.fanOut(chosen) { index, moment in
            await makeClip(
                index: index, moment: moment, sourcePath: sourcePath,
                workdir: workdir, aspect: aspect, reframe: reframeWanted, using: runTool
            )
        }

        guard !result.produced.isEmpty else {
            return Self.fail("Shorts pipeline produced no clips: \(result.failures.first ?? "no clip could be rendered")")
        }
        let kind = reframeWanted ? "vertical " : ""
        var summary = "Made \(result.produced.count) captioned \(kind)clip\(result.produced.count == 1 ? "" : "s")."
        if !result.failures.isEmpty {
            summary += " \(result.failures.count) clip\(result.failures.count == 1 ? "" : "s") could not be finished."
        }
        return HarnessShortsOutcome(text: summary, succeeded: true, producedFiles: result.produced)
    }

    // MARK: - Per-clip pipeline

    /// Cut one span, caption it from an on-device transcription of the clip, reframe to vertical, and burn
    /// the captions on. Captioning and reframing degrade gracefully — a clip with no transcript or a reframe
    /// that fails still ships, so one weak moment never sinks the whole job.
    private func makeClip(
        index: Int, moment: MomentSpan, sourcePath: String,
        workdir: String, aspect: String, reframe: Bool, using runTool: MediaPipeline.ToolRunner
    ) async -> PipelineItemOutcome {
        let n = index + 1
        func path(_ name: String) -> String { (workdir as NSString).appendingPathComponent(name) }

        // a. Cut the span. Accurate seek (after -i) and a clean re-encode, so the clip is frame-accurate
        //    rather than snapped to the nearest keyframe.
        let clip = path("clip_\(n).mp4")
        let cut = MediaPipeline.runStep(
            "ffmpeg",
            ["-y", "-i", sourcePath, "-ss", Self.seconds(moment.startSec), "-t", Self.seconds(max(0.5, moment.durationSec)),
             "-c:v", "h264_videotoolbox", "-c:a", "aac", clip],
            workingDirectory: workdir, expecting: clip, using: runTool
        )
        if case let .failed(reason) = cut { return .failed(reason: "clip \(n): could not cut the span — \(reason)") }

        // b. Transcribe the clip (zero-based) for caption timings and write an SRT. Best-effort.
        let srtPath = await captionSRT(forClip: clip, index: n, workdir: workdir, using: runTool)

        // c. Reframe to vertical, following the active speaker. On failure keep the original framing.
        var base = clip
        if reframe {
            let vertical = path("clip_\(n)_v.mp4")
            let reframed = MediaPipeline.runStep(
                "reframe",
                ["--input", clip, "--output", vertical, "--aspect", aspect, "--height", "1920"],
                workingDirectory: workdir, expecting: vertical, using: runTool
            )
            if case .ok = reframed { base = vertical }
        }

        // d. Burn the captions on; fall back to a soft track if this ffmpeg lacks libass, and to the
        //    uncaptioned clip if even that fails.
        guard let srt = srtPath else { return .produced([base]) }
        let final = path("clip_\(n)_captioned.mp4")
        let burn = MediaPipeline.runStep(
            "ffmpeg",
            ["-y", "-i", base, "-vf", "subtitles=\((srt as NSString).lastPathComponent)", "-c:a", "copy", final],
            workingDirectory: workdir, expecting: final, using: runTool
        )
        if case .ok = burn { return .produced([final]) }
        let soft = MediaPipeline.runStep(
            "ffmpeg",
            ["-y", "-i", base, "-i", srt, "-c", "copy", "-c:s", "mov_text", final],
            workingDirectory: workdir, expecting: final, using: runTool
        )
        if case .ok = soft { return .produced([final]) }
        return .produced([base])
    }

    /// Extract compact audio from the clip, transcribe it on-device (timings zero-based to the clip), and
    /// write an SRT next to it. Returns the SRT path, or nil when the clip has no usable transcript.
    private func captionSRT(forClip clip: String, index n: Int, workdir: String, using runTool: MediaPipeline.ToolRunner) async -> String? {
        let clipAudio = (workdir as NSString).appendingPathComponent("clip_\(n).mp3")
        let audio = MediaPipeline.runStep(
            "ffmpeg",
            ["-y", "-i", clip, "-vn", "-ac", "1", "-c:a", "libmp3lame", "-b:a", "64k", clipAudio],
            workingDirectory: workdir, expecting: clipAudio, using: runTool
        )
        guard case .ok = audio,
              let transcript = await transcribe(HarnessTranscriptionRequest(filePath: clipAudio)),
              transcript.failureReason == nil, !transcript.words.isEmpty else {
            return nil
        }
        let srtPath = (workdir as NSString).appendingPathComponent("clip_\(n).srt")
        guard (try? Self.makeSRT(transcript.words).write(toFile: srtPath, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        return srtPath
    }

    // MARK: - Source resolution

    private func resolveSource(_ source: String, workdir: String, using runTool: MediaPipeline.ToolRunner) -> MediaStepResult {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            // Pin the output path and force a real download (--no-simulate), then read the exact final path
            // yt-dlp prints, so later steps never hunt for the file.
            let template = (workdir as NSString).appendingPathComponent("source.%(ext)s")
            let result = runTool(
                "yt-dlp",
                ["-o", template, "--no-simulate", "--print", "after_move:filepath",
                 "--retries", "5", "--extractor-retries", "3", trimmed],
                workdir
            )
            guard result.exitCode == 0 else {
                let why = result.stderr.isEmpty ? result.stdout : result.stderr
                return .failed(reason: "yt-dlp could not download the source: \(MediaPipeline.lastLines(why))")
            }
            let printed = result.stdout
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last(where: { !$0.isEmpty })
            if let printed, FileManager.default.fileExists(atPath: printed) {
                return .ok(producedPath: printed)
            }
            return .failed(reason: "yt-dlp finished but its downloaded file path could not be determined.")
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let resolved = (expanded as NSString).isAbsolutePath
            ? expanded
            : (workdir as NSString).appendingPathComponent(expanded)
        if FileManager.default.fileExists(atPath: resolved) {
            return .ok(producedPath: resolved)
        }
        return .failed(reason: "No source video at \(source).")
    }

    // MARK: - Formatting helpers

    private static func fail(_ text: String) -> HarnessShortsOutcome {
        HarnessShortsOutcome(text: text, succeeded: false, producedFiles: [])
    }

    /// ffmpeg accepts a bare-seconds time spec for `-ss`/`-t`; three decimals is well under frame precision.
    static func seconds(_ value: Double) -> String { MediaSubtitles.seconds(value) }

    /// Render the transcript one line per ~12 words, each prefixed with its `[m:ss]` start, so the moment
    /// selector can name spans by time.
    static func timestampedTranscript(_ words: [HarnessTranscriptionWord]) -> String {
        var lines: [String] = []
        var current: [HarnessTranscriptionWord] = []
        func flush() {
            guard let first = current.first else { return }
            lines.append("[\(clock(first.startMS))] " + current.map(\.text).joined(separator: " "))
            current = []
        }
        for word in words {
            current.append(word)
            let endsSentence = word.text.last.map { ".!?".contains($0) } ?? false
            if current.count >= 12 || endsSentence { flush() }
        }
        flush()
        return lines.joined(separator: "\n")
    }

    /// Build an SRT from per-word timings — cue grouping and rendering shared with the caption pipeline.
    static func makeSRT(_ words: [HarnessTranscriptionWord]) -> String {
        MediaSubtitles.srt(from: MediaSubtitles.cues(from: words))
    }

    /// `m:ss` clock for the transcript markers the selector reads.
    static func clock(_ ms: Int) -> String {
        let total = max(0, ms) / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// `HH:MM:SS,mmm` SRT timestamp.
    static func srtTime(_ ms: Int) -> String { MediaSubtitles.srtTime(ms) }
}
