import DonkeyContracts
import Foundation

/// The turn-trace manager: the single sink every model call and every executed step reports to, so a
/// run's whole decision path — what was sent to the model, what came back, which sensing modality each
/// step used, and where the time went — is traceable in the thread file.
///
/// It owns no file of its own; it renders through the turn's `ThreadTranscript` (kept as the sole
/// writer of `thread.md`) and adds the timing the transcript can't see on its own. The model boundaries
/// hold this as `any HarnessTurnTracing` and only `recordModelCall`; the command handler holds the
/// concrete type and additionally drives `recordStep` / `recordTurnTiming`.
///
/// Timing model: a step's "decision time" is the sum of the planner calls made while choosing it
/// (including retries); its "tool time" is the gap from the last planner reply to the step landing.
/// One-shot calls (understanding, the background summary) are recorded for visibility but never counted
/// toward a step, so they can't inflate the next step's timing.
///
/// Concurrency mirrors `ThreadTranscript`: a `final class` with an `NSLock` guarding the small timing
/// accumulator, so it's callable synchronously from the planner's hot path and from the `@MainActor`
/// step callback without actor hops.
public final class HarnessTurnTrace: HarnessTurnTracing, @unchecked Sendable {
    private let transcript: ThreadTranscript
    private let now: @Sendable () -> RunTraceTimestamp
    private let lock = NSLock()

    /// Summed duration of the planner calls recorded since the last step landed — the upcoming step's
    /// decision time. Reset each time a step is recorded.
    private var pendingDecisionMS: Double = 0
    /// When the most recent planner call returned, used to measure the tool time of the step it chose.
    private var lastPlannerReplyAt: RunTraceTimestamp?

    /// `now` is the clock used to stamp when a step lands (for tool-time); it defaults to the real
    /// wall+monotonic clock and is injectable so tests can drive deterministic durations.
    public init(
        transcript: ThreadTranscript,
        now: @escaping @Sendable () -> RunTraceTimestamp = RunTraceTimestamp.now
    ) {
        self.transcript = transcript
        self.now = now
    }

    // MARK: - Model calls (HarnessTurnTracing)

    public func recordModelCall(_ call: TraceModelCall) {
        if call.kind == .plannerStep {
            lock.lock()
            pendingDecisionMS += call.durationMS ?? 0
            lastPlannerReplyAt = call.endedAt
            lock.unlock()
        }
        transcript.modelCall(
            kindLabel: Self.label(for: call.kind),
            prompt: call.prompt,
            response: call.response,
            finishReason: call.finishReason,
            attempt: call.attempt,
            durationMS: call.durationMS,
            status: call.status.rawValue
        )
    }

    // MARK: - Steps

    /// Render one executed step with its timing attached: the decision time accumulated from this step's
    /// planner calls, the tool time since the last planner reply, and the sensing modality / cache / size
    /// derived by the caller from the executed tool's own facts.
    public func recordStep(
        number: Int,
        thought: String?,
        reason: String?,
        tool: String,
        input: [String: String],
        status: String,
        output: String,
        planningErrors: [String],
        modality: TraceModality,
        cacheHit: Bool?,
        elementCount: Int?
    ) {
        lock.lock()
        let decisionMS = pendingDecisionMS > 0 ? pendingDecisionMS : nil
        let toolMS = lastPlannerReplyAt?.milliseconds(until: now())
        pendingDecisionMS = 0
        lastPlannerReplyAt = nil
        lock.unlock()

        transcript.step(
            number: number,
            thought: thought,
            reason: reason,
            tool: tool,
            input: input,
            status: status,
            output: output,
            planningErrors: planningErrors,
            decisionMS: decisionMS,
            toolMS: toolMS,
            modality: modality == .none ? nil : modality.rawValue,
            cacheHit: cacheHit,
            elementCount: elementCount
        )
    }

    // MARK: - Turn

    /// Close the turn with a compact timing summary so the whole-run cost (and the time to the first
    /// real action) is readable at the foot of the thread alongside the per-step breakdown.
    public func recordTurnTiming(
        e2eTotalMS: Double,
        timeToFirstActionMS: Double?,
        steps: Int
    ) {
        var parts = ["total \(Self.durationLabel(e2eTotalMS))"]
        if let timeToFirstActionMS {
            parts.append("first action \(Self.durationLabel(timeToFirstActionMS))")
        }
        if steps > 0 {
            parts.append("avg/step \(Self.durationLabel(e2eTotalMS / Double(steps)))")
        }
        transcript.systemEvent("⏱ Turn timing — \(parts.joined(separator: " · "))")
    }

    // MARK: - Helpers

    private static func label(for kind: TraceModelCallKind) -> String {
        switch kind {
        case .understanding: return "understanding"
        case .plannerStep: return "planner step"
        case .threadSummary: return "thread summary"
        }
    }

    private static func durationLabel(_ ms: Double) -> String {
        ms >= 1_000 ? String(format: "%.1fs", ms / 1_000) : String(format: "%.0fms", ms)
    }
}
