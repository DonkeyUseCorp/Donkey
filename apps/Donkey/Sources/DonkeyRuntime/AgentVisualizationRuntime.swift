import DonkeyContracts
import Foundation

public enum LocalAppTaskAgentVisualizationBuilder {
    public static func projectedPlan(
        command: String,
        traceID: String,
        resolution: LocalAppTaskCatalogResolution
    ) -> AgentVisualizationPlan? {
        guard resolution.status == .resolved,
              let definition = resolution.definition
        else {
            return nil
        }

        let workflowSteps = definition.workflowSteps.isEmpty
            ? fallbackWorkflowSteps(for: definition)
            : definition.workflowSteps
        let steps = workflowSteps.enumerated().map { index, workflowStep in
            projectedStep(
                from: workflowStep,
                index: index,
                definition: definition
            )
        }
        guard !steps.isEmpty else { return nil }

        var metadata = [
            "source": "local-app-projected-workflow",
            "targetApp": definition.targetApp.appName,
            "taskType": definition.taskType,
            "resolution.status": resolution.status.rawValue,
            "realPointerMoved": "false",
            "grounding.source": AgentVisualizationGroundingSource.dryRun.rawValue,
            "workflowStage": "preExecution"
        ].merging(resolution.metadata) { current, _ in current }

        if let intent = resolution.intent {
            metadata["intent.id"] = intent.intentID
            metadata["intent.confidence"] = String(intent.confidence)
            metadata["intent.entityNames"] = intent.entities.keys.sorted().joined(separator: ",")
        }
        if !command.isEmpty {
            metadata["command.present"] = "true"
        }

        return AgentVisualizationPlan(
            id: "agent-visualization-\(traceID)-projected",
            title: "Working in \(definition.targetApp.appName)",
            executionMode: .live,
            sourceTraceID: traceID,
            steps: steps,
            verification: AgentVisualizationVerificationReport(
                status: .unverified,
                summary: "Execution is still in progress.",
                confidence: 0,
                evidenceCount: 0,
                metadata: ["workflowStage": "preExecution"]
            ),
            metadata: metadata
        )
    }

    public static func plan(
        for result: LocalAppTaskLiveRunResult,
        sourceTraceID: String? = nil
    ) -> AgentVisualizationPlan? {
        guard let definition = result.resolution.definition else { return nil }

        let evidencePlan = result.finalPlan ?? result.initialPlan
        var steps = (evidencePlan?.steps ?? []).enumerated().map { index, dryRunStep in
            visualizationStep(
                from: dryRunStep,
                index: index,
                definition: definition,
                actionTrace: matchingTrace(for: dryRunStep, in: result.actionTraces)
            )
        }

        let dryRunStepIDs = Set((evidencePlan?.steps ?? []).map(\.id))
        let extraTraceSteps = result.actionTraces
            .filter { trace in
                guard let workflowStepID = trace.command.metadata["workflowStepID"] else { return true }
                return !dryRunStepIDs.contains(workflowStepID)
            }
            .enumerated()
            .map { offset, trace in
                actionTraceStep(
                    trace,
                    index: steps.count + offset,
                    definition: definition
                )
            }
        steps.append(contentsOf: extraTraceSteps)

        guard !steps.isEmpty else { return nil }

        let verification = verificationReport(for: result)
        return AgentVisualizationPlan(
            id: "agent-visualization-\(result.traceID)",
            title: title(for: result, definition: definition),
            executionMode: .live,
            sourceTraceID: sourceTraceID ?? result.traceID,
            steps: steps,
            verification: verification,
            metadata: [
                "source": "local-app-live-runner",
                "targetApp": definition.targetApp.appName,
                "taskType": definition.taskType,
                "realPointerMoved": "false",
                "actionTraceCount": String(result.actionTraces.count),
                "workflowStageCount": String(result.workflowProgress.stages.count)
            ].merging(result.metadata.filter { key, _ in
                key.hasPrefix("latency.") || key.hasPrefix("verification.")
            }) { current, _ in current }
        )
    }

    private static func projectedStep(
        from step: LocalAppTaskWorkflowStepDefinition,
        index: Int,
        definition: LocalAppTaskDefinition
    ) -> AgentVisualizationStep {
        let metadata = step.metadata.merging([
            "workflow.stepID": step.id,
            "workflow.stepRole": step.role.rawValue,
            "targetApp": definition.targetApp.appName,
            "projection.status": LocalAppTaskStepStatus.projected.rawValue
        ]) { current, _ in current }

        return AgentVisualizationStep(
            id: step.id,
            kind: kind(for: step.role),
            label: label(for: step.role, summary: step.summary),
            target: AgentVisualizationStepTarget(
                point: targetPoint(for: step.role, index: index),
                description: step.summary,
                controlID: step.metadata["controlID"],
                source: .dryRun,
                confidence: 0.58,
                metadata: metadata
            ),
            travelDuration: duration(for: step.role).travel,
            holdDuration: duration(for: step.role).hold,
            metadata: metadata
        )
    }

