import DonkeyContracts
@testable import DonkeyRuntime
import Foundation
import Testing

@Suite
struct RunLessonMemoryTests {
    // MARK: - parse

    @Test
    func parsesCleanLessonJSON() {
        let raw = #"{"lesson": "Use mdfind to locate files.", "cue": "finding files", "confidence": 0.8}"#
        let distillation = RunLessonMemory.parse(raw)
        #expect(distillation?.lesson == "Use mdfind to locate files.")
        #expect(distillation?.cue == "finding files")
        #expect(distillation?.confidence == 0.8)
    }

    @Test
    func parsesLessonFromFencedOrPrefixedReply() {
        let raw = """
        Here is the lesson:
        ```json
        {"lesson": "Prefer mdfind over a broad find.", "cue": "file search", "confidence": 0.7}
        ```
        """
        let distillation = RunLessonMemory.parse(raw)
        #expect(distillation?.lesson == "Prefer mdfind over a broad find.")
        #expect(distillation?.confidence == 0.7)
    }

    @Test
    func parseReturnsNilForEmptyLesson() {
        #expect(RunLessonMemory.parse(#"{"lesson": "", "cue": "x", "confidence": 0.9}"#) == nil)
        #expect(RunLessonMemory.parse(#"{"lesson": "   ", "confidence": 0.9}"#) == nil)
    }

    @Test
    func parseReturnsNilForUnusableReply() {
        #expect(RunLessonMemory.parse("no json here") == nil)
        #expect(RunLessonMemory.parse("") == nil)
    }

    @Test
    func parseAcceptsConfidenceAsIntOrString() {
        #expect(RunLessonMemory.parse(#"{"lesson": "a", "confidence": 1}"#)?.confidence == 1)
        #expect(RunLessonMemory.parse(#"{"lesson": "a", "confidence": "0.6"}"#)?.confidence == 0.6)
        // Missing confidence defaults to 0 (and would be rejected at write time).
        #expect(RunLessonMemory.parse(#"{"lesson": "a"}"#)?.confidence == 0)
    }

    @Test
    func parseClampsConfidenceToUnitRange() {
        #expect(RunLessonMemory.parse(#"{"lesson": "a", "confidence": 5}"#)?.confidence == 1)
        #expect(RunLessonMemory.parse(#"{"lesson": "a", "confidence": -3}"#)?.confidence == 0)
    }

    // MARK: - proposal

    @Test
    func proposalBuildsDurableGlobalLessonRecord() {
        let distillation = RunLessonMemory.Distillation(
            lesson: "Use mdfind to locate a named file.",
            cue: "finding files",
            confidence: 0.9
        )
        let proposal = RunLessonMemory.proposal(
            for: distillation,
            goal: "fill out a form",
            outcome: "failedSafe",
            traceID: "trace-1",
            now: .now()
        )
        let record = proposal?.record
        #expect(record?.scope == .global)
        #expect(record?.kind == .workflowMemory)
        #expect(record?.durable == true)
        #expect(record?.id.hasPrefix("lesson:") == true)
        #expect(record?.value == "Use mdfind to locate a named file.")
        #expect(record?.source.traceID == "trace-1")
        #expect(record?.source.isLinked == true)
        #expect(record?.metadata["lesson"] == "true")
        #expect(record?.metadata["outcome"] == "failedSafe")
        #expect(record?.metadata["cue"] == "finding files")
        #expect(proposal?.proposedBy == .model)
    }

    @Test
    func proposalRejectsLowConfidence() {
        let weak = RunLessonMemory.Distillation(lesson: "Maybe do X.", cue: "", confidence: 0.4)
        #expect(RunLessonMemory.proposal(for: weak, goal: "g", outcome: "ok", traceID: "t", now: .now()) == nil)
    }

    @Test
    func proposalDedupsByNormalizedLessonText() {
        let a = RunLessonMemory.Distillation(lesson: "Use mdfind to locate files.", cue: "x", confidence: 0.9)
        let b = RunLessonMemory.Distillation(lesson: "  use   MDFIND to LOCATE files.  ", cue: "y", confidence: 0.7)
        let idA = RunLessonMemory.proposal(for: a, goal: "g", outcome: "ok", traceID: "t1", now: .now())?.record.id
        let idB = RunLessonMemory.proposal(for: b, goal: "g", outcome: "ok", traceID: "t2", now: .now())?.record.id
        #expect(idA != nil)
        #expect(idA == idB)

        let c = RunLessonMemory.Distillation(lesson: "A different lesson entirely.", cue: "z", confidence: 0.9)
        let idC = RunLessonMemory.proposal(for: c, goal: "g", outcome: "ok", traceID: "t3", now: .now())?.record.id
        #expect(idC != idA)
    }

