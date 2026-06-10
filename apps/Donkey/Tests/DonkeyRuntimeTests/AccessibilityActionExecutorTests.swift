import CoreGraphics
@testable import DonkeyRuntime
import DonkeyContracts
import Foundation
import Testing

@Suite
struct AccessibilityActionExecutorTests {
    @Test
    func clickPointIsTheCenterOfTheControlFrame() {
        let frame = WindowTargetBounds(x: 100, y: 200, width: 80, height: 40)
        let point = AccessibilityActionExecutor.clickPoint(for: frame)
        #expect(point.x == 140)
        #expect(point.y == 220)
    }

    @Test
    func modifierTokensMapToEventFlags() {
        #expect(MacKeyboardInput.eventFlags(for: ["command"]) == .maskCommand)
        #expect(MacKeyboardInput.eventFlags(for: ["cmd+shift"]) == [.maskCommand, .maskShift])
        #expect(MacKeyboardInput.eventFlags(for: ["option", "ctrl"]) == [.maskAlternate, .maskControl])
        // Unknown tokens are ignored rather than guessed.
        #expect(MacKeyboardInput.eventFlags(for: ["hyper"]).isEmpty)
        #expect(MacKeyboardInput.eventFlags(for: []).isEmpty)
    }

    @Test
    func letterAndNamedKeysResolveToVirtualKeyCodes() {
        // Chords like Cmd+C need concrete letter key codes, not unicode typing.
        #expect(MacKeyboardInput.virtualKeyCode(for: "c") == 8)
        #expect(MacKeyboardInput.virtualKeyCode(for: "a") == 0)
        #expect(MacKeyboardInput.virtualKeyCode(for: "return") == 36)
        #expect(MacKeyboardInput.virtualKeyCode(for: "pagedown") == 121)
        #expect(MacKeyboardInput.virtualKeyCode(for: "notakey") == nil)
    }
}
