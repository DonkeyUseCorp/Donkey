import DonkeyHarness
import Foundation

/// The deterministic pipeline behind `media.caption`: take a video (optionally a clipped span of one),
/// transcribe it on-device, optionally translate the text with ONE model call, build the SRT in code, and
/// burn it in with a known-good encoder — then verify. This is the captioning/subtitling/translation family
/// done as fixed code instead of through the planner loop.
///
/// It exists because that recipe, left to the planner, is where runs explode: a model-authored SRT comes
/// back messy, so the planner re-cleans it, writes a Python filter, re-runs it; the burn fails on a default
/// encoder, so it probes `ffmpeg -encoders`; a `-c copy` trim of a webm yields the wrong duration, so it
/// runs eight `ffprobe`s to debug — every probe a full-context LLM round-trip. Here the timings come from
/// on-device transcription, the SRT is built from them (never parsed back from a model), the trim re-encodes
/// for an accurate span, and the burn pins `h264_videotoolbox -pix_fmt yuv420p -c:a aac` so the video stream
/// is never dropped (VideoToolbox is the bundled LGPL ffmpeg's H.264 encoder — it has no libx264). The only
/// model call is the optional translation.
///
/// ```
///   resolve source (yt-dlp, with --download-sections for a URL span)
///        → [trim local span] → extract audio → transcribe (on-device)
///        → [translate cue texts]  ← the ONE model call, only when a language is asked for
///        → build SRT in code → burn (h264_videotoolbox/yuv420p/aac) → verify
/// ```
public struct CaptionOrchestrator: Sendable {
    public typealias TranslateCues = @Sendable (_ lines: [String], _ targetLanguage: String) async -> [String]?
    public typealias Transcribe = @Sendable (HarnessTranscriptionRequest) async -> HarnessTranscriptionResult?

    private let translateCues: TranslateCues
    private let transcribe: Transcribe
    private let makeRunTool: @Sendable (SandboxPolicy?) -> MediaPipeline.ToolRunner

    public init(
        translateCues: @escaping TranslateCues,
        transcribe: @escaping Transcribe,
        makeRunTool: @escaping @Sendable (SandboxPolicy?) -> MediaPipeline.ToolRunner = MediaPipeline.sandboxedRunner
    ) {
        self.translateCues = translateCues
        self.transcribe = transcribe
        self.makeRunTool = makeRunTool
    }

    public func caption(_ request: HarnessCaptionRequest) async -> HarnessCaptionOutcome {
        let workdir = DonkeyCommandBackends.resolvedWorkingDirectoryPath(request.workingDirectory)
        func path(_ name: String) -> String { (workdir as NSString).appendingPathComponent(name) }
        // Every bundled-tool spawn for this run is confined to the workspace (with the source readable).
        let runTool = makeRunTool(SandboxPolicy.forWorkspace(baseDirectory: request.workingDirectory, localSource: request.source))

        let startSec = request.clipStart.flatMap(Self.parseSeconds)
        let durationSec = request.clipDuration.flatMap(Self.parseSeconds)

        // 1. Resolve to a local video, applying the requested span as we go (a URL span downloads only that
        //    range; a local span is trimmed with an accurate re-encode, never `-c copy`).
        let base: String
        switch resolveBase(request.source, startSec: startSec, durationSec: durationSec, workdir: workdir, makePath: path, using: runTool) {
        case .ok(let resolved): base = resolved
        case .failed(let reason): return Self.fail(reason)
        }

        // 2. Extract compact audio and transcribe on-device — the timings the cues are built from. Free.
        let audio = path("caption_audio.mp3")
        let audioStep = MediaPipeline.runStep(
            "ffmpeg",
            ["-y", "-i", base, "-vn", "-ac", "1", "-c:a", "libmp3lame", "-b:a", "64k", audio],
            workingDirectory: workdir, expecting: audio, using: runTool
        )
        if case let .failed(reason) = audioStep {
            return Self.fail("Could not read audio from the video: \(reason)")
        }
        guard let transcript = await transcribe(HarnessTranscriptionRequest(filePath: audio)),
              transcript.failureReason == nil, !transcript.words.isEmpty else {
            return Self.fail("Could not transcribe the video to build captions.")
        }

        // 3. Build cues from the timings. Optionally translate the cue TEXTS (one model call) while keeping
        //    the exact timings — so a translation never disturbs sync and the SRT is never model-authored.
        var cues = MediaSubtitles.cues(from: transcript.words)
        var translatedNote = ""
        if let language = request.translateTo, !language.isEmpty {
            guard let translated = await translateCues(cues.map(\.text), language),
                  translated.count == cues.count else {
                return Self.fail("Could not translate the captions to \(language).")
            }
            for index in cues.indices { cues[index].text = translated[index] }
            translatedNote = " translated to \(language)"
        }

        // 4. Write the SRT (built in code — valid by construction) and burn it in with a known-good encoder.
        let srtPath = path("captions.srt")
        guard (try? MediaSubtitles.srt(from: cues).write(toFile: srtPath, atomically: true, encoding: .utf8)) != nil else {
            return Self.fail("Could not write the captions file.")
        }
        let output = path("captioned.mp4")
        let burn = MediaPipeline.runStep(
            "ffmpeg",
            ["-y", "-i", base, "-vf", "subtitles=\((srtPath as NSString).lastPathComponent)",
             "-c:v", "h264_videotoolbox", "-pix_fmt", "yuv420p", "-c:a", "aac", output],
            workingDirectory: workdir, expecting: output, using: runTool
        )
        if case .ok = burn {
            return HarnessCaptionOutcome(text: "Captioned\(translatedNote): \(output)", succeeded: true, producedFiles: [output])
        }
        // libass missing → deliver a toggleable soft track instead of burned-in text (no re-encode needed).
        let soft = MediaPipeline.runStep(
            "ffmpeg",
            ["-y", "-i", base, "-i", srtPath, "-c", "copy", "-c:s", "mov_text", output],
            workingDirectory: workdir, expecting: output, using: runTool
        )
        if case let .failed(reason) = soft {
            return Self.fail("Could not burn the captions in: \(reason)")
        }
        return HarnessCaptionOutcome(
            text: "Added a soft caption track\(translatedNote) (burn-in unavailable): \(output)",
            succeeded: true, producedFiles: [output]
        )
    }

