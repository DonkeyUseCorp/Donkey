import DonkeyAI
import DonkeyContracts
import Foundation
import Testing

@Suite
struct AIReplayEvaluationTests {
    @Test
    func replayEvaluatorSummarizesModelPromptPromotionMetrics() {
        let accepted = PlannerHintReplayCase(
            id: "case-accepted",
            trace: trace(id: "trace-1"),
            hint: hint(id: "hint-1"),
            validationIssues: [],
            modelTrace: modelTrace(id: "call-1", latencyMS: 20),
            memoryDecisions: [memoryDecision(approved: true)],
            fallbackCount: 1,
            recoverySucceeded: true,
            estimatedCostUSD: 0.01
        )
        let rejected = PlannerHintReplayCase(
            id: "case-rejected",
            trace: trace(id: "trace-2"),
            hint: hint(id: "hint-2"),
            validationIssues: [.staleStateReference],
            modelTrace: modelTrace(id: "call-2", latencyMS: 40),
            memoryDecisions: [memoryDecision(approved: false)],
            fallbackCount: 2,
            recoverySucceeded: false,
            estimatedCostUSD: 0.02
        )

        let report = PlannerHintReplayEvaluator.evaluate(
            suiteID: "planner-replay-v1",
            promptVersion: "planner-hint-v2",
            modelEntryID: "openai-planner",
            cases: [accepted, rejected],
            generatedAt: timestamp(100)
        )

        #expect(report.caseIDs == ["case-accepted", "case-rejected"])
        #expect(report.metrics.caseCount == 2)
        #expect(report.metrics.schemaValidCount == 2)
        #expect(report.metrics.hintAcceptedCount == 1)
        #expect(report.metrics.memoryWriteAcceptedCount == 1)
        #expect(report.metrics.memoryWriteRejectedCount == 1)
        #expect(report.metrics.fallbackCount == 3)
        #expect(report.metrics.recoverySuccessCount == 1)
        #expect(report.metrics.averageModelLatencyMS == 30)
        #expect(report.metrics.p95ModelLatencyMS == 40)
        #expect(abs(report.metrics.totalEstimatedCostUSD - 0.03) < 0.0001)
    }

    @Test
    func modelUpdateChecklistEncodesRequiredPromotionFields() throws {
        let checklist = AIModelUpdateChecklist(
            modelEntryID: "backend-planner",
            promptVersion: "planner-hint-v2",
            lastVerifiedAt: Date(timeIntervalSince1970: 1_000),
            docsURLs: [URL(string: "donkey://docs/guides/backend-apis")!],
            evalSuiteID: "planner-replay-v1",
            rollbackModelID: "backend-planner-rollback",
            evalReportID: "report-1",
            notes: ["dry-run only"]
        )

        let data = try JSONEncoder().encode(checklist)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["last_verified_at"] != nil)
        #expect(object["docs_urls"] != nil)
        #expect(object["eval_suite_id"] as? String == "planner-replay-v1")
        #expect(object["rollback_model_id"] as? String == "openai-planner-rollback")
    }

    private func trace(id: String) -> ReflexTraceRecord {
        ReflexTraceRecord(
            traceID: id,
            frameID: "frame-\(id)",
            stateID: "state-\(id)",
            actionID: "action-\(id)",
            timestamps: ReflexTraceTimeline(
                captureStart: timestamp(1),
                captureEnd: timestamp(2),
                controllerStart: timestamp(3),
                controllerEnd: timestamp(4),
                actionEnqueued: timestamp(5),
                inputExecuted: timestamp(6)
            ),
            controllerPolicy: "deterministic-controller",
            confidence: 0.8
        )
    }

    private func hint(id: String) -> StructuredPlannerHint {
        StructuredPlannerHint(
            id: id,
            goal: "avoid hazards",
            policyName: "planner-policy",
            preferredActions: [.wait],
            avoidActions: [.tapTarget],
            confidence: 0.8,
            createdAt: timestamp(10),
            expiresAt: timestamp(100),
            sourceTraceID: "trace-1",
            sourceStateID: "state-1"
        )
    }

    private func modelTrace(id: String, latencyMS: Double) -> AIModelCallTrace {
        AIModelCallTrace(
            id: id,
            role: .plannerHint,
            provider: .donkeyBackend,
            modelID: AIModelRegistryEntry.backendSelectedModelID,
            promptVersion: "planner-hint-v2",
            schemaID: "planner_hint_v1",
            latencyMS: latencyMS,
            timeoutMS: 8_000,
            status: .completed,
            validationStatus: "schemaDecoded",
            sourceTraceID: "trace-1"
        )
    }

    private func memoryDecision(approved: Bool) -> RunMemoryWriteDecision {
        let proposal = RunMemoryWriteProposal(
            id: approved ? "proposal-approved" : "proposal-rejected",
            proposedBy: .model,
            record: RunMemoryRecord(
                id: approved ? "memory-approved" : "memory-rejected",
                scope: .target,
                kind: .targetFact,
                targetID: "target-1",
                value: "target fact",
                createdAt: timestamp(10),
                expiresAt: timestamp(100),
                source: RunMemorySource(traceID: "trace-1", summary: "trace")
            ),
            rationale: "eval fixture"
        )
        let approval = RunMemoryWriteApproval(
            proposalID: proposal.id,
            approved: approved,
            issues: approved ? [] : [.missingSourceLink],
            decidedAt: timestamp(20)
        )
        return RunMemoryWriteDecision(
            proposal: proposal,
            approval: approval,
            storedRecord: approved ? proposal.record : nil
        )
    }

    private func timestamp(_ milliseconds: UInt64) -> RunTraceTimestamp {
        RunTraceTimestamp(
            wallClock: Date(timeIntervalSince1970: Double(milliseconds) / 1_000),
            monotonicUptimeNanoseconds: milliseconds * 1_000_000
        )
    }
}
