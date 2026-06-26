import DonkeyContracts
import DonkeyHarness
import DonkeyRuntime
import Foundation
import Testing

@Suite
struct ImageRenderTests {
    @MainActor
    private func run(_ input: [String: String], baseDir: String?) async -> HarnessToolResult? {
        let descriptor = DonkeyCommandLayer.descriptors.first { $0.name == "image_render" }!
        var worldModel = HarnessWorldModel()
        if let baseDir {
            worldModel.facts["workspace.baseDir"] = baseDir
        }
        let context = HarnessToolExecutionContext(
            agentID: "test",
            call: HarnessToolCall(name: "image_render", input: input),
            descriptor: descriptor,
            worldModel: worldModel,
            grantedPermissions: []
        )
        return await DonkeyCommandBackends.makeExecutor()(context)
    }

    @Test
    @MainActor
    func imageRenderRequiresEitherHtmlOrHtmlPath() async {
        let result = await run([:], baseDir: nil)
        #expect(result?.status == .invalidInput)
    }

    @Test
    @MainActor
    func imageRenderWithDirectHtmlSucceeds() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let expectedDestination = tempDir.appendingPathComponent("output.png")
        let htmlContent = "<html><body><h1>Hello World</h1></body></html>"
        
        let result = await run([
            "html": htmlContent,
            "destination": "output.png",
            "format": "png"
        ], baseDir: tempDir.path)

        #expect(result?.status == .succeeded)
        #expect(FileManager.default.fileExists(atPath: expectedDestination.path))
    }

    @Test
    @MainActor
    func imageRenderWithHtmlPathSucceeds() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write template HTML file to workspace
        let templatePath = tempDir.appendingPathComponent("template.html")
        let htmlContent = "<html><body style='background: red;'><h1>Render from path</h1></body></html>"
        try htmlContent.write(to: templatePath, atomically: true, encoding: .utf8)

        let expectedDestination = tempDir.appendingPathComponent("rendered_output.png")
        
        // Pass relative path "template.html"
        let result = await run([
            "htmlPath": "template.html",
            "destination": "rendered_output.png",
            "format": "png"
        ], baseDir: tempDir.path)

        #expect(result?.status == .succeeded)
        #expect(FileManager.default.fileExists(atPath: expectedDestination.path))
    }
}
