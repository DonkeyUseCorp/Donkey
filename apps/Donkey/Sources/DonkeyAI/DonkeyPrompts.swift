import DonkeyContracts
import DonkeyHarness
import Foundation

/// The single home for the prompts that define how Donkey behaves — edit agent
/// doctrine here, not at the call sites.
///
/// Three boundaries get their full prompt text from this file:
///
/// - `realtimeCommandSystemInstruction` — the always-on realtime command
///   session, regardless of which provider's realtime model backs it
///   (currently `GeminiLiveVoiceController`).
/// - `requestUnderstanding` — the one-shot typed understanding of a user turn
///   before the harness loop (`HostedHarnessRequestUnderstanding`).
/// - `harnessStep` — the per-observation planning step of the harness loop
///   (`HostedHarnessStepPlanner`).
///
/// What the models read but does NOT live here, by design:
///
/// - Tool descriptors (name, summary, schemas) stay with their tools:
///   `DonkeyCommandLayer` (fast command tools), `BuiltInHarnessToolCatalog`
///   (harness tools), and the Live escalation descriptors in
///   `GeminiLiveVoiceController`. A descriptor states only that tool's own
///   factual contract — cross-tool doctrine belongs here.
/// - App-specific operating knowledge lives in discoverable skill packs
///   (`Resources/BuiltInSkills/<app>/SKILL.md`), never in prompts.
/// - Narrow task adapters keep their specialized prompts next to their parsing:
///   `VisionActionPlanner`, `GeminiVertexVisionBoxPlanner`,
///   `DebugUIInspectionHostedAdapter`, `HostedAppleScriptGenerationAdapter`,
///   `HostedTaskFollowUpResolver`, and `HostedLocalAppCatalogProfileGenerator`.
public enum DonkeyPrompts {
    // MARK: - Realtime command session

    /// Cross-tool policy only. Each tool's purpose, parameters, examples, and
    /// safety constraints live in its registered function declaration (see
    /// `CommandLayerFunctionDeclarations` / `DonkeyCommandLayer`), not here.
    public static let realtimeCommandSystemInstruction = """
    You are Donkey, a fast macOS assistant — an expert computer user sitting next \
    to the user. Act directly and immediately with the registered tools, preferring \
    shell_exec for anything the more specific tools don't cover. When a task targets \
    a specific app, call app_skill first unless you already know how to drive it: \
    the installed skill is the authority on how that app is operated (scripting, \
    vision, known workflows) and overrides your assumptions. When a skill \
    advertises a validated script that covers the task, execute it with skill_run \
    instead of reinventing the steps. If the skill says the app needs vision, or \
    scripting it fails, call vision_control with the app and goal; a vision agent \
    will operate the screen. For multi-step work the fast tools can't finish, call \
    agent_run with the goal; the desktop agent reports to the user itself. Discover \
    before guessing rather than inventing names or values. Read each tool's returned \
    output and retry or adjust on failure. Always end your turn by telling the user \
    the answer or what you did, concretely and briefly — e.g. name the files you \
    found, confirm the app you opened.
    """

    // MARK: - Request understanding (once per turn, before the loop)

    public static func requestUnderstanding(command: String, frontmostAppName: String) -> String {
        """
        You are the first step of a macOS agent. Read the user's request and return a precise, structured
        understanding of EXACTLY what they want. You do not act or choose tools here — a separate planner
        does that. Be broad in what you accept and specific in what you capture.

        The app currently in front of the user is "\(frontmostAppName)".

        USER REQUEST: \(command)

        Fill the fields:
        - restatedGoal: one concrete imperative sentence capturing exactly what to accomplish.
        - targetAppName: the macOS app that must be driven through its GUI to do this. Set it only when
          the task genuinely needs a specific app's interface (e.g. composing a message in a mail app,
          editing in a design app). LEAVE IT EMPTY when an expert would use system tools instead — finding files,
          opening or quitting apps, reading or changing settings or state — and for pure conversation.
          If it clearly concerns the current app's UI, use "\(frontmostAppName)".
        - parameters: the concrete details needed to do it (e.g. title, recipient, query, value), as
          string key/values. Omit what is not specified.
        - successCriteria: what would be visible on screen once the goal is done.
        - needsClarification: set true ONLY when the request is genuinely ambiguous or missing detail
          that you cannot reasonably resolve, or when it is destructive without a clear target. For an
          under-specified but low-risk, reversible request, pick sensible specifics and set this false.
        - clarifyingQuestion: the single question to ask when needsClarification is true; otherwise empty.

        Return JSON only.
        """
    }

    // MARK: - Harness step planning (every step of the loop)

    /// At most this many world-model elements are described to the model
    /// (highest-signal first).
    public static let harnessStepMaxElements = 150

