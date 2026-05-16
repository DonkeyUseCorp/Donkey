import DonkeyContracts
@testable import DonkeyRuntime
import Foundation
import Testing

@Suite
struct RunMemoryStoreTests {
    @Test
    func deterministicApproverRequiresSourceLinkAndTargetRetention() {
        let proposal = RunMemoryWriteProposal(
            id: "proposal-1",
            proposedBy: .model,
            record: RunMemoryRecord(
                id: "memory-1",
                scope: .target,
                kind: .targetFact,
                targetID: "target-1",
                value: "jump button is lower right",
                createdAt: timestamp(10),
                source: RunMemorySource(summary: "model guessed")
            ),
            rationale: "remember target layout"
        )

        let approval = RunMemoryApprover.evaluate(proposal, decidedAt: timestamp(20))

        #expect(approval.approved == false)
        #expect(approval.issues == [.missingRetention, .missingSourceLink])
    }

    @Test
    func targetMemoryJsonlStoresListsAndDeletesApprovedRecords() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try TargetMemoryJSONLStore(baseDirectory: root)
        let proposal = RunMemoryWriteProposal(
            id: "proposal-1",
            proposedBy: .model,
            record: targetRecord(id: "memory-1", runID: "run-1", userID: "user-1"),
            rationale: "fixture-proven target fact"
        )

        let decision = try await store.appendApprovedProposal(proposal, decidedAt: timestamp(20))

        #expect(decision.approval.approved == true)
        #expect(decision.storedRecord?.id == "memory-1")

        let records = try await store.records(targetID: "target-1")
        #expect(records.map(\.id) == ["memory-1"])

        let scoped = try await store.records(targetID: "target-1", runID: "run-1", userID: "user-1")
        #expect(scoped.map(\.id) == ["memory-1"])

        let deleted = try await store.delete(targetID: "target-1", recordID: "memory-1")
        #expect(deleted == 1)
        #expect(try await store.records(targetID: "target-1").isEmpty)
    }

    @Test
    func rejectedMemoryProposalIsInspectableAndNotStored() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try TargetMemoryJSONLStore(baseDirectory: root)
        let proposal = RunMemoryWriteProposal(
            id: "proposal-rejected",
            proposedBy: .model,
            record: RunMemoryRecord(
                id: "memory-rejected",
                scope: .target,
                kind: .targetFact,
                targetID: "target-1",
                value: "",
                createdAt: timestamp(10),
                source: RunMemorySource(traceID: "trace-1", summary: "empty proposal")
            ),
            rationale: "bad proposal"
        )

        let decision = try await store.appendApprovedProposal(proposal, decidedAt: timestamp(20))

        #expect(decision.approval.approved == false)
        #expect(decision.storedRecord == nil)
        #expect(decision.approval.issues == [.emptyValue, .missingRetention])
        #expect(try await store.records(targetID: "target-1").isEmpty)
    }

    @Test
    func inProcessRunMemoryBuildsBoundedSnapshot() async {
        let memory = InMemoryRunMemory(
            runID: "run-1",
            targetID: "target-1",
            currentGoal: "avoid hazards",
            capacity: 2
        )

        await memory.setActiveHints([
            RunPlannerHint(id: "hint-expired", summary: "old", isValid: false),
            RunPlannerHint(id: "hint-live", summary: "stay center", isValid: true)
        ])
        await memory.rememberState(RunWorldStateSummary(stateID: "state-1", summary: "left lane", confidence: 0.8))
        await memory.rememberState(RunWorldStateSummary(stateID: "state-2", summary: "center lane", confidence: 0.9))
        await memory.rememberFailure(RunFailureSummary(traceID: "trace-1", summary: "missed obstacle"))
        await memory.append(instructionRecord(id: "instruction-1", value: "do not tap ads"))
        await memory.append(safetyStopRecord(id: "stop-1", value: "operator stopped after focus loss"))

        let snapshot = await memory.snapshot(now: timestamp(40))

        #expect(snapshot.currentGoal == "avoid hazards")
        #expect(snapshot.activeHints.map(\.id) == ["hint-live"])
        #expect(snapshot.recentStates.map(\.stateID) == ["state-1", "state-2"])
        #expect(snapshot.recentFailures.map(\.traceID) == ["trace-1"])
        #expect(snapshot.userInstructions.map(\.value) == ["do not tap ads"])
        #expect(snapshot.safetyStops.map(\.value) == ["operator stopped after focus loss"])
    }

    @Test
    func contextAssemblerCarriesMemorySnapshot() {
        let assembler = RunContextAssembler()
        let session = RunSession(id: "run-1", userGoal: "avoid hazards", targetID: "target-1")
        let snapshot = RunMemorySnapshot(
            currentGoal: "avoid hazards",
            activeHints: [RunPlannerHint(id: "hint-1", summary: "stay center", isValid: true)],
            recentStates: [RunWorldStateSummary(stateID: "state-1", summary: "center", confidence: 0.9)],
            targetRecords: [targetRecord(id: "memory-1", runID: "run-1", userID: "user-1")]
        )

        let context = assembler.build(
            session: session,
            transcriptSummary: "",
            memorySnapshot: snapshot
        )

        #expect(context.memorySnapshot?.currentGoal == "avoid hazards")
        #expect(context.memorySnapshot?.targetRecords.map(\.id) == ["memory-1"])
    }

    private func targetRecord(id: String, runID: String, userID: String) -> RunMemoryRecord {
        RunMemoryRecord(
            id: id,
            scope: .target,
            kind: .targetFact,
            targetID: "target-1",
            runID: runID,
            userID: userID,
            value: "jump button is lower right",
            createdAt: timestamp(10),
            expiresAt: timestamp(1_000),
            durable: false,
            source: RunMemorySource(traceID: "trace-1", stateID: "state-1", summary: "recorded trace")
        )
    }

    private func instructionRecord(id: String, value: String) -> RunMemoryRecord {
        RunMemoryRecord(
            id: id,
            scope: .run,
            kind: .userInstruction,
            targetID: "target-1",
            runID: "run-1",
            value: value,
            createdAt: timestamp(10),
            source: RunMemorySource(eventSequence: 1, summary: "user instruction")
        )
    }

    private func safetyStopRecord(id: String, value: String) -> RunMemoryRecord {
        RunMemoryRecord(
            id: id,
            scope: .run,
            kind: .safetyStop,
            targetID: "target-1",
            runID: "run-1",
            value: value,
            createdAt: timestamp(20),
            source: RunMemorySource(traceID: "trace-stop", summary: "abort")
        )
    }

    private func timestamp(_ milliseconds: UInt64) -> RunTraceTimestamp {
        RunTraceTimestamp(
            wallClock: Date(timeIntervalSince1970: Double(milliseconds) / 1_000),
            monotonicUptimeNanoseconds: milliseconds * 1_000_000
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "DonkeyMemoryStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
