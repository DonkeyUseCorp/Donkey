import Foundation

public struct HarnessStepExecutionResult: Equatable, Sendable {
    public var task: HarnessAgentState
    public var toolResult: HarnessToolResult?
    public var stoppedForGate: Bool

    public init(
        task: HarnessAgentState,
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
    func planNextStep(for task: HarnessAgentState, rollingContext: String?) async -> HarnessToolCall?
}

public extension HarnessNextStepPlanning {
    /// Convenience for callers without rolling conversation context (e.g. tests).
    func planNextStep(for task: HarnessAgentState) async -> HarnessToolCall? {
        await planNextStep(for: task, rollingContext: nil)
    }
}

/// Produces the bounded rolling context — recent conversation events plus a rolling summary of older
/// turns — that a step's planner prompt carries, so a long conversation stays coherent without resending
/// its whole history. When the rolling context grows past the policy threshold the implementation writes
/// a fresh summary event back into the conversation, so subsequent steps read the digest, not the raw
/// older turns. The full record on disk is never touched. Returns nil when there is nothing to carry.
public protocol HarnessConversationCompacting: Sendable {
    func rollingContext(agentID: String) async -> String?
}

public struct GenericHarnessRuntime: Sendable {
    public var coordinator: HarnessAgentCoordinator
    public var registry: HarnessToolRegistry

