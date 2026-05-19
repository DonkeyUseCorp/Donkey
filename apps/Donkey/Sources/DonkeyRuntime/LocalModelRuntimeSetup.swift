import CryptoKit
import Foundation

public enum LocalModelRuntimeID: String, Codable, CaseIterable, Equatable, Sendable {
    case parakeetTranscriber = "parakeet-transcriber"
    case yoloSegmenter = "yolo-segmenter"
    case uiUnderstander = "ui-understander"
    case localLLM = "local-llm"
}

public enum LocalModelRuntimeInstallState: String, Codable, Equatable, Sendable {
    case installed
    case notInstalled
    case invalidExecutable
    case healthCheckFailed
}

public enum LocalModelRuntimeSetupError: Error, Equatable, Sendable {
    case unknownRuntime(String)
    case missingDownloadedExecutable(runtimeID: LocalModelRuntimeID, expectedRelativePath: String)
    case downloadedExecutableNotExecutable(runtimeID: LocalModelRuntimeID, path: String)
    case manifestRuntimeMismatch(expected: LocalModelRuntimeID, actual: LocalModelRuntimeID)
    case manifestUnsupportedPlatform(String)
    case manifestUnsupportedArchitecture(String)
    case manifestMissingExecutable(String)
    case manifestFileHashMismatch(relativePath: String)
    case manifestMissingDownloadURL(relativePath: String)
    case manifestMissingSignature
    case manifestUnknownSigningKey(String)
    case manifestInvalidSignature
}

public enum LocalModelRuntimeDownloadState: String, Codable, Equatable, Sendable {
    case idle
    case downloading
    case installed
    case failed
}

public enum LocalModelRuntimeHealthState: String, Codable, Equatable, Sendable {
    case healthy
    case unavailable
    case failed
    case invalidOutput
}

public enum LocalModelRuntimeModelPreparationState: String, Codable, Equatable, Sendable {
    case prepared
    case unavailable
    case failed
    case invalidOutput
}

public struct LocalModelRuntimeSpec: Codable, Equatable, Sendable {
    public var id: LocalModelRuntimeID
    public var displayName: String
    public var environmentVariableName: String
    public var expectedExecutableRelativePath: String
    public var modelName: String
    public var downloadPageURL: URL?
    public var manifestURL: URL?
    public var installSteps: [String]
    public var metadata: [String: String]

    public init(
        id: LocalModelRuntimeID,
        displayName: String,
        environmentVariableName: String,
        expectedExecutableRelativePath: String,
        modelName: String,
        downloadPageURL: URL? = nil,
        manifestURL: URL? = nil,
        installSteps: [String],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.displayName = displayName
        self.environmentVariableName = environmentVariableName
        self.expectedExecutableRelativePath = expectedExecutableRelativePath
        self.modelName = modelName
        self.downloadPageURL = downloadPageURL
        self.manifestURL = manifestURL
        self.installSteps = installSteps
        self.metadata = metadata
    }
}

public struct LocalModelRuntimePackageFile: Codable, Equatable, Sendable {
    public var relativePath: String
    public var downloadURL: URL?
    public var sha256: String
    public var isExecutable: Bool

    public init(
        relativePath: String,
        downloadURL: URL? = nil,
        sha256: String,
        isExecutable: Bool = false
    ) {
        self.relativePath = relativePath
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.isExecutable = isExecutable
    }
}

public struct LocalModelRuntimePackageManifest: Codable, Equatable, Sendable {
    public var runtimeID: LocalModelRuntimeID
    public var runtimeVersion: String
    public var modelID: String
    public var platform: String
    public var architecture: String
    public var sidecarProtocolVersion: String
    public var minimumDonkeyVersion: String
    public var executableRelativePath: String
    public var files: [LocalModelRuntimePackageFile]
    public var signature: String?
    public var signingKeyID: String?
    public var releaseNotesURL: URL?
    public var metadata: [String: String]

    public init(
        runtimeID: LocalModelRuntimeID,
        runtimeVersion: String,
        modelID: String,
        platform: String = LocalModelRuntimePackageManifest.currentPlatform,
        architecture: String = LocalModelRuntimePackageManifest.currentArchitecture,
        sidecarProtocolVersion: String = "v1",
        minimumDonkeyVersion: String = "0.0.0",
        executableRelativePath: String,
        files: [LocalModelRuntimePackageFile],
        signature: String? = nil,
        signingKeyID: String? = nil,
        releaseNotesURL: URL? = nil,
        metadata: [String: String] = [:]
    ) {
        self.runtimeID = runtimeID
        self.runtimeVersion = runtimeVersion
        self.modelID = modelID
        self.platform = platform
        self.architecture = architecture
        self.sidecarProtocolVersion = sidecarProtocolVersion
        self.minimumDonkeyVersion = minimumDonkeyVersion
        self.executableRelativePath = executableRelativePath
        self.files = files
        self.signature = signature
        self.signingKeyID = signingKeyID
        self.releaseNotesURL = releaseNotesURL
        self.metadata = metadata
    }

    public static var currentPlatform: String { "macos" }

    public static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

public struct LocalModelRuntimeInstallation: Codable, Equatable, Sendable {
    public var runtimeID: LocalModelRuntimeID
    public var executablePath: String
    public var downloadedDirectoryPath: String
    public var installedAt: Date
    public var runtimeVersion: String?
    public var modelID: String?
    public var sidecarProtocolVersion: String?
    public var metadata: [String: String]

