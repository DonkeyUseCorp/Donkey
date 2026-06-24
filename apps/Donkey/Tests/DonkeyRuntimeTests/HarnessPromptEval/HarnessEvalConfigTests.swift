import Foundation
import Testing

/// Pure config-resolution checks for the prompt-eval runner — no network, so they run in a plain
/// `swift test` (unlike the scenario suites). They lock the two rules that matter: the eval still requires
/// the `DONKEY_PROMPT_EVAL=1` opt-in, and the backend URL no longer has to be passed by hand.
@Suite
struct HarnessEvalConfigTests {
    @Test
    func optInIsStillRequired() {
        // Without the opt-in flag the eval must skip, even if a URL is present — these tests hit the real
        // model and must never run by accident in a plain `swift test`.
        #expect(HarnessEvalRunner.configFromEnvironment([:]) == nil)
        #expect(HarnessEvalRunner.configFromEnvironment(["DONKEY_WEB_BASE_URL": "http://x.test"]) == nil)
    }

    @Test
    func backendURLDefaultsWhenUnset() {
        // The whole point of this change: opting in is enough; the URL defaults to the dev backend instead
        // of forcing the developer to export DONKEY_WEB_BASE_URL.
        let config = HarnessEvalRunner.configFromEnvironment(["DONKEY_PROMPT_EVAL": "1"])
        #expect(config?.baseURL == HarnessEvalRunner.defaultBaseURL)
    }

    @Test
    func explicitEnvURLStillWins() {
        let config = HarnessEvalRunner.configFromEnvironment([
            "DONKEY_PROMPT_EVAL": "1",
            "DONKEY_WEB_BASE_URL": "http://example.test:9999"
        ])
        #expect(config?.baseURL == URL(string: "http://example.test:9999"))
    }
}