    public init(
        coordinator: HarnessAgentCoordinator,
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
        agentID: String,
        planner: any HarnessNextStepPlanning,
        maxSteps: Int = 200,
        maxNoProgressSteps: Int = 6,
        maxIdenticalRepeats: Int = 3,
        maxRepeatedFailures: Int = 3,
        compactor: (any HarnessConversationCompacting)? = nil,
        onStep: (@Sendable (HarnessStepExecutionResult) async -> Void)? = nil
    ) async -> [HarnessStepExecutionResult] {
        var results: [HarnessStepExecutionResult] = []
        var noProgressStreak = 0
        var identicalNoProgressStreak = 0
        var lastCallSignature: String?
        var iterations = 0
        // Whether the run did real work — a step that BOTH changed the world model AND came from a
        // non-read-only tool (a produced file, a changed app state), not a read/verify — and how many steps
        // in a row left the world unchanged. Together they decide a spinning run's outcome: a run that did
        // real work and is now only re-reading/re-verifying (or whose planner gave up) should CONCLUDE as
        // completed, not time out or fail safe. Requiring BOTH conditions is deliberate: a read that merely
        // reports observations (re-listing, re-verifying) is not real work, so a stuck explorer that never
        // produced anything still fails safe — the stall guard's guarantee is preserved.
        var hadRealWork = false
        var stepsSinceWorldChange = 0
        // Names of read-only tools, so only a world-changing NON-read-only success counts as real work.
        let readOnlyToolNames = Set((await registry.descriptors()).filter { $0.safetyClass == .readOnly }.map(\.name))

        // Mark this task as having a live loop. While marked, an enqueued follow-up is guaranteed delivery:
        // it is drained at the top of each iteration, and the only stop that actually ends the run is one
        // where `endRunUnlessPending` confirms the queue is empty in the same actor step. A follow-up that
        // slips in at any stop reopens the run for one more pass instead of being silently dropped.
        await coordinator.beginRun(agentID: agentID)

        loop: while true {
            // Fold any queued follow-up into the world model before planning. A fresh instruction resets
            // the no-progress streak (legitimately new work) but NOT the identical-repeat guard, so a
            // planner looping on one call is still caught; it also reopens a task whose previous step had
            // already finished the run, so the new instruction is acted on rather than dropped.
            if !(await coordinator.drainUserMessages(agentID: agentID)).isEmpty {
                noProgressStreak = 0
                await coordinator.reopenForFollowUp(agentID: agentID)
            }

            // Step-budget reached. Borrowed from a computer-use loop's "do the work, verify, then stop":
            // if the run did real work and is now only SPINNING (several steps with no world change — i.e.
            // re-verifying) and completion is evidence-backed, the goal is met, so COMPLETE rather than
            // report a timeout. A run still changing the world each step (genuinely advancing) times out and
            // stays retryable; so does one that changed nothing at all (stuck exploring).
            if iterations >= maxSteps {
                if hadRealWork,
                   stepsSinceWorldChange >= Self.spinStepsBeforeConclude,
                   await completionWouldBeAccepted(agentID: agentID) {
                    _ = await coordinator.complete(
                        agentID: agentID,
                        reason: "Reached the step budget with the goal already produced and verified."
                    )
                } else {
                    await coordinator.timeOutIfRunnable(agentID: agentID, reason: "maxStepsReached")
                }
                await coordinator.markLoopEnded(agentID: agentID)
                break loop
            }
            iterations += 1

            guard let task = await coordinator.agent(id: agentID), task.status.canExecuteTools else {
                if await coordinator.endRunUnlessPending(agentID: agentID) { break loop } else { continue loop }
            }
            // Compact before planning: fold older turns into a rolling summary when the conversation has
            // grown past the threshold, and hand the planner the bounded recent-events-plus-summary view.
            let rollingContext = await compactor?.rollingContext(agentID: agentID)
            guard let plannedCall = await planner.planNextStep(for: task, rollingContext: rollingContext) else {
                // The planner stopped without a lifecycle call: an abnormal stop, not a timeout.
                await coordinator.failSafeIfRunnable(agentID: agentID, reason: "plannerStopped")
                if await coordinator.endRunUnlessPending(agentID: agentID) { break loop } else { continue loop }
            }
            // A planner that gives up (run.failSafe) AFTER the goal is already produced and verified should
            // COMPLETE, not fail — the work exists; only the next decision didn't render (e.g. a transient
            // run of empty model replies). The same "do the work, verify, then conclude" rule as the
            // step-budget path. Unrecoverable give-ups (signed out, out of credits) still surface so the
            // user can act on them; a give-up with no real work done still fails.
            var call = plannedCall
            if call.name == "run.failSafe",
               !Self.isUnrecoverableFailSafe(call.input["reason"]),
               hadRealWork,
               await completionWouldBeAccepted(agentID: agentID) {
                call = HarnessToolCall(
                    name: "run.complete",
                    input: ["reason": "Goal produced and verified; finalizing despite a transient planning failure."]
                )
            }
            let signature = call.name + "\u{1}" + Self.canonicalInput(call.input)

            guard let step = await executeToolCall(agentID: agentID, call: call) else {
                await coordinator.failSafeIfRunnable(agentID: agentID, reason: "executeFailed")
                if await coordinator.endRunUnlessPending(agentID: agentID) { break loop } else { continue loop }
            }
            results.append(step)
            await onStep?(step)
            let stepChangedWorld = Self.worldChanged(from: task, to: step.task)
            if stepChangedWorld {
                stepsSinceWorldChange = 0
                if step.toolResult?.status == .succeeded,
                   !call.name.hasPrefix("run."),
                   !readOnlyToolNames.contains(call.name) {
                    hadRealWork = true
                }
            } else {
                stepsSinceWorldChange += 1
            }
            if step.stoppedForGate || !step.task.status.canExecuteTools {
                if await coordinator.endRunUnlessPending(agentID: agentID) { break loop } else { continue loop }
            }

            // Stall detection — a step that changes the world or records a succeeded action is
            // progress and resets the streaks, so an arbitrarily long advancing run continues. Three
            // signals end a stuck run: enough consecutive no-progress steps (busy but going nowhere),
            // the SAME call repeated with no progress (looping on one action), or — over the whole
            // tool history, immune to interleaved successes and varied input fields — the same tool
            // failing the same way again and again, or a trailing run of invalid calls across any
            // tools. Lifecycle calls are exempt from the repeat signal — they legitimately end the
            // run themselves.
            let repeatedSameCall = signature == lastCallSignature
            if Self.stepMadeProgress(
                before: task,
                after: step.task,
                result: step.toolResult,
                repeatedSameCall: repeatedSameCall
            ) {
                noProgressStreak = 0
                identicalNoProgressStreak = 0
            } else {
                noProgressStreak += 1
                if !call.name.hasPrefix("run."), signature == lastCallSignature {
                    identicalNoProgressStreak += 1
                    // One deterministic warning before the stall guard ends the run: annotate the
                    // repeated record so the next planning prompt shows the model it is re-running
                    // what it already knows (observed live: a planner re-read identical playlist
                    // entries out of disbelief until the guard killed the run).
                    _ = await coordinator.annotateLastToolRecord(
                        agentID: agentID,
                        note: "NOTE: this exact call already ran and returned the same result — you "
                            + "already have this information. Do not repeat it; take the next action "
                            + "toward the goal, or report the blocker honestly."
                    )
                } else {
                    identicalNoProgressStreak = 0
                }
                if noProgressStreak >= maxNoProgressSteps {
                    await failSafeStall(agentID: agentID, reason: "noProgress", hadRealWork: hadRealWork)
                    if await coordinator.endRunUnlessPending(agentID: agentID) { break loop } else { continue loop }
                }
                if identicalNoProgressStreak + 1 >= maxIdenticalRepeats {
                    await failSafeStall(agentID: agentID, reason: "stuckRepeatingCall", hadRealWork: hadRealWork)
                    if await coordinator.endRunUnlessPending(agentID: agentID) { break loop } else { continue loop }
                }
                if let reason = Self.repeatedFailureStallReason(after: step, threshold: maxRepeatedFailures) {
                    await failSafeStall(agentID: agentID, reason: reason, hadRealWork: hadRealWork)
                    if await coordinator.endRunUnlessPending(agentID: agentID) { break loop } else { continue loop }
                }
            }
            lastCallSignature = signature
        }
        return results
    }

