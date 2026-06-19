import DonkeyContracts
import DonkeyHarness
import DonkeyRuntime
import Foundation
import Testing

@testable import Donkey

/// Covers the task-lifecycle changes: follow-up injection into a running loop (instead of restarting it),
/// concurrent loops on one coordinator, the timed-out status, and the relaunch staleness mapping.
@Suite
struct TaskFollowUpInjectionTests {
    // A stateless planner for the injection test: complete once the injected instruction has been folded
    // into the world model, otherwise queue one follow-up and take a no-op step. Keying off the fact (not
    // a call counter) keeps it a value type.
    private struct InjectingPlanner: HarnessNextStepPlanning {
        let coordinator: HarnessTaskCoordinator
        let taskID: String
        let injectText: String

        func planNextStep(for task: HarnessTaskState) async -> HarnessToolCall? {
            if task.worldModel.facts[HarnessTaskCoordinator.additionalInstructionsFactKey] != nil {
                return HarnessToolCall(name: "run.complete", input: ["reason": "saw the follow-up"])
            }
            await coordinator.enqueueUserMessage(taskID: taskID, text: injectText)
            return HarnessToolCall(name: "test.noop")
        }
    }

    // Observe once, then complete — used to prove two loops run concurrently to completion.
    private struct ObserveThenCompletePlanner: HarnessNextStepPlanning {
        func planNextStep(for task: HarnessTaskState) async -> HarnessToolCall? {
            if task.worldModel.facts["observed"] == "true" {
                return HarnessToolCall(name: "run.complete", input: ["reason": "done"])
            }
            return HarnessToolCall(name: "test.observe")
        }
    }

    private func noopTool() -> HarnessTool {
        HarnessTool(
            descriptor: HarnessToolDescriptor(name: "test.noop", pluginID: "test", summary: "noop", safetyClass: .readOnly)
        ) { context in
            HarnessToolResult(callID: context.call.id, toolName: context.call.name, status: .succeeded, summary: "noop")
        }
    }

    private func observeTool() -> HarnessTool {
        HarnessTool(
            descriptor: HarnessToolDescriptor(name: "test.observe", pluginID: "test", summary: "observe", safetyClass: .readOnly)
        ) { context in
            HarnessToolResult(
                callID: context.call.id,
                toolName: context.call.name,
                status: .succeeded,
                summary: "observed",
                observations: HarnessObservationDelta(facts: ["observed": "true"])
            )
        }
    }

    @Test
    func enqueueAndDrainFoldInTheInstructionWithoutTouchingTheGoalOrHistory() async {
        let coordinator = HarnessTaskCoordinator()
        _ = await coordinator.createTask(id: "t", threadID: "th", goal: "original goal")

        // No live loop is running for this bare task, so enqueue reports false (the caller would resume).
        let live = await coordinator.enqueueUserMessage(taskID: "t", text: "also rename the file")
        #expect(live == false)

        let drained = await coordinator.drainUserMessages(taskID: "t")
        #expect(drained.map(\.text) == ["also rename the file"])

        let after = await coordinator.task(id: "t")
        // The follow-up amends the work: the goal is preserved (not clobbered like interrupt would), the
        // run is not restarted (no history), and the instruction is surfaced via the additive fact.
        #expect(after?.goal == "original goal")
        #expect(after?.toolHistory.isEmpty == true)
        #expect(after?.worldModel.facts[HarnessTaskCoordinator.additionalInstructionsFactKey] == "also rename the file")

        // A second drain is empty — the queue cleared.
        let drainedAgain = await coordinator.drainUserMessages(taskID: "t")
        #expect(drainedAgain.isEmpty)
    }

    @Test
    func drainAccumulatesMultipleFollowUps() async {
        let coordinator = HarnessTaskCoordinator()
        _ = await coordinator.createTask(id: "t", threadID: "th", goal: "g")
        _ = await coordinator.enqueueUserMessage(taskID: "t", text: "first")
        _ = await coordinator.drainUserMessages(taskID: "t")
        _ = await coordinator.enqueueUserMessage(taskID: "t", text: "second")
        _ = await coordinator.drainUserMessages(taskID: "t")

        let after = await coordinator.task(id: "t")
        #expect(after?.worldModel.facts[HarnessTaskCoordinator.additionalInstructionsFactKey] == "first\nsecond")
    }

    @Test
    func enqueueOnUnknownTaskReportsNoLiveLoop() async {
        let coordinator = HarnessTaskCoordinator()
        let live = await coordinator.enqueueUserMessage(taskID: "missing", text: "x")
        #expect(live == false)
    }

