import DonkeyContracts
import DonkeyHarness
import Foundation
import os

public enum LocalAppUserQueryHarnessServices {
    private static let logger = Logger(subsystem: "com.donkey.app", category: "skill-script")

    public static func builtInSkillBackedServices() -> HarnessBuiltInToolServices {
        HarnessBuiltInToolServices(
            skillRegistry: HarnessSkillRegistry(skills: BuiltInLocalAppSkillPacks.descriptors()),
            generatedScripts: HarnessGeneratedScriptStore(artifacts: builtInValidatedScriptArtifacts()),
            // Learned + promoted skill packs land under the default LearnedApplications root, where
            // BuiltInLocalAppSkillPacks re-discovers them (30s TTL) for app_skill / skill_run.
            applicationSkillPackWriter: HarnessApplicationSkillPackWriter(
                rootDirectory: HarnessApplicationSkillPackWriter.defaultRootDirectory()
            ),
            scriptingDictionaryProvider: { targetApp, bundleIdentifier in
                let lookup = await AppScriptingDictionaryService.shared.lookup(
                    appName: targetApp,
                    bundleIdentifier: bundleIdentifier ?? targetApp
                )
                guard lookup.dictionary != nil else { return nil }
                return HarnessScriptingDictionarySnapshot(
                    digest: lookup.digest,
                    commandNames: lookup.commandNames
                )
            },
            appleScriptCompiler: { source, targetApp, bundleIdentifier in
                await NSAppleScriptCompileGate().compile(
                    source: source,
                    targetApp: targetApp,
                    bundleIdentifier: bundleIdentifier
                )
            },
            appleScriptExecutor: { artifact, context in
                await executeSkillScript(artifact: artifact, context: context)
            },
            skillScriptExecutor: { artifact, context in
                await executeSkillScript(artifact: artifact, context: context)
            },
            // Preflight Automation consent (no prompt) so mid-task AppleScript routes through the
            // in-notch permission gate instead of firing a bare system dialog.
            automationConsentGranted: { bundleIdentifier in
                SystemPermissionCoordinator.isGranted(.automation(targetBundleID: bundleIdentifier))
            },
            // The Command Layer (incl. shell_exec) is intentionally available to
            // the local planner as well as the Gemini Live session; both go
            // through the same DonkeyCommandBackends guardrails.
            commandExecutor: DonkeyCommandBackends.makeExecutor()
        )
    }

    public static func builtInValidatedScriptArtifacts() -> [HarnessGeneratedScriptArtifact] {
        BuiltInLocalAppSkillPacks.descriptors().flatMap { skill in
            skill.scripts.compactMap { script -> HarnessGeneratedScriptArtifact? in
                guard let source = BuiltInLocalAppSkillPacks.scriptSource(
                    skillID: skill.id,
                    relativePath: script.relativePath
                ) else {
                    return nil
                }
                return HarnessGeneratedScriptArtifact(
                    id: script.id,
                    language: generatedLanguage(for: script.language),
                    source: source,
                    validationStatus: .validated,
                    createdByToolName: "built-in-skill-pack",
                    ownerSkillID: skill.id,
                    metadata: script.metadata.merging([
                        "skillID": skill.id,
                        "relativePath": script.relativePath,
                        "validation.policy": "builtInSkillScript",
                        "validation.provenance": "bundleResource"
                    ]) { current, _ in current }
                )
            }
        }
    }

    public static func executeSkillScript(
        artifact: HarnessGeneratedScriptArtifact,
        context: HarnessToolExecutionContext
    ) async -> HarnessScriptExecutionOutcome {
        switch artifact.language {
        case .appleScript:
            return await executeAppleScriptSkill(artifact: artifact, context: context)
        case .shell, .javaScript, .python, .swift, .unknown:
            return HarnessScriptExecutionOutcome(
                succeeded: false,
                summary: "Skill script language is not supported by the guarded local-app backend.",
                metadata: [
                    "reason": "unsupportedSkillScriptLanguage",
                    "language": artifact.language.rawValue
                ]
            )
        }
    }

