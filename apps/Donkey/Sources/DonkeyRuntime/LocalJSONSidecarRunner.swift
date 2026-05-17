import Foundation

public enum LocalJSONSidecarStatus: String, Codable, Equatable, Sendable {
    case completed
    case unavailable
    case failed
    case timedOut
    case invalidOutput
}

public struct LocalJSONSidecarRequest: Equatable, Sendable {
    public var environmentVariableName: String
    public var inputData: Data
    public var timeoutMS: Int
    public var metadata: [String: String]

    public init(
        environmentVariableName: String,
        inputData: Data,
        timeoutMS: Int,
        metadata: [String: String] = [:]
    ) {
        self.environmentVariableName = environmentVariableName
        self.inputData = inputData
        self.timeoutMS = max(1, timeoutMS)
        self.metadata = metadata
    }
}

public struct LocalJSONSidecarResult: Equatable, Sendable {
    public var status: LocalJSONSidecarStatus
    public var outputData: Data
    public var exitCode: Int32?
    public var stderrText: String
    public var latencyMS: Double?
    public var metadata: [String: String]

    public init(
        status: LocalJSONSidecarStatus,
        outputData: Data = Data(),
        exitCode: Int32? = nil,
        stderrText: String = "",
        latencyMS: Double? = nil,
        metadata: [String: String] = [:]
    ) {
        self.status = status
        self.outputData = outputData
        self.exitCode = exitCode
        self.stderrText = stderrText
        self.latencyMS = latencyMS
        self.metadata = metadata
    }
}

public protocol LocalJSONSidecarRunning: Sendable {
    func run(_ request: LocalJSONSidecarRequest) async -> LocalJSONSidecarResult
}

public struct ProcessBackedLocalJSONSidecarRunner: LocalJSONSidecarRunning {
    public var environment: [String: String]
    public var executableResolver: @Sendable (String, [String: String]) -> String?
    public var isExecutableFile: @Sendable (String) -> Bool
    public var now: @Sendable () -> Date

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableResolver: @escaping @Sendable (String, [String: String]) -> String? = Self.defaultExecutablePath,
        isExecutableFile: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.environment = environment
        self.executableResolver = executableResolver
        self.isExecutableFile = isExecutableFile
        self.now = now
    }

    public func run(_ request: LocalJSONSidecarRequest) async -> LocalJSONSidecarResult {
        guard let executablePath = executableResolver(request.environmentVariableName, environment),
              !executablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return LocalJSONSidecarResult(
                status: .unavailable,
                metadata: metadata(
                    request: request,
                    executablePath: nil,
                    reason: "missingEnvironmentVariable"
                )
            )
        }

        guard isExecutableFile(executablePath) else {
            return LocalJSONSidecarResult(
                status: .unavailable,
                metadata: metadata(
                    request: request,
                    executablePath: executablePath,
                    reason: "executableMissingOrNotExecutable"
                )
            )
        }

        let startedAt = now()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        let termination = DispatchSemaphore(value: 0)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { _ in
            termination.signal()
        }

        do {
            try process.run()
            try stdin.fileHandleForWriting.write(contentsOf: request.inputData)
            try stdin.fileHandleForWriting.close()
        } catch {
            return LocalJSONSidecarResult(
                status: .failed,
                stderrText: String(describing: error),
                latencyMS: startedAt.distance(to: now()) * 1_000,
                metadata: metadata(
                    request: request,
                    executablePath: executablePath,
                    reason: "processLaunchFailed"
                )
            )
        }

        let timeout = DispatchTime.now() + .milliseconds(request.timeoutMS)
        if Self.waitForTermination(termination, timeout: timeout) == .timedOut {
            process.terminate()
            _ = Self.waitForTermination(termination, timeout: .now() + .seconds(1))
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            return LocalJSONSidecarResult(
                status: .timedOut,
                exitCode: process.isRunning ? nil : process.terminationStatus,
                stderrText: String(decoding: stderrData, as: UTF8.self),
                latencyMS: startedAt.distance(to: now()) * 1_000,
                metadata: metadata(
                    request: request,
                    executablePath: executablePath,
                    reason: "timeout"
                )
            )
        }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(decoding: stderrData, as: UTF8.self)
        let status: LocalJSONSidecarStatus = process.terminationStatus == 0 ? .completed : .failed

        return LocalJSONSidecarResult(
            status: status,
            outputData: outputData,
            exitCode: process.terminationStatus,
            stderrText: stderrText,
            latencyMS: startedAt.distance(to: now()) * 1_000,
            metadata: metadata(
                request: request,
                executablePath: executablePath,
                reason: status == .completed ? "completed" : "nonZeroExit"
            )
        )
    }

    private func metadata(
        request: LocalJSONSidecarRequest,
        executablePath: String?,
        reason: String
    ) -> [String: String] {
        var values = request.metadata
        values["sidecar.environmentVariable"] = request.environmentVariableName
        values["sidecar.executablePath"] = executablePath ?? ""
        values["sidecar.reason"] = reason
        values["sidecar.timeoutMS"] = String(request.timeoutMS)
        return values
    }

    private static func waitForTermination(
        _ semaphore: DispatchSemaphore,
        timeout: DispatchTime
    ) -> DispatchTimeoutResult {
        semaphore.wait(timeout: timeout)
    }

    public static func defaultExecutablePath(
        environmentVariableName: String,
        environment: [String: String]
    ) -> String? {
        if let path = environment[environmentVariableName],
           !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return path
        }

        return LocalModelRuntimeExecutableResolver().executablePath(
            environmentVariableName: environmentVariableName
        )
    }
}