    /// Whether a `run.failSafe` reason is one the user must see rather than have silently turned into a
    /// completion — an expired session or a spent balance. Matched on the harness-generated reason CODE
    /// (a typed technical field set by the planner's fail-safe path), never on user text. Any other
    /// give-up reason is recoverable-into-completion when the goal is already done + evidenced.
    private static func isUnrecoverableFailSafe(_ reason: String?) -> Bool {
        guard let reason else { return false }
        return reason == "sessionSignedOut" || reason == "insufficientCredits"
    }

    /// Whether the world model the planner reasons over changed across a step — new/changed elements,
    /// facts, or visible text. This is "did something actually happen" independent of any tool's
    /// self-reported observations, so it stays true real work occurred even when later steps only re-read.
    private static func worldChanged(from before: HarnessAgentState, to after: HarnessAgentState) -> Bool {
        before.worldModel.elements != after.worldModel.elements
            || before.worldModel.facts != after.worldModel.facts
            || before.worldModel.visibleText != after.worldModel.visibleText
    }

    /// Whether a `run.complete` issued right now would pass the completion-evidence gate — i.e. the goal is
    /// already evidence-backed. Used by the step-budget path to decide complete-vs-timeout.
    private func completionWouldBeAccepted(agentID: String) async -> Bool {
        guard let task = await coordinator.agent(id: agentID) else { return false }
        let synthetic = HarnessToolCall(name: "run.complete", input: [:])
        return await completionEvidenceRejection(call: synthetic, task: task) == nil
    }

    /// A step advanced the task if it changed the observed world (elements, facts, or visible text)
    /// or recorded a succeeded state-changing action. A failed step, or a re-observation that returns
    /// the same world, is no progress. Used to detect a busy-but-stuck loop.
    private static func stepMadeProgress(
        before: HarnessAgentState,
        after: HarnessAgentState,
        result: HarnessToolResult?,
        repeatedSameCall: Bool
    ) -> Bool {
        guard let result else { return false }
        guard result.status == .succeeded else { return false }
        let worldChanged = before.worldModel.elements != after.worldModel.elements
            || before.worldModel.facts != after.worldModel.facts
            || before.worldModel.visibleText != after.worldModel.visibleText
        if worldChanged { return true }
        // Repeating the exact same call and learning nothing new is not progress, no matter what
        // the result reports — observed live: nine identical succeeded playlist-list reads, each
        // returning the same facts, kept resetting the streaks until the model hallucinated
        // completion.
        if repeatedSameCall { return false }
        // A succeeded action that reports observations (a click, a shell command) counts as progress
        // even when the merged world model looks unchanged.
        return !result.observations.facts.isEmpty
            || !result.observations.elements.isEmpty
            || !result.observations.visibleText.isEmpty
    }

