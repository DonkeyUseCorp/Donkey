import DonkeyAI
import DonkeyContracts
import DonkeyHarness
import DonkeyRuntime
import Foundation
import Testing

/// Prompt eval — GREETING LATENCY / round-trip budget. A bare greeting like "Hi" must be cheap: the
/// understanding boundary types it `.converse` AND returns the reply inline (`conversationReply`), so a fresh
/// greeting is answered in ONE model round trip — no second responder call, and crucially zero planner
/// steps. This test drives the real understanding boundary and counts model calls through a trace sink, so a
/// regression that makes a greeting slow is localized:
///   - `plannerStep > 0`         → the greeting was misrouted into the action loop (the expensive failure).
///   - `understanding > 1`       → the understanding boundary started doing multiple calls.
///   - empty `conversationReply` → the inline reply regressed, forcing the second responder round trip.
///   - total > 1                 → an extra round trip crept into the fresh-greeting path.
///
/// Opt-in like the other prompt evals (see `HarnessEvalRunner.configFromEnvironment`); a plain `swift test`
/// returns early. Per-call latency is printed (not asserted — it is network-dependent) so a "slow today"
/// report can be read as "too many round trips" vs "each call is slow".
@Suite
@MainActor
struct GreetingRoundTripEvalTests {
    @Test
    func greetingIsConverseAnsweredInOneRoundTrip() async {
        guard let config = HarnessEvalRunner.configFromEnvironment() else { return }

        var configuration = DonkeyBackendInferenceConfiguration(
            baseURL: config.baseURL,
            clientID: config.clientID,
            devAuthBypass: config.devAuthBypass
        )
        configuration.conversationID = "greeting-eval-\(UUID().uuidString)"
        let backend = DonkeyBackendInferenceClient(configuration: configuration)
        let trace = CountingTurnTrace()
        let streamed = StreamedReplyBox()

        // The one round trip: stream the understanding. A greeting must classify as converse — only then does
        // it skip the action planner — and the reply must arrive as live deltas from this same call, so a
        // fresh greeting is one round trip with real streaming (the path `UserQueryCommandHandler` takes).
        let understanding = await HostedHarnessRequestUnderstanding(backend: backend, trace: trace)
            .understandStreaming(
                command: "Hi",
                frontmostAppName: "Finder",
                skillCatalog: BuiltInLocalAppSkillPacks.skillSelectionCatalog(),
                onReplyDelta: { delta in streamed.append(delta) }
            )

        let calls = trace.snapshot()
        print(
            "\n=== greeting round trips (\(calls.count) total) ===\n"
                + calls.map { "  \($0.kind.rawValue) — \(Int($0.milliseconds))ms" }.joined(separator: "\n")
                + "\nstreamed reply: \(streamed.text.isEmpty ? "<none>" : "\"\(streamed.text.prefix(80))\"") in \(streamed.deltaCount) deltas\n"
        )

        #expect(
            understanding?.turnKind == .converse,
            "a bare greeting must classify as converse (never .act, which enters the planner loop); got \(String(describing: understanding?.turnKind))"
        )
        #expect(
            understanding?.conversationReply?.isEmpty == false,
            "understanding must carry an inline conversationReply for a converse turn so a fresh greeting is one round trip"
        )
        #expect(
            !streamed.text.isEmpty,
            "the reply must arrive as live stream deltas (real streaming), not all at once after the call"
        )
        #expect(
            streamed.text == (understanding?.conversationReply ?? ""),
            "the streamed deltas should reconstruct the final reply exactly; streamed=\"\(streamed.text.prefix(60))\" final=\"\(understanding?.conversationReply?.prefix(60) ?? "")\""
        )
        #expect(trace.count(of: .understanding) == 1, "expected exactly 1 understanding call; got \(trace.count(of: .understanding))")
        #expect(trace.count(of: .conversationalReply) == 0, "a fresh greeting should NOT need the separate responder; conversational replies: \(trace.count(of: .conversationalReply))")
        #expect(trace.count(of: .plannerStep) == 0, "a greeting must NOT reach the planner; planner steps: \(trace.count(of: .plannerStep))")
        #expect(
            calls.count == 1,
            "a fresh greeting should be exactly 1 model round trip (understanding streams the reply); got \(calls.count): \(calls.map { $0.kind.rawValue })"
        )
    }
}

/// Collects streamed reply deltas from the `@MainActor @Sendable` callback so the test can assert real
/// streaming happened (non-empty, multiple deltas) and that the pieces reconstruct the final reply.
@MainActor
final class StreamedReplyBox {
    private(set) var text = ""
    private(set) var deltaCount = 0
    func append(_ delta: String) {
        text += delta
        deltaCount += 1
    }
}

/// A trace sink that just tallies model calls and their spans, so a test can assert how many round trips a
/// turn took and how long each was. Thread-safe because the harness may record from off the main actor.
final class CountingTurnTrace: HarnessTurnTracing, @unchecked Sendable {
    struct Entry {
        var kind: TraceModelCallKind
        var milliseconds: Double
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func recordModelCall(_ call: TraceModelCall) {
        lock.lock()
        entries.append(Entry(kind: call.kind, milliseconds: call.durationMS ?? 0))
        lock.unlock()
    }

    func snapshot() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    func count(of kind: TraceModelCallKind) -> Int {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.kind == kind }.count
    }
}
