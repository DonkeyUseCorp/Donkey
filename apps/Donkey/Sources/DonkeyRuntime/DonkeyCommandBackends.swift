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
        case .appSkill:
            return appSkill(context)
        case .skillRun:
            return await runSkillScript(context)
        }
    }

    // MARK: - app_skill

    /// Surface the installed operating playbook for an app, discovered from the
    /// skill packs by display name or bundle id — never from a hardcoded app
    /// list. Apps without a skill report that plainly so the model falls back to
    /// its general tools.
    private static func appSkill(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        guard let app = trimmed(context.call.input["app"]) else {
            return invalidInput(context, "app_skill requires an `app` display name or bundle identifier.")
        }
        guard let descriptor = BuiltInLocalAppSkillPacks.appSkillDescriptor(forApp: app, bundleIdentifier: app),
              let guidance = BuiltInLocalAppSkillPacks.appOperatingGuidance(forApp: app, bundleIdentifier: app)
        else {
            return success(
                context,
                summary: "No operating skill is installed for \(app).",
                facts: ["appSkill.\(app)": "notFound"],
                metadata: ["found": "false", "app": app]
            )
        }
        // Advertise the skill's validated scripts so the model can execute a
        // covered workflow directly with skill_run instead of reinventing it.
        let scriptLines = descriptor.scripts.map { script in
            "- skillID=\(descriptor.id) scriptID=\(script.id)\(script.purpose.isEmpty ? "" : " — \(script.purpose)")"
        }
        let scriptsBlock = scriptLines.isEmpty
            ? ""
            : "\n\nValidated scripts (execute with skill_run):\n" + scriptLines.joined(separator: "\n")
        return success(
            context,
            summary: guidance + scriptsBlock,
            facts: ["appSkill.\(app)": "loaded"],
            metadata: [
                "found": "true",
                "app": app,
                "skillID": descriptor.id,
                "scriptIDs": descriptor.scripts.map(\.id).joined(separator: ","),
                "guidance": guidance
            ]
        )
    }

    // MARK: - apps_list

    /// Default and ceiling for the installed-list page size. The installed
    /// catalog can run to ~100+ entries, which overflowed the response cap and
    /// silently dropped the tail; pagination lets the model page deterministically.
    private static let appsDefaultPageSize = 50
    private static let appsMaxPageSize = 200
    /// Char budget for the joined installed names. The page is built to fit this so
    /// the reported `returned`/`hasMore`/`nextOffset` describe exactly the names
    /// emitted — a later truncation can never silently drop names the model was told
    /// it received and would page past.
    private static let appsResponseCharBudget = 3_000
    /// The Spotlight-backed catalog scan (mdfind subprocess + per-app Info.plist
    /// reads) is expensive and barely changes within a session, so reuse it across
    /// paginated calls instead of re-enumerating on every page.
    private static let installedCatalogTTLSeconds: TimeInterval = 60
    @MainActor private static var installedCatalogCache: (expires: Date, apps: [LocalApplicationCatalogCandidate])?

    @MainActor
    private static func cachedInstalledApplications() -> [LocalApplicationCatalogCandidate] {
        let now = Date()
        if let cache = installedCatalogCache, cache.expires > now { return cache.apps }
        let apps = MacLocalAppAvailabilityProvider.installedApplications()
        installedCatalogCache = (now.addingTimeInterval(installedCatalogTTLSeconds), apps)
        return apps
    }

    @MainActor
    private static func listApps(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        let filter = trimmed(context.call.input["filter"])?.lowercased()

        func passesFilter(_ value: String) -> Bool {
            guard let filter else { return true }
            return value.lowercased().contains(filter)
        }

        // Pagination inputs apply to the installed list only (the large one);
        // running apps are few and always returned in full.
        var offset = 0
        if let rawOffset = trimmed(context.call.input["offset"]) {
            guard let parsed = Int(rawOffset), parsed >= 0 else {
                return invalidInput(context, "`offset` must be a non-negative integer (zero-based index into the installed list).")
            }
            offset = parsed
        }

        var limit = appsDefaultPageSize
        if let rawLimit = trimmed(context.call.input["limit"]) {
            guard let parsed = Int(rawLimit), parsed >= 1 else {
                return invalidInput(context, "`limit` must be a positive integer (max \(appsMaxPageSize)).")
            }
            limit = min(parsed, appsMaxPageSize)
        }

        // Reuse the shared Spotlight-backed catalog (names + bundle ids, all the
        // standard search roots — including /System/Applications, so Apple native
        // apps are present) instead of a duplicated directory scan.
        let installedAll = cachedInstalledApplications()
            .filter { passesFilter($0.appName) || ($0.bundleIdentifier.map(passesFilter) ?? false) }
            .map { candidate -> String in
                guard let bundleID = candidate.bundleIdentifier, !bundleID.isEmpty else { return candidate.appName }
                return "\(candidate.appName) (\(bundleID))"
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        let installedTotal = installedAll.count
        let pageStart = min(offset, installedTotal)
        // Build the page so what we COUNT is exactly what we EMIT: take up to `limit`
        // names from `pageStart`, but stop early if the joined text would exceed the
        // response budget. `nextOffset`/`hasMore` then describe the real emitted page,
        // not an over-counted slice the response cap would have silently truncated.
        let (installedPage, installedText) = pagedNames(
            installedAll, start: pageStart, maxCount: limit, charBudget: appsResponseCharBudget
        )
        let pageEnd = pageStart + installedPage.count
        let hasMore = pageEnd < installedTotal
        let nextOffset = hasMore ? pageEnd : nil

        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
            .filter(passesFilter)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        // Self-describing page header so the model can chain pages from the
        // result text alone, without re-deriving the input schema.
        let rangeText = installedTotal == 0
            ? "Installed (0)"
            : "Installed \(pageStart + 1)–\(pageEnd) of \(installedTotal)"
        let moreText = nextOffset.map { " — more available, call apps_list again with offset=\($0) (same filter) for the next page" } ?? ""

        var metadata: [String: String] = [
            "installed": installedText,
            "running": capped(running),
            "installedTotal": String(installedTotal),
            "offset": String(pageStart),
            "limit": String(limit),
            "returned": String(installedPage.count),
            "hasMore": hasMore ? "true" : "false"
        ]
        if let nextOffset { metadata["nextOffset"] = String(nextOffset) }
        if let filter = trimmed(context.call.input["filter"]) { metadata["filter"] = filter }

        return success(
            context,
            summary: "\(rangeText)\(moreText): \(installedText)\nRunning (\(running.count)): \(capped(running))",
            facts: [
                "installedAppCount": String(installedTotal),
                "installedReturnedCount": String(installedPage.count)
            ],
            metadata: metadata
        )
    }

    /// Take up to `maxCount` names starting at `start`, stopping early if the joined
    /// text would exceed `charBudget`, and return the names actually taken alongside
    /// their joined string. The returned count is authoritative: callers derive
    /// `returned`/`hasMore`/`nextOffset` from it so the page header can't claim more
    /// than was emitted. At least one name is always taken (so paging makes progress
    /// even if a single name exceeds the budget).
    private static func pagedNames(
        _ names: [String],
        start: Int,
        maxCount: Int,
        charBudget: Int
    ) -> (page: [String], joined: String) {
        var page: [String] = []
        var joinedLength = 0
        var index = start
        while index < names.count, page.count < maxCount {
            let name = names[index]
            let separatorLength = page.isEmpty ? 0 : 2  // ", "
            let projected = joinedLength + separatorLength + name.count
            if !page.isEmpty, projected > charBudget { break }
            page.append(name)
            joinedLength = projected
            index += 1
        }
        return (page, page.joined(separator: ", "))
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

    // MARK: - skill_run

    /// Execute a validated script an installed skill ships, looked up by the
    /// skill/script ids the model got from `app_skill` — the generic native
    /// fast path for any skill-covered workflow, with nothing domain-specific.
    private static func runSkillScript(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        guard let skillID = trimmed(context.call.input["skillID"]) else {
            return invalidInput(context, "skill_run requires the `skillID` advertised by app_skill.")
        }
        guard let scriptID = trimmed(context.call.input["scriptID"]) else {
            return invalidInput(context, "skill_run requires the `scriptID` advertised by app_skill.")
        }
        guard let artifact = LocalAppUserQueryHarnessServices
            .builtInValidatedScriptArtifacts()
            .first(where: { $0.id == scriptID && $0.ownerSkillID == skillID }) else {
            return failed(
                context,
                "No validated script \(scriptID) is installed for skill \(skillID). Look the app's skill up with app_skill for the available scripts.",
                reason: "skillScriptUnavailable"
            )
        }
        let outcome = await LocalAppUserQueryHarnessServices.executeSkillScript(artifact: artifact, context: context)
        if outcome.metadata["clarification.required"] == "true" {
            return HarnessToolResult(
                callID: context.call.id,
                toolName: context.call.name,
                status: .waitingForUser,
                summary: "The script needs clarification before it can proceed.",
                question: outcome.metadata["clarification.question"] ?? "What exactly should I use?",
                metadata: outcome.metadata.merging(["gate": "clarification"]) { current, _ in current }
            )
        }
        guard outcome.succeeded else {
            // Preserve the script's full output metadata on failure — it may carry an
            // `escalate.app`/`escalate.goal` signal that the runtime's structural feedback loop acts
            // on (hand the unfinished task to the vision agent) instead of dead-ending.
            return HarnessToolResult(
                callID: context.call.id,
                toolName: context.call.name,
                status: .failed,
                summary: outcome.summary,
                metadata: outcome.metadata.merging([
                    "reason": outcome.metadata["failureReason"] ?? "skillScriptFailed"
                ]) { current, _ in current }
            )
        }
        return success(
            context,
            summary: outcome.summary,
            facts: ["skillRun.\(scriptID)": outcome.metadata["status"] ?? "succeeded"],
            metadata: outcome.metadata
        )
    }

    // MARK: - shell_exec

    /// Max characters accepted for a one-line command.
    private static let shellCommandMaxLength = 400
    /// Seconds before a command is terminated when the call does not set its own budget.
    private static let shellTimeout: TimeInterval = 12
    /// Upper bound for a caller-provided `timeoutSeconds`, so a planner mistake can never hang a run.
    private static let shellTimeoutMax: TimeInterval = 120
    /// Max stdout characters returned to the model.
    private static let shellOutputMaxLength = 4_000

    /// Truncates output to the model-facing cap, announcing the cut instead of trimming silently —
    /// the model must know it saw a prefix, not the whole output.
    private static func boundedOutput(_ output: String) -> (text: String, truncated: Bool) {
        guard output.count > shellOutputMaxLength else { return (output, false) }
        return (String(output.prefix(shellOutputMaxLength)) + "\n… [output truncated]", true)
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

        // Classify by risk tier. Reads run immediately; anything that changes
        // state needs consent (allow-once / always-allow) unless it was already
        // granted. Nothing is silently refused.
        let classification = ShellCommandClassifier.classify(command)
        if classification.tier != .read {
            if let gate = await consentGate(context, command: command, classification: classification) {
                return gate
            }
        }

        let timeout = context.call.input["timeoutSeconds"].flatMap(Double.init)
            .map { min(max($0, 1), shellTimeoutMax) } ?? shellTimeout
        let result = await Task.detached(priority: .userInitiated) {
            runShellSync(command, timeout: timeout)
        }.value

        let stdout = boundedOutput(result.stdout)
        guard result.exitCode == 0 else {
            let stderr = boundedOutput(result.stderr)
            return HarnessToolResult(
                callID: context.call.id,
                toolName: context.call.name,
                status: .failed,
                summary: result.timedOut
                    ? "Command timed out after \(Int(timeout))s and was terminated. Pass timeoutSeconds (max \(Int(shellTimeoutMax))) for known-slow commands."
                    : "Command exited with code \(result.exitCode).",
                metadata: [
                    "executor": "donkeyCommandLayer",
                    "reason": result.timedOut ? "timedOut" : "nonZeroExit",
                    "exitCode": String(result.exitCode),
                    "stdout": stdout.text,
                    "stderr": stderr.text,
                    "stdoutTruncated": String(stdout.truncated),
                    "timeoutSeconds": String(Int(timeout))
                ]
            )
        }
        return success(
            context,
            summary: stdout.text.isEmpty ? "Command ran (no output)." : stdout.text,
            facts: ["lastShellExitCode": "0"],
            metadata: ["stdout": stdout.text, "exitCode": "0", "stdoutTruncated": String(stdout.truncated)]
        )
    }

    /// Returns nil when the command is already allowed (run it), or a
    /// `waitingForPermission` gate result the runtime turns into an allow-once /
    /// always-allow prompt. `highRisk` commands can only be allowed once.
    private static func consentGate(
        _ context: HarnessToolExecutionContext,
        command: String,
        classification: ShellCommandClassification
    ) async -> HarnessToolResult? {
        let store = ShellPermissionPolicyStore.shared
        let signature = classification.signature

        var allowed = false
        if classification.tier != .highRisk {
            allowed = await store.isAlwaysAllowed(signature)
        }
        if !allowed {
            allowed = await store.consumeOnce(taskID: context.taskID, signature: signature)
        }
        if allowed { return nil }

        let allowAlways = classification.tier != .highRisk
        let reason = classification.reason.map { " (\($0))" } ?? ""
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .waitingForPermission,
            summary: "Needs your approval to run `\(command)`\(reason).",
            metadata: [
                "executor": "donkeyCommandLayer",
                "gate": "shellConsent",
                "shell.command": command,
                "shell.signature": signature,
                "shell.tier": classification.tier.rawValue,
                "shell.reason": classification.reason ?? "",
                "shell.allowAlways": allowAlways ? "true" : "false"
            ]
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
