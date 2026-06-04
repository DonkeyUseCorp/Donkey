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
