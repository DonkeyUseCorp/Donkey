import DonkeyContracts
@testable import DonkeyRuntime
import Foundation
import Testing

@Suite
struct AgentVisualizationRuntimeTests {
    @Test
    func localAppStepLoopWithoutGroundedTargetsDoesNotCreateCursorPlayback() throws {
        let definition = localAppDefinition()
        let intent = taskIntent(definition: definition)
        let actionPlan = LocalAppEvidenceBackedActionPlan(
            intent: intent,
            targetApp: definition.targetApp,
            steps: definition.workflowSteps.map { step in
                LocalAppEvidenceBackedActionStep(
                    id: step.id,
                    role: step.role,
                    status: step.id == "verify" ? .verified : .needsEvidence,
                    summary: step.summary,
                    metadata: step.metadata
                )
            },
            terminalState: .completed,
            canExecuteGuardedActions: true,
            verificationConfidence: 0.82
        )
        let result = LocalAppTaskLiveRunResult(
            command: "create a table in Numbers",
            traceID: "trace-projected-visualization",
            status: .completed,
            resolution: LocalAppTaskCatalogResolution(
                status: .resolved,
                intent: intent,
                definition: definition,
                availability: LocalAppAvailability(target: definition.targetApp, isInstalled: true),
                metadata: ["resolutionSource": "test"]
            ),
            initialActionPlan: actionPlan,
            finalActionPlan: actionPlan,
            observation: LocalAppTaskObservation(appIsRunning: true, appIsFocused: true, confidence: 0.8)
        )
        let plan = try #require(LocalAppTaskAgentVisualizationBuilder.plan(for: result))

        #expect(plan.executionMode == .live)
        #expect(plan.verification.status == .verified)
        #expect(plan.usesRealPointer == false)
        #expect(plan.metadata["source"] == "local-app-live-runner")
        #expect(plan.metadata["cursorGuideEligible"] == "false")
        #expect(plan.metadata["cursorGuide.reason"] == "noGroundedTargets")
        #expect(plan.cursorOverlayRequest() == nil)
        #expect(plan.steps.map(\.kind).contains(.observe))
        #expect(plan.steps.map(\.kind).contains(.enterText))
        #expect(plan.steps.allSatisfy { $0.target == nil })
        #expect(plan.steps.first?.metadata["evidencePlan.stepID"] == "launch")
    }

    @Test
    func localAppStepLoopBuildsLiveVisualizationPlanWithoutMovingRealPointer() throws {
        let definition = localAppDefinition()
        let intent = taskIntent(definition: definition)
        let actionPlan = LocalAppEvidenceBackedActionPlan(
            intent: intent,
            targetApp: definition.targetApp,
            steps: definition.workflowSteps.map { step in
                LocalAppEvidenceBackedActionStep(
                    id: step.id,
                    role: step.role,
                    status: step.id == "verify" ? .verified : .needsEvidence,
                    summary: step.summary,
                    metadata: step.metadata
                )
            },
            terminalState: .completed,
            canExecuteGuardedActions: true,
            verificationConfidence: 0.82
        )
        let trace = actionTrace(
            commandID: "intent-set-text",
            workflowStepID: "set-text",
            targetBounds: HotLoopRect(x: 0.35, y: 0.48, width: 0.3, height: 0.08, space: .normalizedTarget)
        )
        let result = LocalAppTaskLiveRunResult(
            command: "create a table in Numbers",
            traceID: "trace-visual-live",
            status: .completed,
            resolution: LocalAppTaskCatalogResolution(
                status: .resolved,
                intent: intent,
                definition: definition,
                availability: LocalAppAvailability(target: definition.targetApp, isInstalled: true)
            ),
            initialActionPlan: actionPlan,
            finalActionPlan: actionPlan,
            observation: LocalAppTaskObservation(appIsRunning: true, appIsFocused: true, confidence: 0.8),
            actionTraces: [trace]
        )

        let plan = try #require(LocalAppTaskAgentVisualizationBuilder.plan(for: result))
        let cursorRequest = try #require(plan.cursorOverlayRequest())

        #expect(plan.executionMode == .live)
        #expect(plan.usesRealPointer == false)
        #expect(plan.verification.status == .verified)
        #expect(plan.steps.map(\.kind).contains(.enterText))
        #expect(plan.steps.first(where: { $0.id == "set-text" })?.metadata["actionTrace.executed"] == "true")
        #expect(cursorRequest.steps.map(\.id) == ["set-text"])
        #expect(cursorRequest.metadata["realPointerMoved"] == "false")
        #expect(cursorRequest.metadata["agentVisualization.executionMode"] == "live")
    }

