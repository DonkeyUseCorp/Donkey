import DonkeyContracts
@testable import DonkeyRuntime
import Foundation
import Testing

@Suite
struct SlowPlannerSidecarTests {
    @Test
    func sidecarBuildsCompactSnapshotAndPublishesOnlyValidatedHint() async {
        let coordinator = RunCoordinator()
        _ = await coordinator.start(session())
        let memory = InMemoryRunMemory(
            runID: "session-planner",
            targetID: "target-1",
            currentGoal: "switch to the docs tab"
        )
        await memory.rememberFailure(
            RunFailureSummary(traceID: "trace-old", summary: "target not found")
        )
        await memory.append(
            RunMemoryRecord(
                id: "instruction-1",
                scope: .run,
                kind: .userInstruction,
                runID: "session-planner",
                value: "Prefer tabs with install docs",
                createdAt: timestamp(1),
                source: RunMemorySource(traceID: "trace-old", summary: "user instruction")
            )
        )

        let state = worldState(confidence: 0.35)
        let action = action(
            state: state,
            confidence: 0.35,
            metadata: [
                "fallback": "true",
                "fallbackReason": "lowConfidence"
            ]
        )
        let trace = trace(state: state, action: action)
        await coordinator.appendReflexTrace(trace)

        let planner = RecordingSlowPlanner()
        await planner.enqueueHint(validHint(for: state, trace: trace))
        let hintBus = ValidatedPlannerHintBus()
        let sidecar = DryRunSlowPlannerSidecar(
            coordinator: coordinator,
            memory: memory,
            hintBus: hintBus,
            planner: planner,
            screenshotReferences: [
                SlowPlannerScreenshotReference(
                    artifactID: "screenshot-1",
                    summary: "manual screenshot artifact"
                )
            ]
        )

        await sidecar.observe(
            worldState: state,
            action: action,
            trace: trace,
            userInstruction: "Look for install docs"
        )

        let snapshots = await planner.snapshots()
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.triggerReasons.contains(.lowConfidence) == true)
        #expect(snapshots.first?.triggerReasons.contains(.userInstruction) == true)
        #expect(snapshots.first?.context.latestWorldState?.stateID == state.id)
        #expect(snapshots.first?.context.memorySnapshot?.currentGoal == "switch to the docs tab")
        #expect(snapshots.first?.traceSummaries.map(\.traceID) == ["trace-1"])
        #expect(snapshots.first?.screenshotReferences.map(\.artifactID) == ["screenshot-1"])

