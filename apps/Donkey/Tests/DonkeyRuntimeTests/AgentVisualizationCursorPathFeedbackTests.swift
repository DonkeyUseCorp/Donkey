import CoreGraphics
import DonkeyContracts
@testable import DonkeyUI
import Foundation
import Testing

@Suite
struct AgentVisualizationCursorPathFeedbackTests {
    @Test
    func samplerMovesCursorThroughExactPointToPointSamples() throws {
        let request = cursorRequest()
        let screen = CGSize(width: 1_000, height: 500)

        let start = AgentVisualizationCursorPathSampler.sample(
            request: request,
            elapsed: 0,
            screenSize: screen
        )
        let firstArrival = AgentVisualizationCursorPathSampler.sample(
            request: request,
            elapsed: 1.0,
            screenSize: screen
        )
        let secondTravelSample = AgentVisualizationCursorPathSampler.sample(
            request: request,
            elapsed: 1.6,
            screenSize: screen
        )
        let secondArrival = AgentVisualizationCursorPathSampler.sample(
            request: request,
            elapsed: 3.5,
            screenSize: screen
        )
        let complete = AgentVisualizationCursorPathSampler.sample(
            request: request,
            elapsed: 4.1,
            screenSize: screen
        )

        expectPoint(start.position, x: 100, y: 100)
        #expect(start.phase == .travel)
        #expect(start.stepID == "point-a")
        #expect(start.linearProgress == 0)
        #expect(start.easedProgress == 0)

        expectPoint(firstArrival.position, x: 300, y: 300)
        #expect(firstArrival.phase == .travel)
        #expect(firstArrival.stepID == "point-a")
        #expect(firstArrival.linearProgress == 1)
        #expect(firstArrival.easedProgress == 1)

        expectPoint(secondTravelSample.position, x: 378.57886907159434, y: 289.6409226789856)
        expectApproximately(secondTravelSample.angle, -21.80140948635181)
        expectApproximately(secondTravelSample.linearProgress, 0.05)
        expectApproximately(secondTravelSample.easedProgress, 0.1426250000000001)
        #expect(secondTravelSample.phase == .travel)
        #expect(secondTravelSample.stepID == "point-b")
        #expect(secondTravelSample.position.x > firstArrival.position.x)
        #expect(secondTravelSample.position.x < secondArrival.position.x)
        #expect(secondTravelSample.position.y < firstArrival.position.y)
        #expect(secondTravelSample.position.y > secondArrival.position.y)

        expectPoint(secondArrival.position, x: 800, y: 100)
        #expect(secondArrival.phase == .travel)
        #expect(secondArrival.stepID == "point-b")
        #expect(distance(from: start.position, to: firstArrival.position) > 280)
        #expect(distance(from: firstArrival.position, to: secondArrival.position) > 530)

        expectPoint(complete.position, x: 800, y: 100)
        #expect(complete.phase == .complete)
        #expect(complete.stepID == "point-b")
        #expect(complete.visibleLabel == "Point B")
        #expect(complete.isHolding)
    }

    @MainActor
    @Test
    func overlayViewModelUsesSamplerForVisibleCursorPosition() throws {
        let request = cursorRequest()
        let screen = CGSize(width: 1_000, height: 500)
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let viewModel = PointerCoachCursorOverlayViewModel(
            request: request,
            screenSize: screen
        )

        viewModel.start(at: startedAt)
        viewModel.update(now: startedAt.addingTimeInterval(1.6))

        let expected = AgentVisualizationCursorPathSampler.sample(
            request: request,
            elapsed: 1.6,
            screenSize: screen
        )
        let frame = viewModel.animationFrame

        expectPoint(frame.position, x: 378.57886907159434, y: 289.6409226789856)
        expectPoint(frame.position, x: expected.position.x, y: expected.position.y)
        expectApproximately(frame.angle, expected.angle)
        #expect(frame.visibleLabel == "")
        #expect(frame.isHolding == false)
    }

