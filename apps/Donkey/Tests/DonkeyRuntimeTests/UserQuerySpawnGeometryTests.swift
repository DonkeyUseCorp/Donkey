import CoreGraphics
import DonkeyContracts
import DonkeyUI
import Testing

@Suite
struct UserQuerySpawnGeometryTests {
    @Test
    func fallbackPointSitsBelowNotchAndClampsInsideScreen() {
        let point = UserQuerySpawnGeometry.fallbackPoint(
            screenSize: CGSize(width: 1200, height: 800),
            notchBottomY: 32
        )

        #expect(point.x == 600)
        #expect(point.y == 282)

        let shortScreenPoint = UserQuerySpawnGeometry.fallbackPoint(
            screenSize: CGSize(width: 360, height: 260),
            notchBottomY: 40
        )

        #expect(shortScreenPoint.x == 180)
        #expect(shortScreenPoint.y == 224)
    }

    @Test
    func clampedPointRespectsMinimumInset() {
        let point = UserQuerySpawnGeometry.clampedPoint(
            CGPoint(x: -20, y: 1000),
            in: CGSize(width: 500, height: 400),
            inset: 40
        )

        #expect(point.x == 40)
        #expect(point.y == 360)
    }

    @Test
    func cueAngleUsesTopLeftCoordinateSpace() {
        #expect(
            UserQuerySpawnGeometry.angleDegrees(
                from: CGPoint(x: 100, y: 100),
                to: CGPoint(x: 100, y: 200)
            ) == 90
        )
        #expect(
            UserQuerySpawnGeometry.angleDegrees(
                from: CGPoint(x: 100, y: 100),
                to: CGPoint(x: 0, y: 100)
            ) == 180
        )
    }

    @Test
    func labelTypingIdentityChangesWhenLabelChanges() {
        let first = UserQuerySpawnGeometry.labelTypingIdentity(
            spawnID: "spawn-1",
            label: "Routing task"
        )
        let second = UserQuerySpawnGeometry.labelTypingIdentity(
            spawnID: "spawn-1",
            label: "Opening Music"
        )

        #expect(first != second)
        #expect(
            first == UserQuerySpawnGeometry.labelTypingIdentity(
                spawnID: "spawn-1",
                label: "Routing task"
            )
        )
    }

    @Test @MainActor
    func spawnOverlayPlacesCursorInsideViewportAndLabelAboveIt() {
        let viewModel = UserQuerySpawnOverlayViewModel()
        let cursorPoint = CGPoint(x: 600, y: 282)
        let screenSize = CGSize(width: 1200, height: 800)
        let state = UserQuerySpawnState(
            id: "spawn-1",
            commandText: "hi there",
            label: "hi there",
            accentIndex: 1,
            phase: .holding
        )

        viewModel.show(
            state: state,
            origin: cursorPoint,
            destination: cursorPoint,
            screenSize: screenSize
        )
        let cursorFrame = viewModel.cursorOnlyVisualFrame(at: cursorPoint)
        viewModel.updateViewport(origin: cursorFrame.origin, size: cursorFrame.size)

        #expect(viewModel.localCursorCenter.x == cursorFrame.width / 2)
        #expect(viewModel.localCursorCenter.y == cursorFrame.height / 2)
        #expect(viewModel.localHaloCenter.x == viewModel.localCursorCenter.x)
        #expect(viewModel.localHaloCenter.y > viewModel.localCursorCenter.y)
        #expect(viewModel.localLabelCenter(in: screenSize).x == viewModel.localCursorCenter.x)
        #expect(viewModel.localLabelCenter(in: screenSize).y < viewModel.localCursorCenter.y)
        #expect(viewModel.localCursorCenter.y - viewModel.localLabelCenter(in: screenSize).y == 46)
    }

    @Test @MainActor
    func spawnOverlayKeepsTravelAngleAfterCursorArrives() async throws {
        let viewModel = UserQuerySpawnOverlayViewModel()
        let origin = CGPoint(x: 600, y: -24)
        let destination = CGPoint(x: 420, y: 282)
        let screenSize = CGSize(width: 1200, height: 800)
        let state = UserQuerySpawnState(
            id: "spawn-1",
            commandText: "hi there",
            label: "hi there",
            accentIndex: 1,
            phase: .traveling
        )
        let expectedAngle = UserQuerySpawnGeometry.angleDegrees(
            from: origin,
            to: destination
        )

        viewModel.show(
            state: state,
            origin: origin,
            destination: destination,
            screenSize: screenSize
        )

        #expect(abs(viewModel.cursorAngleDegrees - expectedAngle) < 0.0001)

        try await Task.sleep(nanoseconds: 900_000_000)

        #expect(viewModel.position == destination)
        #expect(viewModel.isHolding)
        #expect(abs(viewModel.cursorAngleDegrees - expectedAngle) < 0.0001)
    }

    @Test @MainActor
    func spawnOverlayWagsTailUntilResponseLabelArrives() async throws {
        let viewModel = UserQuerySpawnOverlayViewModel()
        let origin = CGPoint(x: 600, y: -24)
        let destination = CGPoint(x: 420, y: 282)
        let state = UserQuerySpawnState(
            id: "spawn-1",
            commandText: "hi there",
            label: "hi there",
            accentIndex: 1,
            phase: .traveling
        )

        viewModel.show(
            state: state,
            origin: origin,
            destination: destination,
            screenSize: CGSize(width: 1200, height: 800)
        )

        let landedBeforeWorkingDelay = UInt64(
            (UserQuerySpawnOverlayViewModel.travelDuration + 0.15) * 1_000_000_000
        )
        try await Task.sleep(nanoseconds: landedBeforeWorkingDelay)

        #expect(viewModel.isHolding)
        #expect(!viewModel.isWorking)

        let workingDelay = UInt64(
            (UserQuerySpawnOverlayViewModel.terminalTailAnimationDuration + 0.2) * 1_000_000_000
        )
        try await Task.sleep(nanoseconds: workingDelay)

        #expect(!viewModel.isWorking)

        viewModel.update(
            state: UserQuerySpawnState(
                id: "spawn-1",
                commandText: "hi there",
                label: "Hi! What would you like to work on?",
                accentIndex: 1,
                phase: .holding
            ),
            destination: destination,
            screenSize: CGSize(width: 1200, height: 800)
        )

        #expect(viewModel.isWorking)
        #expect(abs(viewModel.terminalTailAngleDegrees) < 0.0001)
    }

    @Test @MainActor
    func spawnCursorDragFreezesMovementAndRepositionsInPlace() async throws {
        let viewModel = UserQuerySpawnOverlayViewModel()
        viewModel.show(
            state: UserQuerySpawnState(
                id: "spawn-1",
                commandText: "plan",
                label: "checking",
                accentIndex: 1,
                phase: .holding
            ),
            origin: CGPoint(x: 600, y: 282),
            destination: CGPoint(x: 600, y: 282),
            screenSize: CGSize(width: 1200, height: 800)
        )
        let landedDelay = UInt64(
            (UserQuerySpawnOverlayViewModel.travelDuration + 0.05) * 1_000_000_000
        )
        try await Task.sleep(nanoseconds: landedDelay)
        #expect(viewModel.isHolding)

        var reportedPoint: CGPoint?
        viewModel.cursorDragged = { reportedPoint = $0 }
        viewModel.reportCursorDrag(at: CGPoint(x: 400, y: 300))
        #expect(viewModel.isCursorDragging)
        #expect(viewModel.freezesMovement)
        #expect(reportedPoint == CGPoint(x: 400, y: 300))

        viewModel.setPosition(CGPoint(x: 400, y: 500))
        #expect(viewModel.position == CGPoint(x: 400, y: 500))
        #expect(viewModel.destination == CGPoint(x: 400, y: 500))
        #expect(viewModel.isHolding)

        viewModel.endCursorDrag()
        #expect(!viewModel.isCursorDragging)
        #expect(!viewModel.freezesMovement)
    }

    @Test @MainActor
    func spawnDismissReportsSpawnID() {
        let viewModel = UserQuerySpawnOverlayViewModel()
        var dismissedID: String?
        viewModel.dismissed = { dismissedID = $0 }

        viewModel.dismiss()
        #expect(dismissedID == nil)

        viewModel.show(
            state: UserQuerySpawnState(
                id: "spawn-1",
                commandText: "plan",
                label: "checking",
                accentIndex: 1,
                phase: .holding
            ),
            origin: CGPoint(x: 600, y: 282),
            destination: CGPoint(x: 600, y: 282),
            screenSize: CGSize(width: 1200, height: 800)
        )
        viewModel.dismiss()
        #expect(dismissedID == "spawn-1")
    }

    @Test @MainActor
    func spawnOverlayReservesPanelDrawingRoomWithoutExpandingHitArea() async throws {
        let viewModel = UserQuerySpawnOverlayViewModel()
        let state = UserQuerySpawnState(
            id: "spawn-1",
            taskID: "task-1",
            commandText: "plan",
            label: Array(repeating: "checking", count: 18).joined(separator: " "),
            accentIndex: 1,
            phase: .holding
        )

        viewModel.show(
            state: state,
            origin: CGPoint(x: 600, y: 282),
            destination: CGPoint(x: 600, y: 282),
            screenSize: CGSize(width: 1200, height: 800)
        )
        let landedDelay = UInt64(
            (UserQuerySpawnOverlayViewModel.travelDuration + 0.05) * 1_000_000_000
        )
        try await Task.sleep(nanoseconds: landedDelay)

        let panelFrame = viewModel.visualFrame
        let hitTestFrame = viewModel.hitTestFrame
        viewModel.updateViewport(origin: panelFrame.origin, size: panelFrame.size)

        #expect(!panelFrame.isNull)
        #expect(!hitTestFrame.isNull)
        #expect(panelFrame.contains(hitTestFrame))
        #expect(panelFrame.width > hitTestFrame.width)
        #expect(viewModel.localHitTestFrame.minX >= 0)
        #expect(viewModel.localHitTestFrame.maxX <= viewModel.viewportSize.width)
        #expect(viewModel.localHitTestFrame.minY >= 0)
        #expect(viewModel.localHitTestFrame.maxY <= viewModel.viewportSize.height)
    }

    @Test @MainActor
    func spawnOverlayUsesPaddedPanelFrameForTravelingCursor() {
        let viewModel = UserQuerySpawnOverlayViewModel()
        let point = CGPoint(x: 420, y: 282)
        let cursorFrame = viewModel.cursorOnlyVisualFrame(at: point)
        let panelFrame = viewModel.cursorPanelFrame(at: point)

        #expect(panelFrame.contains(cursorFrame))
        #expect(panelFrame.width > cursorFrame.width)
        #expect(panelFrame.height > cursorFrame.height)
    }

    @Test @MainActor
    func inlineSpawnLabelEditorSubmitsTrimmedFollowUpForTask() {
        let viewModel = UserQuerySpawnOverlayViewModel()
        let state = UserQuerySpawnState(
            id: "spawn-1",
            taskID: "task-1",
            commandText: "hi there",
            label: "hi there",
            accentIndex: 1,
            phase: .holding
        )
        var submittedSpawnID: String?
        var submittedTaskID: String?
        var submittedText: String?
        viewModel.followUpSubmitted = { spawnID, taskID, text in
            submittedSpawnID = spawnID
            submittedTaskID = taskID
            submittedText = text
        }

        viewModel.show(
            state: state,
            origin: CGPoint(x: 600, y: 282),
            destination: CGPoint(x: 600, y: 282),
            screenSize: CGSize(width: 1200, height: 800)
        )
        viewModel.beginInlineInput()
        #expect(viewModel.isLabelEditing)
        #expect(viewModel.freezesMovement)

        viewModel.draftText = "  do this next  "
        viewModel.submitInlineInput()

        #expect(!viewModel.isLabelEditing)
        #expect(!viewModel.freezesMovement)
        #expect(submittedSpawnID == "spawn-1")
        #expect(submittedTaskID == "task-1")
        #expect(submittedText == "do this next")
    }

    @Test @MainActor
    func inlineSpawnLabelEditorClosesWhenIdleFocusIsLost() {
        let viewModel = UserQuerySpawnOverlayViewModel()
        let state = UserQuerySpawnState(
            id: "spawn-1",
            taskID: "task-1",
            commandText: "hi there",
            label: "hi there",
            accentIndex: 1,
            phase: .holding
        )

        viewModel.show(
            state: state,
            origin: CGPoint(x: 600, y: 282),
            destination: CGPoint(x: 600, y: 282),
            screenSize: CGSize(width: 1200, height: 800)
        )
        viewModel.beginInlineInput()
        #expect(viewModel.isLabelEditing)

        viewModel.closeInlineInputIfIdle()

        #expect(!viewModel.isLabelEditing)
        #expect(viewModel.draftText.isEmpty)
    }
}