    @Test
    func enqueueReportsLiveLoopOnlyWhileARunIsMarked() async {
        let coordinator = HarnessTaskCoordinator()
        _ = await coordinator.createTask(id: "t", threadID: "th", goal: "g")

        // Before any run: not live → caller resumes.
        #expect(await coordinator.enqueueUserMessage(taskID: "t", text: "a") == false)

        // While a run is marked: live → caller injects and the loop drains it.
        await coordinator.beginRun(taskID: "t")
        #expect(await coordinator.enqueueUserMessage(taskID: "t", text: "b") == true)

        // endRunUnlessPending sees the queued messages and keeps the run alive (returns false).
        #expect(await coordinator.endRunUnlessPending(taskID: "t") == false)
        _ = await coordinator.drainUserMessages(taskID: "t")
        // With the queue now empty, the run truly ends and a later enqueue reports not-live again.
        #expect(await coordinator.endRunUnlessPending(taskID: "t") == true)
        #expect(await coordinator.enqueueUserMessage(taskID: "t", text: "c") == false)
    }

    @Test
    func reopenForFollowUpRevivesACompletedTaskPreservingFacts() async {
        let coordinator = HarnessTaskCoordinator()
        _ = await coordinator.createTask(id: "t", threadID: "th", goal: "g")
        _ = await coordinator.drainUserMessages(taskID: "t") // no-op
        _ = await coordinator.enqueueUserMessage(taskID: "t", text: "late instruction")
        _ = await coordinator.drainUserMessages(taskID: "t") // folds into the fact
        _ = await coordinator.complete(taskID: "t")
        // complete() clears the follow-up fact, so re-enqueue to simulate a fresh late arrival.
        _ = await coordinator.enqueueUserMessage(taskID: "t", text: "newer instruction")
        _ = await coordinator.drainUserMessages(taskID: "t")

        await coordinator.reopenForFollowUp(taskID: "t")
        let task = await coordinator.task(id: "t")
        #expect(task?.status == .running)
        #expect(task?.worldModel.facts[HarnessTaskCoordinator.additionalInstructionsFactKey] == "newer instruction")
    }

    @Test
    func runningLoopFoldsInAFollowUpMidRunInsteadOfRestarting() async {
        let coordinator = HarnessTaskCoordinator()
        let registry = BuiltInHarnessToolCatalog.registryWithBuiltInExecutors()
        await registry.register(noopTool())
        let runtime = GenericHarnessRuntime(coordinator: coordinator, registry: registry)
        let task = await coordinator.createTask(
            id: "task-inject",
            threadID: "thread-inject",
            goal: "tidy the desktop",
            grantedPermissions: [.lifecycle]
        )

        let planner = InjectingPlanner(coordinator: coordinator, taskID: task.id, injectText: "also empty the trash")
        let steps = await runtime.run(taskID: task.id, planner: planner, maxSteps: 10)

        // The queued instruction is delivered at the next loop iteration, so the run completes rather than
        // stalling, and the original goal is untouched (the follow-up amended the work in place).
        let finalTask = await coordinator.task(id: task.id)
        #expect(finalTask?.status == .completed)
        #expect(finalTask?.goal == "tidy the desktop")
        #expect(steps.last?.toolResult?.toolName == "run.complete")
    }

    @Test
    func twoLoopsRunConcurrentlyOnOneCoordinatorWithoutCrossTalk() async {
        let coordinator = HarnessTaskCoordinator()
        let registry = BuiltInHarnessToolCatalog.registryWithBuiltInExecutors()
        await registry.register(observeTool())
        let runtime = GenericHarnessRuntime(coordinator: coordinator, registry: registry)
        let taskA = await coordinator.createTask(id: "task-a", threadID: "thread-a", goal: "goal A", grantedPermissions: [.lifecycle])
        let taskB = await coordinator.createTask(id: "task-b", threadID: "thread-b", goal: "goal B", grantedPermissions: [.lifecycle])

        let planner = ObserveThenCompletePlanner()
        async let runA = runtime.run(taskID: taskA.id, planner: planner, maxSteps: 5)
        async let runB = runtime.run(taskID: taskB.id, planner: planner, maxSteps: 5)
        _ = await (runA, runB)

        let finalA = await coordinator.task(id: taskA.id)
        let finalB = await coordinator.task(id: taskB.id)
        #expect(finalA?.status == .completed)
        #expect(finalB?.status == .completed)
        // Each task kept its own goal and history — no state bled between the concurrent loops.
        #expect(finalA?.goal == "goal A")
        #expect(finalB?.goal == "goal B")
    }

