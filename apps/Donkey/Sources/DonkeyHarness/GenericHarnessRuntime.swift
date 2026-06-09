import Foundation

public struct HarnessStepExecutionResult: Equatable, Sendable {
    public var task: HarnessTaskState
    public var toolResult: HarnessToolResult?
    public var stoppedForGate: Bool

    public init(
        task: HarnessTaskState,
        toolResult: HarnessToolResult? = nil,
        stoppedForGate: Bool = false
    ) {
        self.task = task
        self.toolResult = toolResult
        self.stoppedForGate = stoppedForGate
    }
}

/// The model boundary the harness consults to choose the next tool call. This is the planning step of
/// the harness loop: it is asked again after every observation, with the task's world model already
/// updated by the previous tool's result, and returns the next call (or nil to stop). It expresses
/// completion by returning a `run.complete` lifecycle call, which ends the loop.
public protocol HarnessNextStepPlanning: Sendable {
    func planNextStep(for task: HarnessTaskState) async -> HarnessToolCall?
}

public struct GenericHarnessRuntime: Sendable {
    public var coordinator: HarnessTaskCoordinator
    public var registry: HarnessToolRegistry

    public init(
        coordinator: HarnessTaskCoordinator,
        registry: HarnessToolRegistry
    ) {
        self.coordinator = coordinator
        self.registry = registry
    }

    /// Runs the harness loop driven by per-observation re-planning: observe → plan one step → execute
    /// → record observation → re-plan, repeating until the planner stops, a gate stops the task, the
    /// task becomes non-executable (e.g. `run.complete`/`run.failSafe`), or `maxSteps` is reached.
    ///
    /// The planner is consulted with the *current* task each iteration, so it sees the world model the
    /// previous tool produced — that is what makes this a real harness loop rather than a fixed plan.
    /// `onStep`, when provided, is awaited after each executed step with that step's result. It lets a
    /// caller react to realtime loop progress (e.g. drive a cursor-path overlay toward the target the
    /// step just acted on) without the runtime knowing anything about the UI.
    @discardableResult
    public func run(
        taskID: String,
        planner: any HarnessNextStepPlanning,
        maxSteps: Int = 16,
        onStep: (@Sendable (HarnessStepExecutionResult) async -> Void)? = nil
    ) async -> [HarnessStepExecutionResult] {
        var results: [HarnessStepExecutionResult] = []
        for _ in 0..<maxSteps {
            guard let task = await coordinator.task(id: taskID), task.status.canExecuteTools else {
                break
            }
            guard let call = await planner.planNextStep(for: task) else {
                break
            }
            guard let step = await executeToolCall(taskID: taskID, call: call) else {
                break
            }
            results.append(step)
            await onStep?(step)
            if step.stoppedForGate || !step.task.status.canExecuteTools {
                break
            }
        }
        return results
    }

