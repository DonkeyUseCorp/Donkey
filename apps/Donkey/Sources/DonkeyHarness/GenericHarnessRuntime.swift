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
        // Whether the run performed a real, non-read ACTION — a GUI action, a write, a capability tool — as
        // opposed to only reading/scouting. Combined with a recorded deliverable, this is "the run produced
        // its result"; on its own it is what lets a FILE-LESS task (play music, answer a question, drive an
        // app) conclude even though it writes no output file.
        var performedAction = false
        var stepsSinceWorldChange = 0
        // Whether the deliverable-progress gate has already nudged this run (one-shot, so a long
        // legitimate acquisition isn't repeatedly scolded).
        var reconNudged = false
        // Names of NON-producing tools, so only a world-changing success that actually produces something
        // counts as "real work". This is every read-only tool PLUS the cacheable reads (files.describe,
        // transcribe) — those are classed `.sensitive` for permissions but are still reconnaissance, not a
        // deliverable, so they must not flip the recon done-gate's `hadRealWork`.
        let nonProducingToolNames = Set((await registry.descriptors()).filter {
            $0.safetyClass == .readOnly
                || $0.metadata[HarnessToolDescriptor.cacheableReadMetadataKey] == "true"
        }.map(\.name))

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

            // Make sure the conversation has its dedicated working directory before anything runs, then
            // project the workspace memory (working dir, files produced, promoted folder) into the world
            // model before planning so the shell's cwd and relative paths resolve there and it survives
            // compaction.
            await coordinator.ensureWorkspaceRoot(agentID: agentID)
            await coordinator.refreshWorkspaceFact(agentID: agentID)
            // Inline the small working-directory files into a fact so the planner always has them and never
            // re-reads its own inputs (the re-read loop that burned whole runs without producing anything).
            await coordinator.refreshFileContentsFact(agentID: agentID)
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
            // step-budget path. Unrecoverable give-ups (signed out, out of credits) still surface so the user
            // can act on them. The upgrade requires that the run actually PRODUCED ITS RESULT — a recorded
            // deliverable file OR a real non-read action (a GUI task, an answer, playing music, none of which
            // leave a file). A pure scout — reads and page dumps, no action, no file — still fails honestly,
            // which is what catches "read the form for a dozen steps then quit without filling it".
            var call = plannedCall
            let producedResult: Bool
            if performedAction {
                producedResult = true
            } else {
                producedResult = await coordinator.producedAnyDeliverable(agentID: agentID)
            }
            if call.name == "run.failSafe",
               !Self.isUnrecoverableFailSafe(call.input["reason"]),
               producedResult,
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
                   !nonProducingToolNames.contains(call.name) {
                    hadRealWork = true
                    // A shell READ (a listing, a page dump) flips hadRealWork but is still only scouting, so
                    // it must not count as a real action. Everything else here — a GUI action, a write, a
                    // capability tool — is genuine action a file-less task can conclude on.
                    if !Self.wasShellRead(call: call, result: step.toolResult) {
                        performedAction = true
                    }
                }
            } else {
                stepsSinceWorldChange += 1
            }
            if step.stoppedForGate || !step.task.status.canExecuteTools {
                if await coordinator.endRunUnlessPending(agentID: agentID) { break loop } else { continue loop }
            }

            // Reconnaissance done-gate. Once enough steps have passed with the run still only scouting —
            // `producedResult` is false, so no deliverable file AND no real non-read action, just reads,
            // listings, and scratch dumps — nudge once: produce the result now or report the specific
            // blocker. Keying on `producedResult` rather than `hadRealWork` is deliberate: a shell read flips
            // `hadRealWork`, so the old gate never fired for the runs that need it (scout the input for a
            // dozen steps and quit), while keying on a real action keeps it from scolding a legitimately long
            // GUI/answer task that has actually been acting. One-shot annotation, not a hard stop, so a long
            // acquisition isn't killed; the stall guards below still backstop a true loop.
            if !reconNudged, iterations >= Self.maxReconStepsBeforeNudge, !producedResult {
                reconNudged = true
                _ = await coordinator.annotateLastToolRecord(
                    agentID: agentID,
                    note: "NOTE: \(iterations) steps in and you have produced NOTHING yet — only "
                        + "reconnaissance (reading, listing, dumping to scratch files). Stop scouting and "
                        + "PRODUCE THE RESULT now from what you already have: if the task creates or fills a "
                        + "file, write it (the step with an explicit `-o`/`--output`); if it asks a question, "
                        + "give the answer. Reading or listing more is not progress. If you are genuinely "
                        + "blocked, report the specific blocker honestly instead of continuing to scout."
                )
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

    /// How many steps a run may take while producing NOTHING toward the deliverable (only reconnaissance —
    /// locating, reading, listing) before the loop nudges it to produce-or-report. The no-progress streak
    /// resets on any world-model change, so a string of distinct successful reads looks like progress and
    /// never trips it (observed: 16 steps of recon, zero fields filled). This gate watches a different
    /// thing — whether any *producing* action has happened yet — so pure scouting can't run forever.
    private static let maxReconStepsBeforeNudge = 8

    /// A `shell_exec` step that only READ — the executor stamps `shell.effect=read` for a listing, a page
    /// dump, a probe. It changes the world model and so flips `hadRealWork`, but it is reconnaissance, not a
    /// produced result, so it must not count as a real action for the done-gates. A shell command that wrote
    /// a file or had a side effect (`open`, `osascript`) is stamped `write` and does count.
    private static func wasShellRead(call: HarnessToolCall, result: HarnessToolResult?) -> Bool {
        call.name == "shell_exec" && result?.metadata["shell.effect"] == "read"
    }

    /// Ends a stalled run. A QUIET stall — the planner stopped advancing but isn't thrashing
    /// (`noProgress`) — can be a finished task that is merely re-verifying itself, so if it did real work
    /// and the goal is evidence-backed, conclude as COMPLETE rather than fail. Every OTHER stall is the
    /// planner visibly thrashing — hammering the same call, repeating a failure, or emitting invalid
    /// calls — and concluding "done" from thrashing is a false success (observed live: a clip-subtitle
    /// run that only downloaded the clip, then repeated `ffprobe`, was reported completed though nothing
    /// was ever subtitled). Thrashing stalls always fail safe — honest and retryable.
    private func failSafeStall(agentID: String, reason: String, hadRealWork: Bool) async {
        if reason == "noProgress", hadRealWork, await completionWouldBeAccepted(agentID: agentID) {
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

    /// Both halves of "you already ran this exact (tool, input) and it succeeded this run":
    ///  - a tool that OPTS IN to caching (`cacheableRead`) → serve the prior result from the run's READ
    ///    CACHE instead of re-executing, so an identical re-read costs nothing.
    ///  - a STATE-CHANGING tool → reject the repeat (re-running duplicates the side effect) and hand the
    ///    prior result back so the planner isn't blind and advances instead of looping.
    /// Caching is opt-in — and gated on the FLAG, not the safety class — because "read-only" does not imply
    /// "pure": a counter, a clock, a directory being written all read without side effects yet return
    /// different values each call, so a blanket read-only cache would serve stale data. Only a tool that
    /// declares its identical-input result stable opts in. A read whose resource a later state-changing step
    /// may have altered is re-run, not served stale. Plain read-only tools that don't opt in, a multi-action
    /// tool's declared read actions, lifecycle calls, and records from previous runs are all exempt (re-run).
    private func duplicateActionRejection(
        call: HarnessToolCall,
        task: HarnessAgentState
    ) async -> HarnessToolResult? {
        guard !call.name.hasPrefix("run."), !call.name.hasPrefix("conversation.") else { return nil }
        let descriptors = await registry.descriptors()
        let descriptor = descriptors.first { $0.name == call.name }
        let isReadOnly = descriptor?.safetyClass == .readOnly
        // Cache-eligible iff the tool explicitly asserts a stable read AND isn't a live observation. The
        // flag — not the safety class — is the gate: a pure read (a file's contents) may be classed
        // `.sensitive` for permissions yet still be safe to cache.
        let isCacheableRead = descriptor?.metadata[HarnessToolDescriptor.cacheableReadMetadataKey] == "true"
            && descriptor?.metadata[HarnessToolDescriptor.volatileResultMetadataKey] != "true"
        // A multi-action tool's read actions (list/entries style) are verification, not side
        // effects — exempt them by the descriptor's declared read-only action values, matched on
        // the typed `action` input.
        if let action = call.input["action"],
           let declared = descriptor?.metadata[HarnessToolDescriptor.readOnlyActionsMetadataKey],
           declared.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains(action) {
            return nil
        }
        // A plain read-only tool that doesn't opt into caching re-runs freely (re-reading/observing is
        // cheap and legitimately reflects fresh state).
        if isReadOnly, !isCacheableRead { return nil }
        // A VOLATILE tool re-reflects live, changed state on every call — a scrolling `content.harvest`
        // after a "load more" click, a fresh capture — so re-running it with the same input is the whole
        // point, not a redundant repeat. It is never deduped (the read cache above already exempts it; this
        // exempts it from the "already done" block below, which fires for non-read-only tools like harvest
        // and would otherwise trap the load-more→re-harvest loop into repeating "already done" forever).
        if descriptor?.metadata[HarnessToolDescriptor.volatileResultMetadataKey] == "true" { return nil }
        let signature = Self.canonicalInput(call.input)
        let runHistory = Self.currentRunHistory(task.toolHistory)
        guard let priorIndex = runHistory.lastIndex(where: { record in
            record.resultStatus == .succeeded
                && record.call.name == call.name
                && Self.canonicalInput(record.call.input) == signature
        }) else { return nil }
        let priorRecord = runHistory[priorIndex]

        // Hand the earlier RESULT back, not just "don't repeat". The planner usually re-runs a call
        // because its result fell out of the compacted context — so withholding it leaves the planner
        // blind and it loops on the same call until the stall guard kills the run (observed live: a
        // clip-subtitle run re-ran `ffprobe` three times and was then wrongly concluded done). Surfacing
        // the prior output gives the planner what it was after so it can move on. Bounded so a large
        // listing can't bloat the next prompt.
        let priorOutput = priorRecord.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        // Echo the prior result with a generous bound. When it is clipped, say WHY in the same terms the
        // planner prompt uses for trimmed history: the full output is already captured and re-running won't
        // lengthen this view. A bare "[truncated]" marker reads as a truncated FILE and sends the planner
        // re-reading the same content through ever-fancier commands — the loop this echo exists to stop.
        let dedupEchoMaxLength = 2_000
        let echoBody = priorOutput.count > dedupEchoMaxLength
            ? String(priorOutput.prefix(dedupEchoMaxLength))
                + " …[view trimmed; the full \(priorOutput.count)-char output is already captured — "
                + "re-running this read will NOT lengthen it]"
            : priorOutput
        let resultBlock = priorOutput.isEmpty
            ? ""
            : " It already returned:\n\(echoBody)\n"

        if isCacheableRead {
            // Read cache. Only serve the cached value when nothing the run has done since could have
            // changed what this read sees: a succeeded state-changing step in between means the resource
            // may differ now, so let it re-run rather than serve stale.
            let readOnlyNames = Set(descriptors.filter { $0.safetyClass == .readOnly }.map(\.name))
            let stateChangedSince = runHistory[runHistory.index(after: priorIndex)...].contains { record in
                record.resultStatus == .succeeded
                    && !record.call.name.hasPrefix("run.")
                    && !record.call.name.hasPrefix("conversation.")
                    && !readOnlyNames.contains(record.call.name)
            }
            if stateChangedSince { return nil }
            return HarnessToolResult(
                callID: call.id,
                toolName: call.name,
                status: .succeeded,
                summary: "Served from this run's read cache: `\(call.name)` already ran with this exact input and nothing you've done since changes what it sees.\(resultBlock)Use this; don't re-read it.",
                metadata: ["reason": "readCacheHit", "servedFromCache": "true"]
            )
        }

        return HarnessToolResult(
            callID: call.id,
            toolName: call.name,
            status: .failed,
            summary: "Already done: `\(call.name)` ran with this exact input and succeeded earlier in this run.\(resultBlock)You already have this result — do not run it again. Take the next action toward the goal; only run.complete once the goal itself is met and verified.",
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