    public init(
        runtimeID: LocalModelRuntimeID,
        executablePath: String,
        downloadedDirectoryPath: String,
        installedAt: Date,
        runtimeVersion: String? = nil,
        modelID: String? = nil,
        sidecarProtocolVersion: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.runtimeID = runtimeID
        self.executablePath = executablePath
        self.downloadedDirectoryPath = downloadedDirectoryPath
        self.installedAt = installedAt
        self.runtimeVersion = runtimeVersion
        self.modelID = modelID
        self.sidecarProtocolVersion = sidecarProtocolVersion
        self.metadata = metadata
    }
}

public struct LocalModelRuntimeStatus: Codable, Equatable, Sendable {
    public var spec: LocalModelRuntimeSpec
    public var state: LocalModelRuntimeInstallState
    public var installation: LocalModelRuntimeInstallation?
    public var metadata: [String: String]

    public init(
        spec: LocalModelRuntimeSpec,
        state: LocalModelRuntimeInstallState,
        installation: LocalModelRuntimeInstallation? = nil,
        metadata: [String: String] = [:]
    ) {
        self.spec = spec
        self.state = state
        self.installation = installation
        self.metadata = metadata
    }
}

public struct LocalModelRuntimeHealthReport: Codable, Equatable, Sendable {
    public var runtimeID: LocalModelRuntimeID
    public var state: LocalModelRuntimeHealthState
    public var runtimeVersion: String?
    public var modelID: String?
    public var sidecarProtocolVersion: String?
    public var latencyMS: Double?
    public var metadata: [String: String]

    public init(
        runtimeID: LocalModelRuntimeID,
        state: LocalModelRuntimeHealthState,
        runtimeVersion: String? = nil,
        modelID: String? = nil,
        sidecarProtocolVersion: String? = nil,
        latencyMS: Double? = nil,
        metadata: [String: String] = [:]
    ) {
        self.runtimeID = runtimeID
        self.state = state
        self.runtimeVersion = runtimeVersion
        self.modelID = modelID
        self.sidecarProtocolVersion = sidecarProtocolVersion
        self.latencyMS = latencyMS
        self.metadata = metadata
    }
}

public struct LocalModelRuntimeDownloadResult: Codable, Equatable, Sendable {
    public var runtimeID: LocalModelRuntimeID
    public var state: LocalModelRuntimeDownloadState
    public var installation: LocalModelRuntimeInstallation?
    public var metadata: [String: String]

    public init(
        runtimeID: LocalModelRuntimeID,
        state: LocalModelRuntimeDownloadState,
        installation: LocalModelRuntimeInstallation? = nil,
        metadata: [String: String] = [:]
    ) {
        self.runtimeID = runtimeID
        self.state = state
        self.installation = installation
        self.metadata = metadata
    }
}

public struct LocalModelRuntimeModelPreparationReport: Codable, Equatable, Sendable {
    public var runtimeID: LocalModelRuntimeID
    public var state: LocalModelRuntimeModelPreparationState
    public var cacheDirectory: String?
    public var modelID: String?
    public var latencyMS: Double?
    public var metadata: [String: String]

    public init(
        runtimeID: LocalModelRuntimeID,
        state: LocalModelRuntimeModelPreparationState,
        cacheDirectory: String? = nil,
        modelID: String? = nil,
        latencyMS: Double? = nil,
        metadata: [String: String] = [:]
    ) {
        self.runtimeID = runtimeID
        self.state = state
        self.cacheDirectory = cacheDirectory
        self.modelID = modelID
        self.latencyMS = latencyMS
        self.metadata = metadata
    }
}

public struct LocalModelRuntimeManifestSigningKey: Equatable, Sendable {
    public var keyID: String
    public var publicKeyBase64: String

    public init(keyID: String, publicKeyBase64: String) {
        self.keyID = keyID
        self.publicKeyBase64 = publicKeyBase64
    }
}

public struct LocalModelRuntimeRepairReport: Codable, Equatable, Sendable {
    public var runtimeID: LocalModelRuntimeID
    public var downloadResult: LocalModelRuntimeDownloadResult
    public var modelPreparation: LocalModelRuntimeModelPreparationReport
    public var health: LocalModelRuntimeHealthReport
    public var metadata: [String: String]

    public init(
        runtimeID: LocalModelRuntimeID,
        downloadResult: LocalModelRuntimeDownloadResult,
        modelPreparation: LocalModelRuntimeModelPreparationReport,
        health: LocalModelRuntimeHealthReport,
        metadata: [String: String] = [:]
    ) {
        self.runtimeID = runtimeID
        self.downloadResult = downloadResult
        self.modelPreparation = modelPreparation
        self.health = health
        self.metadata = metadata
    }
}

public struct LocalModelRuntimeSupportStatus: Codable, Equatable, Sendable {
    public var runtimeID: LocalModelRuntimeID
    public var displayName: String
    public var state: LocalModelRuntimeInstallState
    public var environmentVariableName: String
    public var runtimeVersion: String?
    public var modelID: String
    public var sidecarProtocolVersion: String?
    public var reason: String?

    public init(
        runtimeID: LocalModelRuntimeID,
        displayName: String,
        state: LocalModelRuntimeInstallState,
        environmentVariableName: String,
        runtimeVersion: String? = nil,
        modelID: String,
        sidecarProtocolVersion: String? = nil,
        reason: String? = nil
    ) {
        self.runtimeID = runtimeID
        self.displayName = displayName
        self.state = state
        self.environmentVariableName = environmentVariableName
        self.runtimeVersion = runtimeVersion
        self.modelID = modelID
        self.sidecarProtocolVersion = sidecarProtocolVersion
        self.reason = reason
    }
}

public struct LocalModelRuntimeSupportSnapshot: Codable, Equatable, Sendable {
    public var generatedAt: Date
    public var statuses: [LocalModelRuntimeSupportStatus]