    private static func executeAppleScriptSkill(
        artifact: HarnessGeneratedScriptArtifact,
        context: HarnessToolExecutionContext
    ) async -> HarnessScriptExecutionOutcome {
        let input = context.call.input["input"]
            ?? context.call.input["query"]
            ?? context.call.input["entityValue"]
            ?? ""
        let command = ActionEngineCommand(
            id: "\(context.agentID)-\(artifact.id)",
            traceID: context.call.metadata["traceID"] ?? context.agentID,
            targetID: context.call.input["targetID"] ?? artifact.ownerSkillID ?? artifact.id,
            kind: .controller,
            issuedAt: now(),
            key: input,
            metadata: [
                "automationBackend": "appleScript",
                "appleScript.action": artifact.metadata["action"] ?? artifact.id,
                "appleScript.template": artifact.source,
                "appleScript.query": input,
                "appleScript.entityValue": input,
                "targetApp": context.call.input["targetApp"] ?? "",
                "bundleIdentifier": context.call.input["bundleIdentifier"] ?? ""
            ]
        )
        let result = await MacAppleScriptActionEngineInputBackend().execute(command)
        let output = result.metadata["appleScript.output"] ?? ""
        let outputMetadata = structuredOutputMetadata(output)
        let clarificationRequired = outputMetadata["clarification.required"] == "true"
        // Honor a status the script reports about its own outcome: a script can run cleanly (executed)
        // yet report `status=not_found`/`status=failed` because the real-world effect didn't happen
        // (e.g. playback never started). Treating that as success is a false positive — the agent
        // would claim it did something it didn't.
        let scriptStatus = outputMetadata["status"]
        let statusReportsFailure = scriptStatus == "not_found" || scriptStatus == "failed"
        let succeeded = result.executed && !clarificationRequired && !statusReportsFailure
        let summary = skillScriptSummary(
            succeeded: succeeded,
            executed: result.executed,
            output: output,
            error: result.metadata["appleScript.error"] ?? ""
        )
        logger.log(
            "skill script result skillID=\(artifact.ownerSkillID ?? "", privacy: .public) scriptID=\(artifact.id, privacy: .public) executed=\(result.executed) succeeded=\(succeeded) status=\(scriptStatus ?? "", privacy: .public) error=\(result.metadata["appleScript.error"] ?? "", privacy: .public)"
        )
        return HarnessScriptExecutionOutcome(
            succeeded: succeeded,
            summary: summary,
            output: output,
            metadata: result.metadata.merging(outputMetadata) { current, _ in current }.merging([
                "skillID": artifact.ownerSkillID ?? "",
                "scriptID": artifact.id,
                "script.relativePath": artifact.metadata["relativePath"] ?? ""
            ]) { current, _ in current }
        )
    }

    /// The summary is the tool-result body the planner actually reads each step (history lines and
    /// the thread both carry it; the structured output only lands in world-model facts). A skill
    /// script's whole feedback loop — `status=not_found` → escalate to vision instead of retrying —
    /// depends on its self-report traveling in this string, so never collapse a failure to a generic
    /// one-liner.
    public static func skillScriptSummary(
        succeeded: Bool,
        executed: Bool,
        output: String,
        error: String
    ) -> String {
        if !executed && output.isEmpty {
            let detail = error.isEmpty ? "no output" : String(error.prefix(300))
            return "Skill script errored before reporting a status: \(detail)"
        }
        let headline = succeeded
            ? "Skill script succeeded."
            : "Skill script ran but reported the goal was not achieved — read its status below and adjust your approach; do not repeat the same call."
        guard !output.isEmpty else { return headline }
        return headline + "\nScript report:\n" + String(output.prefix(500))
    }

    private static func structuredOutputMetadata(_ output: String) -> [String: String] {
        var metadata: [String: String] = [:]
        let fields = output
            .split { character in
                character == "\n" || character == "\r" || character == ";"
            }
        for field in fields {
            let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            metadata[key] = value
        }
        return metadata
    }

    private static func generatedLanguage(
        for language: HarnessSkillScriptLanguage
    ) -> HarnessGeneratedScriptLanguage {
        switch language {
        case .appleScript:
            return .appleScript
        case .shell:
            return .shell
        case .javaScript:
            return .javaScript
        case .python:
            return .python
        case .swift:
            return .swift
        case .unknown:
            return .unknown
        }
    }

    private static func now() -> RunTraceTimestamp {
        RunTraceTimestamp(
            wallClock: Date(),
            monotonicUptimeNanoseconds: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        )
    }
}
