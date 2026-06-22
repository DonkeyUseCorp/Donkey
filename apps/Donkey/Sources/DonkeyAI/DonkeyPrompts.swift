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
    shell_exec for anything the more specific tools don't cover. Do things LOCALLY \
    first: for anything an installed Mac app or system tool handles — playing music, \
    notes, mail, calendar, files, settings — drive that local app or tool, and do NOT \
    open a website or web service for it (play music in the Music app, never YouTube \
    Music or a web player). Reach for the web only when the task is inherently web \
    (open a given URL, search the internet) or no local app can do it. When a request \
    maps to a kind of app rather than a named one (e.g. "play some coldplay" → a music \
    app), call app_skill for that app first and follow it: if it ships an action/play \
    script, run it with skill_run to actually do the task (start playback), picking a \
    sensible default for a vague request instead of just opening the app or asking \
    which item. To read or change \
    content inside a Mac app (a note, mail, a calendar event, a contact, the current \
    browser tab), drive it with AppleScript (`osascript -e 'tell application "App" to \
    …'`), NEVER an invented app URL scheme like `notes://` or `bear://` — those \
    silently fail on macOS; use `open` only to open files/URLs or launch an app. When \
    a task targets a specific app, call app_skill first unless you are just launching \
    it: the installed skill is the authority on how to operate that app and overrides \
    remembered schemes or shortcuts. For shell technique the built-in `system-tools` \
    skill is the authority (safe file-finding, settings); consult it when a command \
    errors — and note shell_exec runs under zsh, where a glob matching nothing aborts \
    with `no matches found`, which never means "no such files exist": widen the search \
    (e.g. `ls -t ~/Downloads | grep -iE '\\.png$|\\.jpg$' | head -1`) and avoid \
    parentheses, which trip the safety classifier. When a skill advertises a validated \
    script that covers the task, execute it with skill_run instead of reinventing the \
    steps. If the skill says the app needs vision, or scripting it fails, call \
    vision_control with the app and goal; a vision agent will operate the screen. For \
    multi-step work the fast tools can't finish, call agent_run with the goal; the \
    desktop agent reports to the user itself. To compose or transform text — build a \
    list or tracklist, write a summary, clean up a body, produce long content for a \
    note — use the llm.generate tool; for anything long, set its toFile=true and build \
    the note/document from the returned file so the content never has to fit in one \
    shell command. Don't refuse a big task as \"too long\" — generate to a file and \
    assemble it. Discover before guessing rather than \
    inventing names or values. Run a real feedback loop on EVERY task, whatever skill \
    it uses: read each tool's output, and when an approach fails or you can't confirm \
    it worked, ADJUST and try another — broaden the query, switch to AppleScript, or if \
    a step left the app in a partial state (e.g. search results on screen) call \
    vision_control to look and finish it; for multi-step work the fast tools can't \
    complete, call agent_run. Never repeat the same failing command, and only ask the \
    user once you have genuinely exhausted these paths. Low-risk reversible actions \
    (play, pause, open, search, draft) need no confirmation, but confirm first before \
    anything destructive, costly, or externally visible (sending, posting, purchasing, \
    deleting) that the user did not explicitly ask for. Always end your turn by telling the user the answer or \
    what you did, concretely and briefly — the result, not the steps — e.g. name the files you found, confirm the \
    app you opened. Never claim success you haven't confirmed: if the task didn't \
    finish, say what happened and the most likely reason.
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
          Resolve casual or incomplete phrasing into the likely concrete intent ("turn it down a
          little" → lower the volume; "the new Taylor album" → the latest Taylor Swift album).
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
        - executionPreference: "background" or "foreground". Choose "foreground" ONLY when the point of
          the request is for the user to watch or be shown the result on screen — e.g. "pull up…",
          "show me…", "open … so I can see it", "walk me through…", "how do I…", or any turn whose
          value is the user looking at the app. Choose "background" for everything else: the user wants
          the work done, not to watch it happen. When unsure, prefer "background".

        Return JSON only.
        """
    }

    // MARK: - Harness step planning (every step of the loop)

    /// At most this many world-model elements are described to the model
    /// (highest-signal first).
    public static let harnessStepMaxElements = 150

    /// The most recent steps rendered with their full one-line summaries; everything older is
    /// condensed to "tool → status" so the model never loses sight of its own earlier trajectory.
    public static let harnessStepMaxDetailedHistorySteps = 12

    public static func harnessStep(
        task: HarnessTaskState,
        descriptors: [HarnessToolDescriptor],
        appName: String,
        appGuidance: String?,
        understanding: HarnessRequestUnderstanding?,
        environmentSummary: String?,
        skillCatalog: String? = nil,
        retryNote: String? = nil,
        openWindows: [MacWindowTargetCandidate] = []
    ) -> String {
        let elementsBlock = harnessStepElementsBlock(task.worldModel.elements)
        let windowsBlock = harnessStepWindowsBlock(openWindows)

        // Follow-up instructions the user added after the task started are surfaced in their own block
        // below (right under the goal), so they are excluded from the generic facts dump here.
        let displayFacts = task.worldModel.facts
            .filter { $0.key != HarnessTaskCoordinator.additionalInstructionsFactKey }
        let factsBlock = displayFacts.isEmpty
            ? ""
            : "\nKnown state:\n" + displayFacts.sorted { $0.key < $1.key }
                .map { "  \($0.key) = \($0.value)" }.joined(separator: "\n") + "\n"

        let followUpInstructions = task.worldModel.facts[HarnessTaskCoordinator.additionalInstructionsFactKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let followUpBlock = followUpInstructions.isEmpty
            ? ""
            : "\nADDITIONAL INSTRUCTIONS FROM THE USER (sent after the task started — fold them into your "
                + "current work; do NOT restart from scratch or redo completed steps):\n"
                + String(followUpInstructions.prefix(800)) + "\n"

        let environmentBlock = (environmentSummary?.isEmpty == false)
            ? "\nENVIRONMENT (command-line tools on this Mac — only reach for what's installed):\n  \(environmentSummary!)\n"
            : ""

        let historyBlock = harnessStepHistoryBlock(task.toolHistory)

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

        // The full installed-skill catalog, so the planner can route to an authoritative playbook even
        // when the task has no GUI target app (e.g. playing music or saving a note by script): those
        // skills are not preloaded above because no specific app window is being driven.
        let skillCatalogBlock: String
        if let skillCatalog, !skillCatalog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            skillCatalogBlock = "\nINSTALLED APP SKILLS (authoritative playbooks for these apps/domains — when the task maps to one, get its full guide with app_skill and run its validated scripts with skill_run instead of improvising raw commands):\n\(skillCatalog)\n"
        } else {
            skillCatalogBlock = ""
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
        \(followUpBlock)\(understandingBlock)
        \(historyBlock)
        \(factsBlock)\(environmentBlock)\(guidanceBlock)\(skillCatalogBlock)\(windowsBlock)
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
          — then act on a specific element by passing its id from the list above in "input". The see/act
          tools focus the target app for you, so do NOT `open -a`/activate it first as a prerequisite —
          go straight to ax.observe. Re-issuing a focus/open step instead of advancing is a loop that
          burns the run.
        - The action you need may not be a visible button. Figure it out like a person would, using the
          general actions: RIGHT-CLICK an item (ax.click/vision.click button=right) to open its full
          context menu — that is where Delete / Remove / Rename / "…from Library" usually live; or
          select/open the item first and use its focused "⋯" / "More" / gear OVERFLOW menu; mouse.scroll
          to bring offscreen items or controls into view; use the menu bar; or select an item and press
          the matching key. After any of these, SEE again and read the
          WHOLE menu before clicking — a context menu, popup, or confirmation dialog is just more
          elements to observe, and the right entry is often a small labeled row near the bottom of a long
          menu. Don't conclude something is impossible until you've tried these; only report it
          unsupported if a skill says so or the paths are exhausted.
        - Operating a specific app — even by script (playing music, saving a note, sending mail)? If it
          appears in INSTALLED APP SKILLS above, consult that skill FIRST (app_skill) and run its
          validated scripts (skill_run) before hand-writing osascript: the skill is the authority and
          far more reliable than improvising commands. When a skill documents a known limitation
          (an element not scriptable, state that reports stale), believe it and take the path the
          skill prescribes — do not rediscover the limitation through repeated failed attempts. With
          no guide and no listed skill, use
          skill.search for a workflow. This is the most common way to avoid looping on a fragile command.
        - When a step fails, read the failure before retrying. A good retry changes exactly one
          thing: a better query, a different tool or layer, activating the app, a more specific
          element. Never re-run the same tool with the same input, and after one or two informed
          retries stop and report the blocker instead of trying a third variation.
        - Need a current fact you can't be sure of (an artist's latest album, today's news, a price, an
          address)? Use web.search to find it and web.fetch to read a result in full — don't guess and
          don't drive a browser GUI for this. Never write factual or creative material (a tracklist,
          lyrics, article text) from memory into a reply or tool input: it may be stale, and replies
          that reproduce such material verbatim get blocked by the model provider's content filter,
          which kills the step. To build a long note/document, generate it with llm.generate (or fetch
          it) using toFile=true, then assemble the note from the returned file — never refuse a task
          as "too long".
        - If the request is a question or chit-chat rather than an action, answer with
          conversation.respond (set input.response), then run.complete.
        - If a required detail is missing and you cannot safely proceed, use user.clarify
          (set input.question). Low-risk, reversible actions (play, open, search, draft, navigate)
          need no confirmation — just do them. But before an action that is destructive, costly,
          externally visible, or hard to undo (sending a message, posting, purchasing, deleting,
          sharing private data) and goes beyond what the user explicitly asked for, confirm with
          user.clarify first.
        - Once a state-changing action SUCCEEDS (a note created, a message sent, a file moved), do NOT
          do it again — repeating it, even with slightly different content, just makes duplicates.
          Verify the result and run.complete. Re-acting after success is the most common way to loop.
        - Verification must be evidence-backed: after acting, confirm the effect (a shell command's
          output/exit code, a re-observe, or state.verify) BEFORE choosing run.complete. A focused app
          is not evidence; only complete once the goal is confirmed by what you can see.
        - But do NOT re-verify what a tool already confirmed: a skill_run that returns a success status
          (e.g. status=played with what's now playing), or a shell command whose exit-0 output already
          shows the goal is met, IS your evidence — go straight to run.complete with that as the reason.
          Running a second tool just to re-check an already-confirmed result is how runs stall.
        - Anything said to the user (conversation.respond, run.complete reason) reports the result,
          not the process: what is now true ("Playing Yellow by Coldplay"), not the steps taken.
          Never fake completion — if the goal could not be reached, say plainly what happened and
          the most likely reason, with any caveat the user needs.
        Return JSON: {"tool": "<one tool name>", "input": {"key": "value", ...}, "narration": "<one warm sentence>"}. \
        ALWAYS include "input" with every required field for the chosen tool filled, exactly as its schema names them; use {} only for a tool that needs no input.
        "narration" is the one line the user reads for this step, shown live and saved to the conversation. \
        Write it in the first person, present or near tense, as if you were narrating your work to the person \
        watching — warm and plain, never robotic ("I'll start by reading the attached screenshots and finding \
        the relevant notch UI code.", "Let me check what's already on screen before I click.", "Found the file — \
        now I'll make the edit."). Say what you're doing this step and why in one breath. This narrates the \
        process; it is NOT the result. Reporting what is now true for the user is done only in conversation.respond \
        and run.complete, which still report the result, not the steps. Keep narration to one sentence; do not \
        restate the whole plan or repeat the previous step.\(retryNote.map { "\nIMPORTANT: \($0)" } ?? "")
        """
    }

    /// Renders the other windows currently on screen — across every app and display — so the planner
    /// knows what *else* exists in the world and can switch to or target a window that isn't in front.
    /// A request often lives in a window the user isn't looking at; the planner needs it to exist here
    /// before it can navigate to it. Bounds are global screen points (the same space tools act in).
    public static func harnessStepWindowsBlock(_ windows: [MacWindowTargetCandidate]) -> String {
        let onScreen = windows.filter { $0.isOnScreen && $0.bounds.width > 1 && $0.bounds.height > 1 }
        guard !onScreen.isEmpty else { return "" }
        let lines = onScreen.prefix(14).map { window -> String in
            let app = window.appName ?? "?"
            let title = (window.title?.isEmpty == false) ? " — \"\(window.title!)\"" : ""
            let front = window.isFrontmost ? " [frontmost]" : ""
            let bounds = window.bounds
            return "  - \(app)\(title)\(front) at \(Int(bounds.x)),\(Int(bounds.y)) \(Int(bounds.width))x\(Int(bounds.height))"
        }
        return "\nOPEN WINDOWS (every window on screen, any app or display — switch to or target one that isn't in front; widen vision.capture scope to screen or desktop to see a window off the active display):\n"
            + lines.joined(separator: "\n") + "\n"
    }

    /// Renders observed elements in reading order with the geometry and state the observation already
    /// captured — position (from `ax.frame.*` screen points or `vision.bbox.*` capture pixels), value,
    /// and click eligibility — so the model can reason spatially ("the field under the Subject label")
    /// instead of guessing from bare labels. Over the cap, clickable controls are kept first and the
    /// drop is announced rather than silent.
    public static func harnessStepElementsBlock(_ elements: [HarnessWorldElement]) -> String {
        guard !elements.isEmpty else {
            return "No on-screen elements have been observed. That is normal for system-tool tasks (shell_exec needs no observation). Only if the task needs the GUI, use a SEE tool (ax.observe or vision.capture) before acting on an element."
        }
        let ordered = readingOrder(elements)
        var kept = ordered
        var omitted = 0
        if ordered.count > harnessStepMaxElements {
            let clickable = ordered.filter(\.isActionEligible)
            let rest = ordered.filter { !$0.isActionEligible }
            kept = readingOrder(Array((clickable + rest).prefix(harnessStepMaxElements)))
            omitted = ordered.count - kept.count
        }
        let lines = kept.map(elementLine).joined(separator: "\n")
        let omittedLine = omitted > 0 ? "\n  (+\(omitted) more element(s) not shown; clickable controls were kept)" : ""
        return """
        Elements currently observed, in reading order (id: [role] "label" @(x,y wxh) — use the \
        positions to reason about layout: above/below/left/right):
        \(lines)\(omittedLine)
        """
    }

    private static func elementLine(_ element: HarnessWorldElement) -> String {
        var line = "  \(element.id): [\(element.role)] \"\(element.label)\""
        if let frame = frame(of: element) {
            line += " @(\(Int(frame.x)),\(Int(frame.y)) \(Int(frame.width))x\(Int(frame.height)))"
        }
        if let value = element.metadata["ax.value"], !value.isEmpty {
            line += " value=\"\(String(value.prefix(80)))\""
        }
        if !element.isActionEligible {
            line += " (not clickable)"
        }
        return line
    }

    private struct ElementFrame {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    /// Both observation producers stash geometry in element metadata: AX observations under
    /// `ax.frame.*` (screen points) and vision parses under `vision.bbox.*` (capture-image pixels).
    /// One observation always uses a single source, so positions stay mutually comparable.
    private static func frame(of element: HarnessWorldElement) -> ElementFrame? {
        for prefix in ["ax.frame", "vision.bbox"] {
            if let x = element.metadata["\(prefix).x"].flatMap(Double.init),
               let y = element.metadata["\(prefix).y"].flatMap(Double.init),
               let width = element.metadata["\(prefix).width"].flatMap(Double.init),
               let height = element.metadata["\(prefix).height"].flatMap(Double.init) {
                return ElementFrame(x: x, y: y, width: width, height: height)
            }
        }
        return nil
    }

    /// Top-to-bottom, then left-to-right; elements without geometry keep their original order at the end.
    private static func readingOrder(_ elements: [HarnessWorldElement]) -> [HarnessWorldElement] {
        elements.enumerated().sorted { lhs, rhs in
            switch (frame(of: lhs.element), frame(of: rhs.element)) {
            case let (left?, right?):
                return (left.y, left.x) < (right.y, right.x)
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// Detailed one-line summaries for the most recent steps, preceded by a condensed
    /// "tool → status" trail of everything older, so a long run never forgets where it has been.
    public static func harnessStepHistoryBlock(_ toolHistory: [HarnessToolCallRecord]) -> String {
        guard !toolHistory.isEmpty else { return "Nothing has been done yet." }
        let recent = Array(toolHistory.suffix(harnessStepMaxDetailedHistorySteps))
        let evicted = toolHistory.dropLast(recent.count)
        var lines: [String] = []
        if !evicted.isEmpty {
            let condensed = evicted.map { "\($0.call.name) → \($0.resultStatus.rawValue)" }
                .joined(separator: "; ")
            lines.append("  Earlier steps 1-\(evicted.count) (condensed): \(condensed)")
        }
        lines += recent.map { "  \($0.call.name): \($0.summary)" }
        return "Steps already taken (most recent last):\n" + lines.joined(separator: "\n")
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
