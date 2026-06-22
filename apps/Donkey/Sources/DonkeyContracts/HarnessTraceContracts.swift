import Foundation

/// Why a model was called during a turn. Drives both the display label in the thread and how the
/// trace manager attributes time: only `.plannerStep` calls count toward a step's "decision time",
/// so a one-shot understanding or background summary call never inflates the next step's timing.
public enum TraceModelCallKind: String, Codable, Equatable, Sendable {
    /// The one-shot request-understanding call that runs before the loop.
    case understanding
    /// A per-step planning call (the first sample or a feedback-driven retry).
    case plannerStep
    /// The background call that rewrites the compacted thread summary.
    case threadSummary
}

/// What came back from a model call. Distinguishes the failure shapes the planner already separates
/// (empty reply vs. provider content filter vs. transport/decode error) so the thread shows which one
/// happened instead of a generic failure.
public enum TraceModelCallStatus: String, Codable, Equatable, Sendable {
    /// A usable reply came back.
    case ok
    /// The reply carried no output text (e.g. truncated at the token cap).
    case empty
    /// The provider's content filter withheld the generated reply.
    case filtered
    /// A transport, timeout, or decode error before a reply could be used.
    case failed
}

/// Which sensing modality produced the elements a step reasoned over — the answer to "did this step
/// use Accessibility or AI vision?". Derived from the executed tool's own facts, not from any guess.
public enum TraceModality: String, Codable, Equatable, Sendable {
    /// Accessibility tree read (`ax.observe`).
    case accessibility
    /// Screenshot + AI vision parse (`vision.capture`).
    case vision
    /// The step did not sense (shell, wait, respond, verify, …).
    case none
}

/// One model call captured for the thread trace: what was asked and what came back (both clipped by
/// the renderer), the provider's finish reason, the attempt index for retried planning, the outcome,
/// and the wall+monotonic span. The span is the whole point of the trace — it lets a slow turn be
/// attributed to a specific call instead of a coarse end-to-end number.
public struct TraceModelCall: Sendable {
    public var kind: TraceModelCallKind
    public var prompt: String
    public var response: String
    public var finishReason: String?
    /// 1-based attempt for `.plannerStep` (1 is the first sample, 2+ are retries); nil for one-shot calls.
    public var attempt: Int?
    public var status: TraceModelCallStatus
    public var startedAt: RunTraceTimestamp
    public var endedAt: RunTraceTimestamp

    public init(
        kind: TraceModelCallKind,
        prompt: String,
        response: String,
        finishReason: String? = nil,
        attempt: Int? = nil,
        status: TraceModelCallStatus,
        startedAt: RunTraceTimestamp,
        endedAt: RunTraceTimestamp
    ) {
        self.kind = kind
        self.prompt = prompt
        self.response = response
        self.finishReason = finishReason
        self.attempt = attempt
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    /// Elapsed milliseconds for this call, or nil if the monotonic clock went backwards.
    public var durationMS: Double? { startedAt.milliseconds(until: endedAt) }
}

/// The recording surface the model boundaries depend on. The AI boundaries (`HostedHarnessStepPlanner`,
/// `HostedHarnessRequestUnderstanding`) hold only this protocol, so they record without importing the
/// runtime that writes files and stay testable with a recording double — the same split the harness
/// uses for `HarnessThreadStoring`. The concrete `HarnessTurnTrace` lives in DonkeyRuntime and adds the
/// per-step and per-turn methods the handler calls directly.
///
/// A nil recorder means tracing is off; every call site treats it as optional so the hot path is
/// untouched when no trace is attached. `RunTraceTimestamp` (wall + monotonic) is the shared clock.
public protocol HarnessTurnTracing: AnyObject, Sendable {
    func recordModelCall(_ call: TraceModelCall)
}

public extension RunTraceTimestamp {
    /// The current instant on both clocks. Durations are computed from the monotonic component (process
    /// uptime, immune to wall-clock adjustments); the wall clock is for human-readable stamps. Bracket a
    /// model call with `RunTraceTimestamp.now()` before and after to get its span.
    static func now() -> RunTraceTimestamp {
        RunTraceTimestamp(
            wallClock: Date(),
            monotonicUptimeNanoseconds: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        )
    }
}
