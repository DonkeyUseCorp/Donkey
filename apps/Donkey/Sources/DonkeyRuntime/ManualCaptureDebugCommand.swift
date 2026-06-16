import DonkeyContracts
import Foundation

public enum ManualCaptureDebugCommand: Equatable, Sendable {
    case listWindowCandidates
    case manualCapture(ManualCaptureDebugCaptureOptions)
    case dryRunLatencyReport(DryRunLatencyReportDebugOptions)
    case localAppTask(LocalAppTaskDebugOptions)
}

public struct ManualCaptureDebugCaptureOptions: Equatable, Sendable {
    public var selection: MacWindowSelectionRequest
    public var runID: String?
    public var traceID: String?

    public init(
        selection: MacWindowSelectionRequest = MacWindowSelectionRequest(),
        runID: String? = nil,
        traceID: String? = nil
    ) {
        self.selection = selection
        self.runID = runID
        self.traceID = traceID
    }
}

public struct DryRunLatencyReportDebugOptions: Equatable, Sendable {
    public var frameCount: Int
    public var mode: ReflexReplayBenchmarkMode

    public init(
        frameCount: Int = 30,
        mode: ReflexReplayBenchmarkMode = .endToEndDryRun
    ) {
        self.frameCount = frameCount
        self.mode = mode
    }
}

public struct LocalAppTaskDebugOptions: Equatable, Sendable {
    public var command: String

    public init(command: String) {
        self.command = command
    }
}

public enum ManualCaptureDebugCommandParseError: Error, Equatable, Sendable, CustomStringConvertible {
    case conflictingCommands
    case missingCommand
    case missingValue(String)
    case invalidWindowID(String)
    case invalidFrameCount(String)
    case invalidBenchmarkMode(String)
    case invalidIdentifier(option: String, value: String)
    case unsupportedOption(String)

    public var description: String {
        switch self {
        case .conflictingCommands:
            return "Use only one Donkey debug command."
        case .missingCommand:
            return "Use --list-window-candidates or --manual-capture before capture options."
        case .missingValue(let option):
            return "Missing value for \(option)."
        case .invalidWindowID(let value):
            return "Invalid --window-id value: \(value)."
        case .invalidFrameCount(let value):
            return "Invalid --frame-count value: \(value)."
        case .invalidBenchmarkMode(let value):
            return "Invalid --benchmark-mode value: \(value)."
        case .invalidIdentifier(let option, let value):
            return "Invalid \(option) value: \(value). Use letters, numbers, '.', '_', or '-'."
        case .unsupportedOption(let option):
            return "Unsupported manual capture debug option: \(option)."
        }
    }
}

public enum ManualCaptureDebugCommandParser {
    public static func containsDebugCommand(arguments: [String]) -> Bool {
        normalizedArguments(arguments).contains { argument in
            argument == "--list-window-candidates"
                || argument == "--manual-capture"
                || argument == "--dry-run-latency-report"
                || argument == "--local-app-task"
                || argument == "--command"
                || argument == "--window-id"
                || argument == "--run-id"
                || argument == "--trace-id"
                || argument == "--frame-count"
                || argument == "--benchmark-mode"
        }
    }