    @Test
    func visualizationPlanFeedbackLoopPreservesExpectedCursorTargets() throws {
        let plan = AgentVisualizationPlan(
            id: "feedback-plan",
            title: "Feedback Loop",
            executionMode: .live,
            sourceTraceID: "trace-feedback",
            steps: [
                AgentVisualizationStep(
                    id: "observe",
                    kind: .observe,
                    label: "Observe A",
                    target: AgentVisualizationStepTarget(
                        point: HotLoopPoint(x: 0.30, y: 0.22, space: .normalizedTarget),
                        description: "A",
                        source: .dryRun,
                        confidence: 0.8
                    ),
                    travelDuration: 0.4,
                    holdDuration: 0.4
                ),
                AgentVisualizationStep(
                    id: "focus",
                    kind: .focusControl,
                    label: "Focus B",
                    target: AgentVisualizationStepTarget(
                        point: HotLoopPoint(x: 0.44, y: 0.22, space: .normalizedTarget),
                        description: "B",
                        source: .dryRun,
                        confidence: 0.8
                    ),
                    travelDuration: 0.4,
                    holdDuration: 0.4
                ),
                AgentVisualizationStep(
                    id: "verify",
                    kind: .verify,
                    label: "Verify C",
                    target: AgentVisualizationStepTarget(
                        point: HotLoopPoint(x: 0.58, y: 0.22, space: .normalizedTarget),
                        description: "C",
                        source: .dryRun,
                        confidence: 0.8
                    ),
                    travelDuration: 0.4,
                    holdDuration: 0.4
                )
            ],
            metadata: ["realPointerMoved": "false"]
        )

        let request = try #require(plan.cursorOverlayRequest())
        let screen = CGSize(width: 1_000, height: 500)
        let expectedArrivals = [
            (elapsed: 0.4, x: 300.0, y: 110.0, stepID: "observe"),
            (elapsed: 1.2, x: 440.0, y: 110.0, stepID: "focus"),
            (elapsed: 2.0, x: 580.0, y: 110.0, stepID: "verify")
        ]

        #expect(request.metadata["realPointerMoved"] == "false")
        #expect(request.steps.map(\.id) == ["observe", "focus", "verify"])

        for expected in expectedArrivals {
            let sample = AgentVisualizationCursorPathSampler.sample(
                request: request,
                elapsed: expected.elapsed,
                screenSize: screen
            )
            expectPoint(sample.position, x: expected.x, y: expected.y)
            #expect(sample.stepID == expected.stepID)
            #expect(sample.phase == .travel)
        }
    }

    private func cursorRequest() -> PointerCoachCursorGuideRequest {
        PointerCoachCursorGuideRequest(
            id: "exact-cursor-path",
            title: "Exact Cursor Path",
            origin: CGPoint(x: 0.10, y: 0.20),
            steps: [
                PointerCoachCursorGuideStep(
                    id: "point-a",
                    label: "Point A",
                    target: CGPoint(x: 0.30, y: 0.60),
                    travelDuration: 1.0,
                    holdDuration: 0.5
                ),
                PointerCoachCursorGuideStep(
                    id: "point-b",
                    label: "Point B",
                    target: CGPoint(x: 0.80, y: 0.20),
                    travelDuration: 2.0,
                    holdDuration: 0.5
                )
            ],
            metadata: ["realPointerMoved": "false"]
        )
    }

    private func expectPoint(
        _ point: CGPoint,
        x: Double,
        y: Double,
        tolerance: Double = 0.000_001
    ) {
        expectApproximately(Double(point.x), x, tolerance: tolerance)
        expectApproximately(Double(point.y), y, tolerance: tolerance)
    }

    private func expectApproximately(
        _ actual: Double,
        _ expected: Double,
        tolerance: Double = 0.000_001
    ) {
        #expect(abs(actual - expected) <= tolerance)
    }

    private func distance(from first: CGPoint, to second: CGPoint) -> Double {
        hypot(Double(second.x - first.x), Double(second.y - first.y))
    }
}