    public static func harnessStep(
        task: HarnessTaskState,
        descriptors: [HarnessToolDescriptor],
        appName: String,
        appGuidance: String?,
        understanding: HarnessRequestUnderstanding?,
        environmentSummary: String?
    ) -> String {
        let elements = task.worldModel.elements
        let elementsBlock: String
        if elements.isEmpty {
            elementsBlock = "No on-screen elements have been observed. That is normal for system-tool tasks (shell_exec needs no observation). Only if the task needs the GUI, use a SEE tool (ax.observe or vision.capture) before acting on an element."
        } else {
            let lines = elements.prefix(harnessStepMaxElements).map { element -> String in
                "  \(element.id): [\(element.role)] \"\(element.label)\""
            }.joined(separator: "\n")
            elementsBlock = "Elements currently observed (id: [role] \"label\"):\n\(lines)"
        }

        let factsBlock = task.worldModel.facts.isEmpty
            ? ""
            : "\nKnown state:\n" + task.worldModel.facts.sorted { $0.key < $1.key }
                .map { "  \($0.key) = \($0.value)" }.joined(separator: "\n") + "\n"

        let environmentBlock = (environmentSummary?.isEmpty == false)
            ? "\nENVIRONMENT (command-line tools on this Mac — only reach for what's installed):\n  \(environmentSummary!)\n"
            : ""

        let history = task.toolHistory.suffix(12).map { "  \($0.call.name): \($0.summary)" }
        let historyBlock = history.isEmpty
            ? "Nothing has been done yet."
            : "Steps already taken (most recent last):\n" + history.joined(separator: "\n")

        let toolsBlock = descriptors
            .sorted { $0.name < $1.name }
            .map { descriptor -> String in
                let inputs = descriptor.inputSchema.keys.sorted().map { key -> String in
                    let optional = descriptor.optionalInputKeys.contains(key)
                    return "\(key)\(optional ? "?" : "")"
                }
                let inputsText = inputs.isEmpty ? "" : " (input: \(inputs.joined(separator: ", ")))"
                return "  - \(descriptor.name): \(descriptor.summary)\(inputsText)"
            }
            .joined(separator: "\n")

        let guidanceBlock: String
        if let appGuidance, !appGuidance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guidanceBlock = "\nAPP-SPECIFIC OPERATING GUIDE for \"\(appName)\":\n\(appGuidance)\n"
        } else {
            guidanceBlock = ""
        }

        // Prefer the restated goal parsed once up front; fall back to the raw task goal when no
        // understanding was produced.
        let restatedGoal = understanding?.restatedGoal
        let goalText = (restatedGoal?.isEmpty == false ? restatedGoal : nil) ?? task.goal
        let understandingBlock = self.understandingBlock(understanding)

        return """
        You are an expert macOS power user. Choose ONE tool to run next, then you will see the result
        and choose again. Work toward the goal in small, verifiable steps. Many tasks are solved
        entirely with system tools and have no on-screen UI target; reach for the GUI only when the task
        truly needs it.
        GOAL: \(goalText)
        \(understandingBlock)
        \(historyBlock)
        \(factsBlock)\(environmentBlock)\(guidanceBlock)
        \(elementsBlock)

        AVAILABLE TOOLS:
        \(toolsBlock)

        Guidance:
        - Solve it the way an expert terminal user would. Prefer shell_exec with system tools to find
          files (mdfind, ls -t, find), launch or quit apps (open -a, osascript), read state (date,
          pmset -g batt, system_profiler, defaults read), and change settings (defaults write,
          networksetup). Read-only commands run instantly; state-changing ones ask the user for
          one-time or always-allow consent, so propose them freely rather than avoiding them.
        - Only operate the GUI when the task genuinely needs it (canvas/Electron/proprietary UI, or no
          system-tool equivalent). When you do: SEE before you act — prefer ax.observe (fast,
          structured) for native apps; use vision.capture when Accessibility is missing or insufficient
          — then act on a specific element by passing its id from the list above in "input".
        - Driving a specific app with no operating guide above? Look its skill up first (app_skill, or
          skill.search for workflows) — the installed skill is the authority on how that app is
          operated and overrides assumptions.
        - If the request is a question or chit-chat rather than an action, answer with
          conversation.respond (set input.response), then run.complete.
        - If a required detail is missing and you cannot safely proceed, use user.clarify
          (set input.question).
        - Verification must be evidence-backed: after acting, confirm the effect (a shell command's
          output/exit code, a re-observe, or state.verify) BEFORE choosing run.complete. A focused app
          is not evidence; only complete once the goal is confirmed by what you can see.
        Return JSON: {"tool": "<one tool name>", "input": {"key": "value", ...}, "reason": "<one sentence>"}.
        """
    }

    /// A compact, high-signal block describing the parsed request, rendered every step so the planner
    /// keeps the precise target, parameters, and success criteria in view. Empty when no understanding
    /// was produced.
    private static func understandingBlock(_ understanding: HarnessRequestUnderstanding?) -> String {
        guard let understanding else { return "" }
        var lines: [String] = []
        if let app = understanding.targetAppName, !app.isEmpty {
            lines.append("  Target app: \(app)")
        }
        if !understanding.parameters.isEmpty {
            let params = understanding.parameters.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            lines.append("  Parameters: \(params)")
        }
        if let criteria = understanding.successCriteria, !criteria.isEmpty {
            lines.append("  Success when: \(criteria)")
        }
        guard !lines.isEmpty else { return "" }
        return "WHAT THE USER WANTS:\n" + lines.joined(separator: "\n") + "\n"
    }
}