    @Test
    func aProgressingRunThatNeverCompletesTimesOutRatherThanFailing() async {
        // Keeps making progress (a new fact each step) so the stall guards never fire; it should hit the
        // step ceiling and be marked timedOut (retryable), not failedSafe.
        struct AlwaysProgressPlanner: HarnessNextStepPlanning {
            func planNextStep(for task: HarnessTaskState) async -> HarnessToolCall? {
                HarnessToolCall(name: "test.progress", input: ["n": String(task.toolHistory.count)])
            }
        }
        let coordinator = HarnessTaskCoordinator()
        let registry = BuiltInHarnessToolCatalog.registryWithBuiltInExecutors()
        await registry.register(
            HarnessTool(
                descriptor: HarnessToolDescriptor(name: "test.progress", pluginID: "test", summary: "progress", safetyClass: .readOnly)
            ) { context in
                HarnessToolResult(
                    callID: context.call.id,
                    toolName: context.call.name,
                    status: .succeeded,
                    summary: "advanced",
                    observations: HarnessObservationDelta(facts: ["seen-\(context.call.input["n"] ?? "?")": "true"])
                )
            }
        )
        let runtime = GenericHarnessRuntime(coordinator: coordinator, registry: registry)
        let task = await coordinator.createTask(id: "task-timeout", threadID: "t", goal: "go forever", grantedPermissions: [.lifecycle])

        _ = await runtime.run(taskID: task.id, planner: AlwaysProgressPlanner(), maxSteps: 3)

        let finalTask = await coordinator.task(id: task.id)
        #expect(finalTask?.status == .timedOut)
    }

    @Test
    func aPlannerThatStopsWithoutALifecycleCallFailsSafe() async {
        struct GivesUpPlanner: HarnessNextStepPlanning {
            func planNextStep(for task: HarnessTaskState) async -> HarnessToolCall? { nil }
        }
        let coordinator = HarnessTaskCoordinator()
        let registry = BuiltInHarnessToolCatalog.registryWithBuiltInExecutors()
        let runtime = GenericHarnessRuntime(coordinator: coordinator, registry: registry)
        let task = await coordinator.createTask(id: "task-giveup", threadID: "t", goal: "g", grantedPermissions: [.lifecycle])

        _ = await runtime.run(taskID: task.id, planner: GivesUpPlanner(), maxSteps: 5)

        let finalTask = await coordinator.task(id: task.id)
        #expect(finalTask?.status == .failedSafe)
    }

    @Test
    func timeOutMarksTheTaskRetryableAndClearsAnyGate() async {
        let coordinator = HarnessTaskCoordinator()
        _ = await coordinator.createTask(id: "t", threadID: "th", goal: "g")
        // Leave a pending continuation behind to prove timeOut clears it.
        _ = await coordinator.waitForUser(taskID: "t", question: "which file?")

        let timedOut = await coordinator.timeOut(taskID: "t")
        #expect(timedOut?.status == .timedOut)
        #expect(timedOut?.pendingContinuation == nil)
        #expect(timedOut?.status.canExecuteTools == false)
    }

    @MainActor
    @Test
    func restoredTasksMapByStalenessAndState() {
        let now = Date()
        func task(_ id: String, _ status: UserQueryTaskStatus, ageMinutes: Double) -> UserQueryNotchTask {
            UserQueryNotchTask(
                id: id,
                title: id,
                detail: "d",
                status: status,
                accentIndex: 0,
                updatedAt: now.addingTimeInterval(-ageMinutes * 60)
            )
        }

        let recentRunning = task("recent", .running, ageMinutes: 10)
        let staleRunning = task("stale", .running, ageMinutes: 120)
        let waiting = task("waiting", .waitingForClarification, ageMinutes: 5)
        let paused = task("paused", .paused, ageMinutes: 5)
        let completed = task("done", .completed, ageMinutes: 5)

        let result = UserQueryOverlayModel.restoredTasks(
            from: [recentRunning, staleRunning, waiting, paused, completed],
            now: now
        )

        // Only the recently-running task auto-resumes; it keeps running.
        #expect(result.autoResumeIDs == ["recent"])
        func status(_ id: String) -> UserQueryTaskStatus? { result.tasks.first { $0.id == id }?.status }
        #expect(status("recent") == .running)
        #expect(status("stale") == .timedOut)        // too old to auto-run → retryable row
        #expect(status("waiting") == .paused)         // was blocked on the user → comes back paused
        #expect(status("paused") == .paused)          // user-paused stays paused
        #expect(status("done") == .completed)         // terminal states untouched
        // The persisted updatedAt is preserved so elapsed-time stays the real run duration.
        #expect(result.tasks.first { $0.id == "stale" }?.updatedAt == staleRunning.updatedAt)
    }
}
