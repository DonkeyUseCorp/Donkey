import DonkeyContracts
@testable import DonkeyRuntime
import Foundation
import Testing

@Suite
struct AccessibilityCursorPathBuilderTests {
    // A 1000x800 window at screen origin (200, 100).
    private let window = WindowTargetBounds(x: 200, y: 100, width: 1_000, height: 800)

    private func control(
        id: String,
        label: String,
        kind: LocalAppControlKind = .button,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        controlID: String? = nil
    ) -> LocalAppDiscoveredControl {
        LocalAppDiscoveredControl(
            id: id,
            kind: kind,
            label: label,
            frame: WindowTargetBounds(x: x, y: y, width: width, height: height),
            metadata: controlID.map { ["controlID": $0] } ?? [:]
        )
    }

    @Test
    func groundsResolvedControlsToNormalizedTargetSteps() {
        // Search field centered horizontally near the top; a result row lower-left.
        let controls = [
            control(id: "search", label: "Search", kind: .searchField, x: 600, y: 140, width: 200, height: 40),
            control(id: "row-1", label: "Yellow — Coldplay", kind: .listItem, x: 260, y: 400, width: 480, height: 60)
        ]
        let steps = AccessibilityCursorPathBuilder.buildSteps(
            targetApp: "Spotify",
            windowBounds: window,
            controls: controls,
            targets: [
                AccessibilityCursorPathTarget(query: "Search", label: "Search box", kind: .targetControl),
                AccessibilityCursorPathTarget(query: "Yellow Coldplay", label: "Play Yellow", kind: .act)
            ]
        )

        #expect(steps.count == 2)

        // Search field center: x=(700-200)/1000=0.5, y=(160-100)/800=0.075.
        let search = steps[0]
        #expect(search.kind == .targetControl)
        #expect(search.source == .accessibility)
        #expect(search.controlID == "search")
        let searchPoint = try! #require(search.point)
        #expect(searchPoint.space == .normalizedTarget)
        #expect(abs(searchPoint.x - 0.5) < 0.0001)
        #expect(abs(searchPoint.y - 0.075) < 0.0001)

        // Result row center: x=(500-200)/1000=0.3, y=(430-100)/800=0.4125.
        let play = steps[1]
        #expect(play.kind == .act)
        #expect(play.controlID == "row-1")
        let playPoint = try! #require(play.point)
        #expect(abs(playPoint.x - 0.3) < 0.0001)
        #expect(abs(playPoint.y - 0.4125) < 0.0001)
    }

    @Test
    func dropsTargetsThatDoNotResolveOrLackGeometry() {
        let controls = [
            control(id: "search", label: "Search", kind: .searchField, x: 600, y: 140, width: 200, height: 40),
            // Zero-area control must be ignored even though its label matches.
            control(id: "ghost", label: "Settings", x: 10, y: 10, width: 0, height: 0)
        ]
        let steps = AccessibilityCursorPathBuilder.buildSteps(
            targetApp: "Spotify",
            windowBounds: window,
            controls: controls,
            targets: [
                AccessibilityCursorPathTarget(query: "Search", label: "Search"),
                AccessibilityCursorPathTarget(query: "Settings", label: "Settings"),   // zero-area → dropped
                AccessibilityCursorPathTarget(query: "Nonexistent", label: "Nope")      // no match → dropped
            ]
        )
        #expect(steps.map(\.controlID) == ["search"])
    }

    @Test
    func prefersExactLabelOverPartialMatch() {
        let controls = [
            control(id: "play-pause", label: "Play / Pause", x: 500, y: 700, width: 40, height: 40),
            control(id: "playlist", label: "Play", kind: .button, x: 260, y: 300, width: 80, height: 30)
        ]
        let resolved = AccessibilityCursorPathBuilder.resolve("Play", in: controls)
        #expect(resolved?.id == "playlist")
    }

    @Test
    func returnsEmptyForDegenerateWindow() {
        let steps = AccessibilityCursorPathBuilder.buildSteps(
            targetApp: "Spotify",
            windowBounds: WindowTargetBounds(x: 0, y: 0, width: 0, height: 0),
            controls: [control(id: "search", label: "Search", x: 10, y: 10, width: 20, height: 20)],
            targets: [AccessibilityCursorPathTarget(query: "Search", label: "Search")]
        )
        #expect(steps.isEmpty)
    }

    @Test
    func clampsOffWindowControlsIntoUnitRange() {
        // A control partly outside the window must clamp to [0, 1].
        let controls = [control(id: "edge", label: "Edge", x: 1_150, y: 850, width: 200, height: 200)]
        let steps = AccessibilityCursorPathBuilder.buildSteps(
            targetApp: "App",
            windowBounds: window,
            controls: controls,
            targets: [AccessibilityCursorPathTarget(query: "Edge", label: "Edge")]
        )
        let bounds = try! #require(steps.first?.bounds)
        #expect(bounds.origin.x >= 0 && bounds.origin.x <= 1)
        #expect(bounds.origin.y >= 0 && bounds.origin.y <= 1)
        #expect(bounds.origin.x + bounds.size.width <= 1.0001)
        #expect(bounds.origin.y + bounds.size.height <= 1.0001)
    }
}
