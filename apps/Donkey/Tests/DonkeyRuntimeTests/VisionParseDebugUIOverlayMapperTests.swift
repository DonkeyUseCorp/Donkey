import DonkeyAI
import DonkeyContracts
import Foundation
import Testing

@Suite
struct VisionParseDebugUIOverlayMapperTests {
    private func target(
        windowID: UInt32 = 11,
        bounds: WindowTargetBounds
    ) -> MacWindowTargetCandidate {
        MacWindowTargetCandidate(
            windowID: windowID,
            processID: 100,
            appName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            title: "Window",
            bounds: bounds,
            isVisible: true,
            isOnScreen: true,
            isFrontmost: true,
            isFocused: true,
            isIPhoneMirroring: false,
            safetyAssessment: WindowTargetSafetyAssessment(
                status: .allowed,
                summary: "allowed"
            )
        )
    }

    private func response(_ json: String) throws -> RemoteVisionParseResponse {
        try JSONDecoder().decode(RemoteVisionParseResponse.self, from: Data(json.utf8))
    }

    @Test
    func mapsPixelBoxIntoScreenLocalBounds() throws {
        // Image size equals the window size, so element pixels map 1:1 into window
        // space, then offset by the window origin and clipped to the screen.
        let parsed = try response(
            """
            {
              "image": { "width": 500, "height": 300 },
              "elements": [
                {
                  "id": "abc",
                  "label": "Save",
                  "kind": "button",
                  "interactive": true,
                  "box": { "x": 40, "y": 60, "width": 80, "height": 30 },
                  "point": { "x": 80, "y": 75 },
                  "confidence": 0.5
                }
              ]
            }
            """
        )

        let frame = VisionParseDebugUIOverlayMapper.frame(
            from: parsed,
            target: target(bounds: WindowTargetBounds(x: 100, y: 200, width: 500, height: 300)),
            screenFrame: WindowTargetBounds(x: 0, y: 0, width: 1000, height: 800),
            minConfidence: 0.25
        )

        let element = try #require(frame.elements.first { $0.id.hasPrefix("ai-") })
        #expect(element.id == "ai-11-abc")
        #expect(element.type == .button)
        #expect(element.label == "Save")
        #expect(element.bbox == DebugUIBoundingBox(x: 140, y: 260, width: 80, height: 30))
        #expect(element.metadata["localUIElement.sources"] == "remote-vision-parser")
        #expect(element.metadata["target.windowID"] == "11")
        #expect(element.metadata["debugOverlay.localBounds.x"] == "40.0")
        #expect(element.metadata["debugOverlay.localBounds.y"] == "60.0")
        #expect(element.metadata["debugOverlay.localBounds.width"] == "80.0")
        #expect(element.metadata["debugOverlay.localBounds.height"] == "30.0")
    }

    @Test
    func scalesBoxesWhenImageSizeDiffersFromWindow() throws {
        // Worker saw a 250x150 image but the window is 500x300, so boxes scale 2x.
        let parsed = try response(
            """
            {
              "image": { "width": 250, "height": 150 },
              "elements": [
                {
                  "id": "x1",
                  "label": "Icon",
                  "kind": "icon",
                  "interactive": false,
                  "box": { "x": 20, "y": 30, "width": 40, "height": 15 },
                  "point": { "x": 40, "y": 37 },
                  "confidence": 0.5
                }
              ]
            }
            """
        )

        let frame = VisionParseDebugUIOverlayMapper.frame(
            from: parsed,
            target: target(bounds: WindowTargetBounds(x: 0, y: 0, width: 500, height: 300)),
            screenFrame: WindowTargetBounds(x: 0, y: 0, width: 1000, height: 800),
            minConfidence: 0.25
        )

        let element = try #require(frame.elements.first { $0.id.hasPrefix("ai-") })
        #expect(element.type == .other)
        #expect(element.bbox == DebugUIBoundingBox(x: 40, y: 60, width: 80, height: 30))
    }

    @Test
    func dropsElementsBelowConfidenceThreshold() throws {
        let parsed = try response(
            """
            {
              "image": { "width": 500, "height": 300 },
              "elements": [
                {
                  "id": "lowconf",
                  "label": "Maybe",
                  "kind": "button",
                  "interactive": true,
                  "box": { "x": 10, "y": 10, "width": 20, "height": 20 },
                  "point": { "x": 20, "y": 20 },
                  "confidence": 0.5
                }
              ]
            }
            """
        )

        let frame = VisionParseDebugUIOverlayMapper.frame(
            from: parsed,
            target: target(bounds: WindowTargetBounds(x: 0, y: 0, width: 500, height: 300)),
            screenFrame: WindowTargetBounds(x: 0, y: 0, width: 1000, height: 800),
            minConfidence: 0.75
        )

        #expect(frame.elements.first { $0.id.hasPrefix("ai-") } == nil)
    }
}
