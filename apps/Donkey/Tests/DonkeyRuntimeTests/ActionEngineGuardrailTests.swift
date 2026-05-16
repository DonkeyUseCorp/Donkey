import DonkeyContracts
@testable import DonkeyRuntime
import Foundation
import Testing

@Suite
struct ActionEngineGuardrailTests {
    @Test
    func defaultPolicyDeniesInputCommandBeforeExecution() async {
        let engine = ActionEngineGuardrail()

        let trace = await engine.handle(command(id: "tap-1", issuedAtMS: 0))

        #expect(trace.decision == .denied(reason: "input permission denied"))
        #expect(trace.executed == false)
        #expect(trace.permissionDecision.isAllowed == false)
        #expect(await engine.allTraces() == [trace])
    }

    @Test
    func allowedInputProjectsDryRunWithoutLiveExecution() async {
        let engine = ActionEngineGuardrail()
        let policy = ToolCallPolicy(deniedCapabilities: [])

        let trace = await engine.handle(
            command(id: "tap-allowed", issuedAtMS: 0),
            permissionPolicy: policy
        )

        #expect(trace.decision == .projectedDryRun)
        #expect(trace.executed == false)
        #expect(trace.liveInputEnabled == false)
        #expect(trace.focusGuardPassed == true)
        #expect(trace.metadata["liveInputBackend"] == "notImplemented")
    }

    @Test
    func focusGuardCanDenyInputCommand() async {
        let engine = ActionEngineGuardrail(focusGuard: DenyingFocusGuard())
        let policy = ToolCallPolicy(deniedCapabilities: [])

        let trace = await engine.handle(
            command(id: "tap-focus", issuedAtMS: 0),
            permissionPolicy: policy
        )

        #expect(trace.decision == .denied(reason: "focus guard failed"))
        #expect(trace.focusGuardPassed == false)
    }

    @Test
    func holdDurationAboveMaximumIsDenied() async {
        let engine = ActionEngineGuardrail(
            configuration: ActionEngineConfiguration(maximumHoldDurationMS: 100)
        )
        let policy = ToolCallPolicy(deniedCapabilities: [])

        let trace = await engine.handle(
            command(id: "key-hold", kind: .key, issuedAtMS: 0, holdDurationMS: 250),
            permissionPolicy: policy
        )

        #expect(trace.decision == .denied(reason: "hold duration exceeds maximum"))
        #expect(trace.metadata["maximumHoldDurationMS"] == "100.0")
    }

    @Test
    func rateLimitDeniesCommandsTooCloseTogether() async {
        let engine = ActionEngineGuardrail(
            configuration: ActionEngineConfiguration(minimumCommandIntervalMS: 20)
        )
        let policy = ToolCallPolicy(deniedCapabilities: [])

        _ = await engine.handle(
            command(id: "tap-1", issuedAtMS: 0),
            permissionPolicy: policy
        )
        let trace = await engine.handle(
            command(id: "tap-2", issuedAtMS: 10),
            permissionPolicy: policy
        )

        #expect(trace.decision == .denied(reason: "rate limited"))
        #expect(trace.rateLimited == true)
        #expect(trace.metadata["elapsedMS"] == "10.0")
    }

    @Test
    func releaseAllClearsHeldInputAndRecordsReplayableTrace() async {
        let engine = ActionEngineGuardrail()
        let policy = ToolCallPolicy(deniedCapabilities: [])

        _ = await engine.handle(
            command(id: "mouse-held", kind: .mouse, issuedAtMS: 0, holdDurationMS: 50),
            permissionPolicy: policy
        )
        #expect(await engine.heldInputCount() == 1)

        let release = await engine.releaseAll(
            traceID: "trace-1",
            targetID: "target-1",
            issuedAt: timestamp(100)
        )

        #expect(release.command.kind == .releaseAll)
        #expect(release.releaseAll == true)
        #expect(release.metadata["heldInputReleased"] == "true")
        #expect(await engine.heldInputCount() == 0)
    }

    private func command(
        id: String,
        kind: ActionEngineCommandKind = .tap,
        issuedAtMS: UInt64,
        holdDurationMS: Double? = nil
    ) -> ActionEngineCommand {
        ActionEngineCommand(
            id: id,
            traceID: "trace-1",
            targetID: "target-1",
            stateID: "state-1",
            actionID: "action-1",
            kind: kind,
            issuedAt: timestamp(issuedAtMS),
            targetBounds: HotLoopRect(x: 0.4, y: 0.5, width: 0.1, height: 0.1, space: .normalizedTarget),
            holdDurationMS: holdDurationMS
        )
    }

    private func timestamp(_ milliseconds: UInt64) -> RunTraceTimestamp {
        RunTraceTimestamp(
            wallClock: Date(timeIntervalSince1970: Double(milliseconds) / 1_000),
            monotonicUptimeNanoseconds: milliseconds * 1_000_000
        )
    }
}

private struct DenyingFocusGuard: ActionEngineFocusGuard {
    func targetIsSafeForInput(targetID: String) async -> Bool {
        false
    }
}
