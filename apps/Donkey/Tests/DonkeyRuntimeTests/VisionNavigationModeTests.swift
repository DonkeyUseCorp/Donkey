@testable import Donkey
import Testing

/// Unit coverage for the configurable, env-gated vision-navigation route flag. The route itself
/// drives real input/screenshots (covered by the live smoke pattern), but the on/off parsing is
/// pure and must stay reliable so the path is easy to enable and revert.
@Suite
struct VisionNavigationModeTests {
    @Test
    func enabledForTruthyValues() {
        for value in ["1", "true", "TRUE", "Yes", "on"] {
            let mode = VisionNavigationMode.fromEnvironment(["DONKEY_VISION_NAV": value])
            #expect(mode.isEnabled, "expected \"\(value)\" to enable vision navigation")
        }
    }

    @Test
    func disabledByDefaultAndForFalsyValues() {
        #expect(VisionNavigationMode.fromEnvironment([:]).isEnabled == false)
        for value in ["", "0", "false", "off", "no", "  "] {
            let mode = VisionNavigationMode.fromEnvironment(["DONKEY_VISION_NAV": value])
            #expect(mode.isEnabled == false, "expected \"\(value)\" to leave vision navigation off")
        }
    }

    @Test
    func toleratesSurroundingWhitespaceAndCase() {
        #expect(VisionNavigationMode.fromEnvironment(["DONKEY_VISION_NAV": "  On  "]).isEnabled)
    }
}
