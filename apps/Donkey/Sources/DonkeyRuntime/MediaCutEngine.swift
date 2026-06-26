import DonkeyHarness
import Foundation

/// The IO half of `media.cut`: it runs the bundled ffmpeg/ffprobe to detect silence, reads the
/// `transcribe` JSON for fillers, asks `MediaCutPlanner` (pure, tested) for the exact spans to keep, then
/// renders the cut by re-encoding the kept segments and concatenating them. Frame-accurate, audio and
/// video in lockstep, and fully deterministic — the model picks WHAT to remove, never HOW.
///
/// The render uses `h264_videotoolbox` because Donkey's bundled ffmpeg is the LGPL build with no
/// libx264; VideoToolbox is the hardware H.264 encoder that is present.
public enum MediaCutEngine {
    /// Run a cut request to completion. Blocking ffmpeg work runs off the calling actor.
    public static func run(_ request: HarnessMediaCutRequest) async -> HarnessMediaCutResult {
        await Task.detached(priority: .userInitiated) { runSync(request) }.value
    }

    // MARK: - Orchestration

    private static func runSync(_ request: HarnessMediaCutRequest) -> HarnessMediaCutResult {
        let inputURL = URL(fileURLWithPath: request.inputPath)
        let failed: (String) -> HarnessMediaCutResult = { reason in
            HarnessMediaCutResult(outputPath: "", removedSpanCount: 0, inputDurationSec: 0, outputDurationSec: 0, failureReason: reason)
        }

        guard let toolsDir = DonkeyCommandBackends.bundledToolsDirectory else {
            return failed("the media tools are still installing — try again in a moment")
        }
        let ffmpeg = toolsDir.appendingPathComponent("ffmpeg")
        let ffprobe = toolsDir.appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path),
              FileManager.default.isExecutableFile(atPath: ffprobe.path) else {
            return failed("the media tools are still installing — try again in a moment")
        }

        // Confine every ffmpeg/ffprobe spawn to the workspace, allowing reads of the input + transcript
        // (which may sit outside it) and a write to the output's own folder — so an in-place save the user
        // asked for lands instead of EPERMing. nil policy with no workspace, so behavior is unchanged there.
        let workdir = request.workingDirectory
        let outputURL = resolveOutputURL(request: request, input: inputURL)
        let policy = SandboxPolicy.forWorkspace(
            baseDirectory: workdir,
            readableInputs: [request.inputPath, request.transcriptPath].compactMap { $0 },
            alsoWritable: [outputURL.deletingLastPathComponent().path]
        )
        guard let duration = probeDuration(ffprobe, inputURL, policy: policy, workingDirectory: workdir), duration > 0 else {
            return failed("could not read the file's duration — is \(inputURL.lastPathComponent) a real media file?")
        }
        let streams = probeStreams(ffprobe, inputURL, policy: policy, workingDirectory: workdir)
        guard streams.hasVideo || streams.hasAudio else {
            return failed("the file has no audio or video stream to edit")
        }

        let parameters = MediaCutPlanner.Parameters()
        var removals: [MediaTimeSpan] = []

        if request.removeSilence {
            let detect = runProcess(
                ffmpeg,
                ["-hide_banner", "-nostats", "-i", inputURL.path, "-af", "silencedetect=noise=-30dB:d=0.5", "-f", "null", "-"],
                timeout: max(120, duration),
                policy: policy, workingDirectory: workdir
            )
            // silencedetect logs to stderr.
            removals += MediaCutPlanner.silenceSpans(fromSilenceDetect: detect.stderr, keepPauseSec: parameters.keepPauseSec)
        }

