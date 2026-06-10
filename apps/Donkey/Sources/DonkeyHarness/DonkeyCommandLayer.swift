import Foundation

/// The Donkey Command Layer: fast, deterministic, native commands the model can
/// call directly without screenshots or Accessibility. Descriptors live here in
/// the (Foundation-only) harness module; the native side effects are injected as
/// a `commandExecutor` closure on `HarnessBuiltInToolServices`, with the concrete
/// implementation in `DonkeyRuntime`.
public enum DonkeyCommandLayer {
    public static let pluginID = "donkey.command"

    /// Single source of truth for the command names shared between the descriptors
    /// here and the runtime backend that executes them.
    ///
    /// Names must be valid LLM function-call identifiers (`[A-Za-z_][A-Za-z0-9_]*`):
    /// Gemini/Vertex Live rejects dots and silently normalizes them, so a name like
    /// `apps.list` would come back from the model as `apps_list` and miss dispatch.
    /// Use underscores, never dots.
    public enum Command: String, CaseIterable, Sendable {
        case shellExec = "shell_exec"
        case appsList = "apps_list"
        case appSkill = "app_skill"
        case skillRun = "skill_run"
    }

    public static var descriptors: [HarnessToolDescriptor] {
        [
            // Primary, general-purpose tool — listed first so the model reaches
            // for it by default.
            HarnessToolDescriptor(
                name: Command.shellExec.rawValue,
                pluginID: pluginID,
                summary: "Run a single-line shell command on the user's Mac and return its output. This is your primary, expert tool: prefer it for finding files (`mdfind`, `ls -t`, `find`), launching or quitting apps (`open -a \"App Name\"`, `osascript -e 'quit app \"App Name\"'`), reading state (`date`, `pmset -g batt`, `system_profiler`), and changing settings (`defaults write`, `networksetup -set…`). Read-only commands run immediately; anything that changes state asks the user for one-time or always-allow consent first, so you may freely propose it. Destructive or privileged commands (`sudo`, `rm`, `dd`, piping into a shell) ask every time.",
                inputSchema: ["command": "A safe, single-line shell command, e.g. `open -a \"App Name\"`, `osascript -e '…'`, or `date`."],
                outputSchema: [
                    "stdout": "Captured standard output (trimmed).",
                    "exitCode": "Process exit code."
                ],
                requiredPermissions: [.appControl, .input],
                safetyClass: .guardedInput,
                verificationHints: ["the command exits with code 0"]
            ),
            HarnessToolDescriptor(
                name: Command.appsList.rawValue,
                pluginID: pluginID,
                summary: "List installed and currently-running applications (display names + bundle ids), so you can target exact app names before opening, quitting, or scripting an app instead of guessing. Prefer `filter` when you already know part of the name. The installed list is paginated: to browse the full catalog, read `hasMore`/`nextOffset` in the result and call again with `offset` set to `nextOffset`, keeping the same `filter`.",
                inputSchema: [
                    "filter": "Case-insensitive substring to narrow both lists. Use this first when you know part of the app name.",
                    "offset": "Zero-based start index into the installed list, for pagination. Defaults to 0. Pass the previous result's `nextOffset` to fetch the next page.",
                    "limit": "Max installed apps to return in this page. Defaults to 50, capped at 200. Running apps are always returned in full."
                ],
                optionalInputKeys: ["filter", "offset", "limit"],
                outputSchema: [
                    "installed": "Comma-separated installed app names for the current page.",
                    "running": "Comma-separated running app names (always the full list).",
                    "installedTotal": "Total installed apps matching the filter, across all pages.",
                    "offset": "Start index of the returned page.",
                    "limit": "Page size applied.",
                    "returned": "Number of installed apps in this page.",
                    "hasMore": "\"true\" when more installed pages remain.",
                    "nextOffset": "Offset to pass next to continue paging (present only when hasMore is true)."
                ],
                requiredPermissions: [.appLookup],
                safetyClass: .readOnly
            ),
            HarnessToolDescriptor(
                name: Command.appSkill.rawValue,
                pluginID: pluginID,
                summary: "Look up the installed operating playbook (skill) for a specific app before driving it. The playbook says how that app is operated — whether it is scriptable, must be driven by vision, and its known workflows and pitfalls. Call this whenever a task targets a specific app you have no loaded guidance for; if no skill is installed the result says so and you fall back to your general tools.",
                inputSchema: ["app": "The app's display name or bundle identifier."],
                outputSchema: [
                    "found": "\"true\" when an operating playbook is installed for the app.",
                    "guidance": "The app's operating playbook, when found."
                ],
                requiredPermissions: [.skillLookup],
                safetyClass: .readOnly
            ),
            HarnessToolDescriptor(
                name: Command.skillRun.rawValue,
                pluginID: pluginID,
                summary: "Execute a validated script that an installed skill ships, without screenshots. Skills advertise their scripts through app_skill (skill id + script ids); running one performs that skill's bounded multi-step workflow natively in well under a second. Use it whenever a looked-up skill offers a script that covers the task, instead of reinventing the steps yourself.",
                inputSchema: [
                    "skillID": "The skill that ships the script, as advertised by app_skill.",
                    "scriptID": "The validated script to execute, as advertised by app_skill.",
                    "input": "The script's input value (e.g. a search query), when it takes one."
                ],
                optionalInputKeys: ["input"],
                outputSchema: ["status": "Structured status the script reports."],
                requiredPermissions: [.appControl, .input],
                safetyClass: .guardedInput,
                verificationHints: ["the script reports a successful structured status"]
            )
        ]
    }
}