    public func executeToolCall(
        taskID: String,
        call: HarnessToolCall
    ) async -> HarnessStepExecutionResult? {
        guard let task = await coordinator.task(id: taskID) else { return nil }
        guard task.status.canExecuteTools || Self.canExecuteLifecycleCall(call, when: task.status) else {
            let result = HarnessToolResult(
                callID: call.id,
                toolName: call.name,
                status: .failed,
                summary: "Task is stopped and cannot execute tools.",
                metadata: [
                    "taskStatus": task.status.rawValue,
                    "reason": "taskNotExecutable"
                ]
            )
            return HarnessStepExecutionResult(
                task: task,
                toolResult: result,
                stoppedForGate: true
            )
        }

        if call.name == "user.clarify" {
            let question = call.input["question"] ?? "What detail should I use?"
            guard let stoppedTask = await coordinator.waitForUser(
                taskID: taskID,
                question: question,
                pendingToolCall: call
            ) else {
                return nil
            }
            let result = HarnessToolResult(
                callID: call.id,
                toolName: call.name,
                status: .waitingForUser,
                summary: "Task stopped for user clarification.",
                question: question,
                metadata: ["gate": "clarification"]
            )
            return HarnessStepExecutionResult(
                task: stoppedTask,
                toolResult: result,
                stoppedForGate: true
            )
        }

        if call.name == "permission.request" {
            let permission = call.input["permission"].flatMap(HarnessPermission.init(rawValue:))
            let missing = permission.map { [$0] } ?? []
            guard let stoppedTask = await coordinator.waitForPermission(
                taskID: taskID,
                missingPermissions: missing,
                pendingToolCall: call
            ) else {
                return nil
            }
            let result = HarnessToolResult(
                callID: call.id,
                toolName: call.name,
                status: .waitingForPermission,
                summary: "Task stopped for permission.",
                missingPermissions: missing,
                metadata: ["gate": "permission"]
            )
            return HarnessStepExecutionResult(
                task: stoppedTask,
                toolResult: result,
                stoppedForGate: true
            )
        }

        let result = await registry.execute(
            call,
            taskID: taskID,
            worldModel: task.worldModel,
            grantedPermissions: task.grantedPermissions
        )

        if result.status == .permissionDenied {
            guard let stoppedTask = await coordinator.waitForPermission(
                taskID: taskID,
                missingPermissions: result.missingPermissions,
                pendingToolCall: call
            ) else {
                return nil
            }
            return HarnessStepExecutionResult(
                task: stoppedTask,
                toolResult: result,
                stoppedForGate: true
            )
        }

        if result.status == .waitingForUser {
            guard let stoppedTask = await coordinator.waitForUser(
                taskID: taskID,
                question: result.question ?? "What detail should I use?",
                pendingToolCall: call
            ) else {
                return nil
            }
            return HarnessStepExecutionResult(
                task: stoppedTask,
                toolResult: result,
                stoppedForGate: true
            )
        }

        if result.status == .waitingForPermission {
            guard let stoppedTask = await coordinator.waitForPermission(
                taskID: taskID,
                missingPermissions: result.missingPermissions,
                pendingToolCall: call,
                metadata: result.metadata
            ) else {
                return nil
            }
            return HarnessStepExecutionResult(
                task: stoppedTask,
                toolResult: result,
                stoppedForGate: true
            )
        }

        guard let updatedTask = await coordinator.recordToolResult(
            taskID: taskID,
            call: call,
            result: result
        ) else {
            return nil
        }

        if let lifecycleTask = await applyLifecycleResult(
            taskID: taskID,
            call: call,
            result: result
        ) {
            return HarnessStepExecutionResult(
                task: lifecycleTask,
                toolResult: result,
                stoppedForGate: false
            )
        }

        return HarnessStepExecutionResult(
            task: updatedTask,
            toolResult: result,
            stoppedForGate: false
        )
    }

    public func executeNextPlannedStep(taskID: String) async -> HarnessStepExecutionResult? {
        guard let task = await coordinator.task(id: taskID),
              task.status.canExecuteTools,
              let step = task.plan?.steps.first(where: { step in
                  guard let call = step.toolCall else { return false }
                  return !task.toolHistory.contains { $0.call.id == call.id }
              }),
              let call = step.toolCall
        else {
            return nil
        }

        return await executeToolCall(taskID: taskID, call: call)
    }

    private func applyLifecycleResult(
        taskID: String,
        call: HarnessToolCall,
        result: HarnessToolResult
    ) async -> HarnessTaskState? {
        guard result.status == .succeeded else { return nil }
        switch call.name {
        case "run.pause":
            return await coordinator.pause(
                taskID: taskID,
                reason: call.input["reason"] ?? "Task paused by lifecycle tool"
            )
        case "run.resume":
            return await coordinator.resume(
                taskID: taskID,
                reason: call.input["reason"] ?? "Task resumed by lifecycle tool"
            )
        case "run.cancel":
            return await coordinator.cancel(
                taskID: taskID,
                reason: call.input["reason"] ?? "Task cancelled by lifecycle tool"
            )
        case "run.complete":
            return await coordinator.complete(
                taskID: taskID,
                reason: call.input["reason"] ?? "Task completed by lifecycle tool"
            )
        case "run.failSafe":
            return await coordinator.failSafe(
                taskID: taskID,
                reason: call.input["reason"] ?? "Task failed safe by lifecycle tool"
            )
        default:
            return nil
        }
    }

    private static func canExecuteLifecycleCall(
        _ call: HarnessToolCall,
        when status: HarnessTaskStatus
    ) -> Bool {
        guard call.name == "run.resume" else { return false }
        return [.paused, .interrupted].contains(status)
    }
}