    @Test
    func localAppVisualizationUsesObservedControlBounds() throws {
        let definition = localAppDefinition()
        let intent = taskIntent(definition: definition)
        let adapter = LocalAppTaskAdapter(definition: definition)
        var observationMetadata = LocalAppObservationGeometry.targetBoundsMetadata(
            WindowTargetBounds(x: 100, y: 200, width: 800, height: 600)
        )
        observationMetadata.merge(
            LocalAppObservationGeometry.controlMetadata(
                controlID: "editor",
                frame: HotLoopRect(x: 180, y: 320, width: 240, height: 30, space: .screen),
                source: .accessibility,
                label: "Editor",
                kind: .textField,
                confidence: 0.88
            )
        ) { current, _ in current }
        let observation = LocalAppTaskObservation(
            appIsRunning: true,
            appIsFocused: true,
            availableControls: ["editor": true],
            visibleText: ["query": "Item"],
            confidence: 0.9,
            metadata: observationMetadata
        )
        let actionPlan = adapter.evidenceBackedActionPlan(for: intent, observation: observation)
        let result = LocalAppTaskLiveRunResult(
            command: "create a table in Numbers",
            traceID: "trace-grounded-control",
            status: .completed,
            resolution: LocalAppTaskCatalogResolution(
                status: .resolved,
                intent: intent,
                definition: definition,
                availability: LocalAppAvailability(target: definition.targetApp, isInstalled: true)
            ),
            initialActionPlan: actionPlan,
            finalActionPlan: actionPlan,
            observation: observation
        )

        let plan = try #require(LocalAppTaskAgentVisualizationBuilder.plan(for: result))
        let focusStep = try #require(plan.steps.first(where: { $0.id == "focus-input" }))
        let enterStep = try #require(plan.steps.first(where: { $0.id == "set-text" }))
        let cursorRequest = try #require(plan.cursorOverlayRequest())
        let cursorFocusStep = try #require(cursorRequest.steps.first(where: { $0.id == "focus-input" }))
        let cursorEnterStep = try #require(cursorRequest.steps.first(where: { $0.id == "set-text" }))

        #expect(focusStep.target?.source == .accessibility)
        #expect(focusStep.target?.bounds?.space == .normalizedTarget)
        #expect(enterStep.target?.controlID == "editor")
        #expect(cursorFocusStep.metadata["cursor.targetSpace"] == "targetWindowNormalized")
        #expect(cursorFocusStep.metadata["target.bounds.x"] == "100.0")
        #expect(abs(cursorFocusStep.target.x - 0.25) < 0.001)
        #expect(abs(cursorFocusStep.target.y - 0.225) < 0.001)
        #expect(abs(cursorEnterStep.target.x - cursorFocusStep.target.x) < 0.001)
        #expect(abs(cursorEnterStep.target.y - cursorFocusStep.target.y) < 0.001)
        let screenPoint = AgentVisualizationCursorPathSampler.point(
            cursorFocusStep.target,
            metadata: cursorFocusStep.metadata,
            screenFrame: CGRect(x: 0, y: 0, width: 1200, height: 900)
        )
        #expect(abs(screenPoint.x - 300) < 0.001)
        #expect(abs(screenPoint.y - 335) < 0.001)
    }

