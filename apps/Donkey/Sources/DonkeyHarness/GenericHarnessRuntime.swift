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
    /// task becomes non-executable (e.g. `run.complete`/`run.failSafe`), the run stalls, or the
    /// runaway ceiling `maxSteps` is reached.
    ///
    /// Step budget is governed by *progress*, not a fixed count: a long task that keeps advancing
    /// runs to completion, while a task that spins stops fast. `maxSteps` is only a runaway backstop
    /// set far above any real task. Two stall signals end the run as a `failSafe`:
    ///
    /// - **No progress**: `maxNoProgressSteps` consecutive steps that neither change the world model
    ///   nor record a succeeded state-changing action — the loop is busy but getting nowhere.
    /// - **Exact repeat**: the same tool with the same input chosen `maxIdenticalRepeats` times — the
    ///   planner is looping on one call.
    ///
    /// The planner is consulted with the *current* task each iteration, so it sees the world model the
    /// previous tool produced — that is what makes this a real harness loop rather than a fixed plan.
    /// `onStep`, when provided, is awaited after each executed step with that step's result.
    @discardableResult
    public func run(
        taskID: String,
        planner: any HarnessNextStepPlanning,
        maxSteps: Int = 200,
        maxNoProgressSteps: Int = 6,
        maxIdenticalRepeats: Int = 3,
        onStep: (@Sendable (HarnessStepExecutionResult) async -> Void)? = nil
    ) async -> [HarnessStepExecutionResult] {
        var results: [HarnessStepExecutionResult] = []
        var noProgressStreak = 0
        var identicalNoProgressStreak = 0
        var lastCallSignature: String?
        for _ in 0..<maxSteps {
            guard let task = await coordinator.task(id: taskID), task.status.canExecuteTools else {
                break
            }
            guard let call = await planner.planNextStep(for: task) else {
                break
            }
            let signature = call.name + "\u{1}" + Self.canonicalInput(call.input)

            guard let step = await executeToolCall(taskID: taskID, call: call) else {
                break
            }
            results.append(step)
            await onStep?(step)
            if step.stoppedForGate || !step.task.status.canExecuteTools {
                break
            }

            // Stall detection — a step that changes the world or records a succeeded action is
            // progress and resets the streaks, so an arbitrarily long advancing run continues. Two
            // signals end a stuck run: enough consecutive no-progress steps (busy but going nowhere),
            // or the SAME call repeated with no progress (looping on one action). Lifecycle calls are
            // exempt from the repeat signal — they legitimately end the run themselves.
            if Self.stepMadeProgress(before: task, after: step.task, result: step.toolResult) {
                noProgressStreak = 0
                identicalNoProgressStreak = 0
            } else {
                noProgressStreak += 1
                if !call.name.hasPrefix("run."), signature == lastCallSignature {
                    identicalNoProgressStreak += 1
                } else {
                    identicalNoProgressStreak = 0
                }
                if noProgressStreak >= maxNoProgressSteps {
                    await failSafeStall(taskID: taskID, reason: "noProgress")
                    break
                }
                if identicalNoProgressStreak + 1 >= maxIdenticalRepeats {
                    await failSafeStall(taskID: taskID, reason: "stuckRepeatingCall")
                    break
                }
            }
            lastCallSignature = signature
        }
        return results
    }

    /// A step advanced the task if it changed the observed world (elements, facts, or visible text)
    /// or recorded a succeeded state-changing action. A failed step, or a re-observation that returns
    /// the same world, is no progress. Used to detect a busy-but-stuck loop.
    private static func stepMadeProgress(
        before: HarnessTaskState,
        after: HarnessTaskState,
        result: HarnessToolResult?
    ) -> Bool {
        guard let result else { return false }
        guard result.status == .succeeded else { return false }
        let worldChanged = before.worldModel.elements != after.worldModel.elements
            || before.worldModel.facts != after.worldModel.facts
            || before.worldModel.visibleText != after.worldModel.visibleText
        if worldChanged { return true }
        // A succeeded action that reports observations (a click, a shell command) counts as progress
        // even when the merged world model looks unchanged.
        return !result.observations.facts.isEmpty
            || !result.observations.elements.isEmpty
            || !result.observations.visibleText.isEmpty
    }

    /// Canonical, order-independent serialization of a tool call's input, so the same call is
    /// recognized regardless of key ordering.
    private static func canonicalInput(_ input: [String: String]) -> String {
        input.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\u{1f}")
    }

    /// Moves the task to a failed-safe stall state with a typed reason, so a stuck run ends cleanly
    /// instead of burning the whole runaway ceiling.
    private func failSafeStall(taskID: String, reason: String) async {
        _ = await coordinator.failSafe(taskID: taskID, reason: "Run stopped: \(reason).")
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

        // Completion must be evidence-backed, enforced by the runtime rather than left to prompt
        // guidance: after the last state-changing step there must be at least one later succeeded
        // step (a re-observe, read command, or verification) before run.complete is accepted.
        if call.name == "run.complete", let blocked = await completionEvidenceRejection(call: call, task: task) {
            guard let updatedTask = await coordinator.recordToolResult(
                taskID: taskID,
                call: call,
                result: blocked
            ) else {
                return nil
            }
            return HarnessStepExecutionResult(task: updatedTask, toolResult: blocked, stoppedForGate: false)
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

    /// Rejects a `run.complete` whose most recent succeeded state-changing step has no succeeded
    /// evidence step after it: acting and immediately declaring victory is exactly the unverified
    /// completion the harness must not accept. Evidence steps are read-only tools plus tools whose
    /// descriptors declare their result is itself evidence (e.g. a shell command's output and exit
    /// code). Conversation-only and pure-read tasks have no state-changing step and complete freely.
    /// Tools the registry no longer knows count as evidence so stale history can never wedge
    /// completion.
    private func completionEvidenceRejection(
        call: HarnessToolCall,
        task: HarnessTaskState
    ) async -> HarnessToolResult? {
        let descriptors = await registry.descriptors()
        let knownNames = Set(descriptors.map(\.name))
        let evidenceNames = Set(
            descriptors.filter {
                $0.safetyClass == .readOnly
                    || $0.metadata[HarnessToolDescriptor.resultIsEvidenceMetadataKey] == "true"
            }.map(\.name)
        )
        func isEvidence(_ record: HarnessToolCallRecord) -> Bool {
            evidenceNames.contains(record.call.name) || !knownNames.contains(record.call.name)
        }
        let lastActionIndex = task.toolHistory.lastIndex {
            $0.resultStatus == .succeeded && !isEvidence($0)
        }
        guard let lastActionIndex else { return nil }
        let hasEvidenceAfterAction = task.toolHistory[task.toolHistory.index(after: lastActionIndex)...]
            .contains { $0.resultStatus == .succeeded && isEvidence($0) }
        guard !hasEvidenceAfterAction else { return nil }
        return HarnessToolResult(
            callID: call.id,
            toolName: call.name,
            status: .failed,
            summary: "Not completing yet: the last action has not been verified. Run a read-only check first (re-observe, a read command, or state.verify) confirming the goal, then complete.",
            metadata: ["reason": "completionRequiresEvidence"]
        )
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
