import Foundation
import Testing
@testable import DonkeyHarness
@testable import DonkeyRuntime

/// The caption pipeline's point: subtitling a video is ONE call (or zero when no translation is asked for),
/// with the SRT built in code and the burn done with a fixed encoder — no per-tool planner round-trips and no
/// model-authored-SRT cleanup loop.
@Suite
struct CaptionOrchestratorTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var translateCalls = 0
        private(set) var toolRuns: [String] = []

        func recordTranslate() { lock.lock(); translateCalls += 1; lock.unlock() }
        func recordTool(_ name: String) { lock.lock(); toolRuns.append(name); lock.unlock() }
    }

    private static func stubRunner(_ recorder: Recorder) -> MediaPipeline.ToolRunner {
        { name, arguments, _ in
            recorder.recordTool(name)
            for argument in arguments where argument.hasPrefix("/") {
                if ["mp4", "mp3", "srt"].contains((argument as NSString).pathExtension.lowercased()) {
                    FileManager.default.createFile(atPath: argument, contents: Data())
                }
            }
            return (0, "", "")
        }
    }

    private static func words(_ count: Int) -> [HarnessTranscriptionWord] {
        (0..<count).map { HarnessTranscriptionWord(text: "word\($0)", startMS: $0 * 400, endMS: $0 * 400 + 300) }
    }

    private func makeWorkdir() -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("caption-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test
    func translatingCaptionsMakesExactlyOneModelCall() async throws {
        let recorder = Recorder()
        let workdir = makeWorkdir()
        defer { try? FileManager.default.removeItem(atPath: workdir) }
        let source = (workdir as NSString).appendingPathComponent("input.mp4")
        FileManager.default.createFile(atPath: source, contents: Data())

        let orchestrator = CaptionOrchestrator(
            translateCues: { lines, language in
                recorder.recordTranslate()
                return lines.map { "[\(language)] \($0)" }
            },
            transcribe: { _ in HarnessTranscriptionResult(text: "x", words: Self.words(20), backend: "stub") },
            runTool: Self.stubRunner(recorder)
        )

        let outcome = await orchestrator.caption(
            HarnessCaptionRequest(source: source, translateTo: "Korean", workingDirectory: workdir)
        )

        #expect(outcome.succeeded)
        #expect(outcome.producedFiles.count == 1)
        #expect(recorder.translateCalls == 1)
        // A captions file was actually written in code (no model-authored SRT).
        #expect(FileManager.default.fileExists(atPath: (workdir as NSString).appendingPathComponent("captions.srt")))
    }

    @Test
    func captioningWithoutTranslationMakesNoModelCalls() async throws {
        let recorder = Recorder()
        let workdir = makeWorkdir()
        defer { try? FileManager.default.removeItem(atPath: workdir) }
        let source = (workdir as NSString).appendingPathComponent("input.mp4")
        FileManager.default.createFile(atPath: source, contents: Data())

        let orchestrator = CaptionOrchestrator(
            translateCues: { _, _ in recorder.recordTranslate(); return nil },
            transcribe: { _ in HarnessTranscriptionResult(text: "x", words: Self.words(12), backend: "stub") },
            runTool: Self.stubRunner(recorder)
        )

        let outcome = await orchestrator.caption(
            HarnessCaptionRequest(source: source, workingDirectory: workdir)
        )
        #expect(outcome.succeeded)
        #expect(outcome.producedFiles.count == 1)
        #expect(recorder.translateCalls == 0)
    }

    @Test
    func missingSourceFailsCleanly() async throws {
        let recorder = Recorder()
        let workdir = makeWorkdir()
        defer { try? FileManager.default.removeItem(atPath: workdir) }

        let orchestrator = CaptionOrchestrator(
            translateCues: { _, _ in recorder.recordTranslate(); return nil },
            transcribe: { _ in HarnessTranscriptionResult(text: "x", words: Self.words(8), backend: "stub") },
            runTool: Self.stubRunner(recorder)
        )
        let outcome = await orchestrator.caption(
            HarnessCaptionRequest(source: "/no/such/file.mp4", translateTo: "Korean", workingDirectory: workdir)
        )
        #expect(outcome.succeeded == false)
        #expect(recorder.translateCalls == 0)
    }

    @Test
    func parseSecondsHandlesBareAndClockForms() {
        #expect(CaptionOrchestrator.parseSeconds("90") == 90)
        #expect(CaptionOrchestrator.parseSeconds("1:30") == 90)
        #expect(CaptionOrchestrator.parseSeconds("1:00:00") == 3600)
        #expect(CaptionOrchestrator.parseSeconds("") == nil)
    }

    @Test
    func mediaSubtitlesBuildsValidSRT() {
        let cues = MediaSubtitles.cues(from: Self.words(16))
        #expect(!cues.isEmpty)
        let srt = MediaSubtitles.srt(from: cues)
        #expect(srt.hasPrefix("1\n"))
        #expect(srt.contains(" --> "))
        #expect(srt.contains("00:00:00,000"))
    }
}