    public init(
        generatedAt: Date,
        statuses: [LocalModelRuntimeSupportStatus]
    ) {
        self.generatedAt = generatedAt
        self.statuses = statuses
    }
}

public protocol LocalModelRuntimePackageDownloading: Sendable {
    func download(from url: URL) async throws -> Data
}

public struct URLSessionLocalModelRuntimePackageDownloader: LocalModelRuntimePackageDownloading {
    public init() {}

    public func download(from url: URL) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }
}

public struct LocalModelRuntimeInstallInstruction: Codable, Equatable, Sendable {
    public var spec: LocalModelRuntimeSpec
    public var setupDirectory: URL

    public init(spec: LocalModelRuntimeSpec, setupDirectory: URL) {
        self.spec = spec
        self.setupDirectory = setupDirectory
    }
}

public struct LocalModelRuntimeRegistry: Codable, Equatable, Sendable {
    public var installations: [String: LocalModelRuntimeInstallation]

    public init(installations: [String: LocalModelRuntimeInstallation] = [:]) {
        self.installations = installations
    }
}

public struct LocalModelRuntimeSetupManager: Sendable {
    public var baseDirectory: URL
    public var specs: [LocalModelRuntimeSpec]
    public var isExecutableFile: @Sendable (String) -> Bool
    public var now: @Sendable () -> Date
    public var trustedManifestSigningKeys: [String: String]
    public var requiresCryptographicManifestSignatures: Bool

    public init(
        baseDirectory: URL? = nil,
        specs: [LocalModelRuntimeSpec] = Self.defaultSpecs,
        isExecutableFile: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        now: @escaping @Sendable () -> Date = Date.init,
        trustedManifestSigningKeys: [LocalModelRuntimeManifestSigningKey] = Self.defaultTrustedManifestSigningKeys(),
        requiresCryptographicManifestSignatures: Bool = Self.defaultRequiresCryptographicManifestSignatures()
    ) throws {
        self.baseDirectory = try baseDirectory ?? Self.defaultBaseDirectory()
        self.specs = specs
        self.isExecutableFile = isExecutableFile
        self.now = now
        self.trustedManifestSigningKeys = Dictionary(
            uniqueKeysWithValues: trustedManifestSigningKeys.map { ($0.keyID, $0.publicKeyBase64) }
        )
        self.requiresCryptographicManifestSignatures = requiresCryptographicManifestSignatures
    }

    public static let defaultSpecs: [LocalModelRuntimeSpec] = [
        LocalModelRuntimeSpec(
            id: .parakeetTranscriber,
            displayName: "Parakeet voice transcription",
            environmentVariableName: "DONKEY_PARAKEET_TRANSCRIBER",
            expectedExecutableRelativePath: "bin/donkey-parakeet-transcriber",
            modelName: "nvidia/parakeet-tdt-0.6b-v3",
            downloadPageURL: URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3"),
            manifestURL: Self.defaultPackageManifestURL(for: .parakeetTranscriber),
            installSteps: [
                "Click Set Up in Donkey after installing the app.",
                "Donkey downloads and verifies the compatible Parakeet runtime package.",
                "Donkey records bin/donkey-parakeet-transcriber in Application Support."
            ],
            metadata: ["sidecar.role": "voiceTranscription"]
        ),
        LocalModelRuntimeSpec(
            id: .yoloSegmenter,
            displayName: "YOLO26 screenshot segmentation",
            environmentVariableName: "DONKEY_YOLO_SEGMENTER",
            expectedExecutableRelativePath: "bin/donkey-yolo-segmenter",
            modelName: "ultralytics/yolo26n-seg",
            downloadPageURL: URL(string: "https://docs.ultralytics.com/models/yolo26/"),
            manifestURL: Self.defaultPackageManifestURL(for: .yoloSegmenter),
            installSteps: [
                "Click Set Up in Donkey after installing the app.",
                "Donkey downloads and verifies the compatible YOLO26 segmentation runtime package.",
                "Donkey records bin/donkey-yolo-segmenter in Application Support."
            ],
            metadata: ["sidecar.role": "screenshotSegmentation"]
        ),
        LocalModelRuntimeSpec(
            id: .uiUnderstander,
            displayName: "Local UI understanding",
            environmentVariableName: "DONKEY_UI_UNDERSTANDER",
            expectedExecutableRelativePath: "bin/donkey-ui-understander",
            modelName: "apple-vision-text-recognition",
            downloadPageURL: nil,
            manifestURL: Self.defaultPackageManifestURL(for: .uiUnderstander),
            installSteps: [
                "Click Set Up in Donkey after installing the app.",
                "Donkey downloads and verifies the compatible UI-understanding runtime package.",
                "Donkey records bin/donkey-ui-understander in Application Support."
            ],
            metadata: ["sidecar.role": "uiUnderstanding"]
        ),
        LocalModelRuntimeSpec(
            id: .localLLM,
            displayName: "Local command parser LLM",
            environmentVariableName: "DONKEY_LOCAL_LLM_RUNNER",
            expectedExecutableRelativePath: "bin/donkey-local-llm",
            modelName: "qwen3:8b",
            downloadPageURL: URL(string: "https://ollama.com/library/qwen3"),
            manifestURL: Self.defaultPackageManifestURL(for: .localLLM),
            installSteps: [
                "Click Set Up in Donkey after installing the app.",
                "Donkey asks the local LLM runner to download and cache qwen3:8b.",
                "Donkey records bin/donkey-local-llm in Application Support."
            ],
            metadata: [
                "sidecar.role": "localLLM",
                "modelWeights.provider": "ollama",
                "modelWeights.ollamaModel": "qwen3:8b"
            ]
        )
    ]

