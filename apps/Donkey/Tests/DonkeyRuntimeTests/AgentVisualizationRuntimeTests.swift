import DonkeyContracts
@testable import DonkeyRuntime
import Foundation
import Testing

@Suite
struct AgentVisualizationRuntimeTests {
    @Test
    func resolvedLocalTaskBuildsProjectedLiveVisualizationBeforeExecution() throws {
        let definition = localAppDefinition()
        let intent = taskIntent(definition: definition)
        let plan = try #require(LocalAppTaskAgentVisualizationBuilder.projectedPlan(
            command: "create a table in Numbers",
            traceID: "trace-projected-visualization",
            resolution: LocalAppTaskCatalogResolution(
                status: .resolved,
                intent: intent,
                definition: definition,
                availability: LocalAppAvailability(target: definition.targetApp, isInstalled: true),
                metadata: ["resolutionSource": "test"]
            )
        ))

        #expect(plan.executionMode == .live)
        #expect(plan.verification.status == .unverified)
        #expect(plan.usesRealPointer == false)
        #expect(plan.metadata["source"] == "local-app-projected-workflow")
        #expect(plan.metadata["workflowStage"] == "preExecution")
        #expect(plan.steps.map(\.kind).contains(.observe))
        #expect(plan.steps.map(\.kind).contains(.enterText))
        #expect(plan.steps.first?.target?.source == .dryRun)
        #expect(plan.steps.first?.metadata["workflow.stepID"] == "launch")
    }

    @Test
    func localAppRunBuildsLiveVisualizationPlanWithoutMovingRealPointer() throws {
        let definition = localAppDefinition()
        let intent = taskIntent(definition: definition)
        let dryRunPlan = LocalAppTaskDryRunPlan(
            intent: intent,
            targetApp: definition.targetApp,
            steps: definition.workflowSteps.map { step in
                LocalAppTaskDryRunStep(
                    id: step.id,
                    role: step.role,
                    status: step.id == "verify" ? .verified : .projected,
                    summary: step.summary,
                    metadata: step.metadata
                )
            },
            terminalState: .completed,
            canAttemptGuardedLive: true,
            verificationConfidence: 0.82
        )
        let trace = actionTrace(commandID: "intent-set-text", workflowStepID: "set-text")
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
            initialPlan: dryRunPlan,
            finalPlan: dryRunPlan,
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
        #expect(cursorRequest.metadata["realPointerMoved"] == "false")
        #expect(cursorRequest.metadata["agentVisualization.executionMode"] == "live")
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
                        source: .dryRun,
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
        workflowStepID: String
    ) -> ActionEngineCommandTrace {
        let command = ActionEngineCommand(
            id: commandID,
            traceID: "trace-visual-live",
            targetID: "local-app-task-local-app-interaction",
            kind: .key,
            issuedAt: timestamp(10),
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
