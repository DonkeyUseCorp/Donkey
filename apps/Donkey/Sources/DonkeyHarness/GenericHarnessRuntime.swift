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

    public func executeToolCall(
        taskID: String,
        call: HarnessToolCall
    ) async -> HarnessStepExecutionResult? {
        guard let task = await coordinator.task(id: taskID) else { return nil }
        guard task.status.canExecuteTools else {
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

        guard let updatedTask = await coordinator.recordToolResult(
            taskID: taskID,
            call: call,
            result: result
        ) else {
            return nil
        }

        return HarnessStepExecutionResult(
            task: updatedTask,
            toolResult: result,
            stoppedForGate: false
        )
    }

    public func executeNextPlannedStep(taskID: String) async -> HarnessStepExecutionResult? {
        guard let task = await coordinator.task(id: taskID),
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
}