    public static func defaultBaseDirectory() throws -> URL {
        try FileManager.default
            .url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("Donkey", isDirectory: true)
            .appendingPathComponent("LocalModelRuntimes", isDirectory: true)
    }

    public static func defaultPackageManifestURL(for runtimeID: LocalModelRuntimeID) -> URL? {
        if let bundledURLs = Bundle.main.object(
            forInfoDictionaryKey: "DonkeyRuntimePackageManifestURLs"
        ) as? [String: String],
            let value = bundledURLs[runtimeID.rawValue],
            let url = URL(string: value) {
            return url
        }

        if let value = ProcessInfo.processInfo.environment[manifestURLEnvironmentName(for: runtimeID)],
           let url = URL(string: value) {
            return url
        }

        return ProcessInfo.processInfo.environment["DONKEY_RUNTIME_PACKAGE_MANIFEST_URLS"]?
            .split(separator: ",")
            .compactMap { pair -> (String, String)? in
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return nil }
                return (parts[0], parts[1])
            }
            .first(where: { runtime, _ in runtime == runtimeID.rawValue })
            .flatMap { _, value in URL(string: value) }
    }

    private static func manifestURLEnvironmentName(for runtimeID: LocalModelRuntimeID) -> String {
        switch runtimeID {
        case .parakeetTranscriber:
            return "DONKEY_PARAKEET_RUNTIME_MANIFEST_URL"
        case .yoloSegmenter:
            return "DONKEY_YOLO_RUNTIME_MANIFEST_URL"
        case .uiUnderstander:
            return "DONKEY_UI_UNDERSTANDER_RUNTIME_MANIFEST_URL"
        case .localLLM:
            return "DONKEY_LOCAL_LLM_RUNTIME_MANIFEST_URL"
        }
    }

    public static func defaultTrustedManifestSigningKeys() -> [LocalModelRuntimeManifestSigningKey] {
        var keys: [LocalModelRuntimeManifestSigningKey] = []
        if let bundledKeys = Bundle.main.object(
            forInfoDictionaryKey: "DonkeyRuntimeManifestPublicKeys"
        ) as? [String: String] {
            keys.append(contentsOf: bundledKeys.map { keyID, publicKey in
                LocalModelRuntimeManifestSigningKey(keyID: keyID, publicKeyBase64: publicKey)
            })
        }

        keys.append(contentsOf: ProcessInfo.processInfo.environment["DONKEY_RUNTIME_MANIFEST_PUBLIC_KEYS"]?
            .split(separator: ",")
            .compactMap { pair -> LocalModelRuntimeManifestSigningKey? in
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                    return nil
                }
                return LocalModelRuntimeManifestSigningKey(keyID: parts[0], publicKeyBase64: parts[1])
            } ?? [])
        return keys
    }

    public static func defaultRequiresCryptographicManifestSignatures() -> Bool {
        if let bundledValue = Bundle.main.object(
            forInfoDictionaryKey: "DonkeyRuntimeRequiresCryptographicManifestSignatures"
        ) as? Bool {
            return bundledValue
        }
        return ProcessInfo.processInfo.environment["DONKEY_RUNTIME_REQUIRE_CRYPTO_SIGNATURES"] == "1"
    }

    public func instructions() -> [LocalModelRuntimeInstallInstruction] {
        specs.map { spec in
            LocalModelRuntimeInstallInstruction(
                spec: spec,
                setupDirectory: baseDirectory.appendingPathComponent(spec.id.rawValue, isDirectory: true)
            )
        }
    }

    public func statuses() throws -> [LocalModelRuntimeStatus] {
        try specs.map { spec in
            try status(for: spec.id)
        }
    }

    public func status(for runtimeID: LocalModelRuntimeID) throws -> LocalModelRuntimeStatus {
        let spec = try spec(for: runtimeID)
        let registry = try loadRegistry()
        guard let installation = registry.installations[runtimeID.rawValue] else {
            return LocalModelRuntimeStatus(
                spec: spec,
                state: .notInstalled,
                metadata: ["reason": "noRegisteredRuntime"]
            )
        }

        let state: LocalModelRuntimeInstallState = isExecutableFile(installation.executablePath)
            ? .installed
            : .invalidExecutable
        return LocalModelRuntimeStatus(
            spec: spec,
            state: state,
            installation: installation,
            metadata: [
                "reason": state == .installed ? "installed" : "executableMissingOrNotExecutable"
            ]
        )
    }

    public func validateManifest(
        _ manifest: LocalModelRuntimePackageManifest,
        for runtimeID: LocalModelRuntimeID,
        requiresSignature: Bool = true
    ) throws {
        let spec = try spec(for: runtimeID)
        guard manifest.runtimeID == runtimeID else {
            throw LocalModelRuntimeSetupError.manifestRuntimeMismatch(
                expected: runtimeID,
                actual: manifest.runtimeID
            )
        }
        guard manifest.platform == LocalModelRuntimePackageManifest.currentPlatform else {
            throw LocalModelRuntimeSetupError.manifestUnsupportedPlatform(manifest.platform)
        }
        guard manifest.architecture == LocalModelRuntimePackageManifest.currentArchitecture else {
            throw LocalModelRuntimeSetupError.manifestUnsupportedArchitecture(manifest.architecture)
        }
        guard manifest.executableRelativePath == spec.expectedExecutableRelativePath,
              manifest.files.contains(where: { $0.relativePath == manifest.executableRelativePath && $0.isExecutable })
        else {
            throw LocalModelRuntimeSetupError.manifestMissingExecutable(manifest.executableRelativePath)
        }
        if requiresSignature,
           (manifest.signature?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            || manifest.signingKeyID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            throw LocalModelRuntimeSetupError.manifestMissingSignature
        }
        try verifyManifestSignatureIfConfigured(manifest, requiresSignature: requiresSignature)
    }

    @discardableResult
    public func installDownloadedPackage(
        manifest: LocalModelRuntimePackageManifest,
        packageDirectory: URL,
        requiresSignature: Bool = true
    ) throws -> LocalModelRuntimeInstallation {
        try validateManifest(manifest, for: manifest.runtimeID, requiresSignature: requiresSignature)
        for file in manifest.files {
            let fileURL = safePackageURL(root: packageDirectory, relativePath: file.relativePath)
            let data = try Data(contentsOf: fileURL)
            guard Self.sha256Hex(data) == file.sha256.lowercased() else {
                throw LocalModelRuntimeSetupError.manifestFileHashMismatch(relativePath: file.relativePath)
            }
            if file.isExecutable {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: fileURL.path
                )
            }
        }

        let managedDirectory = managedPackageDirectory(for: manifest)
        if FileManager.default.fileExists(atPath: managedDirectory.path) {
            try FileManager.default.removeItem(at: managedDirectory)
        }
        try FileManager.default.createDirectory(
            at: managedDirectory,
            withIntermediateDirectories: true
        )
        for file in manifest.files {
            let sourceURL = safePackageURL(root: packageDirectory, relativePath: file.relativePath)
            let destinationURL = safePackageURL(root: managedDirectory, relativePath: file.relativePath)
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            if file.isExecutable {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: destinationURL.path
                )
            }
        }

        let executableURL = safePackageURL(
            root: managedDirectory,
            relativePath: manifest.executableRelativePath
        )
        return try registerExecutable(
            runtimeID: manifest.runtimeID,
            executableURL: executableURL,
            downloadedDirectory: managedDirectory,
            runtimeVersion: manifest.runtimeVersion,
            modelID: manifest.modelID,
            sidecarProtocolVersion: manifest.sidecarProtocolVersion,
            metadata: [
                "installedBy": "donkey-local-runtime-download",
                "manifest.platform": manifest.platform,
                "manifest.architecture": manifest.architecture,
                "manifest.minimumDonkeyVersion": manifest.minimumDonkeyVersion,
                "manifest.signingKeyID": manifest.signingKeyID ?? "",
                "manifest.signaturePresent": String(manifest.signature != nil)
            ].merging(manifest.metadata) { current, _ in current }
        )
    }

    @discardableResult
    public func downloadAndInstall(
        manifest: LocalModelRuntimePackageManifest,
        downloader: any LocalModelRuntimePackageDownloading = URLSessionLocalModelRuntimePackageDownloader(),
        requiresSignature: Bool = true
    ) async throws -> LocalModelRuntimeDownloadResult {
        try validateManifest(manifest, for: manifest.runtimeID, requiresSignature: requiresSignature)
        let stagingDirectory = baseDirectory
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("\(manifest.runtimeID.rawValue)-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )
            for file in manifest.files {
                guard let downloadURL = file.downloadURL else {
                    throw LocalModelRuntimeSetupError.manifestMissingDownloadURL(relativePath: file.relativePath)
                }
                let data = try await downloader.download(from: downloadURL)
                guard Self.sha256Hex(data) == file.sha256.lowercased() else {
                    throw LocalModelRuntimeSetupError.manifestFileHashMismatch(relativePath: file.relativePath)
                }
                let destination = safePackageURL(root: stagingDirectory, relativePath: file.relativePath)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: destination, options: .atomic)
                if file.isExecutable {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o755],
                        ofItemAtPath: destination.path
                    )
                }
            }
            let installation = try installDownloadedPackage(
                manifest: manifest,
                packageDirectory: stagingDirectory,
                requiresSignature: requiresSignature
            )
            return LocalModelRuntimeDownloadResult(
                runtimeID: manifest.runtimeID,
                state: .installed,
                installation: installation,
                metadata: ["download.stagingDirectory": stagingDirectory.path]
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingDirectory)
            throw error
        }
    }

    @discardableResult
    public func downloadAndInstall(
        runtimeID: LocalModelRuntimeID,
        downloader: any LocalModelRuntimePackageDownloading = URLSessionLocalModelRuntimePackageDownloader(),
        requiresSignature: Bool = true
    ) async throws -> LocalModelRuntimeDownloadResult {
        let spec = try spec(for: runtimeID)
        guard let manifestURL = spec.manifestURL else {
            throw LocalModelRuntimeSetupError.manifestMissingDownloadURL(relativePath: "manifest")
        }
        let manifestData = try await downloader.download(from: manifestURL)
        let manifest = try Self.decoder().decode(LocalModelRuntimePackageManifest.self, from: manifestData)
        return try await downloadAndInstall(
            manifest: manifest,
            downloader: downloader,
            requiresSignature: requiresSignature
        )
    }

    public func recheckHealth(
        runtimeID: LocalModelRuntimeID,
        timeoutMS: Int = 2_000
    ) async throws -> LocalModelRuntimeHealthReport {
        let status = try status(for: runtimeID)
        guard status.state == .installed,
              let installation = status.installation
        else {
            return LocalModelRuntimeHealthReport(
                runtimeID: runtimeID,
                state: .unavailable,
                metadata: status.metadata
            )
        }

        let requestData = try Self.encoder().encode(
            LocalModelRuntimeHealthRequest(
                operation: "healthCheck",
                protocolVersion: installation.sidecarProtocolVersion ?? "v1",
                runtimeID: runtimeID.rawValue,
                runtimeVersion: installation.runtimeVersion,
                modelID: installation.modelID ?? status.spec.modelName,
                cacheDirectory: modelCacheDirectory(for: installation).path,
                metadata: status.spec.metadata
                    .merging(installation.metadata) { _, new in new }
            )
        )
        let runner = ProcessBackedLocalJSONSidecarRunner(
            environment: [status.spec.environmentVariableName: installation.executablePath],
            executableResolver: { environmentVariableName, environment in
                environment[environmentVariableName]
            }
        )
        let result = await runner.run(
            LocalJSONSidecarRequest(
                environmentVariableName: status.spec.environmentVariableName,
                inputData: requestData,
                timeoutMS: timeoutMS,
                metadata: ["operation": "healthCheck"]
            )
        )

        guard result.status == .completed else {
            return LocalModelRuntimeHealthReport(
                runtimeID: runtimeID,
                state: result.status == .unavailable ? .unavailable : .failed,
                latencyMS: result.latencyMS,
                metadata: result.metadata.merging([
                    "sidecar.stderr": result.stderrText
                ]) { current, _ in current }
            )
        }

        guard let response = try? Self.decoder().decode(LocalModelRuntimeHealthResponse.self, from: result.outputData),
              response.status == "ok"
        else {
            return LocalModelRuntimeHealthReport(
                runtimeID: runtimeID,
                state: .invalidOutput,
                latencyMS: result.latencyMS,
                metadata: result.metadata
            )
        }

        return LocalModelRuntimeHealthReport(
            runtimeID: runtimeID,
            state: .healthy,
            runtimeVersion: response.runtimeVersion,
            modelID: response.modelID,
            sidecarProtocolVersion: response.protocolVersion,
            latencyMS: result.latencyMS,
            metadata: result.metadata.merging(response.metadata) { current, _ in current }
        )
    }

    public func prepareModelWeights(
        runtimeID: LocalModelRuntimeID,
        timeoutMS: Int = 600_000
    ) async throws -> LocalModelRuntimeModelPreparationReport {
        let status = try status(for: runtimeID)
        guard status.state == .installed,
              let installation = status.installation
        else {
            return LocalModelRuntimeModelPreparationReport(
                runtimeID: runtimeID,
                state: .unavailable,
                metadata: status.metadata
            )
        }

        let cacheDirectory = modelCacheDirectory(for: installation)
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
        let requestData = try Self.encoder().encode(
            LocalModelRuntimeModelPreparationRequest(
                operation: "prepareModelWeights",
                protocolVersion: installation.sidecarProtocolVersion ?? "v1",
                runtimeID: runtimeID.rawValue,
                runtimeVersion: installation.runtimeVersion,
                modelID: installation.modelID ?? status.spec.modelName,
                cacheDirectory: cacheDirectory.path,
                metadata: status.spec.metadata
                    .merging(installation.metadata) { _, new in new }
            )
        )
        let runner = ProcessBackedLocalJSONSidecarRunner(
            environment: [status.spec.environmentVariableName: installation.executablePath],
            executableResolver: { environmentVariableName, environment in
                environment[environmentVariableName]
            }
        )
        let result = await runner.run(
            LocalJSONSidecarRequest(
                environmentVariableName: status.spec.environmentVariableName,
                inputData: requestData,
                timeoutMS: timeoutMS,
                metadata: ["operation": "prepareModelWeights"]
            )
        )

        guard result.status == .completed else {
            return LocalModelRuntimeModelPreparationReport(
                runtimeID: runtimeID,
                state: result.status == .unavailable ? .unavailable : .failed,
                cacheDirectory: cacheDirectory.path,
                modelID: installation.modelID ?? status.spec.modelName,
                latencyMS: result.latencyMS,
                metadata: result.metadata.merging([
                    "sidecar.stderr": result.stderrText
                ]) { current, _ in current }
            )
        }

        guard let response = try? Self.decoder().decode(LocalModelRuntimeModelPreparationResponse.self, from: result.outputData) else {
            return LocalModelRuntimeModelPreparationReport(
                runtimeID: runtimeID,
                state: .invalidOutput,
                cacheDirectory: cacheDirectory.path,
                modelID: installation.modelID ?? status.spec.modelName,
                latencyMS: result.latencyMS,
                metadata: result.metadata
            )
        }

        return LocalModelRuntimeModelPreparationReport(
            runtimeID: runtimeID,
            state: response.status == "ok" ? .prepared : .failed,
            cacheDirectory: response.cacheDirectory ?? cacheDirectory.path,
            modelID: response.modelID ?? installation.modelID ?? status.spec.modelName,
            latencyMS: result.latencyMS,
            metadata: result.metadata.merging(response.metadata) { current, _ in current }
        )
    }

    @discardableResult
    public func registerDownloadedRuntime(
        runtimeID: LocalModelRuntimeID,
        downloadedDirectory: URL
    ) throws -> LocalModelRuntimeInstallation {
        let spec = try spec(for: runtimeID)
        let executableURL = downloadedDirectory.appendingPathComponent(
            spec.expectedExecutableRelativePath,
            isDirectory: false
        )
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw LocalModelRuntimeSetupError.missingDownloadedExecutable(
                runtimeID: runtimeID,
                expectedRelativePath: spec.expectedExecutableRelativePath
            )
        }

        return try registerExecutable(
            runtimeID: runtimeID,
            executableURL: executableURL,
            downloadedDirectory: downloadedDirectory
        )
    }

    @discardableResult
    public func registerExecutable(
        runtimeID: LocalModelRuntimeID,
        executableURL: URL,
        downloadedDirectory: URL,
        runtimeVersion: String? = nil,
        modelID: String? = nil,
        sidecarProtocolVersion: String? = nil,
        metadata: [String: String] = ["installedBy": "donkey-local-runtime-setup"]
    ) throws -> LocalModelRuntimeInstallation {
        guard isExecutableFile(executableURL.path) else {
            throw LocalModelRuntimeSetupError.downloadedExecutableNotExecutable(
                runtimeID: runtimeID,
                path: executableURL.path
            )
        }

        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        var registry = try loadRegistry()
        let installation = LocalModelRuntimeInstallation(
            runtimeID: runtimeID,
            executablePath: executableURL.path,
            downloadedDirectoryPath: downloadedDirectory.path,
            installedAt: now(),
            runtimeVersion: runtimeVersion,
            modelID: modelID,
            sidecarProtocolVersion: sidecarProtocolVersion,
            metadata: metadata
        )
        registry.installations[runtimeID.rawValue] = installation
        try saveRegistry(registry)
        return installation
    }

    public func configuredEnvironment() throws -> [String: String] {
        let registry = try loadRegistry()
        return specs.reduce(into: [:]) { result, spec in
            guard let installation = registry.installations[spec.id.rawValue],
                  isExecutableFile(installation.executablePath)
            else {
                return
            }
            result[spec.environmentVariableName] = installation.executablePath
        }
    }

    public func executablePath(environmentVariableName: String) throws -> String? {
        try configuredEnvironment()[environmentVariableName]
    }

    @discardableResult
    public func removeRuntime(
        runtimeID: LocalModelRuntimeID,
        removePackageFiles: Bool = true,
        removeModelWeights: Bool = true
    ) throws -> Bool {
        _ = try spec(for: runtimeID)
        var registry = try loadRegistry()
        guard let installation = registry.installations.removeValue(forKey: runtimeID.rawValue) else {
            return false
        }
        try saveRegistry(registry)

        if removePackageFiles {
            let packageDirectory = URL(fileURLWithPath: installation.downloadedDirectoryPath, isDirectory: true)
            if packageDirectory.path.hasPrefix(baseDirectory.path),
               FileManager.default.fileExists(atPath: packageDirectory.path) {
                try FileManager.default.removeItem(at: packageDirectory)
            }
        }

        if removeModelWeights {
            let cacheDirectory = modelCacheDirectory(for: installation)
            if cacheDirectory.path.hasPrefix(baseDirectory.path),
               FileManager.default.fileExists(atPath: cacheDirectory.path) {
                try FileManager.default.removeItem(at: cacheDirectory)
            }
        }

        return true
    }

    public func repairRuntime(
        runtimeID: LocalModelRuntimeID,
        downloader: any LocalModelRuntimePackageDownloading = URLSessionLocalModelRuntimePackageDownloader()
    ) async throws -> LocalModelRuntimeRepairReport {
        let removed = try removeRuntime(runtimeID: runtimeID)
        let downloadResult = try await downloadAndInstall(runtimeID: runtimeID, downloader: downloader)
        let modelPreparation = try await prepareModelWeights(runtimeID: runtimeID)
        let health = try await recheckHealth(runtimeID: runtimeID)
        return LocalModelRuntimeRepairReport(
            runtimeID: runtimeID,
            downloadResult: downloadResult,
            modelPreparation: modelPreparation,
            health: health,
            metadata: ["removedExistingRuntime": String(removed)]
        )
    }

    public func supportSnapshot() throws -> LocalModelRuntimeSupportSnapshot {
        LocalModelRuntimeSupportSnapshot(
            generatedAt: now(),
            statuses: try statuses().map { status in
                LocalModelRuntimeSupportStatus(
                    runtimeID: status.spec.id,
                    displayName: status.spec.displayName,
                    state: status.state,
                    environmentVariableName: status.spec.environmentVariableName,
                    runtimeVersion: status.installation?.runtimeVersion,
                    modelID: status.installation?.modelID ?? status.spec.modelName,
                    sidecarProtocolVersion: status.installation?.sidecarProtocolVersion,
                    reason: status.metadata["reason"]
                )
            }
        )
    }

    public func supportExportData() throws -> Data {
        try Self.encoder().encode(supportSnapshot())
    }

    private func spec(for runtimeID: LocalModelRuntimeID) throws -> LocalModelRuntimeSpec {
        guard let spec = specs.first(where: { $0.id == runtimeID }) else {
            throw LocalModelRuntimeSetupError.unknownRuntime(runtimeID.rawValue)
        }
        return spec
    }

    private func verifyManifestSignatureIfConfigured(
        _ manifest: LocalModelRuntimePackageManifest,
        requiresSignature: Bool
    ) throws {
        guard requiresSignature else { return }
        guard let signingKeyID = manifest.signingKeyID,
              let signature = manifest.signature,
              !signingKeyID.isEmpty,
              !signature.isEmpty
        else {
            throw LocalModelRuntimeSetupError.manifestMissingSignature
        }

        guard let publicKeyBase64 = trustedManifestSigningKeys[signingKeyID] else {
            if requiresCryptographicManifestSignatures {
                throw LocalModelRuntimeSetupError.manifestUnknownSigningKey(signingKeyID)
            }
            return
        }

        guard let publicKeyData = Data(base64Encoded: publicKeyBase64),
              let signatureData = Data(base64Encoded: signature)
        else {
            throw LocalModelRuntimeSetupError.manifestInvalidSignature
        }

        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        let payload = try Self.signaturePayloadData(for: manifest)
        guard publicKey.isValidSignature(signatureData, for: payload) else {
            throw LocalModelRuntimeSetupError.manifestInvalidSignature
        }
    }

    private func loadRegistry() throws -> LocalModelRuntimeRegistry {
        let url = registryURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return LocalModelRuntimeRegistry()
        }
        let data = try Data(contentsOf: url)
        return try Self.decoder().decode(LocalModelRuntimeRegistry.self, from: data)
    }

    private func saveRegistry(_ registry: LocalModelRuntimeRegistry) throws {
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        let data = try Self.encoder().encode(registry)
        try data.write(to: registryURL(), options: .atomic)
    }

    private func registryURL() -> URL {
        baseDirectory.appendingPathComponent("runtime-installations.json", isDirectory: false)
    }

    private func safePackageURL(root: URL, relativePath: String) -> URL {
        relativePath
            .split(separator: "/")
            .reduce(root) { partialURL, component in
                partialURL.appendingPathComponent(String(component), isDirectory: false)
            }
    }

    private func managedPackageDirectory(for manifest: LocalModelRuntimePackageManifest) -> URL {
        baseDirectory
            .appendingPathComponent("Packages", isDirectory: true)
            .appendingPathComponent(manifest.runtimeID.rawValue, isDirectory: true)
            .appendingPathComponent(manifest.runtimeVersion, isDirectory: true)
    }

    private func modelCacheDirectory(for installation: LocalModelRuntimeInstallation) -> URL {
        let modelID = (installation.modelID ?? installation.runtimeID.rawValue)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return baseDirectory
            .appendingPathComponent("ModelWeights", isDirectory: true)
            .appendingPathComponent(installation.runtimeID.rawValue, isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func signaturePayloadData(
        for manifest: LocalModelRuntimePackageManifest
    ) throws -> Data {
        try encoder().encode(
            LocalModelRuntimePackageManifestSignaturePayload(
                runtimeID: manifest.runtimeID,
                runtimeVersion: manifest.runtimeVersion,
                modelID: manifest.modelID,
                platform: manifest.platform,
                architecture: manifest.architecture,
                sidecarProtocolVersion: manifest.sidecarProtocolVersion,
                minimumDonkeyVersion: manifest.minimumDonkeyVersion,
                executableRelativePath: manifest.executableRelativePath,
                files: manifest.files,
                signingKeyID: manifest.signingKeyID,
                releaseNotesURL: manifest.releaseNotesURL,
                metadata: manifest.metadata
            )
        )
    }
}

private struct LocalModelRuntimePackageManifestSignaturePayload: Codable, Equatable, Sendable {
    var runtimeID: LocalModelRuntimeID
    var runtimeVersion: String
    var modelID: String
    var platform: String
    var architecture: String
    var sidecarProtocolVersion: String
    var minimumDonkeyVersion: String
    var executableRelativePath: String
    var files: [LocalModelRuntimePackageFile]
    var signingKeyID: String?
    var releaseNotesURL: URL?
    var metadata: [String: String]
}

private struct LocalModelRuntimeHealthRequest: Codable, Equatable, Sendable {
    var operation: String
    var protocolVersion: String
    var runtimeID: String?
    var runtimeVersion: String?
    var modelID: String?
    var cacheDirectory: String?
    var metadata: [String: String]?
}

private struct LocalModelRuntimeHealthResponse: Codable, Equatable, Sendable {
    var status: String
    var runtimeID: String
    var runtimeVersion: String?
    var modelID: String?
    var protocolVersion: String
    var metadata: [String: String]
}

private struct LocalModelRuntimeModelPreparationRequest: Codable, Equatable, Sendable {
    var operation: String
    var protocolVersion: String
    var runtimeID: String
    var runtimeVersion: String?
    var modelID: String
    var cacheDirectory: String
    var metadata: [String: String]
}

private struct LocalModelRuntimeModelPreparationResponse: Codable, Equatable, Sendable {
    var status: String
    var runtimeID: String
    var modelID: String?
    var cacheDirectory: String?
    var metadata: [String: String]
}

public struct LocalModelRuntimeExecutableResolver: Sendable {
    public var setupManagerFactory: @Sendable () throws -> LocalModelRuntimeSetupManager

    public init(
        setupManagerFactory: @escaping @Sendable () throws -> LocalModelRuntimeSetupManager = {
            try LocalModelRuntimeSetupManager()
        }
    ) {
        self.setupManagerFactory = setupManagerFactory
    }

    public func executablePath(environmentVariableName: String) -> String? {
        try? setupManagerFactory().executablePath(environmentVariableName: environmentVariableName)
    }
}