    @Test
    func visualOnlyPlanConvertsToOverlayCursorWithoutRealPointerMovement() throws {
        let plan = AgentVisualizationPlan(
            title: "Show Numbers Table",
            executionMode: .visualOnly,
            sourceTraceID: "trace-visual-only",
            steps: [
                AgentVisualizationStep(
                    id: "observe",
                    kind: .observe,
                    label: "Check the Numbers window",
                    target: AgentVisualizationStepTarget(
                        point: HotLoopPoint(x: 0.5, y: 0.3, space: .normalizedTarget),
                        description: "Numbers window",
                        source: .modelPlan,
                        confidence: 0.9
                    )
                ),
                AgentVisualizationStep(
                    id: "focus",
                    kind: .focusControl,
                    label: "Point at the first cell",
                    target: AgentVisualizationStepTarget(
                        point: HotLoopPoint(x: 0.38, y: 0.46, space: .normalizedTarget),
                        description: "first cell",
                        source: .modelPlan,
                        confidence: 0.88
                    )
                )
            ],
            metadata: ["realPointerMoved": "false"]
        )

        let cursorRequest = try #require(plan.cursorOverlayRequest())

        #expect(cursorRequest.steps.map(\.label) == ["Check the Numbers window", "Point at the first cell"])
        #expect(cursorRequest.steps.first?.target.x == 0.5)
        #expect(cursorRequest.steps.last?.target.y == 0.46)
        #expect(cursorRequest.metadata["agentVisualization.executionMode"] == "visualOnly")
        #expect(cursorRequest.metadata["realPointerMoved"] == "false")
    }

    @Test
    func windowMetadataGroundingAnnotatesExistingTargets() throws {
        let plan = AgentVisualizationPlan(
            title: "Show Numbers Table",
            executionMode: .live,
            sourceTraceID: "trace-grounding",
            steps: [
                AgentVisualizationStep(
                    id: "focus",
                    kind: .focusControl,
                    label: "Point at the first cell",
                    target: AgentVisualizationStepTarget(
                        point: HotLoopPoint(x: 0.38, y: 0.46, space: .normalizedTarget),
                        description: "first cell",
                        source: .evidenceBackedActionPlan,
                        confidence: 0.58
                    )
                )
            ],
            metadata: ["targetApp": "Numbers"]
        )

        let grounded = AgentVisualizationGrounder().ground(
            plan: plan,
            targetAppName: "Numbers",
            candidates: [
                window(
                    appName: "Numbers",
                    title: "Untitled",
                    safetyStatus: .allowed,
                    reasons: []
                )
            ]
        )

        #expect(grounded.metadata["grounding.source"] == AgentVisualizationGroundingSource.windowMetadata.rawValue)
        #expect(grounded.steps.first?.metadata["target.windowID"] == "44")
        #expect(grounded.steps.first?.target?.metadata["grounding.source"] == AgentVisualizationGroundingSource.windowMetadata.rawValue)
        #expect(grounded.steps.first?.target?.point?.x == 0.38)
    }

    @Test
    func windowMetadataGroundingDoesNotInventCursorTargets() throws {
        let plan = AgentVisualizationPlan(
            title: "Worked in Numbers",
            executionMode: .live,
            sourceTraceID: "trace-no-target-grounding",
            steps: [
                AgentVisualizationStep(
                    id: "observe",
                    kind: .observe,
                    label: "Checking the screen"
                )
            ],
            metadata: ["targetApp": "Numbers"]
        )

        let grounded = AgentVisualizationGrounder().ground(
            plan: plan,
            targetAppName: "Numbers",
            candidates: [
                window(
                    appName: "Numbers",
                    title: "Untitled",
                    safetyStatus: .allowed,
                    reasons: []
                )
            ]
        )

        #expect(grounded.steps.first?.metadata["target.windowID"] == "44")
        #expect(grounded.steps.first?.target == nil)
        #expect(grounded.cursorOverlayRequest() == nil)
    }

    @Test
    func unsafeWindowsBlockScreenshotGrounding() throws {
        let plan = AgentVisualizationPlan(
            title: "Show Checkout",
            executionMode: .visualOnly,
            sourceTraceID: "trace-blocked",
            steps: [
                AgentVisualizationStep(kind: .observe, label: "Look at the checkout")
            ],
            metadata: ["targetApp": "Safari"]
        )
        let grounded = AgentVisualizationGrounder().ground(
            plan: plan,
            targetAppName: "Safari",
            candidates: [
                window(
                    appName: "Safari",
                    title: "Checkout Payment",
                    safetyStatus: .blocked,
                    reasons: [.paymentSurface]
                )
            ]
        )

        #expect(grounded.verification.status == .blocked)
        #expect(grounded.metadata["screenshotGroundingAllowed"] == "false")
        #expect(grounded.steps.first?.kind == .recover)
        #expect(grounded.steps.first?.metadata["target.safety.reasons"] == "paymentSurface")

        let passwordGrounded = AgentVisualizationGrounder().ground(
            plan: plan,
            targetAppName: "Safari",
            candidates: [
                window(
                    appName: "Safari",
                    title: "Password Required",
                    safetyStatus: .blocked,
                    reasons: [.passwordSurface]
                )
            ]
        )

        #expect(passwordGrounded.verification.status == .blocked)
        #expect(passwordGrounded.metadata["screenshotGroundingAllowed"] == "false")
        #expect(passwordGrounded.steps.first?.kind == .recover)
        #expect(passwordGrounded.steps.first?.metadata["target.safety.reasons"] == "passwordSurface")
    }

