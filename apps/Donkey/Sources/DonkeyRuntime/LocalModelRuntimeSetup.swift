import Foundation

public enum LocalModelRuntimeID: String, Codable, CaseIterable, Equatable, Sendable {
    case parakeetTranscriber = "parakeet-transcriber"
    case yoloSegmenter = "yolo-segmenter"
    case uiUnderstander = "ui-understander"
}

public enum LocalModelRuntimeInstallState: String, Codable, Equatable, Sendable {
    case installed
    case notInstalled
    case invalidExecutable
}

public enum LocalModelRuntimeSetupError: Error, Equatable, Sendable {
    case unknownRuntime(String)
    case missingDownloadedExecutable(runtimeID: LocalModelRuntimeID, expectedRelativePath: String)
    case downloadedExecutableNotExecutable(runtimeID: LocalModelRuntimeID, path: String)
}

public struct LocalModelRuntimeSpec: Codable, Equatable, Sendable {
    public var id: LocalModelRuntimeID
    public var displayName: String
    public var environmentVariableName: String
    public var expectedExecutableRelativePath: String
    public var modelName: String
    public var downloadPageURL: URL?
    public var installSteps: [String]
    public var metadata: [String: String]

    public init(
        id: LocalModelRuntimeID,
        displayName: String,
        environmentVariableName: String,
        expectedExecutableRelativePath: String,
        modelName: String,
        downloadPageURL: URL? = nil,
        installSteps: [String],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.displayName = displayName
        self.environmentVariableName = environmentVariableName
        self.expectedExecutableRelativePath = expectedExecutableRelativePath
        self.modelName = modelName
        self.downloadPageURL = downloadPageURL
        self.installSteps = installSteps
        self.metadata = metadata
    }
}

public struct LocalModelRuntimeInstallation: Codable, Equatable, Sendable {
    public var runtimeID: LocalModelRuntimeID
    public var executablePath: String
    public var downloadedDirectoryPath: String
    public var installedAt: Date
    public var metadata: [String: String]

    public init(
        runtimeID: LocalModelRuntimeID,
        executablePath: String,
        downloadedDirectoryPath: String,
        installedAt: Date,
        metadata: [String: String] = [:]
    ) {
        self.runtimeID = runtimeID
        self.executablePath = executablePath
        self.downloadedDirectoryPath = downloadedDirectoryPath
        self.installedAt = installedAt
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

    public init(
        baseDirectory: URL? = nil,
        specs: [LocalModelRuntimeSpec] = Self.defaultSpecs,
        isExecutableFile: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        self.baseDirectory = try baseDirectory ?? Self.defaultBaseDirectory()
        self.specs = specs
        self.isExecutableFile = isExecutableFile
        self.now = now
    }

    public static let defaultSpecs: [LocalModelRuntimeSpec] = [
        LocalModelRuntimeSpec(
            id: .parakeetTranscriber,
            displayName: "Parakeet voice transcription",
            environmentVariableName: "DONKEY_PARAKEET_TRANSCRIBER",
            expectedExecutableRelativePath: "bin/donkey-parakeet-transcriber",
            modelName: "nvidia/parakeet-tdt-0.6b-v3",
            downloadPageURL: URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3"),
            installSteps: [
                "Download the Donkey-compatible Parakeet runtime package after installing Donkey.",
                "Choose that downloaded runtime folder in Donkey setup.",
                "Donkey validates bin/donkey-parakeet-transcriber and records the path in Application Support."
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
            installSteps: [
                "Download the Donkey-compatible YOLO26 segmentation runtime package after installing Donkey.",
                "Choose that downloaded runtime folder in Donkey setup.",
                "Donkey validates bin/donkey-yolo-segmenter and records the path in Application Support."
            ],
            metadata: ["sidecar.role": "screenshotSegmentation"]
        ),
        LocalModelRuntimeSpec(
            id: .uiUnderstander,
            displayName: "Local UI understanding",
            environmentVariableName: "DONKEY_UI_UNDERSTANDER",
            expectedExecutableRelativePath: "bin/donkey-ui-understander",
            modelName: "local-ui-understander",
            downloadPageURL: nil,
            installSteps: [
                "Download the Donkey-compatible local UI-understanding runtime package after installing Donkey.",
                "Choose that downloaded runtime folder in Donkey setup.",
                "Donkey validates bin/donkey-ui-understander and records the path in Application Support."
            ],
            metadata: ["sidecar.role": "uiUnderstanding"]
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
        downloadedDirectory: URL
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
            metadata: ["installedBy": "donkey-local-runtime-setup"]
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

    private func spec(for runtimeID: LocalModelRuntimeID) throws -> LocalModelRuntimeSpec {
        guard let spec = specs.first(where: { $0.id == runtimeID }) else {
            throw LocalModelRuntimeSetupError.unknownRuntime(runtimeID.rawValue)
        }
        return spec
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