        #expect((await hintBus.allHints()).map(\.id) == ["hint-valid"])
        #expect((await memory.snapshot(now: timestamp(20))).activeHints.map(\.id) == ["hint-valid"])
        #expect((await sidecar.stats()).publishedHintCount == 1)
    }

    @Test
    func sidecarRejectsInvalidPlannerHintBeforeControllerPublication() async {
        let coordinator = RunCoordinator()
        _ = await coordinator.start(session())
        let state = worldState(confidence: 0.2)
        let action = action(
            state: state,
            confidence: 0.2,
            metadata: [
                "fallback": "true",
                "fallbackReason": "lowConfidence"
            ]
        )
        let trace = trace(state: state, action: action)
        await coordinator.appendReflexTrace(trace)

        let invalid = StructuredPlannerHint(
            id: "hint-invalid",
            goal: "tap directly",
            policyName: "planner",
            preferredActions: [.tapTarget],
            confidence: 0.9,
            createdAt: timestamp(10),
            expiresAt: timestamp(1_000),
            sourceTraceID: trace.traceID,
            sourceFrameID: trace.frameID,
            sourceStateID: state.id
        )
        let planner = RecordingSlowPlanner()
        await planner.enqueueHint(invalid)
        let hintBus = ValidatedPlannerHintBus()
        let sidecar = DryRunSlowPlannerSidecar(
            coordinator: coordinator,
            hintBus: hintBus,
            planner: planner,
            unsafeActions: [.tapTarget]
        )

        await sidecar.observe(worldState: state, action: action, trace: trace)

        #expect(await hintBus.allHints().isEmpty)
        #expect((await hintBus.allValidationResults()).first?.issues == [.unsafeAction])
        #expect((await sidecar.stats()).publishedHintCount == 0)
    }

    @Test
    func hintAwareControllerReadsOnlyLatestValidatedHint() async {
        let state = worldState(confidence: 0.9)
        let trace = trace(state: state, action: action(state: state))
        let hintBus = ValidatedPlannerHintBus()
        _ = await hintBus.publishIfValid(
            validHint(for: state, trace: trace),
            context: PlannerHintValidationContext(
                currentStateID: state.id,
                now: timestamp(20)
            )
        )

        let controller = PlannerHintAwareControllerPolicy(
            base: FixedControllerPolicy(kind: .focusWindow),
            hintBus: hintBus
        )

        let plannedAction = await controller.decide(state: state)

        #expect(plannedAction.plannerHintID == "hint-valid")
        #expect(plannedAction.metadata["plannerHintID"] == "hint-valid")
        #expect(plannedAction.metadata["plannerHintPreferredAction"] == "true")
    }

    @Test
    func controllerRunsThirtySecondsWithoutPlannerOutput() async {
        let frames = (0...30).map { index in
            frame(id: "frame-\(index + 1)", milliseconds: UInt64(index * 1_000))
        }
        let coordinator = RunCoordinator()
        let loop = DryRunReflexLoop(
            coordinator: coordinator,
            frameSource: SyntheticFrameSource(frames: frames)
        )

        let result = await loop.run(session: session())
        let report = await ReflexLatencyReportBuilder.build(
            from: coordinator.reflexTraces(),
            droppedFrameCount: result.droppedFrameCount
        )

        #expect(result.processedFrameCount == 31)
        #expect(result.latestAction != nil)
        #expect(report.traceCount == 31)
        #expect(report.softwareLoopMS.p95 != nil)
    }

    @Test
    func slowPlannerLatencyDoesNotMoveReflexLatencyReport() async {
        let frames = (0..<4).map { index in
            frame(id: "frame-\(index + 1)", milliseconds: UInt64(index * 16))
        }
        let baselineCoordinator = RunCoordinator()
        let baselineLoop = DryRunReflexLoop(
            coordinator: baselineCoordinator,
            frameSource: SyntheticFrameSource(frames: frames)
        )
        let baselineResult = await baselineLoop.run(session: session())
        let baselineReport = await ReflexLatencyReportBuilder.build(
            from: baselineCoordinator.reflexTraces(),
            droppedFrameCount: baselineResult.droppedFrameCount
        )

        let sidecarCoordinator = RunCoordinator()
        let planner = RecordingSlowPlanner(delayNanoseconds: 150_000_000)
        let hintBus = ValidatedPlannerHintBus()
        let sidecar = DryRunSlowPlannerSidecar(
            coordinator: sidecarCoordinator,
            hintBus: hintBus,
            planner: planner
        )
        let loop = DryRunReflexLoop(
            coordinator: sidecarCoordinator,
            frameSource: SyntheticFrameSource(frames: frames),
            slowPlannerSidecar: sidecar
        )

        let result = await loop.run(session: session())
        let report = await ReflexLatencyReportBuilder.build(
            from: sidecarCoordinator.reflexTraces(),
            droppedFrameCount: result.droppedFrameCount
        )

        #expect(report.traceCount == baselineReport.traceCount)
        #expect(report.softwareLoopMS.p95 == baselineReport.softwareLoopMS.p95)
        #expect(report.decisionMS.p95 == baselineReport.decisionMS.p95)
    }

    private func session() -> RunSession {
        RunSession(
            id: "session-planner",
            userGoal: "switch to the docs tab",
            targetID: "target-1"
        )
    }

    private func worldState(
        confidence: Double,
        id: String = "state-1"
    ) -> HotLoopWorldState {
        HotLoopWorldState(
            id: id,
            traceID: "trace-1",
            frameID: "frame-1",
            targetID: "target-1",
            observedAt: timestamp(10),
            signalSummaries: [
                HotLoopPerceptionSignalSummary(
                    id: "signal-1",
                    kind: "localNavigationMetadata",
                    confidence: confidence,
                    sourceAgeMS: 5,
                    observationCount: 1
                )
            ],
            actionAffordances: [
                HotLoopActionAffordance(
                    id: "affordance-1",
                    kind: .focusWindow,
                    targetBounds: HotLoopRect(x: 0, y: 0, width: 100, height: 100, space: .screen),
                    confidence: confidence,
                    sourceSignalID: "signal-1",
                    metadata: [
                        "localNavigation.candidateID": "window-1",
                        "localNavigation.candidateKind": "window",
                        "localNavigation.safetyStatus": "allowed"
                    ]
                )
            ],
            confidence: confidence
        )
    }

    private func action(
        state: HotLoopWorldState,
        confidence: Double = 0.9,
        metadata: [String: String] = ["fallback": "false"]
    ) -> HotLoopControllerAction {
        HotLoopControllerAction(
            id: "action-\(state.id)",
            traceID: state.traceID,
            frameID: state.frameID,
            stateID: state.id,
            kind: .focusWindow,
            policyName: "fixed",
            confidence: confidence,
            rationale: "fixture action",
            metadata: metadata
        )
    }

    private func trace(
        state: HotLoopWorldState,
        action: HotLoopControllerAction
    ) -> ReflexTraceRecord {
        ReflexTraceRecord(
            traceID: state.traceID,
            frameID: state.frameID,
            stateID: state.id,
            actionID: action.id,
            timestamps: ReflexTraceTimeline(
                captureStart: timestamp(1),
                captureEnd: timestamp(2),
                perceptionStart: timestamp(2),
                perceptionEnd: timestamp(4),
                stateUpdateStart: timestamp(4),
                stateUpdateEnd: timestamp(5),
                statePublished: timestamp(5),
                controllerStart: timestamp(5),
                controllerEnd: timestamp(6),
                actionProjectionStart: timestamp(6),
                actionProjectionEnd: timestamp(6),
                actionEnqueued: timestamp(6),
                inputExecuted: timestamp(6)
            ),
            controllerPolicy: action.policyName,
            confidence: action.confidence,
            metadata: [
                "action.kind": action.kind.rawValue,
                "fallbackReason": action.metadata["fallbackReason"] ?? ""
            ]
        )
    }

    private func validHint(
        for state: HotLoopWorldState,
        trace: ReflexTraceRecord
    ) -> StructuredPlannerHint {
        StructuredPlannerHint(
            id: "hint-valid",
            goal: "prefer focusing the requested target",
            policyName: "planner",
            preferredActions: [.focusWindow],
            confidence: 0.9,
            createdAt: timestamp(10),
            expiresAt: timestamp(1_000),
            sourceTraceID: trace.traceID,
            sourceFrameID: trace.frameID,
            sourceStateID: state.id
        )
    }

    private func frame(id: String, milliseconds: UInt64) -> HotLoopFrame {
        HotLoopFrame(
            id: id,
            traceID: "trace-\(id)",
            targetID: "target-1",
            capturedAt: timestamp(milliseconds),
            sourceKind: .synthetic,
            windowBounds: HotLoopRect(x: 0, y: 0, width: 400, height: 300, space: .screen),
            crop: HotLoopCrop(
                id: "crop-\(id)",
                bounds: HotLoopRect(x: 0, y: 0, width: 400, height: 300, space: .window),
                outputSize: HotLoopSize(width: 400, height: 300, space: .crop)
            ),
            pixelSize: HotLoopSize(width: 400, height: 300, space: .window),
            metadata: [
                "tapTargetX": "0.4",
                "tapTargetY": "0.5",
                "tapTargetWidth": "0.1",
                "tapTargetHeight": "0.1",
                "signalConfidence": "0.85"
            ]
        )
    }

    private func timestamp(_ milliseconds: UInt64) -> RunTraceTimestamp {
        RunTraceTimestamp(
            wallClock: Date(timeIntervalSince1970: Double(milliseconds) / 1_000),
            monotonicUptimeNanoseconds: milliseconds * 1_000_000
        )
    }
}