    private static func visualizationStep(
        from step: LocalAppTaskDryRunStep,
        index: Int,
        definition: LocalAppTaskDefinition,
        actionTrace: ActionEngineCommandTrace?
    ) -> AgentVisualizationStep {
        var metadata = step.metadata.merging([
            "dryRun.stepID": step.id,
            "dryRun.stepRole": step.role.rawValue,
            "dryRun.stepStatus": step.status.rawValue,
            "targetApp": definition.targetApp.appName
        ]) { current, _ in current }

        if let actionTrace {
            metadata.merge(actionTraceMetadata(actionTrace)) { current, _ in current }
        }

        return AgentVisualizationStep(
            id: step.id,
            kind: kind(for: step.role),
            label: label(for: step),
            target: AgentVisualizationStepTarget(
                point: targetPoint(for: step.role, index: index),
                description: step.summary,
                controlID: step.metadata["controlID"],
                source: actionTrace == nil ? .dryRun : .actionTrace,
                confidence: confidence(for: step.status, actionTrace: actionTrace),
                metadata: metadata
            ),
            travelDuration: duration(for: step.role).travel,
            holdDuration: duration(for: step.role).hold,
            metadata: metadata
        )
    }

    private static func actionTraceStep(
        _ trace: ActionEngineCommandTrace,
        index: Int,
        definition: LocalAppTaskDefinition
    ) -> AgentVisualizationStep {
        let role = trace.command.metadata["workflowStepRole"] ?? "custom"
        let label = trace.executed ? "Acted safely" : "Checked action safety"
        var metadata = actionTraceMetadata(trace)
        metadata["targetApp"] = definition.targetApp.appName
        metadata["workflowStepRole"] = role

        return AgentVisualizationStep(
            id: trace.command.id,
            kind: kind(forActionTraceRole: role),
            label: label,
            target: AgentVisualizationStepTarget(
                point: centerPoint(for: trace.command.targetBounds) ?? fallbackPoint(index: index),
                bounds: trace.command.targetBounds,
                description: trace.command.metadata["workflowStepID"] ?? trace.command.id,
                controlID: trace.command.metadata["controlID"],
                source: .actionTrace,
                confidence: trace.executed ? 0.88 : 0.45,
                metadata: metadata
            ),
            travelDuration: 0.55,
            holdDuration: 1.0,
            metadata: metadata
        )
    }

    private static func matchingTrace(
        for step: LocalAppTaskDryRunStep,
        in traces: [ActionEngineCommandTrace]
    ) -> ActionEngineCommandTrace? {
        traces.first { trace in
            trace.command.metadata["workflowStepID"] == step.id
        }
    }

    private static func verificationReport(
        for result: LocalAppTaskLiveRunResult
    ) -> AgentVisualizationVerificationReport {
        let status: AgentVisualizationVerificationStatus
        switch result.status {
        case .completed:
            status = .verified
        case .needsUserReview, .needsConfirmation:
            status = .needsReview
        case .appUnavailable, .unsupportedCommand:
            status = .blocked
        case .failedSafe:
            status = .failed
        }

        let verificationStep = result.finalPlan?.steps.first(where: { $0.role == .verifyResult })
            ?? result.initialPlan?.steps.first(where: { $0.role == .verifyResult })
        let confidence = result.finalPlan?.verificationConfidence
            ?? result.initialPlan?.verificationConfidence
            ?? 0
        return AgentVisualizationVerificationReport(
            status: status,
            summary: verificationStep?.summary ?? result.status.rawValue,
            confidence: confidence,
            evidenceCount: result.actionTraces.count + (result.observation == nil ? 0 : 1),
            metadata: (verificationStep?.metadata ?? [:]).merging([
                "liveRun.status": result.status.rawValue
            ]) { current, _ in current }
        )
    }

    private static func title(
        for result: LocalAppTaskLiveRunResult,
        definition: LocalAppTaskDefinition
    ) -> String {
        if result.status == .completed {
            return "Did \(definition.targetApp.appName)"
        }
        return "Worked in \(definition.targetApp.appName)"
    }

    private static func label(for step: LocalAppTaskDryRunStep) -> String {
        label(for: step.role, summary: step.summary)
    }

