import CoreGraphics
@testable import DonkeyAI
import DonkeyContracts
import DonkeyHarness
import DonkeyRuntime
import Testing

/// Coverage for the pure mapping pieces that decide WHERE a vision-detected element gets clicked and
/// WHICH tool the model's per-turn decision invokes. The capture/click execution itself touches the
/// real window server and is exercised by the live path.
@Suite
struct VisionComputerUseToolsTests {
    private func element(
        id: String,
        bbox: DebugUIBoundingBox,
        confidence: Double = 0.9
    ) -> DebugUIElement {
        DebugUIElement(id: id, type: .button, label: "Play", bbox: bbox, confidence: confidence)
    }

    @Test
    func worldElementCarriesGeometryForLaterClickMapping() {
        let detected = element(id: "e1", bbox: DebugUIBoundingBox(x: 350, y: 250, width: 100, height: 100))
        let world = VisionComputerUseToolProvider.worldElement(from: detected, imageWidth: 800, imageHeight: 600)

        #expect(world.id == "e1")
        #expect(world.role == "button")
        #expect(world.isActionEligible)
        #expect(world.actions == ["click"])

        // The stored geometry round-trips back through `geometry(from:)` so a click can re-derive the
        // box center against the window's current bounds.
        let geometry = VisionComputerUseToolProvider.geometry(from: world.metadata)
        #expect(geometry?.imageWidth == 800)
        #expect(geometry?.imageHeight == 600)
        #expect(geometry?.bbox.width == 100)

        // Same parse-pixel → 0–1000 normalized mapping the image planner uses: center (400,300) in an
        // 800x600 image → (500, 500).
        if let geometry {
            let normalized = VisionComputerUseToolProvider.normalizedCenter(
                bbox: geometry.bbox,
                imageWidth: geometry.imageWidth,
                imageHeight: geometry.imageHeight
            )
            #expect(abs(normalized.x - 500) < 0.001)
            #expect(abs(normalized.y - 500) < 0.001)
        }
    }

    @Test
    func screenScopeElementMapsThroughDisplayRectNotWindow() {
        // A modal/dialog detected in a full-screen (scope=screen) capture carries the DISPLAY rect it
        // was found in, so its click maps through that rect — even on a second display offset from the
        // origin. Center of a 1920x1080 parse image, against a display at x-offset 1920, lands dead
        // center of that display: (1920 + 960, 0 + 540).
        let display = WindowTargetBounds(x: 1920, y: 0, width: 1920, height: 1080)
        let detected = element(id: "delete-btn", bbox: DebugUIBoundingBox(x: 910, y: 490, width: 100, height: 100))
        let world = VisionComputerUseToolProvider.worldElement(
            from: detected, imageWidth: 1920, imageHeight: 1080, region: display
        )

        #expect(world.metadata["vision.scope"] == "screen")
        let geometry = VisionComputerUseToolProvider.geometry(from: world.metadata)
        #expect(geometry?.region == display)

        if let geo = geometry, let region = geo.region {
            let normalized = VisionComputerUseToolProvider.normalizedCenter(
                bbox: geo.bbox, imageWidth: geo.imageWidth, imageHeight: geo.imageHeight
            )
            let point = VisionComputerActionExecutor.screenPoint(
                VisionComputerAction.Point(x: normalized.x, y: normalized.y), window: region
            )
            #expect(abs(point.x - 2880) < 0.5)
            #expect(abs(point.y - 540) < 0.5)
        } else {
            Issue.record("expected screen-scope geometry with a region")
        }
    }

    @Test
    func windowScopeElementHasNoRegion() {
        // A normal window capture carries no region, so the click falls back to the window's current
        // bounds (re-resolved at click time, so it stays correct if the window moved).
        let detected = element(id: "e1", bbox: DebugUIBoundingBox(x: 10, y: 10, width: 20, height: 20))
        let world = VisionComputerUseToolProvider.worldElement(from: detected, imageWidth: 100, imageHeight: 100)
        #expect(world.metadata["vision.scope"] == nil)
        #expect(VisionComputerUseToolProvider.geometry(from: world.metadata)?.region == nil)
    }

    @Test
    func zeroAreaElementIsNotActionEligible() {
        let detected = element(id: "e2", bbox: DebugUIBoundingBox(x: 0, y: 0, width: 0, height: 0))
        let world = VisionComputerUseToolProvider.worldElement(from: detected, imageWidth: 100, imageHeight: 100)
        #expect(!world.isActionEligible)
    }

    @Test
    func geometryIsNilWhenMetadataIncomplete() {
        #expect(VisionComputerUseToolProvider.geometry(from: ["vision.bbox.x": "1"]) == nil)
        #expect(VisionComputerUseToolProvider.geometry(from: [:]) == nil)
    }

    @Test
    func visionToolNamesAreNamespaced() {
        // Vision is one tool family among several in the registry; its see/act tools are namespaced so
        // the planner can tell them apart from the AX tools. Keyboard input stays generic (shared).
        #expect(VisionComputerUseToolProvider.ToolName.captureAndAnalyze == "vision.capture")
        #expect(VisionComputerUseToolProvider.ToolName.click == "vision.click")
        #expect(VisionComputerUseToolProvider.ToolName.typeText == "text.enter")
        #expect(VisionComputerUseToolProvider.ToolName.pressKey == "keyboard.press")
    }
}