    // MARK: - Source + span

    private func resolveBase(
        _ source: String, startSec: Double?, durationSec: Double?, workdir: String,
        makePath: (String) -> String, using runTool: MediaPipeline.ToolRunner
    ) -> MediaStepResult {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            var arguments = ["-o", makePath("source.%(ext)s"), "--no-simulate", "--print", "after_move:filepath",
                             "--retries", "5", "--extractor-retries", "3"]
            // A URL with a span downloads ONLY that range, so we never pull a whole long video to clip a minute.
            if let startSec, let durationSec {
                arguments.append(contentsOf: ["--download-sections", "*\(Int(startSec))-\(Int(startSec + durationSec))"])
            }
            arguments.append(trimmed)
            let result = runTool("yt-dlp", arguments, workdir)
            guard result.exitCode == 0 else {
                let why = result.stderr.isEmpty ? result.stdout : result.stderr
                return .failed(reason: "yt-dlp could not download the source: \(MediaPipeline.lastLines(why))")
            }
            let printed = result.stdout
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last(where: { !$0.isEmpty })
            guard let downloaded = printed, FileManager.default.fileExists(atPath: downloaded) else {
                return .failed(reason: "yt-dlp finished but its downloaded file path could not be determined.")
            }
            return .ok(producedPath: downloaded)
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let resolved = (expanded as NSString).isAbsolutePath
            ? expanded
            : (workdir as NSString).appendingPathComponent(expanded)
        guard FileManager.default.fileExists(atPath: resolved) else {
            return .failed(reason: "No source video at \(source).")
        }
        // A local span is trimmed with an accurate re-encode (seek after -i, real codec) — never `-c copy`,
        // which snaps to a keyframe and yields the wrong duration (the bug the planner used to debug by hand).
        guard let startSec, let durationSec else { return .ok(producedPath: resolved) }
        let clip = makePath("clip.mp4")
        let trim = MediaPipeline.runStep(
            "ffmpeg",
            ["-y", "-i", resolved, "-ss", MediaSubtitles.seconds(startSec), "-t", MediaSubtitles.seconds(durationSec),
             "-c:v", "h264_videotoolbox", "-c:a", "aac", clip],
            workingDirectory: workdir, expecting: clip, using: runTool
        )
        if case let .failed(reason) = trim { return .failed(reason: "Could not cut the requested span: \(reason)") }
        return .ok(producedPath: clip)
    }

    private static func fail(_ text: String) -> HarnessCaptionOutcome {
        HarnessCaptionOutcome(text: text, succeeded: false, producedFiles: [])
    }

    /// Parse a time spec to seconds: a bare number, or `M:SS` / `H:MM:SS`.
    static func parseSeconds(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if !trimmed.contains(":") { return Double(trimmed) }
        let parts = trimmed.split(separator: ":").map { Double($0) }
        if parts.contains(nil) { return nil }
        let numbers = parts.compactMap { $0 }
        switch numbers.count {
        case 2: return numbers[0] * 60 + numbers[1]
        case 3: return numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
        default: return nil
        }
    }
}
