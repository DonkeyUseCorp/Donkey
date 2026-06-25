import Foundation
import Testing
@testable import DonkeyHarness
@testable import DonkeyRuntime

/// The shorts pipeline's whole point: a multi-clip run makes exactly ONE model call (moment selection) and
/// renders the clips deterministically, with no planner round-trip between steps. These tests stub the
/// bundled tools and the two injected boundaries so the control flow is verified without real ffmpeg.
@Suite
struct ShortsOrchestratorTests {
    /// Thread-safe recorder for the synchronous tool runner and the async decision closure.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var selectMomentsCalls = 0
        private(set) var transcribeCalls = 0
        private(set) var toolRuns: [String] = []

        func recordSelect() { lock.lock(); selectMomentsCalls += 1; lock.unlock() }
        func recordTranscribe() { lock.lock(); transcribeCalls += 1; lock.unlock() }
        func recordTool(_ name: String) { lock.lock(); toolRuns.append(name); lock.unlock() }
    }

    /// A tool runner that touches every path-like argument (so `runStep`'s file-existence check passes) and
    /// always succeeds — standing in for ffmpeg/reframe without running them.
    private static func stubRunner(_ recorder: Recorder) -> MediaPipeline.ToolRunner {
        { name, arguments, workingDirectory in
            recorder.recordTool(name)
            for argument in arguments where argument.hasPrefix("/") {
                let ext = (argument as NSString).pathExtension.lowercased()
                if ["mp4", "mp3", "srt", "wav", "m4a"].contains(ext) {
                    FileManager.default.createFile(atPath: argument, contents: Data())
                }
            }
            return (0, "", "")
        }
    }

    private static func words(_ count: Int) -> [HarnessTranscriptionWord] {
        (0..<count).map { i in
            HarnessTranscriptionWord(text: "word\(i)", startMS: i * 500, endMS: i * 500 + 400)
        }
    }

    private func makeWorkdir() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("shorts-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test
    func multiClipRunMakesExactlyOneModelCall() async throws {
        let recorder = Recorder()
        let workdir = makeWorkdir()
        defer { try? FileManager.default.removeItem(atPath: workdir) }
        let source = (workdir as NSString).appendingPathComponent("input.mp4")
        FileManager.default.createFile(atPath: source, contents: Data())

        let orchestrator = ShortsOrchestrator(
            selectMoments: { _, _ in
                recorder.recordSelect()
                return [
                    MomentSpan(startSec: 0, endSec: 20, title: "One"),
                    MomentSpan(startSec: 30, endSec: 55, title: "Two")
                ]
            },
            transcribe: { _ in
                recorder.recordTranscribe()
                return HarnessTranscriptionResult(text: "hello world", words: Self.words(8), backend: "stub")
            },
            runTool: Self.stubRunner(recorder)
        )

        let outcome = await orchestrator.make(
            HarnessShortsRequest(source: source, desiredCount: nil, aspect: "9:16", workingDirectory: workdir)
        )

        #expect(outcome.succeeded)
        #expect(outcome.producedFiles.count == 2)
        // The whole guarantee: ONE model call for the two-clip job, no matter how many tools ran.
        #expect(recorder.selectMomentsCalls == 1)
        // On-device transcription is free: once for the source + once per clip.
        #expect(recorder.transcribeCalls == 3)
        // reframe ran once per clip; ffmpeg ran several times — all without returning to the planner.
        #expect(recorder.toolRuns.filter { $0 == "reframe" }.count == 2)
        for path in outcome.producedFiles {
            #expect(FileManager.default.fileExists(atPath: path))
        }
    }

    @Test
    func desiredCountCapsTheClips() async throws {
        let recorder = Recorder()
        let workdir = makeWorkdir()
        defer { try? FileManager.default.removeItem(atPath: workdir) }
        let source = (workdir as NSString).appendingPathComponent("input.mp4")
        FileManager.default.createFile(atPath: source, contents: Data())

        let orchestrator = ShortsOrchestrator(
            selectMoments: { _, _ in
                recorder.recordSelect()
                return (0..<5).map { MomentSpan(startSec: Double($0) * 60, endSec: Double($0) * 60 + 20) }
            },
            transcribe: { _ in
                HarnessTranscriptionResult(text: "x", words: Self.words(6), backend: "stub")
            },
            runTool: Self.stubRunner(recorder)
        )

        let outcome = await orchestrator.make(
            HarnessShortsRequest(source: source, desiredCount: 2, workingDirectory: workdir)
        )
        #expect(outcome.succeeded)
        #expect(outcome.producedFiles.count == 2)
    }

    @Test
    func aspectOriginalSkipsReframe() async throws {
        let recorder = Recorder()
        let workdir = makeWorkdir()
        defer { try? FileManager.default.removeItem(atPath: workdir) }
        let source = (workdir as NSString).appendingPathComponent("input.mp4")
        FileManager.default.createFile(atPath: source, contents: Data())

        let orchestrator = ShortsOrchestrator(
            selectMoments: { _, _ in [MomentSpan(startSec: 0, endSec: 30)] },
            transcribe: { _ in HarnessTranscriptionResult(text: "x", words: Self.words(6), backend: "stub") },
            runTool: Self.stubRunner(recorder)
        )

        let outcome = await orchestrator.make(
            HarnessShortsRequest(source: source, aspect: "original", workingDirectory: workdir)
        )
        #expect(outcome.succeeded)
        #expect(recorder.toolRuns.contains("reframe") == false)
    }

    @Test
    func missingSourceFailsCleanly() async throws {
        let recorder = Recorder()
        let workdir = makeWorkdir()
        defer { try? FileManager.default.removeItem(atPath: workdir) }

        let orchestrator = ShortsOrchestrator(
            selectMoments: { _, _ in recorder.recordSelect(); return [MomentSpan(startSec: 0, endSec: 10)] },
            transcribe: { _ in HarnessTranscriptionResult(text: "x", words: Self.words(4), backend: "stub") },
            runTool: Self.stubRunner(recorder)
        )

        let outcome = await orchestrator.make(
            HarnessShortsRequest(source: "/no/such/file.mp4", workingDirectory: workdir)
        )
        #expect(outcome.succeeded == false)
        #expect(outcome.producedFiles.isEmpty)
        // No source means no model call at all.
        #expect(recorder.selectMomentsCalls == 0)
    }

    @Test
    func srtTimeFormatsAsHoursMinutesSecondsMillis() {
        #expect(ShortsOrchestrator.srtTime(0) == "00:00:00,000")
        #expect(ShortsOrchestrator.srtTime(1_500) == "00:00:01,500")
        #expect(ShortsOrchestrator.srtTime(3_661_250) == "01:01:01,250")
    }

    @Test
    func makeSRTBreaksOnSentencePunctuationAndLength() {
        let words = [
            HarnessTranscriptionWord(text: "Hello", startMS: 0, endMS: 400),
            HarnessTranscriptionWord(text: "there.", startMS: 450, endMS: 900),
            HarnessTranscriptionWord(text: "How", startMS: 1_000, endMS: 1_200),
            HarnessTranscriptionWord(text: "are", startMS: 1_250, endMS: 1_400),
            HarnessTranscriptionWord(text: "you?", startMS: 1_450, endMS: 1_800)
        ]
        let srt = ShortsOrchestrator.makeSRT(words)
        #expect(srt.contains("Hello there."))
        #expect(srt.contains("How are you?"))
        #expect(srt.contains("00:00:00,000 --> 00:00:00,900"))
        // Two cues, numbered.
        #expect(srt.contains("\n1\n") || srt.hasPrefix("1\n"))
        #expect(srt.contains("2\n"))
    }
}