    private static func label(
        for role: LocalAppTaskStepRole,
        summary: String
    ) -> String {
        switch role {
        case .parseIntent:
            return "Planning the task"
        case .launchOrFocusApp:
            return "Opening the app"
        case .observeApp:
            return "Checking the screen"
        case .focusControl:
            return "Finding the control"
        case .enterText:
            return "Entering text"
        case .submit:
            return "Submitting"
        case .verifyResult:
            return "Verifying the result"
        case .custom:
            return summary
        }
    }

    private static func kind(for role: LocalAppTaskStepRole) -> AgentVisualizationStepKind {
        switch role {
        case .parseIntent:
            return .plan
        case .launchOrFocusApp:
            return .navigate
        case .observeApp:
            return .observe
        case .focusControl:
            return .focusControl
        case .enterText:
            return .enterText
        case .submit:
            return .submit
        case .verifyResult:
            return .verify
        case .custom:
            return .moveToTarget
        }
    }

    private static func kind(forActionTraceRole role: String) -> AgentVisualizationStepKind {
        switch role {
        case LocalAppTaskStepRole.focusControl.rawValue:
            return .focusControl
        case LocalAppTaskStepRole.enterText.rawValue:
            return .enterText
        case LocalAppTaskStepRole.submit.rawValue:
            return .submit
        default:
            return .moveToTarget
        }
    }

    private static func confidence(
        for status: LocalAppTaskStepStatus,
        actionTrace: ActionEngineCommandTrace?
    ) -> Double {
        if actionTrace?.executed == true { return 0.9 }
        switch status {
        case .verified:
            return 0.84
        case .projected:
            return 0.58
        case .blocked:
            return 0.2
        }
    }

    private static func duration(for role: LocalAppTaskStepRole) -> (travel: TimeInterval, hold: TimeInterval) {
        switch role {
        case .enterText:
            return (0.45, 1.0)
        case .submit:
            return (0.35, 0.8)
        case .verifyResult:
            return (0.6, 1.2)
        default:
            return (0.55, 1.0)
        }
    }

    private static func targetPoint(
        for role: LocalAppTaskStepRole,
        index: Int
    ) -> HotLoopPoint {
        switch role {
        case .parseIntent:
            return point(0.50, 0.16)
        case .launchOrFocusApp:
            return point(0.50, 0.24)
        case .observeApp:
            return point(0.50, 0.34)
        case .focusControl:
            return point(0.40, 0.44)
        case .enterText:
            return point(0.50, 0.54)
        case .submit:
            return point(0.62, 0.62)
        case .verifyResult:
            return point(0.50, 0.74)
        case .custom:
            return fallbackPoint(index: index)
        }
    }

    private static func fallbackPoint(index: Int) -> HotLoopPoint {
        point(min(0.82, 0.28 + Double(index % 4) * 0.16), min(0.86, 0.20 + Double(index / 4) * 0.18))
    }

    private static func centerPoint(for rect: HotLoopRect?) -> HotLoopPoint? {
        guard let rect,
              rect.space == .normalizedTarget else {
            return nil
        }

        return point(
            rect.origin.x + rect.size.width / 2,
            rect.origin.y + rect.size.height / 2
        )
    }

    private static func point(_ x: Double, _ y: Double) -> HotLoopPoint {
        HotLoopPoint(x: min(max(x, 0.04), 0.96), y: min(max(y, 0.06), 0.94), space: .normalizedTarget)
    }

    private static func fallbackWorkflowSteps(
        for definition: LocalAppTaskDefinition
    ) -> [LocalAppTaskWorkflowStepDefinition] {
        [
            LocalAppTaskWorkflowStepDefinition(
                id: "observe",
                role: .observeApp,
                summary: "Observe \(definition.targetApp.appName)"
            ),
            LocalAppTaskWorkflowStepDefinition(
                id: "verify",
                role: .verifyResult,
                summary: "Verify the result"
            )
        ]
    }

    private static func actionTraceMetadata(_ trace: ActionEngineCommandTrace) -> [String: String] {
        [
            "actionTrace.commandID": trace.command.id,
            "actionTrace.executed": String(trace.executed),
            "actionTrace.decision": decisionDescription(trace.decision),
            "actionTrace.focusGuardPassed": String(trace.focusGuardPassed),
            "actionTrace.rateLimited": String(trace.rateLimited),
            "actionTrace.liveInputEnabled": String(trace.liveInputEnabled)
        ].merging(trace.command.metadata) { current, _ in current }
    }