        if request.removeFillers {
            guard let path = request.transcriptPath, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                return failed("could not read the transcript JSON for filler detection")
            }
            let lexicon = request.fillerWords.isEmpty
                ? MediaCutPlanner.defaultFillerLexicon
                : Set(request.fillerWords.map { $0.lowercased() })
            removals += MediaCutPlanner.fillerSpans(fromTranscriptJSON: data, lexicon: lexicon, padSec: parameters.fillerPadSec)
        }

        if let explicit = request.explicitRemovals {
            removals += MediaCutPlanner.explicitSpans(fromList: explicit)
        }

        let keeps = MediaCutPlanner.keepSegments(removing: removals, duration: duration, parameters: parameters)
        if keeps.isEmpty {
            return failed("the spans to remove cover the entire file — nothing would be left")
        }
        let cutCount = removedRegionCount(keeps: keeps, duration: duration)
        if cutCount == 0 {
            // Nothing matched (or every match fell below the floors): a clean no-op, source left as-is.
            return HarnessMediaCutResult(
                outputPath: inputURL.path,
                removedSpanCount: 0,
                inputDurationSec: duration,
                outputDurationSec: duration,
                failureReason: nil
            )
        }

        let graph = MediaCutPlanner.filterGraph(keeping: keeps, hasVideo: streams.hasVideo, hasAudio: streams.hasAudio)
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("donkey-mediacut-\(UUID().uuidString).txt")
        do {
            try graph.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            return failed("could not stage the cut filtergraph: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let renderArgs = renderArguments(
            input: inputURL,
            output: outputURL,
            script: scriptURL,
            streams: streams,
            videoBitrate: streams.hasVideo ? probeVideoBitrate(ffprobe, inputURL, policy: policy, workingDirectory: workdir) : nil
        )
        let render = runProcess(ffmpeg, renderArgs, timeout: max(180, min(duration * 2, 1800)), policy: policy, workingDirectory: workdir)
        guard render.exitCode == 0, FileManager.default.fileExists(atPath: outputURL.path) else {
            let tail = String(render.stderr.suffix(400))
            return failed("ffmpeg render failed (exit \(render.exitCode)): \(tail)")
        }

        let outputDuration = probeDuration(ffprobe, outputURL, policy: policy, workingDirectory: workdir) ?? 0
        return HarnessMediaCutResult(
            outputPath: outputURL.path,
            removedSpanCount: cutCount,
            inputDurationSec: duration,
            outputDurationSec: outputDuration,
            failureReason: nil
        )
    }

    // MARK: - ffprobe helpers

    private static func probeDuration(_ ffprobe: URL, _ url: URL, policy: SandboxPolicy? = nil, workingDirectory: String? = nil) -> Double? {
        let result = runProcess(
            ffprobe,
            ["-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", url.path],
            timeout: 30,
            policy: policy, workingDirectory: workingDirectory
        )
        return Double(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func probeStreams(_ ffprobe: URL, _ url: URL, policy: SandboxPolicy? = nil, workingDirectory: String? = nil) -> (hasVideo: Bool, hasAudio: Bool) {
        let result = runProcess(
            ffprobe,
            ["-v", "error", "-show_entries", "stream=codec_type", "-of", "default=noprint_wrappers=1:nokey=1", url.path],
            timeout: 30,
            policy: policy, workingDirectory: workingDirectory
        )
        let types = Set(result.stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map { String($0).trimmingCharacters(in: .whitespaces) })
        return (types.contains("video"), types.contains("audio"))
    }

    private static func probeVideoBitrate(_ ffprobe: URL, _ url: URL, policy: SandboxPolicy? = nil, workingDirectory: String? = nil) -> String? {
        let result = runProcess(
            ffprobe,
            ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=bit_rate", "-of", "default=noprint_wrappers=1:nokey=1", url.path],
            timeout: 30,
            policy: policy, workingDirectory: workingDirectory
        )
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (Int(value) != nil) ? value : nil
    }

    // MARK: - Render

    private static func renderArguments(
        input: URL,
        output: URL,
        script: URL,
        streams: (hasVideo: Bool, hasAudio: Bool),
        videoBitrate: String?
    ) -> [String] {
        var args = ["-y", "-hide_banner", "-i", input.path, "-filter_complex_script", script.path]
        if streams.hasVideo { args += ["-map", "[v]"] }
        if streams.hasAudio { args += ["-map", "[a]"] }
        if streams.hasVideo {
            args += ["-c:v", "h264_videotoolbox"]
            if let videoBitrate { args += ["-b:v", videoBitrate] }
        }
        if streams.hasAudio {
            args += ["-c:a", "aac", "-b:a", "192k"]
        }
        args += ["-movflags", "+faststart", output.path]
        return args
    }

    /// Default output path: `<name>-tightened.<ext>` inside the workspace folder, unless the caller named
    /// one. Defaulting into the workspace keeps the write inside the jail's writable root; when the caller
    /// does name a path (an in-place save), the policy makes that folder writable too. With no workspace it
    /// falls back to beside the input.
    private static func resolveOutputURL(request: HarnessMediaCutRequest, input: URL) -> URL {
        if let outputPath = request.outputPath, !outputPath.isEmpty {
            return URL(fileURLWithPath: outputPath)
        }
        let ext = input.pathExtension
        let stem = input.deletingPathExtension().lastPathComponent
        let directory = request.workingDirectory
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? input.deletingLastPathComponent()
        let base = directory.appendingPathComponent("\(stem)-tightened")
        return ext.isEmpty ? base : base.appendingPathExtension(ext)
    }

    /// Count the removed regions implied by the kept segments — the leading gap, each internal gap, and a
    /// trailing gap. Zero means the keeps cover the whole file (nothing was actually cut).
    private static func removedRegionCount(keeps: [MediaTimeSpan], duration: Double) -> Int {
        let epsilon = 1e-3
        var count = 0
        var cursor = 0.0
        for keep in keeps {
            if keep.start - cursor > epsilon { count += 1 }
            cursor = keep.end
        }
        if duration - cursor > epsilon { count += 1 }
        return count
    }

    // MARK: - Process

    private struct ProcessOutput {
        var exitCode: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    /// Run a bundled tool directly (no shell), draining stdout/stderr on background queues so a large
    /// stderr (silencedetect, ffmpeg progress) never deadlocks the pipe, bounded by `timeout`.
    private static func runProcess(_ executable: URL, _ arguments: [String], timeout: TimeInterval,
                                   policy: SandboxPolicy? = nil, workingDirectory: String? = nil) -> ProcessOutput {
        let process = Process()
        // Under a policy the spawn runs in the seatbelt jail (writes confined to the workspace, reads locked
        // to system + the input/transcript). A nil policy is a passthrough — same as before the jail existed.
        let environment = WorkspaceSandbox.childEnvironment(DonkeyCommandBackends.shellEnvironment(), policy: policy)
        let (wrappedExecutable, wrappedArguments) = WorkspaceSandbox.wrap(
            executable: executable, arguments: arguments, policy: policy,
            environment: environment, bundledToolsDir: DonkeyCommandBackends.bundledToolsDirectory?.path
        )
        process.executableURL = wrappedExecutable
        process.arguments = wrappedArguments
        process.environment = environment
        // cwd must be the jail (not home) when confined — home is unreadable under the profile.
        process.currentDirectoryURL = DonkeyCommandBackends.resolvedWorkingDirectory(workingDirectory)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return ProcessOutput(exitCode: 127, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }

        let outBox = DataBox()
        let errBox = DataBox()
        let reads = DispatchGroup()
        reads.enter()
        DispatchQueue.global().async { outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile(); reads.leave() }
        reads.enter()
        DispatchQueue.global().async { errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile(); reads.leave() }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 1.0) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
        }
        // The write ends close on exit, so these reads complete promptly.
        reads.wait()

        return ProcessOutput(
            exitCode: process.terminationStatus,
            stdout: String(data: outBox.data, encoding: .utf8) ?? "",
            stderr: String(data: errBox.data, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}