private actor RecordingSlowPlanner: SlowPlannerHintGenerating {
    private var queuedHints: [StructuredPlannerHint] = []
    private var recordedSnapshots: [SlowPlannerSnapshot] = []
    private let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64 = 0) {
        self.delayNanoseconds = delayNanoseconds
    }

    func enqueueHint(_ hint: StructuredPlannerHint) {
        queuedHints.append(hint)
    }

    func snapshots() -> [SlowPlannerSnapshot] {
        recordedSnapshots
    }

    func generatePlannerHint(
        snapshot: SlowPlannerSnapshot
    ) async -> SlowPlannerHintGenerationResult {
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        recordedSnapshots.append(snapshot)
        return SlowPlannerHintGenerationResult(
            hint: queuedHints.isEmpty ? nil : queuedHints.removeFirst()
        )
    }
}

private struct FixedControllerPolicy: DryRunControllerPolicy {
    var kind: HotLoopActionKind
    var name: String { "fixed-controller" }

    func decide(state: HotLoopWorldState) async -> HotLoopControllerAction {
        HotLoopControllerAction(
            id: "action-\(state.id)",
            traceID: state.traceID,
            frameID: state.frameID,
            stateID: state.id,
            kind: kind,
            policyName: name,
            confidence: 0.9,
            rationale: "fixed action",
            metadata: ["fallback": "false"]
        )
    }
}
