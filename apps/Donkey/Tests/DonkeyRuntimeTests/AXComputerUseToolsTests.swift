import CoreGraphics
import DonkeyContracts
import DonkeyHarness
@testable import DonkeyRuntime
import Testing

/// Coverage for the AX-control → world-element mapping and the frame → click-point math that decides
/// where `ax.click` lands. Observation/click execution touches the live window server and is covered
/// by the live path.
@Suite
struct AXComputerUseToolsTests {
    private func control(
        id: String,
        frame: WindowTargetBounds?,
        isEnabled: Bool = true,
        actions: [String] = ["AXPress"]
    ) -> LocalAppDiscoveredControl {
        LocalAppDiscoveredControl(
            id: id,
            kind: .button,
            role: "AXButton",
            label: "Play",
            frame: frame,
            isEnabled: isEnabled,
            actions: actions
        )
    }

    @Test
    func worldElementCarriesScreenFrameForClick() {
        let element = try! #require(
            AXComputerUseToolProvider.worldElement(
                from: control(id: "ax-1.2", frame: WindowTargetBounds(x: 100, y: 200, width: 40, height: 20))
            )
        )
        #expect(element.id == "ax-1.2")
        #expect(element.role == "AXButton")
        #expect(element.isActionEligible)
        #expect(element.actions == ["AXPress"])

        // Frame center: (100+20, 200+10) = (120, 210), in absolute screen coordinates.
        let center = try! #require(AXComputerUseToolProvider.screenCenter(from: element.metadata))
        #expect(center.x == 120)
        #expect(center.y == 210)
    }

    @Test
    func controlWithoutUsableFrameIsDropped() {
        #expect(AXComputerUseToolProvider.worldElement(from: control(id: "x", frame: nil)) == nil)
        #expect(AXComputerUseToolProvider.worldElement(
            from: control(id: "y", frame: WindowTargetBounds(x: 0, y: 0, width: 0, height: 0))
        ) == nil)
    }

    @Test
    func screenCenterIsNilWhenMetadataIncomplete() {
        #expect(AXComputerUseToolProvider.screenCenter(from: ["ax.frame.x": "1"]) == nil)
        #expect(AXComputerUseToolProvider.screenCenter(from: [:]) == nil)
    }
}