    private static func decisionDescription(_ decision: ActionEngineCommandDecision) -> String {
        switch decision {
        case .projectedDryRun:
            return "projectedDryRun"
        case .executedLive:
            return "executedLive"
        case .denied(let reason):
            return "denied:\(reason)"
        }
    }
}

public struct AgentVisualizationGrounder: Sendable {
    public init() {}

    public func ground(
        plan: AgentVisualizationPlan,
        targetAppName: String?,
        candidates: [MacWindowTargetCandidate]
    ) -> AgentVisualizationPlan {
        guard let target = candidate(
            named: targetAppName ?? plan.metadata["targetApp"],
            in: candidates
        ) else {
            return plan
        }

        guard target.safetyAssessment.status == .allowed else {
            return blockedPlan(plan, target: target)
        }

        var grounded = plan
        grounded.steps = grounded.steps.enumerated().map { index, step in
            var copy = step
            let targetMetadata = [
                "target.windowID": String(target.windowID),
                "target.appName": target.appName ?? "",
                "target.bundleIdentifier": target.bundleIdentifier ?? "",
                "grounding.source": AgentVisualizationGroundingSource.windowMetadata.rawValue
            ]
            if var stepTarget = copy.target {
                stepTarget.metadata = stepTarget.metadata.merging(targetMetadata) { current, _ in current }
                copy.target = stepTarget
            } else {
                copy.target = AgentVisualizationStepTarget(
                    point: normalizedCenter(for: target, metadata: plan.metadata) ?? fallbackPoint(index: index),
                    description: target.title ?? target.appName ?? "target window",
                    source: .windowMetadata,
                    confidence: 0.68,
                    metadata: targetMetadata
                )
            }
            copy.metadata = copy.metadata.merging(targetMetadata) { current, _ in current }
            return copy
        }
        grounded.metadata["grounding.source"] = AgentVisualizationGroundingSource.windowMetadata.rawValue
        grounded.metadata["grounding.targetWindowID"] = String(target.windowID)
        return grounded
    }

    private func blockedPlan(
        _ plan: AgentVisualizationPlan,
        target: MacWindowTargetCandidate
    ) -> AgentVisualizationPlan {
        var blocked = plan
        blocked.steps = [
            AgentVisualizationStep(
                id: "\(plan.id)-blocked",
                kind: .recover,
                label: "Stopped on a sensitive screen",
                target: nil,
                holdDuration: 1.4,
                metadata: [
                    "target.windowID": String(target.windowID),
                    "target.safety.status": target.safetyAssessment.status.rawValue,
                    "target.safety.reasons": target.safetyAssessment.reasons.map(\.rawValue).joined(separator: ",")
                ]
            )
        ]
        blocked.verification = AgentVisualizationVerificationReport(
            status: .blocked,
            summary: target.safetyAssessment.summary,
            confidence: 1,
            evidenceCount: 1,
            metadata: [
                "target.windowID": String(target.windowID),
                "target.safety.status": target.safetyAssessment.status.rawValue,
                "screenshotGroundingAllowed": "false"
            ]
        )
        blocked.metadata["grounding.blocked"] = "true"
        blocked.metadata["screenshotGroundingAllowed"] = "false"
        return blocked
    }

    private func candidate(
        named appName: String?,
        in candidates: [MacWindowTargetCandidate]
    ) -> MacWindowTargetCandidate? {
        guard let appName,
              !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return candidates.first(where: \.isFocused) ?? candidates.first(where: \.isFrontmost)
        }

        let normalized = normalize(appName)
        return candidates.first { candidate in
            normalize(candidate.appName ?? "") == normalized
                || normalize(candidate.bundleIdentifier ?? "") == normalized
                || normalize(candidate.title ?? "") == normalized
        }
    }

    private func normalizedCenter(
        for target: MacWindowTargetCandidate,
        metadata: [String: String]
    ) -> HotLoopPoint? {
        guard let screenWidth = Double(metadata["screen.width"] ?? ""),
              let screenHeight = Double(metadata["screen.height"] ?? ""),
              screenWidth > 0,
              screenHeight > 0
        else {
            return nil
        }

        return HotLoopPoint(
            x: min(max((target.bounds.x + target.bounds.width / 2) / screenWidth, 0.04), 0.96),
            y: min(max((target.bounds.y + target.bounds.height / 2) / screenHeight, 0.06), 0.94),
            space: .normalizedTarget
        )
    }

    private func fallbackPoint(index: Int) -> HotLoopPoint {
        HotLoopPoint(
            x: min(0.82, 0.28 + Double(index % 4) * 0.16),
            y: min(0.86, 0.20 + Double(index / 4) * 0.18),
            space: .normalizedTarget
        )
    }

    private func normalize(_ value: String) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }
}
