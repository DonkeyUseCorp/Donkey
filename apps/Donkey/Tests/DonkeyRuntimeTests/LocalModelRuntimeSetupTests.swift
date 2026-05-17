@testable import DonkeyRuntime
import Foundation
import Testing

@Suite
struct LocalModelRuntimeSetupTests {
    @Test
    func setupInstructionsDescribeDownloadThenAppRegistration() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = try LocalModelRuntimeSetupManager(baseDirectory: root)
        let instructions = manager.instructions()

        #expect(instructions.count == 3)
        #expect(instructions.map(\.spec.id).contains(.parakeetTranscriber))
        #expect(instructions.first { $0.spec.id == .parakeetTranscriber }?.spec.environmentVariableName == "DONKEY_PARAKEET_TRANSCRIBER")
        #expect(instructions.first { $0.spec.id == .yoloSegmenter }?.spec.environmentVariableName == "DONKEY_YOLO_SEGMENTER")
        #expect(instructions.first { $0.spec.id == .uiUnderstander }?.spec.environmentVariableName == "DONKEY_UI_UNDERSTANDER")
        #expect(instructions.first?.spec.installSteps.first?.contains("Download") == true)
    }

    @Test
    func registerDownloadedRuntimeStoresExecutablePathInApplicationSupportRegistry() throws {
        let root = temporaryDirectory()
        let download = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: download)
        }
        let executableURL = try makeExecutable(
            root: download,
            relativePath: "bin/donkey-yolo-segmenter"
        )
        let manager = try LocalModelRuntimeSetupManager(baseDirectory: root)

        let installation = try manager.registerDownloadedRuntime(
            runtimeID: .yoloSegmenter,
            downloadedDirectory: download
        )
        let status = try manager.status(for: .yoloSegmenter)
        let environment = try manager.configuredEnvironment()

        #expect(installation.executablePath == executableURL.path)
        #expect(status.state == .installed)
        #expect(status.installation?.downloadedDirectoryPath == download.path)
        #expect(environment["DONKEY_YOLO_SEGMENTER"] == executableURL.path)
    }

    @Test
    func registerDownloadedRuntimeFailsWhenExecutableIsMissingOrNotExecutable() throws {
        let root = temporaryDirectory()
        let download = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: download)
        }
        let manager = try LocalModelRuntimeSetupManager(baseDirectory: root)

        #expect(throws: LocalModelRuntimeSetupError.missingDownloadedExecutable(
            runtimeID: .parakeetTranscriber,
            expectedRelativePath: "bin/donkey-parakeet-transcriber"
        )) {
            _ = try manager.registerDownloadedRuntime(
                runtimeID: .parakeetTranscriber,
                downloadedDirectory: download
            )
        }

        let executableURL = try makeFile(
            root: download,
            relativePath: "bin/donkey-parakeet-transcriber",
            permissions: 0o644
        )
        #expect(throws: LocalModelRuntimeSetupError.downloadedExecutableNotExecutable(
            runtimeID: .parakeetTranscriber,
            path: executableURL.path
        )) {
            _ = try manager.registerDownloadedRuntime(
                runtimeID: .parakeetTranscriber,
                downloadedDirectory: download
            )
        }
    }

    @Test
    func processRunnerResolvesAppManagedRuntimeWhenShellEnvironmentIsMissing() async throws {
        let root = temporaryDirectory()
        let download = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: download)
        }
        let executableURL = URL(fileURLWithPath: "/bin/cat")
        let manager = try LocalModelRuntimeSetupManager(baseDirectory: root)
        try manager.registerExecutable(
            runtimeID: .parakeetTranscriber,
            executableURL: executableURL,
            downloadedDirectory: download
        )
        let resolver = LocalModelRuntimeExecutableResolver {
            try LocalModelRuntimeSetupManager(baseDirectory: root)
        }
        let runner = ProcessBackedLocalJSONSidecarRunner(
            environment: [:],
            executableResolver: { environmentVariableName, _ in
                resolver.executablePath(environmentVariableName: environmentVariableName)
            }
        )

        let result = await runner.run(
            LocalJSONSidecarRequest(
                environmentVariableName: "DONKEY_PARAKEET_TRANSCRIBER",
                inputData: Data("{\"ok\":true}".utf8),
                timeoutMS: 1_000
            )
        )

        #expect(result.status == .completed)
        #expect(String(decoding: result.outputData, as: UTF8.self) == "{\"ok\":true}")
        #expect(result.metadata["sidecar.executablePath"] == executableURL.path)
    }

    private func makeExecutable(
        root: URL,
        relativePath: String
    ) throws -> URL {
        try makeFile(root: root, relativePath: relativePath, permissions: 0o755)
    }

    private func makeFile(
        root: URL,
        relativePath: String,
        permissions: Int
    ) throws -> URL {
        let url = relativePath
            .split(separator: "/")
            .reduce(root) { partialURL, component in
                partialURL.appendingPathComponent(String(component), isDirectory: false)
            }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\ncat\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
        return url
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("donkey-runtime-setup-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
