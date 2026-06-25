import Foundation

/// Makes a functional eval run against the SAME bundled toolchain as production. In a test process
/// `Bundle.main` is the test runner, not the app, so the agent's `bundledToolsDirectory` would resolve
/// nothing and `lit`/`pdf-fill`/`ffmpeg` would read as "command not found"; on top of that `lit` loads
/// pdfium at runtime and needs `PDFIUM_LIB_PATH`. This bootstrap points both at the repo's
/// `vendor/donkey-tools` (where `fetch-bundled-tools.sh` stages every tool, including `libpdfium.dylib`),
/// exactly the directory the shipped app uses. (The agent's working directory is routed into each run's
/// sandbox by the scenario, via `DONKEY_WORKSPACE_DIR`, so the suite never writes into the real `~/Donkey`.)
///
/// Idempotent — it sets fixed values and is safe to call from every scenario.
enum FunctionalEvalToolchain {
    /// The resolved bundled-tools directory, or nil when the repo's vendored tools are missing (the caller
    /// should fail loudly rather than run a "real pipeline" eval that silently lacks its tools).
    @discardableResult
    static func ensure() -> URL? {
        let env = ProcessInfo.processInfo.environment

        let toolsDir: URL?
        if let override = env["DONKEY_TOOLS_DIR"], !override.isEmpty {
            toolsDir = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else if let vendor = vendorToolsDirectory() {
            setenv("DONKEY_TOOLS_DIR", vendor.path, 1)
            toolsDir = vendor
        } else {
            toolsDir = nil
        }

        // The scenario routes each run's working directory into its sandbox (DONKEY_WORKSPACE_DIR), so we
        // don't set it here.

        guard let toolsDir, FileManager.default.fileExists(atPath: toolsDir.path) else { return nil }
        return toolsDir
    }

    /// `<repo>/vendor/donkey-tools`, found by walking up from this source file until the folder (with `lit`
    /// in it) appears. Robust to where the package sits on disk — no hard-coded depth.
    private static func vendorToolsDirectory(file: StaticString = #filePath) -> URL? {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("vendor/donkey-tools", isDirectory: true)
            if FileManager.default.isExecutableFile(atPath: candidate.appendingPathComponent("lit").path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
