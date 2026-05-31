import AppKit
import DonkeyContracts
import DonkeyHarness
import Foundation

/// Native implementations for the Donkey Command Layer (`DonkeyCommandLayer`).
///
/// These run in-process using AppKit / the bundled AppleScript backend — no
/// screenshots, no Accessibility tree — so the model can act in well under
/// 500ms. The executor is injected into the harness as
/// `HarnessBuiltInToolServices.commandExecutor`.
public enum DonkeyCommandBackends {
    /// Build the closure wired into `HarnessBuiltInToolServices.commandExecutor`.
    /// Returns a result for a recognized command, or `nil` so harness dispatch
    /// falls through to its `unknownTool` handling.
    public static func makeExecutor() -> @Sendable (HarnessToolExecutionContext) async -> HarnessToolResult? {
        { context in await execute(context) }
    }

    @MainActor
    static func execute(_ context: HarnessToolExecutionContext) async -> HarnessToolResult? {
        guard let command = DonkeyCommandLayer.Command(rawValue: context.call.name) else {
            return nil
        }
        switch command {
        case .shellExec:
            return await shellExec(context)
        case .appsList:
            return listApps(context)
        case .musicPlay:
            return await playMusic(context)
        }
    }

    // MARK: - apps.list

    @MainActor
    private static func listApps(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        let filter = trimmed(context.call.input["filter"])?.lowercased()

        func passesFilter(_ value: String) -> Bool {
            guard let filter else { return true }
            return value.lowercased().contains(filter)
        }

        // Reuse the shared Spotlight-backed catalog (names + bundle ids, all the
        // standard search roots) instead of a duplicated directory scan.
        let installed = MacLocalAppAvailabilityProvider.installedApplications()
            .filter { passesFilter($0.appName) || ($0.bundleIdentifier.map(passesFilter) ?? false) }
            .map { candidate -> String in
                guard let bundleID = candidate.bundleIdentifier, !bundleID.isEmpty else { return candidate.appName }
                return "\(candidate.appName) (\(bundleID))"
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
            .filter(passesFilter)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        return success(
            context,
            summary: "Installed (\(installed.count)): \(capped(installed))\nRunning (\(running.count)): \(capped(running))",
            facts: ["installedAppCount": String(installed.count)],
            metadata: [
                "installed": capped(installed),
                "running": capped(running)
            ]
        )
    }

    /// Join names, capped so the model response stays bounded.
    private static func capped(_ names: [String], limit: Int = 3_000) -> String {
        var result = ""
        for name in names {
            let next = result.isEmpty ? name : "\(result), \(name)"
            if next.count > limit {
                return result.isEmpty ? String(name.prefix(limit)) : "\(result), …"
            }
            result = next
        }
        return result
    }

    // MARK: - music.play

    private static func playMusic(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        guard trimmed(context.call.input["query"]) != nil else {
            return invalidInput(context, "music.play requires a `query`.")
        }
        guard let artifact = LocalAppUserQueryHarnessServices
            .builtInValidatedScriptArtifacts()
            .first(where: { $0.id == "scripts-play-media-by-search" }) else {
            return failed(context, "The bundled music playback skill is unavailable.", reason: "musicSkillUnavailable")
        }
        let outcome = await LocalAppUserQueryHarnessServices.executeSkillScript(artifact: artifact, context: context)
        if outcome.metadata["clarification.required"] == "true" {
            return HarnessToolResult(
                callID: context.call.id,
                toolName: context.call.name,
                status: .waitingForUser,
                summary: "The music app needs clarification before playing.",
                question: outcome.metadata["clarification.question"] ?? "What would you like me to play?",
                metadata: outcome.metadata.merging(["gate": "clarification"]) { current, _ in current }
            )
        }
        guard outcome.succeeded else {
            return failed(context, outcome.summary, reason: outcome.metadata["failureReason"] ?? "musicPlayFailed")
        }
        return success(
            context,
            summary: outcome.summary,
            facts: ["musicStatus": outcome.metadata["status"] ?? "played"],
            metadata: outcome.metadata
        )
    }

    // MARK: - shell_exec

    /// Max characters accepted for a one-line command.
    private static let shellCommandMaxLength = 400
    /// Seconds before a command is terminated.
    private static let shellTimeout: TimeInterval = 12
    /// Max stdout characters returned to the model.
    private static let shellOutputMaxLength = 4_000

    /// Executables that are unsafe in any position. Matched against the leading
    /// token of each pipeline/command segment (path-stripped, dequoted), so a
    /// bare `rm file`, `/bin/rm`, or a denied command inside `$(…)` is caught —
    /// unlike substring matching, which both missed these and false-positived on
    /// benign text.
    private static let shellDeniedExecutables: Set<String> = [
        "sudo", "su", "doas",
        "rm", "rmdir", "mv", "dd", "mkfs", "fdisk", "diskutil", "shred", "srm",
        "chmod", "chown", "chflags",
        "shutdown", "reboot", "halt", "killall", "pkill", "kill",
        "launchctl", "csrutil", "spctl", "nvram", "pmset",
        "scp", "sftp", "ssh", "telnet", "nc", "ncat", "curl", "wget",
        "eval", "source", "security"
    ]

    /// Dangerous regardless of position (shell-level constructs / sensitive
    /// redirect targets / privilege-escalation phrases).
    private static let shellDeniedSubstrings: [String] = [
        "do shell script", ":(){", "| sh", "|sh", "| bash", "|bash",
        "> /dev", ">/dev", "> /system", ">/system", "> /usr", ">/usr",
        "> /etc", ">/etc", "defaults delete"
    ]

    /// Returns the matched unsafe token if the command should be refused, else nil.
    static func unsafeShellReason(_ command: String) -> String? {
        let lowered = command.lowercased()
        for substring in shellDeniedSubstrings where lowered.contains(substring) {
            return substring.trimmingCharacters(in: .whitespaces)
        }
        // Split into command segments on shell separators and substitution
        // boundaries, then check each segment's leading executable.
        let separators = CharacterSet(charactersIn: ";|&\n`(")
        for segment in lowered.components(separatedBy: separators) {
            let trimmedSegment = segment.trimmingCharacters(in: .whitespaces)
            guard let firstToken = trimmedSegment.split(separator: " ").first.map(String.init) else { continue }
            let executable = (firstToken.split(separator: "/").last.map(String.init) ?? firstToken)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\\'\"$"))
            if shellDeniedExecutables.contains(executable) {
                return executable
            }
        }
        return nil
    }

    private static func shellExec(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        guard let command = trimmed(context.call.input["command"]) ?? trimmed(context.call.input["cmd"]) else {
            return invalidInput(context, "shell_exec requires a one-line `command`.")
        }
        guard !command.contains("\n"), !command.contains("\r") else {
            return invalidInput(context, "shell_exec only runs a single-line command.")
        }
        guard command.count <= shellCommandMaxLength else {
            return invalidInput(context, "shell_exec command is too long.")
        }
        if let blocked = unsafeShellReason(command) {
            return failed(
                context,
                "Refused an unsafe shell command (matched \"\(blocked)\").",
                reason: "blockedCommand"
            )
        }

        let result = await Task.detached(priority: .userInitiated) {
            runShellSync(command, timeout: shellTimeout)
        }.value

        let stdout = String(result.stdout.prefix(shellOutputMaxLength))
        guard result.exitCode == 0 else {
            return HarnessToolResult(
                callID: context.call.id,
                toolName: context.call.name,
                status: .failed,
                summary: "Command exited with code \(result.exitCode).",
                metadata: [
                    "executor": "donkeyCommandLayer",
                    "reason": result.timedOut ? "timedOut" : "nonZeroExit",
                    "exitCode": String(result.exitCode),
                    "stdout": stdout,
                    "stderr": String(result.stderr.prefix(shellOutputMaxLength))
                ]
            )
        }
        return success(
            context,
            summary: stdout.isEmpty ? "Command ran (no output)." : stdout,
            facts: ["lastShellExitCode": "0"],
            metadata: ["stdout": stdout, "exitCode": "0"]
        )
    }

    private struct ShellResult: Sendable {
        var exitCode: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
    }

    /// Run a one-line command via `/bin/zsh -c`, bounded by `timeout`. Blocking;
    /// always called off the main actor via `Task.detached`.
    private static func runShellSync(_ command: String, timeout: TimeInterval) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Signalled by the OS when the process actually exits — the only
        // reliable completion signal (reading the pipes first can deadlock if the
        // child fills the 64KB buffer and blocks on write).
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            return ShellResult(exitCode: 127, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate() // SIGTERM
            // Escalate to SIGKILL if it ignores SIGTERM, so the bound is real.
            if finished.wait(timeout: .now() + 1.0) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
        }

        // The process has exited, so the pipe write ends are closed and these
        // reads return promptly without deadlocking.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            stderr: String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            timedOut: timedOut
        )
    }

    // MARK: - Result helpers

    private static func success(
        _ context: HarnessToolExecutionContext,
        summary: String,
        facts: [String: String],
        metadata: [String: String]
    ) -> HarnessToolResult {
        var allFacts = facts
        allFacts["lastAcceptedTool"] = context.call.name
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .succeeded,
            summary: summary,
            observations: HarnessObservationDelta(facts: allFacts),
            metadata: metadata.merging(["executor": "donkeyCommandLayer"]) { current, _ in current }
        )
    }

    private static func failed(
        _ context: HarnessToolExecutionContext,
        _ summary: String,
        reason: String
    ) -> HarnessToolResult {
        HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .failed,
            summary: summary,
            metadata: ["executor": "donkeyCommandLayer", "reason": reason]
        )
    }

    private static func invalidInput(
        _ context: HarnessToolExecutionContext,
        _ summary: String
    ) -> HarnessToolResult {
        HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .invalidInput,
            summary: summary,
            metadata: ["executor": "donkeyCommandLayer", "reason": "invalidInput"]
        )
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
