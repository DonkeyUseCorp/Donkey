import DonkeyContracts
import Foundation

public struct AppleScriptExecutionResult: Equatable, Sendable {
    public var succeeded: Bool
    public var output: String
    public var error: String?

    public init(
        succeeded: Bool,
        output: String = "",
        error: String? = nil
    ) {
        self.succeeded = succeeded
        self.output = output
        self.error = error
    }
}

public protocol AppleScriptRunning: Sendable {
    func run(_ script: String) async -> AppleScriptExecutionResult
}

public struct NSAppleScriptRunner: AppleScriptRunning {
    public init() {}

    public func run(_ script: String) async -> AppleScriptExecutionResult {
        await MainActor.run {
            var error: NSDictionary?
            guard let appleScript = NSAppleScript(source: script) else {
                return AppleScriptExecutionResult(
                    succeeded: false,
                    error: "AppleScript source could not be compiled"
                )
            }

            let descriptor = appleScript.executeAndReturnError(&error)
            if let error {
                return AppleScriptExecutionResult(
                    succeeded: false,
                    error: String(describing: error)
                )
            }

            return AppleScriptExecutionResult(
                succeeded: true,
                output: descriptor.stringValue ?? ""
            )
        }
    }
}

public struct MacAppleScriptActionEngineInputBackend: ActionEngineInputBackend {
    private let runner: any AppleScriptRunning

    public init(runner: any AppleScriptRunning = NSAppleScriptRunner()) {
        self.runner = runner
    }

    public func execute(_ command: ActionEngineCommand) async -> ActionEngineInputBackendResult {
        guard command.kind == .controller else {
            return result(
                command: command,
                executed: false,
                metadata: [
                    "liveInputBackend": "mac-apple-script",
                    "reason": "unsupportedCommandKind"
                ]
            )
        }

        guard command.metadata["automationBackend"] == "appleScript" else {
            return result(
                command: command,
                executed: false,
                metadata: [
                    "liveInputBackend": "mac-apple-script",
                    "reason": "missingAppleScriptBackendMarker"
                ]
            )
        }

        guard let generatedScript = AppleScriptActionScriptGenerator.script(for: command) else {
            return result(
                command: command,
                executed: false,
                metadata: [
                    "liveInputBackend": "mac-apple-script",
                    "reason": "unsupportedAppleScriptAction",
                    "appleScript.action": command.metadata["appleScript.action"] ?? ""
                ]
            )
        }

        let execution = await runner.run(generatedScript.source)
        let output = execution.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let acceptedOutputs = Self.acceptedOutputs(for: command)
        let executed = execution.succeeded && (
            acceptedOutputs.isEmpty || acceptedOutputs.contains(output)
        )

        return result(
            command: command,
            executed: executed,
            metadata: [
                "liveInputBackend": "mac-apple-script",
                "appleScript.action": generatedScript.action,
                "appleScript.scriptKind": generatedScript.kind,
                "appleScript.output": output,
                "appleScript.error": execution.error ?? "",
                "appleScript.query": command.metadata["appleScript.query"] ?? command.key ?? ""
            ]
        )
    }

    private func result(
        command: ActionEngineCommand,
        executed: Bool,
        metadata: [String: String]
    ) -> ActionEngineInputBackendResult {
        ActionEngineInputBackendResult(
            executed: executed,
            completedAt: Self.now(),
            metadata: metadata
        )
    }

    static func musicPlaybackScript(query: String) -> String {
        AppleScriptActionScriptGenerator.musicPlaybackScript(query: query)
    }

    private static func acceptedOutputs(for command: ActionEngineCommand) -> Set<String> {
        if let explicitOutputs = command.metadata["appleScript.successOutputs"] {
            return Set(explicitOutputs
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty })
        }

        if command.metadata["appleScript.action"] == "music.playMediaQuery" {
            return [
                "played-library-track",
                "searched-ui-first-result"
            ]
        }

        return []
    }

    private static func now() -> RunTraceTimestamp {
        RunTraceTimestamp(
            wallClock: Date(),
            monotonicUptimeNanoseconds: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        )
    }
}

struct AppleScriptActionScript: Equatable, Sendable {
    var action: String
    var kind: String
    var source: String
}

enum AppleScriptActionScriptGenerator {
    static func script(for command: ActionEngineCommand) -> AppleScriptActionScript? {
        let action = command.metadata["appleScript.action"] ?? "generated"
        let query = command.metadata["appleScript.query"]
            ?? command.metadata["appleScript.entityValue"]
            ?? command.key
            ?? ""

        if let source = nonEmpty(command.metadata["appleScript.source"]) {
            return AppleScriptActionScript(
                action: action,
                kind: "source",
                source: source
            )
        }

        if let template = nonEmpty(command.metadata["appleScript.template"]) {
            return AppleScriptActionScript(
                action: action,
                kind: "template",
                source: renderTemplate(
                    template,
                    command: command,
                    query: query
                )
            )
        }

        if action == "music.playMediaQuery",
           !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AppleScriptActionScript(
                action: action,
                kind: "builtInAction",
                source: musicPlaybackScript(query: query)
            )
        }

        return nil
    }

    static func musicPlaybackScript(query: String) -> String {
        let escapedQuery = appleScriptStringLiteral(query)
        return """
        set donkeyQuery to \(escapedQuery)
        tell application "Music"
            activate
            delay 0.1
            try
                set donkeyMatches to search library playlist 1 for donkeyQuery only songs
                if (count of donkeyMatches) > 0 then
                    play item 1 of donkeyMatches
                    return "played-library-track"
                end if
            end try
        end tell
        try
            tell application "System Events"
                tell process "Music"
                    set frontmost to true
                    keystroke "f" using command down
                    delay 0.12
                    keystroke donkeyQuery
                    delay 0.12
                    key code 36
                    delay 0.25
                    key code 36
                end tell
            end tell
            return "searched-ui-first-result"
        on error donkeyFallbackError
            return "ui-search-error:" & donkeyFallbackError
        end try
        """
    }

    private static func renderTemplate(
        _ template: String,
        command: ActionEngineCommand,
        query: String
    ) -> String {
        let targetApp = command.metadata["targetApp"] ?? ""
        let bundleIdentifier = command.metadata["bundleIdentifier"] ?? ""
        let replacements = [
            "{query}": appleScriptStringLiteral(query),
            "{queryLiteral}": appleScriptStringLiteral(query),
            "{rawQuery}": query,
            "{entityValue}": appleScriptStringLiteral(command.metadata["appleScript.entityValue"] ?? query),
            "{rawEntityValue}": command.metadata["appleScript.entityValue"] ?? query,
            "{targetApp}": appleScriptStringLiteral(targetApp),
            "{rawTargetApp}": targetApp,
            "{bundleIdentifier}": appleScriptStringLiteral(bundleIdentifier),
            "{rawBundleIdentifier}": bundleIdentifier
        ]
        return replacements.reduce(template) { partial, item in
            partial.replacingOccurrences(of: item.key, with: item.value)
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return value
    }

    private static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }
}