    public static func parse(
        arguments: [String]
    ) throws -> ManualCaptureDebugCommand? {
        let arguments = normalizedArguments(arguments)
        guard containsDebugCommand(arguments: arguments) else {
            return nil
        }

        var mode: ManualCaptureDebugCommandMode?
        var windowID: UInt32?
        var runID: String?
        var traceID: String?
        var frameCount = 30
        var benchmarkMode = ReflexReplayBenchmarkMode.endToEndDryRun
        var localAppTaskCommand: String?
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--list-window-candidates":
                try setMode(.listWindowCandidates, current: &mode)
                index += 1
            case "--manual-capture":
                try setMode(.manualCapture, current: &mode)
                index += 1
            case "--dry-run-latency-report":
                try setMode(.dryRunLatencyReport, current: &mode)
                index += 1
            case "--local-app-task":
                try setMode(.localAppTask, current: &mode)
                index += 1
            case "--command":
                localAppTaskCommand = try value(after: argument, in: arguments, at: index)
                index += 2
            case "--window-id":
                let value = try value(after: argument, in: arguments, at: index)
                guard let parsed = UInt32(value) else {
                    throw ManualCaptureDebugCommandParseError.invalidWindowID(value)
                }
                windowID = parsed
                index += 2
            case "--run-id":
                let value = try value(after: argument, in: arguments, at: index)
                try validateIdentifier(value, option: argument)
                runID = value
                index += 2
            case "--trace-id":
                let value = try value(after: argument, in: arguments, at: index)
                try validateIdentifier(value, option: argument)
                traceID = value
                index += 2
            case "--frame-count":
                let value = try value(after: argument, in: arguments, at: index)
                guard let parsed = Int(value), parsed > 0 else {
                    throw ManualCaptureDebugCommandParseError.invalidFrameCount(value)
                }
                frameCount = parsed
                index += 2
            case "--benchmark-mode":
                let value = try value(after: argument, in: arguments, at: index)
                guard let parsed = ReflexReplayBenchmarkMode(rawValue: value) else {
                    throw ManualCaptureDebugCommandParseError.invalidBenchmarkMode(value)
                }
                benchmarkMode = parsed
                index += 2
            default:
                throw ManualCaptureDebugCommandParseError.unsupportedOption(argument)
            }
        }

        guard let mode else {
            throw ManualCaptureDebugCommandParseError.missingCommand
        }

        switch mode {
        case .listWindowCandidates:
            guard windowID == nil, runID == nil, traceID == nil, frameCount == 30,
                  benchmarkMode == .endToEndDryRun, localAppTaskCommand == nil
            else {
                throw ManualCaptureDebugCommandParseError.unsupportedOption(
                    "options are not supported with --list-window-candidates"
                )
            }
            return .listWindowCandidates
        case .manualCapture:
            guard frameCount == 30, benchmarkMode == .endToEndDryRun, localAppTaskCommand == nil else {
                throw ManualCaptureDebugCommandParseError.unsupportedOption(
                    "benchmark options require --dry-run-latency-report"
                )
            }
            return .manualCapture(
                ManualCaptureDebugCaptureOptions(
                    selection: MacWindowSelectionRequest(windowID: windowID),
                    runID: runID,
                    traceID: traceID
                )
            )
        case .dryRunLatencyReport:
            guard windowID == nil, runID == nil, traceID == nil, localAppTaskCommand == nil else {
                throw ManualCaptureDebugCommandParseError.unsupportedOption(
                    "capture options require --manual-capture"
                )
            }
            return .dryRunLatencyReport(
                DryRunLatencyReportDebugOptions(
                    frameCount: frameCount,
                    mode: benchmarkMode
                )
            )
        case .localAppTask:
            guard windowID == nil, runID == nil, traceID == nil, frameCount == 30,
                  benchmarkMode == .endToEndDryRun
            else {
                throw ManualCaptureDebugCommandParseError.unsupportedOption(
                    "capture or benchmark options are not supported with --local-app-task"
                )
            }
            guard let localAppTaskCommand,
                  !localAppTaskCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw ManualCaptureDebugCommandParseError.missingValue("--command")
            }
            return .localAppTask(LocalAppTaskDebugOptions(command: localAppTaskCommand))
        }
    }

    private static func setMode(
        _ next: ManualCaptureDebugCommandMode,
        current: inout ManualCaptureDebugCommandMode?
    ) throws {
        if let current, current != next {
            throw ManualCaptureDebugCommandParseError.conflictingCommands
        }

        current = next
    }

    private static func value(
        after option: String,
        in arguments: [String],
        at index: Int
    ) throws -> String {
        let valueIndex = index + 1
        guard valueIndex < arguments.count else {
            throw ManualCaptureDebugCommandParseError.missingValue(option)
        }

        let value = arguments[valueIndex]
        guard !value.hasPrefix("--") else {
            throw ManualCaptureDebugCommandParseError.missingValue(option)
        }

        return value
    }

    private static func validateIdentifier(
        _ value: String,
        option: String
    ) throws {
        let allowedScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let isSafe = !value.isEmpty
            && value.count <= 128
            && value != "."
            && value != ".."
            && value.unicodeScalars.allSatisfy { allowedScalars.contains($0) }

        guard isSafe else {
            throw ManualCaptureDebugCommandParseError.invalidIdentifier(
                option: option,
                value: value
            )
        }
    }

    private static func normalizedArguments(_ arguments: [String]) -> [String] {
        var normalized = arguments
        if let first = normalized.first, !first.hasPrefix("--") {
            normalized.removeFirst()
        }

        if normalized.first == "--" {
            normalized.removeFirst()
        }

        return normalized
    }
}

