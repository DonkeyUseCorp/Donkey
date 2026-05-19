@testable import DonkeyRuntime
import CryptoKit
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

        #expect(instructions.count == 4)
        #expect(instructions.map(\.spec.id).contains(.parakeetTranscriber))
        #expect(instructions.map(\.spec.id).contains(.localLLM))
        #expect(instructions.first { $0.spec.id == .parakeetTranscriber }?.spec.environmentVariableName == "DONKEY_PARAKEET_TRANSCRIBER")
        #expect(instructions.first { $0.spec.id == .yoloSegmenter }?.spec.environmentVariableName == "DONKEY_YOLO_SEGMENTER")
        #expect(instructions.first { $0.spec.id == .uiUnderstander }?.spec.environmentVariableName == "DONKEY_UI_UNDERSTANDER")
        #expect(instructions.first { $0.spec.id == .localLLM }?.spec.environmentVariableName == "DONKEY_LOCAL_LLM_RUNNER")
        #expect(instructions.first?.spec.installSteps.first?.contains("Set Up") == true)
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

    @Test
    func manifestDownloadVerifiesSignatureMetadataChecksumsAndCachesPackage() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executableData = Data("#!/bin/sh\necho ok\n".utf8)
        let modelData = Data("fake-model".utf8)
        let manifest = LocalModelRuntimePackageManifest(
            runtimeID: .uiUnderstander,
            runtimeVersion: "1.0.0",
            modelID: "local-ui-understander",
            executableRelativePath: "bin/donkey-ui-understander",
            files: [
                LocalModelRuntimePackageFile(
                    relativePath: "bin/donkey-ui-understander",
                    downloadURL: URL(string: "https://example.test/ui/bin")!,
                    sha256: LocalModelRuntimeSetupManager.sha256Hex(executableData),
                    isExecutable: true
                ),
                LocalModelRuntimePackageFile(
                    relativePath: "models/ui-understander.bin",
                    downloadURL: URL(string: "https://example.test/ui/model")!,
                    sha256: LocalModelRuntimeSetupManager.sha256Hex(modelData)
                )
            ],
            signature: "signed-for-test",
            signingKeyID: "test-key"
        )
        let manager = try LocalModelRuntimeSetupManager(baseDirectory: root)

        let result = try await manager.downloadAndInstall(
            manifest: manifest,
            downloader: FakeRuntimeDownloader(files: [
                URL(string: "https://example.test/ui/bin")!: executableData,
                URL(string: "https://example.test/ui/model")!: modelData
            ])
        )
        let status = try manager.status(for: .uiUnderstander)

        #expect(result.state == .installed)
        #expect(status.state == .installed)
        #expect(status.installation?.runtimeVersion == "1.0.0")
        #expect(status.installation?.modelID == "local-ui-understander")
        #expect(status.installation?.downloadedDirectoryPath.contains("/Packages/ui-understander/1.0.0") == true)
        #expect(FileManager.default.fileExists(atPath: status.installation?.executablePath ?? "") == true)
    }

    @Test
    func cryptographicManifestSignatureIsVerifiedWhenKeyIsTrusted() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executableData = Data("#!/bin/sh\necho ok\n".utf8)
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKeyBase64 = privateKey.publicKey.rawRepresentation.base64EncodedString()
        var manifest = LocalModelRuntimePackageManifest(
            runtimeID: .uiUnderstander,
            runtimeVersion: "1.0.0",
            modelID: "local-ui-understander",
            executableRelativePath: "bin/donkey-ui-understander",
            files: [
                LocalModelRuntimePackageFile(
                    relativePath: "bin/donkey-ui-understander",
                    downloadURL: URL(string: "https://example.test/ui/bin")!,
                    sha256: LocalModelRuntimeSetupManager.sha256Hex(executableData),
                    isExecutable: true
                )
            ],
            signingKeyID: "test-release-key"
        )
        let payload = try LocalModelRuntimeSetupManager.signaturePayloadData(for: manifest)
        manifest.signature = try privateKey.signature(for: payload).base64EncodedString()
        let manager = try LocalModelRuntimeSetupManager(
            baseDirectory: root,
            trustedManifestSigningKeys: [
                LocalModelRuntimeManifestSigningKey(
                    keyID: "test-release-key",
                    publicKeyBase64: publicKeyBase64
                )
            ],
            requiresCryptographicManifestSignatures: true
        )

        let result = try await manager.downloadAndInstall(
            manifest: manifest,
            downloader: FakeRuntimeDownloader(files: [
                URL(string: "https://example.test/ui/bin")!: executableData
            ])
        )

        #expect(result.state == .installed)
    }

    @Test
    func cryptographicManifestSignatureRejectsUnknownKeyAndBadSignature() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executableData = Data("#!/bin/sh\necho ok\n".utf8)
        let privateKey = Curve25519.Signing.PrivateKey()
        var manifest = LocalModelRuntimePackageManifest(
            runtimeID: .yoloSegmenter,
            runtimeVersion: "1.0.0",
            modelID: "ultralytics/yolo26n-seg",
            executableRelativePath: "bin/donkey-yolo-segmenter",
            files: [
                LocalModelRuntimePackageFile(
                    relativePath: "bin/donkey-yolo-segmenter",
                    downloadURL: URL(string: "https://example.test/yolo/bin")!,
                    sha256: LocalModelRuntimeSetupManager.sha256Hex(executableData),
                    isExecutable: true
                )
            ],
            signingKeyID: "unknown-key"
        )
        let payload = try LocalModelRuntimeSetupManager.signaturePayloadData(for: manifest)
        manifest.signature = try privateKey.signature(for: payload).base64EncodedString()
        let manager = try LocalModelRuntimeSetupManager(
            baseDirectory: root,
            requiresCryptographicManifestSignatures: true
        )

        await #expect(throws: LocalModelRuntimeSetupError.manifestUnknownSigningKey("unknown-key")) {
            _ = try await manager.downloadAndInstall(
                manifest: manifest,
                downloader: FakeRuntimeDownloader(files: [
                    URL(string: "https://example.test/yolo/bin")!: executableData
                ])
            )
        }

        let trustedManager = try LocalModelRuntimeSetupManager(
            baseDirectory: root,
            trustedManifestSigningKeys: [
                LocalModelRuntimeManifestSigningKey(
                    keyID: "unknown-key",
                    publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString()
                )
            ],
            requiresCryptographicManifestSignatures: true
        )
        var tampered = manifest
        tampered.runtimeVersion = "2.0.0"

        await #expect(throws: LocalModelRuntimeSetupError.manifestInvalidSignature) {
            _ = try await trustedManager.downloadAndInstall(
                manifest: tampered,
                downloader: FakeRuntimeDownloader(files: [
                    URL(string: "https://example.test/yolo/bin")!: executableData
                ])
            )
        }
    }

    @Test
    func manifestDownloadRejectsMissingSignatureAndBadChecksums() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("#!/bin/sh\necho ok\n".utf8)
        let manager = try LocalModelRuntimeSetupManager(baseDirectory: root)
        let unsigned = LocalModelRuntimePackageManifest(
            runtimeID: .yoloSegmenter,
            runtimeVersion: "1.0.0",
            modelID: "ultralytics/yolo26n-seg",
            executableRelativePath: "bin/donkey-yolo-segmenter",
            files: [
                LocalModelRuntimePackageFile(
                    relativePath: "bin/donkey-yolo-segmenter",
                    downloadURL: URL(string: "https://example.test/yolo/bin")!,
                    sha256: LocalModelRuntimeSetupManager.sha256Hex(data),
                    isExecutable: true
                )
            ]
        )

        await #expect(throws: LocalModelRuntimeSetupError.manifestMissingSignature) {
            _ = try await manager.downloadAndInstall(
                manifest: unsigned,
                downloader: FakeRuntimeDownloader(files: [URL(string: "https://example.test/yolo/bin")!: data])
            )
        }

        let signedWithBadHash = LocalModelRuntimePackageManifest(
            runtimeID: .yoloSegmenter,
            runtimeVersion: "1.0.0",
            modelID: "ultralytics/yolo26n-seg",
            executableRelativePath: "bin/donkey-yolo-segmenter",
            files: [
                LocalModelRuntimePackageFile(
                    relativePath: "bin/donkey-yolo-segmenter",
                    downloadURL: URL(string: "https://example.test/yolo/bin")!,
                    sha256: "bad",
                    isExecutable: true
                )
            ],
            signature: "signed",
            signingKeyID: "test-key"
        )

        await #expect(throws: LocalModelRuntimeSetupError.manifestFileHashMismatch(relativePath: "bin/donkey-yolo-segmenter")) {
            _ = try await manager.downloadAndInstall(
                manifest: signedWithBadHash,
                downloader: FakeRuntimeDownloader(files: [URL(string: "https://example.test/yolo/bin")!: data])
            )
        }
    }

    @Test
    func recheckHealthRunsSidecarHealthProtocol() async throws {
        let root = temporaryDirectory()
        let download = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: download)
        }
        let healthExecutable = try makeHealthExecutable(
            root: download,
            relativePath: "bin/donkey-parakeet-transcriber",
            runtimeID: "parakeet-transcriber",
            runtimeVersion: "1.2.3",
            modelID: "nvidia/parakeet-tdt-0.6b-v3"
        )
        let manager = try LocalModelRuntimeSetupManager(baseDirectory: root)
        try manager.registerExecutable(
            runtimeID: .parakeetTranscriber,
            executableURL: healthExecutable,
            downloadedDirectory: download,
            runtimeVersion: "1.2.3",
            modelID: "nvidia/parakeet-tdt-0.6b-v3",
            sidecarProtocolVersion: "v1"
        )

        let report = try await manager.recheckHealth(runtimeID: .parakeetTranscriber)

        #expect(report.state == .healthy)
        #expect(report.runtimeVersion == "1.2.3")
        #expect(report.modelID == "nvidia/parakeet-tdt-0.6b-v3")
    }

    @Test
    func prepareModelWeightsRunsSidecarPreparationProtocol() async throws {
        let root = temporaryDirectory()
        let download = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: download)
        }
        let executable = try makeModelPreparationExecutable(
            root: download,
            relativePath: "bin/donkey-ui-understander",
            runtimeID: "ui-understander",
            modelID: "local-ui-understander"
        )
        let manager = try LocalModelRuntimeSetupManager(baseDirectory: root)
        try manager.registerExecutable(
            runtimeID: .uiUnderstander,
            executableURL: executable,
            downloadedDirectory: download,
            runtimeVersion: "1.0.0",
            modelID: "local-ui-understander",
            sidecarProtocolVersion: "v1",
            metadata: [
                "modelWeights.downloadURL": "https://example.test/ui/model.bin",
                "modelWeights.sha256": "abc",
                "modelWeights.filename": "ui.bin"
            ]
        )

        let report = try await manager.prepareModelWeights(runtimeID: .uiUnderstander)

        #expect(report.state == .prepared)
        #expect(report.modelID == "local-ui-understander")
        #expect(report.cacheDirectory?.contains("/ModelWeights/ui-understander/local-ui-understander") == true)
        #expect(report.metadata["modelWeights.status"] == "downloaded")
    }

    @Test
    func removeRuntimeClearsRegistryAndManagedFiles() throws {
        let root = temporaryDirectory()
        let download = root.appendingPathComponent("Packages/yolo-segmenter/1.0.0", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeExecutable(
            root: download,
            relativePath: "bin/donkey-yolo-segmenter"
        )
        let manager = try LocalModelRuntimeSetupManager(baseDirectory: root)
        try manager.registerExecutable(
            runtimeID: .yoloSegmenter,
            executableURL: executable,
            downloadedDirectory: download,
            runtimeVersion: "1.0.0",
            modelID: "ultralytics/yolo26n-seg"
        )

        let removed = try manager.removeRuntime(runtimeID: .yoloSegmenter)
        let status = try manager.status(for: .yoloSegmenter)

        #expect(removed)
        #expect(status.state == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: download.path))
    }

    @Test
    func supportExportOmitsUserDataAndIncludesRuntimeStatus() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try LocalModelRuntimeSetupManager(baseDirectory: root)

        let snapshot = try manager.supportSnapshot()
        let exportData = try manager.supportExportData()
        let exportText = String(decoding: exportData, as: UTF8.self)

        #expect(snapshot.statuses.count == 4)
        #expect(exportText.contains("parakeet-transcriber"))
        #expect(!exportText.contains(root.path))
    }

    private func makeExecutable(
        root: URL,
        relativePath: String
    ) throws -> URL {
        try makeFile(root: root, relativePath: relativePath, permissions: 0o755)
    }

    private func makeExecutable(
        root: URL,
        relativePath: String,
        data: Data
    ) throws -> URL {
        try makeFile(root: root, relativePath: relativePath, permissions: 0o755, data: data)
    }

    private func makeFile(
        root: URL,
        relativePath: String,
        permissions: Int,
        data: Data = Data("#!/bin/sh\ncat\n".utf8)
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
        try data.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
        return url
    }

    private func makeHealthExecutable(
        root: URL,
        relativePath: String,
        runtimeID: String,
        runtimeVersion: String,
        modelID: String
    ) throws -> URL {
        let script = """
        #!/bin/sh
        cat >/dev/null
        printf '{"status":"ok","runtimeID":"\(runtimeID)","runtimeVersion":"\(runtimeVersion)","modelID":"\(modelID)","protocolVersion":"v1","metadata":{"health":"ok"}}'
        """
        let url = relativePath
            .split(separator: "/")
            .reduce(root) { partialURL, component in
                partialURL.appendingPathComponent(String(component), isDirectory: false)
            }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url
    }

    private func makeModelPreparationExecutable(
        root: URL,
        relativePath: String,
        runtimeID: String,
        modelID: String
    ) throws -> URL {
        let script = """
        #!/bin/sh
        REQUEST="$(cat)"
        CACHE="$(printf '%s' "$REQUEST" | sed -n 's/.*"cacheDirectory"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p' | head -n 1)"
        mkdir -p "$CACHE"
        printf '{"status":"ok","runtimeID":"\(runtimeID)","modelID":"\(modelID)","cacheDirectory":"%s","metadata":{"modelWeights.status":"downloaded"}}' "$CACHE"
        """
        let url = relativePath
            .split(separator: "/")
            .reduce(root) { partialURL, component in
                partialURL.appendingPathComponent(String(component), isDirectory: false)
            }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("donkey-runtime-setup-tests-\(UUID().uuidString)", isDirectory: true)
    }
}

private struct FakeRuntimeDownloader: LocalModelRuntimePackageDownloading {
    var files: [URL: Data]

    func download(from url: URL) async throws -> Data {
        try #require(files[url])
    }
}