    /// Repeated-failure detection over the task's durable tool history, so it survives interleaved
    /// successes that reset the consecutive streaks. Matches only typed fields — tool names, result
    /// statuses, and tool-produced failure summaries (structured output, never user text). Catches
    /// two loops the consecutive-signature guard misses: the same tool failing the same way with
    /// other calls interleaved or minor input fields varied, and invalid calls alternating between
    /// tools. Summaries that embed variable data (positions, timestamps) won't match — acceptable;
    /// the streak guards remain the backstop.
    private static func repeatedFailureStallReason(
        after step: HarnessStepExecutionResult,
        threshold: Int
    ) -> String? {
        guard let result = step.toolResult,
              result.status == .failed || result.status == .invalidInput else { return nil }
        let history = Self.currentRunHistory(step.task.toolHistory)
        let identicalFailures = history.filter {
            $0.call.name == result.toolName
                && ($0.resultStatus == .failed || $0.resultStatus == .invalidInput)
                && $0.summary == result.summary
        }.count
        if identicalFailures >= threshold { return "stuckRepeatingFailure" }
        let trailingInvalidInput = history.reversed().prefix { $0.resultStatus == .invalidInput }.count
        if trailingInvalidInput >= threshold { return "repeatedInvalidInput" }
        return nil
    }

    /// The slice of tool history belonging to the current run: everything after the last succeeded
    /// terminal call (see `BuiltInHarnessToolCatalog.terminalToolNames`). A task resumed for a new
    /// user turn keeps its full history for context, but guards that reason about "this run" —
    /// duplicate actions, repeated failures — must not match records from a run that already ended.
    private static func currentRunHistory(_ history: [HarnessToolCallRecord]) -> ArraySlice<HarnessToolCallRecord> {
        guard let lastTerminal = history.lastIndex(where: {
            BuiltInHarnessToolCatalog.terminalToolNames.contains($0.call.name) && $0.resultStatus == .succeeded
        }) else { return history[...] }
        return history[history.index(after: lastTerminal)...]
    }

    /// Canonical, order-independent serialization of a tool call's input, so the same call is
    /// recognized regardless of key ordering.
    private static func canonicalInput(_ input: [String: String]) -> String {
        input.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\u{1f}")
    }

    /// How many consecutive no-world-change steps mark a run as "spinning" rather than advancing — used
    /// by the step-budget path to tell re-verification (conclude) from genuine progress (time out).
    private static let spinStepsBeforeConclude = 3

    /// Ends a stalled run. The stall guard firing already means the planner is spinning — so if it did
    /// real work and the goal is evidence-backed, that spin is just re-verification of a finished task:
    /// COMPLETE instead of failing safe. Otherwise (nothing produced, or no evidence the goal holds) it
    /// is a genuine stuck run and ends failed-safe, staying retryable.
    private func failSafeStall(agentID: String, reason: String, hadRealWork: Bool) async {
        if hadRealWork, await completionWouldBeAccepted(agentID: agentID) {
            _ = await coordinator.complete(
                agentID: agentID,
                reason: "Goal produced and verified; finalizing after the planner kept re-verifying (\(reason))."
            )
        } else {
            _ = await coordinator.failSafe(agentID: agentID, reason: "Run stopped: \(reason).")
        }
    }

