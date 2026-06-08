import CoreGraphics
import DonkeyContracts
import DonkeyHarness
import Foundation
import Testing
@testable import Donkey

@Suite
struct RealtimeCursorVisualizationTests {
    private func step(metadata: [String: String], status: HarnessToolResultStatus = .succeeded) -> HarnessStepExecutionResult {
        HarnessStepExecutionResult(
            task: HarnessTaskState(threadID: "thread-1", goal: "do it"),
            toolResult: HarnessToolResult(
                callID: "call-1",
                toolName: "vision.click",
                status: status,
                summary: "Clicked",
                metadata: metadata
            )
        )
    }

    @Test
    func mapsClickScreenPointToNormalizedCursorTarget() throws {
        let plan = try #require(LocalAppUserQueryCommandHandler.cursorVisualizationPlan(
            for: step(metadata: ["screenPoint": "200,150", "label": "Search"]),
            appName: "Notes",
            traceID: "trace-1",
            screenSize: CGSize(width: 1000, height: 500)
        ))

        #expect(plan.executionMode == .live)
        #expect(plan.metadata["realPointerMoved"] == "true")
        #expect(plan.steps.count == 1)
        let target = try #require(plan.steps.first?.target?.point)
        #expect(target.space == .normalizedTarget)
        #expect(abs(target.x - 0.2) < 0.0001)
        #expect(abs(target.y - 0.3) < 0.0001)

        // The plan must yield a renderable cursor overlay request landing at the same point.
        let request = try #require(plan.cursorOverlayRequest())
        let cursor = try #require(request.steps.first)
        #expect(abs(cursor.target.x - 0.2) < 0.0001)
        #expect(abs(cursor.target.y - 0.3) < 0.0001)
        #expect(cursor.label == "Search")
    }

    @Test
    func ignoresStepsWithoutAScreenPoint() {
        // Observation / non-pointer steps carry no screenPoint, so no cursor path is shown.
        #expect(LocalAppUserQueryCommandHandler.cursorVisualizationPlan(
            for: step(metadata: ["label": "observed"]),
            appName: "Notes",
            traceID: "trace-1",
            screenSize: CGSize(width: 1000, height: 500)
        ) == nil)
    }

    @Test
    func ignoresFailedStepsAndDegenerateScreens() {
        #expect(LocalAppUserQueryCommandHandler.cursorVisualizationPlan(
            for: step(metadata: ["screenPoint": "10,10"], status: .failed),
            appName: "Notes",
            traceID: "trace-1",
            screenSize: CGSize(width: 1000, height: 500)
        ) == nil)
        #expect(LocalAppUserQueryCommandHandler.cursorVisualizationPlan(
            for: step(metadata: ["screenPoint": "10,10"]),
            appName: "Notes",
            traceID: "trace-1",
            screenSize: .zero
        ) == nil)
    }
}
