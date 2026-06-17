import DonkeyContracts
import Foundation
import Testing
@testable import DonkeyRuntime

@Suite
struct HarnessTurnTraceTests {
    @Test
    func recordsModelCallIntoThread() throws {
        let transcript = makeTranscript()
        let clock = FakeClock()
        let trace = HarnessTurnTrace(transcript: transcript, now: clock.timestamp)

        trace.recordModelCall(TraceModelCall(
            kind: .understanding,
            prompt: "Understand: open mail",
            response: "{\"restatedGoal\":\"open Mail\"}",
            finishReason: "STOP",
            status: .ok,
            startedAt: clock.timestamp(),
            endedAt: clock.advanced(by: 1_500)
        ))

        let text = try threadText(transcript)
        #expect(text.contains("### 🔮 model · understanding"))
        #expect(text.contains("**Duration:** 1.5s"))
        #expect(text.contains("Understand: open mail"))
        #expect(text.contains("\"restatedGoal\":\"open Mail\""))
        #expect(text.contains("**Status:** ok"))
    }

    @Test
    func stepDecisionTimeSumsPlannerAttemptsAndToolTimeFollows() throws {
        let transcript = makeTranscript()
        let clock = FakeClock()
        let trace = HarnessTurnTrace(transcript: transcript, now: clock.timestamp)

        // Two planning attempts for the same step: 6s then 2.4s of decision time.
        let a0 = clock.timestamp()
        let a1 = clock.advanced(by: 6_000)
        trace.recordModelCall(plannerCall(attempt: 1, started: a0, ended: a1))
        let b0 = clock.timestamp()
        let b1 = clock.advanced(by: 2_400)
        trace.recordModelCall(plannerCall(attempt: 2, started: b0, ended: b1))

        // The tool then runs for 300ms before the step lands.
        clock.advance(by: 300)
        trace.recordStep(
            number: 1,
            thought: nil,
            narration: "Reading the screen.",
            tool: "vision.capture",
            input: [:],
            status: "succeeded",
            output: "Captured 12 element(s).",
            planningErrors: [],
            modality: .vision,
            cacheHit: true,
            elementCount: 12
        )

        let text = try threadText(transcript)
        // 6000 + 2400 = 8400ms decision; 300ms tool; vision + cache hit + element count.
        #expect(text.contains("⏱ decision 8.4s · tool 300ms · 👁️ vision · cache hit · 12 elems"))
    }

    @Test
    func understandingDoesNotInflateNextStepDecisionTime() throws {
        let transcript = makeTranscript()
        let clock = FakeClock()
        let trace = HarnessTurnTrace(transcript: transcript, now: clock.timestamp)

        // A long understanding call before the loop must not count toward step 1's decision time.
        let u0 = clock.timestamp()
        let u1 = clock.advanced(by: 9_000)
        trace.recordModelCall(TraceModelCall(
            kind: .understanding, prompt: "p", response: "r", status: .ok, startedAt: u0, endedAt: u1
        ))
        let p0 = clock.timestamp()
        let p1 = clock.advanced(by: 1_000)
        trace.recordModelCall(plannerCall(attempt: 1, started: p0, ended: p1))
        clock.advance(by: 50)
        trace.recordStep(
            number: 1, thought: nil, narration: nil, tool: "ax.observe", input: [:],
            status: "succeeded", output: "ok", planningErrors: [], modality: .accessibility,
            cacheHit: nil, elementCount: 7
        )

        let text = try threadText(transcript)
        #expect(text.contains("decision 1.0s"))
        #expect(!text.contains("decision 10.0s"))
        #expect(text.contains("🌲 AX · 7 elems"))
    }

    @Test
    func nonSensingStepShowsNoModalityOrCache() throws {
        let transcript = makeTranscript()
        let clock = FakeClock()
        let trace = HarnessTurnTrace(transcript: transcript, now: clock.timestamp)

        let p0 = clock.timestamp()
        let p1 = clock.advanced(by: 500)
        trace.recordModelCall(plannerCall(attempt: 1, started: p0, ended: p1))
        clock.advance(by: 20)
        trace.recordStep(
            number: 1, thought: nil, narration: nil, tool: "shell_exec", input: ["command": "ls"],
            status: "succeeded", output: "ok", planningErrors: [], modality: .none,
            cacheHit: true, elementCount: 99
        )

        let text = try threadText(transcript)
        // Exact timing line: decision + tool only, no modality/cache/element segments. (Broad "vision"
        // checks would false-match the planner call's own JSON response rendered above.)
        #expect(text.contains("<sub>⏱ decision 500ms · tool 20ms</sub>"))
        #expect(!text.contains("👁️ vision"))
        #expect(!text.contains("🌲 AX"))
        #expect(!text.contains("cache hit"))
        #expect(!text.contains("99 elems"))
    }

    @Test
    func recordsTurnTimingSummary() throws {
        let transcript = makeTranscript()
        let trace = HarnessTurnTrace(transcript: transcript)
        trace.recordTurnTiming(e2eTotalMS: 12_000, timeToFirstActionMS: 3_400, steps: 4)

        let text = try threadText(transcript)
        #expect(text.contains("⏱ Turn timing — total 12.0s · first action 3.4s · avg/step 3.0s"))
    }

    // MARK: - Helpers

    private func plannerCall(attempt: Int, started: RunTraceTimestamp, ended: RunTraceTimestamp) -> TraceModelCall {
        TraceModelCall(
            kind: .plannerStep,
            prompt: "GOAL: do the thing",
            response: "{\"tool\":\"vision.capture\"}",
            finishReason: "STOP",
            attempt: attempt,
            status: .ok,
            startedAt: started,
            endedAt: ended
        )
    }

    private func makeTranscript() -> ThreadTranscript {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-turn-trace-tests-\(UUID().uuidString)", isDirectory: true)
        return ThreadTranscript(id: UUID().uuidString, root: root)
    }

    private func threadText(_ transcript: ThreadTranscript) throws -> String {
        try String(contentsOfFile: transcript.threadPath, encoding: .utf8)
    }
}

/// A deterministic monotonic clock for trace-timing tests: durations are exact because both the call
/// spans and the manager's step-land stamp come from this same advanceable source.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nanos: UInt64 = 0

    func timestamp() -> RunTraceTimestamp {
        lock.lock(); defer { lock.unlock() }
        return RunTraceTimestamp(wallClock: Date(timeIntervalSince1970: 0), monotonicUptimeNanoseconds: nanos)
    }

    @discardableResult
    func advance(by milliseconds: Double) -> RunTraceTimestamp {
        lock.lock()
        nanos += UInt64(milliseconds * 1_000_000)
        lock.unlock()
        return timestamp()
    }

    /// Advance and return the new instant — reads as "the call ended `ms` later".
    func advanced(by milliseconds: Double) -> RunTraceTimestamp { advance(by: milliseconds) }
}