    private func localAppDefinition() -> LocalAppTaskDefinition {
        LocalAppTaskDefinition(
            taskType: "local_app_interaction",
            targetApp: LocalAppTarget(appName: "Numbers", bundleIdentifier: "com.apple.iWork.Numbers"),
            triggerTerms: [],
            workflowSteps: [
                LocalAppTaskWorkflowStepDefinition(id: "launch", role: .launchOrFocusApp, summary: "Open Numbers"),
                LocalAppTaskWorkflowStepDefinition(id: "observe", role: .observeApp, summary: "Observe Numbers"),
                LocalAppTaskWorkflowStepDefinition(
                    id: "focus-input",
                    role: .focusControl,
                    summary: "Focus the first cell",
                    metadata: ["controlID": "editor"]
                ),
                LocalAppTaskWorkflowStepDefinition(
                    id: "set-text",
                    role: .enterText,
                    summary: "Enter table text",
                    metadata: ["entityName": "query"]
                ),
                LocalAppTaskWorkflowStepDefinition(id: "verify", role: .verifyResult, summary: "Verify table")
            ],
            verificationEntityName: "query",
            metadata: ["modelPlanned": "true"]
        )
    }

    private func taskIntent(definition: LocalAppTaskDefinition) -> TaskIntent {
        TaskIntent(
            intentID: "intent-numbers-table",
            taskType: definition.taskType,
            targetApp: definition.targetApp,
            entities: ["query": "Item\tValue\nA\t1"],
            normalizedEntities: ["query": "Item\tValue\nA\t1"],
            confidence: 0.9,
            parserSource: .localModel,
            actionPlan: LocalAppActionPlan(
                tools: [.openOrFocusApp, .observeApp, .newDocument, .setText, .verifyCommand],
                inputEntity: "query",
                controlID: "editor"
            )
        )
    }

    private func actionTrace(
        commandID: String,
        workflowStepID: String,
        targetBounds: HotLoopRect? = nil
    ) -> ActionEngineCommandTrace {
        let command = ActionEngineCommand(
            id: commandID,
            traceID: "trace-visual-live",
            targetID: "local-app-task-local-app-interaction",
            kind: .key,
            issuedAt: timestamp(10),
            targetBounds: targetBounds,
            key: "Item\tValue",
            metadata: [
                "workflowStepID": workflowStepID,
                "workflowStepRole": LocalAppTaskStepRole.enterText.rawValue
            ]
        )
        return ActionEngineCommandTrace(
            command: command,
            decision: .executedLive,
            recordedAt: timestamp(20),
            executed: true,
            liveInputEnabled: true,
            focusGuardPassed: true,
            permissionDecision: .allow,
            rateLimited: false,
            releaseAll: false
        )
    }

    private func window(
        appName: String,
        title: String,
        safetyStatus: WindowTargetSafetyStatus,
        reasons: [WindowTargetSafetyReason]
    ) -> MacWindowTargetCandidate {
        MacWindowTargetCandidate(
            windowID: 44,
            processID: 400,
            appName: appName,
            bundleIdentifier: "com.apple.Safari",
            title: title,
            bounds: WindowTargetBounds(x: 0, y: 0, width: 800, height: 600),
            isVisible: true,
            isOnScreen: true,
            isFrontmost: true,
            isFocused: true,
            isIPhoneMirroring: false,
            safetyAssessment: WindowTargetSafetyAssessment(
                status: safetyStatus,
                reasons: reasons,
                summary: "Sensitive surface"
            )
        )
    }

    private func timestamp(_ milliseconds: UInt64) -> RunTraceTimestamp {
        RunTraceTimestamp(
            wallClock: Date(timeIntervalSince1970: Double(milliseconds) / 1_000),
            monotonicUptimeNanoseconds: milliseconds * 1_000_000
        )
    }
}