public enum ManualCaptureDebugCommandFormatter {
    public static func lines(
        for snapshot: MacWindowCandidateListSnapshot
    ) -> [String] {
        guard !snapshot.candidates.isEmpty else {
            return ["No visible window candidates found."]
        }

        return snapshot.candidates.map { labeled in
            let candidate = labeled.candidate
            return [
                labeled.label,
                "windowID=\(candidate.windowID)",
                "app=\(candidate.appName ?? "-")",
                "title=\(candidate.title ?? "-")",
                "safety=\(candidate.safetyAssessment.status.rawValue)",
                "iPhoneMirroring=\(candidate.isIPhoneMirroring)"
            ]
            .joined(separator: " | ")
        }
    }

    public static func lines(
        for result: ManualTargetContextCaptureResult,
        runDirectory: URL
    ) -> [String] {
        var lines = [
            "manual capture completed",
            "runID=\(result.traceSummary.runID)",
            "traceID=\(result.traceSummary.traceID)",
            "runFolder=\(runDirectory.path)",
            "target.windowID=\(result.target.windowID)",
            "screenshot=\(artifactURL(runDirectory: runDirectory, relativePath: result.screenshot.artifact.relativePath).path)"
        ]

        switch result.accessibility {
        case .captured(let accessibilityResult):
            lines.append("accessibility=captured")
            lines.append(
                "accessibilityArtifact=\(artifactURL(runDirectory: runDirectory, relativePath: accessibilityResult.artifact.relativePath).path)"
            )
        case .permissionDenied:
            lines.append("accessibility=permissionDenied")
        case .skipped(let reason):
            lines.append("accessibility=skipped")
            lines.append("accessibilityReason=\(reason)")
        }

        return lines
    }

    public static func lines(
        status: String,
        summary: String,
        traceID: String,
        metadata: [String: String]
    ) -> [String] {
        var lines = [
            "local app task completed",
            "status=\(status)",
            "summary=\(summary)",
            "traceID=\(traceID)"
        ]
        for key in metadata.keys.sorted() {
            lines.append("\(key)=\(metadata[key] ?? "")")
        }
        return lines
    }

    public static func errorLine(for error: Error) -> String {
        if let parseError = error as? ManualCaptureDebugCommandParseError {
            return "manual capture debug error: \(parseError.description)"
        }

        return "manual capture debug error: \(String(describing: error))"
    }

    private static func artifactURL(
        runDirectory: URL,
        relativePath: String
    ) -> URL {
        relativePath
            .split(separator: "/")
            .reduce(runDirectory) { url, component in
                url.appendingPathComponent(String(component), isDirectory: false)
            }
    }
}

private enum ManualCaptureDebugCommandMode {
    case listWindowCandidates
    case manualCapture
    case dryRunLatencyReport
    case localAppTask
}