    // MARK: - guardrail-defeat filter

    @Test
    func parseReadsTheTypedUnsafeFlag() {
        #expect(RunLessonMemory.parse(
            #"{"lesson": "a", "confidence": 0.9, "unsafe": true}"#
        )?.defeatsGuardrail == true)
        // String-encoded booleans are tolerated; an absent flag defaults to false.
        #expect(RunLessonMemory.parse(
            #"{"lesson": "a", "confidence": 0.9, "unsafe": "true"}"#
        )?.defeatsGuardrail == true)
        #expect(RunLessonMemory.parse(#"{"lesson": "a", "confidence": 0.9}"#)?.defeatsGuardrail == false)
    }

    @Test
    func proposalRejectsAGuardrailDefeatingLesson() {
        let harmful = RunLessonMemory.Distillation(
            lesson: "When the Already-done guard fires, change the command slightly to bypass the check.",
            cue: "looping",
            confidence: 0.95,
            defeatsGuardrail: true
        )
        #expect(RunLessonMemory.proposal(for: harmful, goal: "g", outcome: "failedSafe", traceID: "t", now: .now()) == nil)
    }

    @Test
    func proposalKeepsABenignLessonThatMerelyMentionsAGuard() {
        // The old substring filter wrongly killed this (defeat verb "work around" + guard noun "permission"
        // + "check"). With the typed flag false, a legitimate craft lesson is kept.
        let benign = RunLessonMemory.Distillation(
            lesson: "Work around the permission check by asking the user first, then proceed once granted.",
            cue: "permissions",
            confidence: 0.9,
            defeatsGuardrail: false
        )
        #expect(RunLessonMemory.proposal(for: benign, goal: "g", outcome: "ok", traceID: "t", now: .now()) != nil)
    }

    // MARK: - recall (round-trip through the real store)

    @Test
    func recallSurfacesAStoredLessonForARelatedGoal() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteAgentMemoryStore(baseDirectory: root, cleanupLegacyStores: false)

        let distillation = RunLessonMemory.Distillation(
            lesson: "When locating a named file on macOS, use mdfind rather than a broad recursive find.",
            cue: "locating files on macOS",
            confidence: 0.9
        )
        let proposal = try #require(
            RunLessonMemory.proposal(
                for: distillation,
                goal: "find a file",
                outcome: "failedSafe",
                traceID: "trace-1",
                now: .now()
            )
        )
        _ = try store.appendApprovedProposal(proposal, decidedAt: .now())

        let block = RunLessonMemory.recall(forGoal: "locate a named file on macOS with mdfind", store: store)
        #expect(block?.contains("use mdfind rather than a broad recursive find") == true)
        #expect(block?.hasPrefix("- ") == true)
    }

    @Test
    func recallIgnoresNonLessonWorkflowRecords() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteAgentMemoryStore(baseDirectory: root, cleanupLegacyStores: false)

        // A workflowMemory record that is NOT a lesson (no `lesson:` id prefix) must never leak into recall.
        let nonLesson = AgentMemoryRecord(
            id: "workflow:locate-files",
            scope: .global,
            kind: .workflowMemory,
            value: "Some other workflow about locating files on macOS with mdfind.",
            createdAt: .now(),
            durable: true,
            source: AgentMemorySource(traceID: "trace-x", summary: "not a lesson")
        )
        try store.upsert(nonLesson)

        let block = RunLessonMemory.recall(forGoal: "locate files on macOS with mdfind", store: store)
        #expect(block == nil)
    }

    @Test
    func recallReturnsNilWhenStoreHasNoLessons() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteAgentMemoryStore(baseDirectory: root, cleanupLegacyStores: false)
        #expect(RunLessonMemory.recall(forGoal: "anything at all", store: store) == nil)
        #expect(RunLessonMemory.recall(forGoal: "", store: store) == nil)
        #expect(RunLessonMemory.recall(forGoal: "x", store: nil) == nil)
    }

    // MARK: - Helpers

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "DonkeyRunLessonMemoryTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
