import DonkeyContracts
import Foundation

/// Turns a finished run into durable, recallable operating knowledge — the write-and-recall halves of
/// the harness's self-improving loop. A run that struggled or failed is distilled (by an LLM, upstream)
/// into one general operating lesson; that lesson is stored as a durable global memory and surfaced to
/// the planner on later turns whose goal is related, so the agent stops repeating a mistake it has
/// already paid for once.
///
/// The store, approval gate, and ranked retrieval are the existing agent-memory machinery. This type
/// only frames lessons within it: how a lesson is parsed from the distiller, how it becomes a deduped
/// write proposal, and how past lessons render into a bounded prompt block. Lessons reuse the
/// `workflowMemory` kind (a learned operating procedure) and carry a `lesson:` id prefix so recall pulls
/// only lessons, never any other workflow record that kind may someday hold.
public enum RunLessonMemory {
    /// The distiller's structured verdict for one finished run.
    public struct Distillation: Equatable, Sendable {
        /// One imperative operating rule for the agent's future self. Empty means "nothing worth saving".
        public var lesson: String
        /// A short phrase naming the kind of task the lesson applies to — extra retrieval text so a
        /// future goal matches the lesson even when its wording differs from the original run's goal.
        public var cue: String
        /// The model's 0–1 confidence that this is a real, general lesson.
        public var confidence: Double
        /// The distiller's own typed judgment that this lesson would teach DEFEATING a harness guardrail
        /// (slipping past a duplicate/stall/permission guard). A lesson flagged here is dropped at write
        /// time. This is a structured field from the model — never inferred by string-matching the lesson
        /// text, which over-flags benign craft ("work around the check by asking first").
        public var defeatsGuardrail: Bool

        public init(lesson: String, cue: String, confidence: Double, defeatsGuardrail: Bool = false) {
            self.lesson = lesson
            self.cue = cue
            self.confidence = min(max(confidence, 0), 1)
            self.defeatsGuardrail = defeatsGuardrail
        }
    }

    /// A lesson is a learned operating procedure; reuse that kind rather than growing the enum.
    static let kind: AgentMemoryKind = .workflowMemory
    /// Records carry this id prefix so recall fetches only lessons out of the shared kind.
    static let idPrefix = "lesson:"
    /// A lesson must clear this confidence to be written — keeps low-signal guesses out of memory.
    static let minWriteConfidence = 0.55
    /// Recall stays small so lessons inform the planner without crowding the per-step prompt.
    static let recallBudget = AgentMemoryRetrievalBudget(
        maxRecords: 4,
        maxPromptCharacters: 800,
        minRelevance: 0.18
    )

    /// Parse the distiller's JSON reply. Returns nil when the reply is unusable or carries no lesson, so
    /// the caller simply writes nothing — the common case for a clean run.
    public static func parse(_ raw: String) -> Distillation? {
        guard let data = jsonObjectData(in: raw),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        let lesson = ((object["lesson"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lesson.isEmpty else { return nil }
        let cue = ((object["cue"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let confidence = (object["confidence"] as? Double)
            ?? (object["confidence"] as? Int).map(Double.init)
            ?? (object["confidence"] as? String).flatMap(Double.init)
            ?? 0
        let defeatsGuardrail = (object["unsafe"] as? Bool)
            ?? (object["unsafe"] as? String).map { ["true", "yes", "1"].contains($0.lowercased()) }
            ?? false
        return Distillation(
            lesson: lesson,
            cue: cue,
            confidence: confidence,
            defeatsGuardrail: defeatsGuardrail
        )
    }

    /// Build a durable global lesson proposal, deduped by lesson content so re-learning the same rule
    /// refreshes the one record instead of piling up copies. Returns nil for an empty or low-confidence
    /// lesson, so the caller skips the write. The `cue` and originating goal ride along as metadata and
    /// search text, broadening the goals a future turn can match the lesson against.
    public static func proposal(
        for distillation: Distillation,
        goal: String,
        outcome: String,
        traceID: String,
        now: RunTraceTimestamp
    ) -> AgentMemoryWriteProposal? {
        let lesson = distillation.lesson.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lesson.isEmpty, distillation.confidence >= minWriteConfidence else { return nil }
        // Never store a lesson that teaches the agent to DEFEAT a harness guardrail — the save-time half of
        // the governance rule. A guard firing means "you are looping" or "this needs consent"; a lesson that
        // says to slip past it is actively harmful. The judgment is the distiller's typed `defeatsGuardrail`
        // flag, decided where the run's full context is, not guessed by matching words in the lesson text.
        guard !distillation.defeatsGuardrail else { return nil }

        let id = idPrefix + stableHash(normalized(lesson))
        var metadata = ["lesson": "true", "outcome": outcome]
        if !distillation.cue.isEmpty { metadata["cue"] = distillation.cue }
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedGoal.isEmpty { metadata["learnedFromGoal"] = String(trimmedGoal.prefix(200)) }

        let record = AgentMemoryRecord(
            id: id,
            scope: .global,
            kind: kind,
            value: lesson,
            createdAt: now,
            durable: true,
            source: AgentMemorySource(traceID: traceID, summary: "post-run lesson distillation"),
            metadata: metadata,
            confidence: distillation.confidence
        )
        return AgentMemoryWriteProposal(
            id: id,
            proposedBy: .model,
            record: record,
            rationale: "Operating lesson distilled from run \(traceID) (outcome=\(outcome))."
        )
    }

    /// Recall the most relevant past lessons for a goal, formatted as a bounded prompt block, or nil when
    /// there are none. Ranking, scoping, and budgeting are the store's; this only filters the ranked
    /// results to lesson records and frames them as a bullet list.
    public static func recall(
        forGoal goal: String,
        store: SQLiteAgentMemoryStore?,
        now: RunTraceTimestamp = .now()
    ) -> String? {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty, let store else { return nil }

        let query = AgentMemoryQuery(
            text: trimmedGoal,
            scope: .global,
            kinds: [kind],
            budget: recallBudget
        )
        let lessons = ((try? store.search(query: query)) ?? [])
            .map(\.record)
            .filter { $0.id.hasPrefix(idPrefix) }
            .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lessons.isEmpty else { return nil }
        return lessons.map { "- \($0)" }.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Lowercased, whitespace-collapsed lesson text, so trivially different phrasings of the same rule
    /// hash to one id and dedup to a single record.
    static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// FNV-1a over the UTF-8 bytes — a stable, process-independent hash. Swift's `Hasher` is seeded per
    /// process, so it cannot key a durable record id that must stay constant across launches.
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Extract the first balanced top-level JSON object from a reply that may be fenced or prefixed with
    /// prose. Returns nil when there is no `{ … }` span.
    private static func jsonObjectData(in text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end
        else {
            return nil
        }
        return String(text[start...end]).data(using: .utf8)
    }
}
