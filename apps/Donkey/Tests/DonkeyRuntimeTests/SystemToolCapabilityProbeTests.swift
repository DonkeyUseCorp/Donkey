import DonkeyRuntime
import Foundation
import Testing

@Suite
struct SystemToolCapabilityProbeTests {
    @Test
    func summaryNeverBlocksOnFirstUseAndServesTheBackgroundResultAfter() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("tool-capabilities.json")
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

        // zsh ships with macOS, so the probe has one deterministic hit.
        let probe = SystemToolCapabilityProbe(cacheURL: cacheURL, toolNames: ["zsh"])

        // First call must not wait on subprocesses — it kicks the probe off and
        // returns an empty environment line.
        #expect(await probe.summary() == "")

        // The background probe lands shortly and subsequent calls serve it.
        var summary = ""
        for _ in 0..<100 where summary.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
            summary = await probe.summary()
        }
        #expect(summary.contains("zsh"))

        // The result is persisted: a fresh instance reads it without re-probing.
        let second = SystemToolCapabilityProbe(cacheURL: cacheURL, toolNames: ["zsh"])
        #expect(await second.summary() == summary)
    }
}