    public func executeToolCall(
        agentID: String,
        call: HarnessToolCall
    ) async -> HarnessStepExecutionResult? {
        guard let task = await coordinator.agent(id: agentID) else { return nil }
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
            let result = HarnessToolResult(
                callID: call.id,
                toolName: call.name,
                status: .waitingForUser,
                summary: "Task stopped for user clarification.",
                question: question,
                metadata: ["gate": "clarification"]
            )
            // Record the ask in tool history before entering the gate, so the run's history shows the
            // planner chose to clarify (decisions stay inspectable) and a resume sees a non-empty history —
            // which keeps the planner's first-step clarify guard from re-firing after the user answers.
            _ = await coordinator.recordToolResult(agentID: agentID, call: call, result: result)
            guard let stoppedTask = await coordinator.waitForUser(
                agentID: agentID,
                question: question,
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

        if call.name == "permission.request" {
            let permission = call.input["permission"].flatMap(HarnessPermission.init(rawValue:))
            let missing = permission.map { [$0] } ?? []
            guard let stoppedTask = await coordinator.waitForPermission(
                agentID: agentID,
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
                agentID: agentID,
                call: call,
                result: blocked
            ) else {
                return nil
            }
            return HarnessStepExecutionResult(task: updatedTask, toolResult: blocked, stoppedForGate: false)
        }

        // Don't re-run a state-changing action that already succeeded with the exact same input —
        // that just duplicates the effect (e.g. creating the same note 16 times). Block it before it
        // executes and tell the planner to verify and complete instead. Read-only tools are exempt
        // (re-observing is idempotent and useful).
        if let blocked = await duplicateActionRejection(call: call, task: task) {
            guard let updatedTask = await coordinator.recordToolResult(
                agentID: agentID,
                call: call,
                result: blocked
            ) else {
                return nil
            }
            return HarnessStepExecutionResult(task: updatedTask, toolResult: blocked, stoppedForGate: false)
        }

        let result = await registry.execute(
            call,
            agentID: agentID,
            worldModel: task.worldModel,
            grantedPermissions: task.grantedPermissions
        )

        if result.status == .permissionDenied {
            guard let stoppedTask = await coordinator.waitForPermission(
                agentID: agentID,
                missingPermissions: result.missingPermissions,
                pendingToolCall: call,
                reason: HarnessPermission.permissionRequestSummary(for: result.missingPermissions)
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
                agentID: agentID,
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
                agentID: agentID,
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
            agentID: agentID,
            call: call,
            result: result
        ) else {
            return nil
        }

        if let lifecycleTask = await applyLifecycleResult(
            agentID: agentID,
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

    public func executeNextPlannedStep(agentID: String) async -> HarnessStepExecutionResult? {
        guard let task = await coordinator.agent(id: agentID),
              task.status.canExecuteTools,
              let step = task.plan?.steps.first(where: { step in
                  guard let call = step.toolCall else { return false }
                  return !task.toolHistory.contains { $0.call.id == call.id }
              }),
              let call = step.toolCall
        else {
            return nil
        }

        return await executeToolCall(agentID: agentID, call: call)
    }

    /// Rejects a `run.complete` whose most recent succeeded state-changing step has no succeeded
    /// evidence step after it: acting and immediately declaring victory is exactly the unverified
    /// completion the harness must not accept. Evidence steps are read-only tools plus tools whose
    /// descriptors declare their result is itself evidence (e.g. a shell command's output and exit
    /// code). Conversation-only and pure-read tasks have no state-changing step and complete freely.
    /// Tools the registry no longer knows count as evidence so stale history can never wedge
    /// completion. Both rules are scoped to the CURRENT run: a fresh turn on a resumed task must
    /// observe at least once before completing — world-model facts carried over from a previous run
    /// can be stale (observed live: the agent re-completed "create a playlist" from old facts after
    /// the user had deleted the playlist).
    private func completionEvidenceRejection(
        call: HarnessToolCall,
        task: HarnessAgentState
    ) async -> HarnessToolResult? {
        let history = Self.currentRunHistory(task.toolHistory)
        if !task.toolHistory.isEmpty, !history.contains(where: { $0.resultStatus == .succeeded }) {
            return HarnessToolResult(
                callID: call.id,
                toolName: call.name,
                status: .failed,
                summary: "Not completing yet: nothing has been verified in this run — facts carried "
                    + "over from a previous run may be stale. Run a read-only check confirming the "
                    + "goal still holds (re-observe, a read command, or state.verify), then complete.",
                metadata: ["reason": "completionRequiresEvidence"]
            )
        }
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
        let lastActionIndex = history.lastIndex {
            $0.resultStatus == .succeeded && !isEvidence($0)
        }
        guard let lastActionIndex else { return nil }
        let hasEvidenceAfterAction = history[history.index(after: lastActionIndex)...]
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

    /// Rejects a state-changing call whose exact (tool, input) already succeeded earlier in this run —
    /// re-running it only duplicates the side effect. Read-only tools, a multi-action tool's declared
    /// read actions, lifecycle calls, and records from previous runs of a resumed task are exempt.
    /// Returns a failed result that tells the planner to verify and complete instead of repeating.
    private func duplicateActionRejection(
        call: HarnessToolCall,
        task: HarnessAgentState
    ) async -> HarnessToolResult? {
        guard !call.name.hasPrefix("run."), !call.name.hasPrefix("conversation.") else { return nil }
        let descriptors = await registry.descriptors()
        let readOnlyNames = Set(descriptors.filter { $0.safetyClass == .readOnly }.map(\.name))
        guard !readOnlyNames.contains(call.name) else { return nil }
        // A multi-action tool's read actions (list/entries style) are verification, not side
        // effects — exempt them by the descriptor's declared read-only action values, matched on
        // the typed `action` input.
        if let action = call.input["action"],
           let declared = descriptors.first(where: { $0.name == call.name })?
               .metadata[HarnessToolDescriptor.readOnlyActionsMetadataKey],
           declared.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains(action) {
            return nil
        }
        let signature = Self.canonicalInput(call.input)
        let alreadySucceeded = Self.currentRunHistory(task.toolHistory).contains { record in
            record.resultStatus == .succeeded
                && record.call.name == call.name
                && Self.canonicalInput(record.call.input) == signature
        }
        guard alreadySucceeded else { return nil }
        return HarnessToolResult(
            callID: call.id,
            toolName: call.name,
            status: .failed,
            summary: "Already done: `\(call.name)` ran with this exact input and succeeded earlier in this run. Repeating it duplicates the effect. Verify the result (a read/observe or state.verify), then run.complete — do not run this again.",
            metadata: ["reason": "duplicateAction"]
        )
    }

    private func applyLifecycleResult(
        agentID: String,
        call: HarnessToolCall,
        result: HarnessToolResult
    ) async -> HarnessAgentState? {
        guard result.status == .succeeded else { return nil }
        switch call.name {
        case "run.pause":
            return await coordinator.pause(
                agentID: agentID,
                reason: call.input["reason"] ?? "Task paused by lifecycle tool"
            )
        case "run.resume":
            return await coordinator.resume(
                agentID: agentID,
                reason: call.input["reason"] ?? "Task resumed by lifecycle tool"
            )
        case "run.cancel":
            return await coordinator.cancel(
                agentID: agentID,
                reason: call.input["reason"] ?? "Task cancelled by lifecycle tool"
            )
        case "run.complete":
            return await coordinator.complete(
                agentID: agentID,
                reason: call.input["reason"] ?? "Task completed by lifecycle tool"
            )
        case "conversation.respond":
            // A chat reply ends its turn: complete the run so the planner can't loop re-issuing the same
            // answer until the stall guard fails it safe. Conversation-only turns have no state-changing
            // step, so this bypasses the completion-evidence gate the same way a pure-read task does.
            return await coordinator.complete(
                agentID: agentID,
                reason: "Task completed by conversation response"
            )
        case "run.failSafe":
            return await coordinator.failSafe(
                agentID: agentID,
                reason: call.input["reason"] ?? "Task failed safe by lifecycle tool"
            )
        default:
            return nil
        }
    }

    private static func canExecuteLifecycleCall(
        _ call: HarnessToolCall,
        when status: HarnessAgentStatus
    ) -> Bool {
        guard call.name == "run.resume" else { return false }
        return [.paused, .interrupted, .timedOut].contains(status)
    }
}
