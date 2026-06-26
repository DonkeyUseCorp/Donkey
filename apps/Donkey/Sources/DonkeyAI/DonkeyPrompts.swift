import DonkeyContracts
import DonkeyHarness
import DonkeyRuntime
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
/// BEFORE ADDING ANYTHING HERE, PLACE IT BY SCOPE. Most model-facing text is NOT
/// cross-tool doctrine and belongs elsewhere — the planner still reads it, just from a
/// better home. The recurring mistake is dropping a single-tool fact into the prompt
/// because the prompt is the obvious place: it bloats every turn and drifts away from the
/// tool it describes.
///
/// - A fact about ONE tool — where it runs, when to prefer it, a parameter caveat, a
///   safety note → that tool's DESCRIPTOR (`DonkeyCommandLayer` for the fast command
///   tools, `BuiltInHarnessToolCatalog` for harness tools, the Live escalation
///   descriptors in `GeminiLiveVoiceController`). The planner reads descriptors in the
///   `AVAILABLE TOOLS` block, so the fact reaches the model co-located with its tool and
///   only when that tool is offered.
/// - A workflow for ONE app or domain — how to subtitle a video, fill a PDF form, drive
///   a specific app → its discoverable SKILL pack (`Resources/BuiltInSkills/<id>/SKILL.md`),
///   never a prompt.
/// - Only doctrine that holds across tools AND tasks — retry discipline, see-before-act,
///   shell-first — belongs in the prompt text here.
///
/// Narrow task adapters keep their own specialized prompts next to their parsing, not here:
/// `VisionActionPlanner`, `GeminiVertexVisionPlanner`, `DebugUIInspectionHostedAdapter`,
/// `HostedAppleScriptGenerationAdapter`, `HostedConversationFollowUpResolver`, and
/// `HostedLocalAppCatalogProfileGenerator`.
public enum DonkeyPrompts {
    // MARK: - Realtime command session

    /// Cross-tool policy only. Each tool's purpose, parameters, examples, and
    /// safety constraints live in its registered function declaration (see
    /// `CommandLayerFunctionDeclarations` / `DonkeyCommandLayer`), not here.
    public static let realtimeCommandSystemInstruction = """
    You are Donkey, a fast macOS assistant — an expert at the user's Mac. Conversation comes first: a \
    greeting ("hi", "hey"), thanks, small talk, or a question you can answer in words gets a plain reply \
    and no tool. There is no default action for "hi". Reach for the tools when the user wants something \
    DONE on the machine; then act directly with the registered tools, preferring shell_exec for whatever \
    the specific tools miss. Work locally first: for anything an installed Mac app or system tool handles \
    — music, notes, mail, calendar, files, settings — drive that local app or tool (play music in the \
    Music app, not YouTube Music or a web player). Use the web only for an inherently web task (open a \
    given URL, search the internet) or when no local app can do it. When a request names a KIND of app \
    rather than one app ("play some coldplay" → a music app), call app_skill for that app first and \
    follow it: run its action/play script with skill_run, picking a sensible default for a vague request \
    rather than just opening the app or asking which item. To read or change content inside a Mac app (a \
    note, mail, a calendar event, a contact, the current browser tab), drive it with AppleScript \
    (`osascript -e 'tell application "App" to …'`), and reserve `open` for opening files/URLs or \
    launching an app — invented URL schemes like `notes://` silently fail on macOS. When a task targets a \
    specific app, call app_skill first unless you are only launching it; the installed skill is the \
    authority and overrides remembered schemes or shortcuts. For shell technique the built-in \
    `system-tools` skill is the authority (safe file-finding, settings) — consult it when a command \
    errors. shell_exec runs under zsh, where a glob matching nothing aborts with `no matches found` (the \
    glob missed; the files may still exist): widen the search (e.g. \
    `ls -t ~/Downloads | grep -iE '\\.png$|\\.jpg$' | head -1`) and avoid parentheses, which trip the \
    safety classifier. When a skill advertises a validated script for the task, run it with skill_run \
    instead of reinventing the steps. If a skill says the app needs vision or scripting it fails, call \
    vision_control with the app and goal; for multi-step work the fast tools can't finish, call agent_run \
    with the goal — the desktop agent reports to the user itself. To compose or transform text (a list, a \
    tracklist, a summary, a cleaned-up body, long note content), use llm.generate; for anything long set \
    toFile=true and assemble the note from the returned file, so a big task always fits. Discover by \
    doing rather than inventing names or values. Run a real feedback loop on EVERY task: read each tool's \
    output, and when an approach fails or you can't confirm it, adjust and try another — broaden the \
    query, switch to AppleScript, or call vision_control to look and finish a step that left the app \
    partway (e.g. search results on screen). Repeating a failing command wastes the turn; after genuinely \
    exhausting these paths, ask the user. Low-risk reversible actions (play, pause, open, search, draft) \
    need no confirmation; confirm first before anything destructive, costly, or externally visible \
    (sending, posting, purchasing, deleting) that the user did not explicitly ask for. End every turn by \
    telling the user the result, concretely and briefly — what is now true, not the steps — e.g. name the \
    files you found, confirm the app you opened. Claim only success you have confirmed; if the task \
    didn't finish, say what happened and the most likely reason.
    """

    // MARK: - Request understanding (once per turn, before the loop)

    public static func requestUnderstanding(
        command: String,
        frontmostAppName: String,
        skillCatalog: String? = nil,
        attachments: [HarnessAttachmentInfo] = []
    ) -> String {
        let trimmedCatalog = skillCatalog?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let skillsBlock = trimmedCatalog.isEmpty
            ? ""
            : "\nSKILLS (each is an authoritative playbook for its domain; the one(s) you name in "
                + "relevantSkillIDs get loaded for the planner):\n\(trimmedCatalog)\n"
        let attachmentsBlock = attachments.isEmpty
            ? ""
            : "\nATTACHED FILES — the user attached these to THIS turn; the request is almost certainly "
                + "about them (\"this photo\", \"these\", \"it\"), so this is an \"act\" turn that operates "
                + "on these files (the planner reads/edits them at their paths):\n"
                + attachments.map { "- \($0.displayName) (\($0.contentType))" }.joined(separator: "\n") + "\n"
        return """
        You are the first step of a macOS agent. Read the user's request and return a precise, structured
        understanding of EXACTLY what they want. You do not act or choose tools here — a separate planner
        does that. Be broad in what you accept and specific in what you capture.

        The app currently in front of the user is "\(frontmostAppName)".

        USER REQUEST: \(command)
        \(attachmentsBlock)\(skillsBlock)
        Fill the fields:
        - turnKind: what this turn fundamentally is. Decide this FIRST and let it govern everything else:
          - "converse": a greeting ("hi", "hey", "yo"), thanks, acknowledgement, small talk, or a
            question you can answer in words alone — about you, your abilities, general knowledge, or the
            conversation so far — WITHOUT doing anything on the Mac. When in doubt between converse and
            act for a bare greeting or a "can you…"/"what is…" question, choose converse. A conversational
            turn must NEVER be turned into a task: do not invent a command, an app to open, or a thing to
            fetch. There is no default action for "hi".
          - "act": the user wants something actually DONE on the machine — open/launch/quit an app, play
            or control media, find or open files, read or change a setting, write or edit a file, operate
            an app, send/post something, run a command. Only this kind ever drives the Mac.
          - "clarify": actionable in spirit, but too ambiguous or missing a critical, user-owned detail to
            proceed safely (and you cannot reasonably pick a default). Used with needsClarification=true.
        - restatedGoal: for "act"/"clarify", one concrete imperative sentence capturing exactly what to
          accomplish. For "converse", a short restatement of what the user said or is asking — NOT an
          invented task. Never leave this empty.
          Resolve casual or incomplete phrasing into the likely concrete intent ("turn it down a
          little" → lower the volume; "the new Taylor album" → the latest Taylor Swift album).
        - targetAppName: the macOS app that must be driven through its GUI to do this. Set it only when
          the task genuinely needs a specific app's interface (e.g. composing a message in a mail app,
          editing in a design app). LEAVE IT EMPTY when an expert would use system tools instead — finding files,
          opening or quitting apps, reading or changing settings or state — and for pure conversation.
          If it clearly concerns the current app's UI, use "\(frontmostAppName)".
        - actionSurface: does this turn operate an app's interface, or produce a result with no app at all?
          - "guiApp": the work happens inside a macOS app's GUI — a named app, or the one in front
            ("\(frontmostAppName)"). Use this whenever the user is operating, editing, or controlling an app.
          - "appless": the deliverable is an artifact or a system change the agent produces with system,
            web, and generative tools — making an image, a chart, a PDF, or a file; fetching or
            researching something; reading or changing a setting. There is no app to drive; the result is
            the file, the answer, or the changed state. Choose this whenever the request is about the
            OUTCOME, not about working in some app — even if an app happens to be in front. When in doubt
            for an "act" turn whose point is a produced result rather than operating an app, prefer
            "appless". Always "appless" for an empty targetAppName that is a system-tool task; always
            "guiApp" when targetAppName is set. Irrelevant for "converse"/"clarify" — leave "guiApp".
        - parameters: the concrete details needed to do it (e.g. title, recipient, query, value), as
          string key/values. Omit what is not specified.
        - successCriteria: what would be visible on screen once the goal is done.
        - plan: for an "act" turn, a SHORT ordered list (usually 3–6 items) of the real steps to the
          deliverable — what an expert would actually do, end to end, INCLUDING the hard part. Name the
          decisive step explicitly so the planner aims at it instead of circling acquisition: e.g. filling
          an official form is "read the data → list the form's fields → MAP fields to the data and COMPUTE
          the derived values (the hard step) → write the filled file → verify", not just "open the form".
          One imperative phrase per step; mark the hard/decisive ones (a mapping, a calculation, a
          transform). Leave empty for a trivial one-step task and for "converse"/"clarify".
        - needsClarification: set true exactly when turnKind is "clarify" — the request is genuinely
          ambiguous or missing detail that you cannot reasonably resolve, or it is destructive without a
          clear target. Always false for "converse" and for an under-specified but low-risk, reversible
          "act" request (pick sensible specifics instead).
          Do NOT ask for a detail the request already implies (the request named the language, the
          source, or the file — use it), and do NOT ask the user to choose HOW to do the work or
          whether some resource exists; deciding the method and finding things out yourself is your
          job, not a question for the user.
        - clarifyingQuestion: the single question to ask when needsClarification is true; otherwise empty.
        - executionPreference: "background" or "foreground". Choose "foreground" ONLY when the point of
          the request is for the user to watch or be shown the result on screen — e.g. "pull up…",
          "show me…", "open … so I can see it", "walk me through…", "how do I…", or any turn whose
          value is the user looking at the app. Choose "background" for everything else: the user wants
          the work done, not to watch it happen. When unsure, prefer "background".
        - relevantSkillIDs: from the SKILLS list above, the ids of any skill whose playbook this task falls
          under (0, 1, or a few — match on each skill's description and keywords). Its full guide is loaded
          for the planner, so the right pick makes the work reliable and a wrong one wastes attention. Empty
          for conversation, a task no skill covers, or when no SKILLS list is shown.
        - conversationReply: ONLY when turnKind is "converse", write the actual reply to send the user here —
          the friendly, helpful thing you would say (a greeting back, the answer to their question, etc.),
          in a sentence or three. This is what they will read, so make it complete on its own. When the turn
          is "converse", output this field FIRST in the JSON so it can stream to the user immediately. Leave
          it empty for "act" and "clarify" — those are handled elsewhere.
        - suggestedFolderName: for "act" turns, suggest a beautiful, spelling-corrected, and user-friendly root folder name for this task by strictly following the authoritative naming rules in the "Creating and Naming Folders and Files" section of the "finder" skill (e.g. spelling corrected, space-separated words, and ending with a capitalized friendly word hash like "Cozy"). Empty/nil for "converse" and "clarify" turns.

        Return JSON only.
        """
    }

    // MARK: - Conversational reply (turnKind == .converse, no action loop)

    /// The responder for a conversational turn. It has NO tools and cannot touch the Mac — by
    /// construction, not by instruction — so this prompt is purely about voice and substance. A turn
    /// only reaches here once the understanding boundary typed it `.converse`; the action planner and
    /// every guarded tool are out of scope. Reply text streams straight into the notch.
    public static func conversationalResponse(
        command: String,
        frontmostAppName: String,
        conversationContext: String?
    ) -> String {
        let contextBlock: String
        if let conversationContext, !conversationContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contextBlock = "\nCONVERSATION SO FAR (most recent last):\n\(conversationContext)\n"
        } else {
            contextBlock = ""
        }
        return """
        You are a fast, friendly macOS assistant who answers in words and also operates the user's Mac \
        when asked. This turn is plain talk — a greeting, thanks, or a question you answer in words. You \
        have no tools this turn, so just talk: keep to words, not claimed actions or narrated steps.

        Reply in one short, warm, welcoming sentence. For a hello, greet back and offer to help — \
        something like "I'm here to help, what can I do for you?" Skip introductions, your name, your \
        features, and any mention of the notch, screen, or where you live. Answer a question directly; if \
        they're about to ask for a task, invite it. Plain, present-tense, first person.
        \(contextBlock)
        The app in front of them is "\(frontmostAppName)".

        USER: \(command)

        Reply with the message text only — no JSON, no quotes, no preamble.
        """
    }

    // MARK: - Harness step planning (every step of the loop)

    /// At most this many world-model elements are described to the model
    /// (highest-signal first).
    public static let harnessStepMaxElements = 150

    /// The most recent steps rendered with their full one-line summaries; everything older is
    /// condensed to "tool → status" so the model never loses sight of its own earlier trajectory.
    public static let harnessStepMaxDetailedHistorySteps = 12

    /// Per-step cap on a rendered summary in the history block. One huge output (a full `ls` of a busy
    /// folder, a long file read) must not dominate the trail and bury the small, relevant results around
    /// it — that buried a clip's `ffprobe` duration under a Downloads listing and the planner re-ran it
    /// until the run stalled. The planner can always re-read specifics; this only bounds the recap.
    public static let harnessStepSummaryMaxLength = 600

    /// The MOST RECENT step's result is the observation the planner acts on right now, so it is rendered
    /// at the full capture budget instead of the 600-char recap cap. Clipping the just-produced result
    /// below what the tool actually captured made a complete small read (e.g. a 1.2 KB text file read with
    /// `cat`) look truncated: the planner saw "…[truncated]", concluded it hadn't seen the whole file, and
    /// looped re-reading it (`cat | cat`, then `python3 …`) — every re-read re-clipped, so it never escaped.
    /// Matching the shell-output capture cap means a read that fit in the capture is shown in full; older
    /// results still collapse to `harnessStepSummaryMaxLength`.
    public static let harnessLatestResultMaxLength = 4_000

    /// Per-step cap on a single tool-input VALUE replayed in the history's assistant turns. A past decision
    /// is shown so the thread reads as the model's own prior choices, but its raw input is otherwise replayed
    /// in FULL on every step it stays in the detailed window — so one big value (a `files.write content`, a
    /// long `llm.generate` prompt) re-sends those tokens every step. Results are already capped this way;
    /// decisions were not. The agent only needs to recall WHAT it did, not re-read a verbatim copy it already
    /// acted on, so an oversized value is clipped to this length.
    public static let harnessDecisionValueMaxLength = 500

    /// Clip one oversized tool-input value for replay in the history's assistant turns. Short values pass
    /// through unchanged; an oversized one is cut to `harnessDecisionValueMaxLength` with a marker.
    public static func clippedDecisionInputValue(_ value: String) -> String {
        value.count > harnessDecisionValueMaxLength
            ? String(value.prefix(harnessDecisionValueMaxLength)) + "…[clipped]"
            : value
    }

    /// The marker appended when a tool result is shortened FOR THE PROMPT (context-window trimming), with
    /// the full size named. This is deliberately not the word "truncated": a bare "…[truncated]" reads
    /// identically whether the harness shortened its own view or the source DATA is partial, and a real run
    /// conflated the two — it saw the marker on a fully-captured 1.2 KB file, decided the file was partial,
    /// and re-read it (cat → python3) into a permission gate. Naming the cause and the full byte count, and
    /// stating that re-reading won't restore it, stops that category error. The full result stays in the
    /// run record; only this rendered view is shortened.
    public static func contextTrimNotice(fullCharacterCount count: Int) -> String {
        " …[context-trimmed for prompt; full output was \(count) chars and is already captured — "
            + "re-running the read will NOT lengthen this view]"
    }

    /// Distills a finished run into at most one durable, general operating lesson for the agent's future
    /// self. Fed the run's goal, terminal outcome, and full thread trace; returns strict JSON. The model
    /// is told to stay general (an operating rule, never task-specific facts or anything about this
    /// user's data) and to return an empty lesson when there is nothing worth carrying forward — most
    /// clean runs teach nothing new, so an empty result is the expected common case.
    public static func runLessonDistillation(goal: String, outcome: String, thread: String) -> String {
        """
        You are reviewing a finished run of a macOS agent to capture what it should LEARN for next time.
        Read the run and decide whether there is ONE durable, general operating lesson worth remembering —
        a rule about HOW to work (which tool to reach for, a trap to avoid, a faster path) that would help
        on FUTURE, different tasks.

        GOAL: \(goal)
        OUTCOME: \(outcome)

        A good lesson is:
        - General craft, reusable across tasks — NOT a fact about this specific task, file, app, or person.
        - Actionable and imperative, addressed to your future self ("When X, do Y, because Z").
        - Earned by what actually happened here: a mistake that cost time, or a move that clearly worked.

        Do NOT save: anything specific to this user, their files, their data, or this one request; secrets
        or personal data; a restatement of the goal; or generic advice this run did not actually teach. If
        the run went smoothly and taught nothing new, return an empty lesson — that is the common case.

        NEVER save a lesson about working around the harness's own guardrails. If the run hit an
        "already done / you already have this" guard, a stall/no-progress stop, or a permission gate, the
        lesson is NOT how to slip past it (perturbing the command, repeating to evade the check) — that is
        backwards and harmful. The guard means the run was looping or needed consent; the lesson, if any, is
        to advance, verify, or ask. Prefer an empty lesson; and if the only lesson you can draw would teach
        slipping past such a guard, set "unsafe": true so it is discarded.

        Return STRICT JSON and nothing else:
        {"lesson": "<one imperative sentence, or empty string if nothing is worth saving>", "cue": "<short phrase naming the kind of task this applies to>", "confidence": <0.0-1.0>, "unsafe": <true only if the lesson teaches defeating a harness guardrail, else false>}

        THREAD:
        \(thread)
        """
    }

    /// The STATIC half of the planning prompt — the system instructions sent once and cacheable. Doctrine,
    /// the goal, the parsed understanding, recalled lessons, the app/skill guides, the tool list, and the
    /// reply shape: none of it changes step to step within a turn. The per-step state (facts, windows,
    /// observed elements, follow-ups, the retry note) moves forward separately in `harnessTurnState`, and
    /// the run's history threads as real turns, so the request reads as a conversation that advances rather
    /// than one monolithic prompt re-sent every step.
    public static func harnessSystemInstructions(
        task: HarnessAgentState,
        descriptors: [HarnessToolDescriptor],
        appName: String,
        appGuidance: String?,
        understanding: HarnessRequestUnderstanding?,
        skillCatalog: String? = nil,
        preloadedSkillGuides: [String] = [],
        lessons: String? = nil
    ) -> String {
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

        // The full guides for the skills the understanding boundary judged relevant to THIS task, preloaded
        // so the planner has the authoritative playbook from step one — the capability-skill analogue of the
        // app guide above. These are the skills to FOLLOW; do not improvise their domain by hand.
        let preloadedGuides = preloadedSkillGuides
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let preloadedSkillsBlock = preloadedGuides.isEmpty
            ? ""
            : "\nRELEVANT SKILL GUIDES for this task (authoritative — follow these step by step instead of "
                + "improvising; they are the reason the task is reliable):\n"
                + preloadedGuides.joined(separator: "\n\n") + "\n"

        // The compact catalog of every other available skill, so the planner can reach one whose relevance
        // only becomes clear after it starts working (the task had no GUI target and was not preselected
        // above). Load a capability skill's full guide with skill.load (or app_skill for an app skill), and
        // run a validated workflow with skill_run, instead of improvising raw commands.
        let skillCatalogBlock: String
        if let skillCatalog, !skillCatalog.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            skillCatalogBlock = "\nOTHER AVAILABLE SKILLS (authoritative playbooks; if the task maps to one that is NOT already preloaded above, load its full guide with skill.load before improvising):\n\(skillCatalog)\n"
        } else {
            skillCatalogBlock = ""
        }

        // The command-line tools Donkey bundles and signs, sorted for a stable prompt. Sourced from the
        // single Swift list so it never drifts. Stated to the planner as guaranteed-present standalone
        // binaries so it invokes them by bare name instead of probing for them or reaching for a Python /
        // pip path — both of which trip the consent gate and never run the tool we actually ship.
        let bundledToolsList = BundledTools.executableNames.sorted().joined(separator: ", ")

        // Prefer the restated goal parsed once up front; fall back to the raw task goal when no
        // understanding was produced.
        let restatedGoal = understanding?.restatedGoal
        let goalText = (restatedGoal?.isEmpty == false ? restatedGoal : nil) ?? task.goal
        let understandingBlock = self.understandingBlock(understanding)

        // Durable operating lessons recalled from earlier runs with a related goal. Placed high, right
        // under the goal, so a known trap (e.g. a search that times out) steers the very first step
        // instead of being re-discovered the hard way. Empty when nothing relevant was learned before.
        let trimmedLessons = lessons?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lessonsBlock = trimmedLessons.isEmpty
            ? ""
            : "\nLESSONS FROM PAST RUNS (hard-won operating knowledge from earlier tasks — apply when "
                + "relevant; they reflect what worked or failed before):\n\(trimmedLessons)\n"

        // GUI-operation craft only earns its place when the turn actually drives an app's interface. The
        // understanding boundary types that as actionSurface, so on an appless turn (the deliverable is a
        // file, answer, or system change) the full cluster below is dead weight on every cached step.
        // Collapse it to a one-line fallback pointer there; the elements block still names the SEE tools if
        // a step unexpectedly needs the GUI. guiApp — and the safe default when no understanding was
        // produced — gets the full craft.
        let drivesGUI = understanding?.actionSurface != .appless
        let guiOperationGuidance = drivesGUI ? """
        - Operate the GUI only when the task genuinely needs it (canvas/Electron/proprietary UI, or no
          system-tool equivalent). SEE before you act: prefer ax.observe (fast, structured) for native
          apps, vision.capture when Accessibility is thin, then act on a specific element by passing its
          id from the list above in "input". The see/act tools focus the target app for you, so go
          straight to ax.observe — re-issuing a focus/open step is a loop that burns the run.
        - The action you need may be hidden, not a visible button. Work it out like a person: RIGHT-CLICK
          an item (ax.click/vision.click button=right) for its context menu, where Delete / Remove /
          Rename / "…from Library" usually live; open the item's focused "⋯" / "More" / gear OVERFLOW
          menu; mouse.scroll to bring offscreen controls into view; use the menu bar; or select an item
          and press the matching key. After any of these, SEE again and read the WHOLE menu before
          clicking — the right entry is often a small labeled row near the bottom of a long menu. Try
          these paths before reporting something unsupported (a skill saying so settles it).
        """ : """
        - This turn's deliverable is a file, answer, or system change, not an app's UI — stay in system,
          web, and generative tools. When a step genuinely needs the GUI, SEE first (ax.observe, or
          vision.capture when Accessibility is thin) and act on an element by its id.
        """

        return """
        You are an expert macOS power user. Choose ONE tool to run next, then you will see the result
        and choose again. Work toward the goal in small, verifiable steps. Many tasks are solved
        entirely with system tools and have no on-screen UI target; reach for the GUI only when the task
        truly needs it.
        GOAL: \(goalText)
        \(understandingBlock)\(lessonsBlock)\(guidanceBlock)\(preloadedSkillsBlock)\(skillCatalogBlock)

        AVAILABLE TOOLS:
        \(toolsBlock)

        Guidance:
        - Solve it like an expert at the terminal. Prefer shell_exec with system tools to find files
          (mdfind, ls -t, find), launch or quit apps (open -a, osascript), read state (date, pmset -g
          batt, system_profiler, defaults read), and change settings (defaults write, networksetup).
          Read-only commands run instantly; state-changing ones prompt for one-time or always-allow
          consent, so propose them freely.
        - Donkey ships these tools on PATH as standalone binaries — invoke the one you need by its BARE
          NAME: \(bundledToolsList). Use it directly (e.g. `yt-dlp 'URL'`, then `ffmpeg -i in.mp4 …`),
          rather than via `python3 -m` or `pip`, and skip any `which`/`--version`/existence check.
          Single-quote any URL. A download, transcode, or network call can run long, so pass a generous
          `timeoutSeconds` (up to 120) or it is killed mid-run.
        - Discover the rest by DOING: run the command by bare name. On `command not found`, adapt —
          reach for another tool, or report what's missing when the task needs that exact one. A missing
          tool is reported; leave package managers (pip, brew, npm) alone.
        \(guiOperationGuidance)
        - Operating a specific app, even by script (playing music, saving a note, sending mail)? When it
          appears in the skills above, consult that skill FIRST (app_skill) and run its validated
          scripts (skill_run) before hand-writing osascript — the skill is the authority and far more
          reliable. Believe a skill's documented limitation (an element not scriptable, state that
          reports stale) and take the path it prescribes. With no guide and no listed skill, use
          skill.search. This is the surest way past a fragile command.
        - When a step fails, read the failure, then change exactly one thing on retry: a better query, a
          different tool or layer, activating the app, a more specific element (the same tool with the
          same input just repeats the failure). After one or two informed retries, report the blocker.
        - An "already done / you already have this result" reply is a LOOP signal: the output is in your
          context — read it and take the NEXT action. A "[context-trimmed; full output already captured]"
          marker means the same — your view was shortened, the data is whole — so proceed with what you
          have. Perturbing the command to slip past either guard turns a finished read into a permission
          gate.
        - Need a current fact you can't be sure of (latest album, today's news, a price, an address)?
          web.search to find it, web.fetch to read a result in full (skip the browser GUI). Pull factual
          or creative material (a tracklist, lyrics, article text) from web.fetch or llm.generate, since
          memory goes stale and verbatim reproductions get blocked by the provider's content filter. For
          a long note/document, generate with llm.generate toFile=true and assemble from the returned
          file — a big task always fits this way.
        - The `workspace` line under Known state names your working directory (full path shown), and your
          shell runs there. Tools and reads may use bare names (`out.pdf`) — they land in it. Your file
          moves/copies/makes/removes (mv, cp, mkdir, rm, chmod) run without asking ONLY inside this folder,
          written in full: `mv "<workspace>/a.pdf" "<workspace>/done/a.pdf"`. The same command aimed at a
          file anywhere else asks the user first — that is expected, so do it when the task needs it. Reads
          are always free. Pull inputs with `cp "<abs input>" "<workspace>/"` and reuse this folder on
          follow-ups (`ls` to reconcile).
        - Never overwrite an existing user file unless the user explicitly asked ("save it back", "in
          place", "replace it"). Otherwise write a new copy or alternate version (`<name>-filled.pdf`,
          `<name>-v2.png`) and leave the original untouched.
        - The `workspace.files` line already shows the contents of the small files in that folder; act
          on them directly.
        - A question or chit-chat turn: answer with conversation.respond (set input.response), then
          run.complete.
        - Missing a required, user-owned detail (which of two accounts, which named file)? Ask with
          user.clarify (set input.question). Decide the method, the format, and whether a resource
          exists yourself, and use any target/source/language the request already names. Low-risk
          reversible actions (play, open, search, draft, navigate) just run. Confirm with user.clarify
          first before an action that is destructive, costly, externally visible, or hard to undo
          (sending, posting, purchasing, deleting, sharing private data) and goes beyond what the user
          asked.
        - Once a state-changing action SUCCEEDS (a note created, a message sent, a file moved), verify
          and run.complete; repeating it just makes duplicates. Re-acting after success is the most
          common way to loop.
        - Verification is evidence-backed: after acting, confirm the effect (a command's output/exit
          code, a re-observe, or state.verify) before run.complete — a focused app is not evidence. When
          a tool already confirmed the result (a skill_run success status, an exit-0 output showing the
          goal met), that IS your evidence — go straight to run.complete. A second check of an
          already-confirmed result just stalls.
        - Anything said to the user (conversation.respond, run.complete reason) reports the result, not
          the process: what is now true ("Playing Yellow by Coldplay"). If the goal was missed, say
          plainly what happened and the most likely reason.
        Return JSON: {"tool": "<one tool name>", "input": {"key": "value", ...}, "narration": "<one warm sentence>"}. \
        Always include "input" with every required field filled exactly as the tool's schema names them; use {} only for a tool that needs none. \
        "narration" is the single first-person line the user reads live for this step — warm and plain, present tense, saying what you're doing and why in one breath ("Found the file — now I'll make the edit."). \
        It narrates the process; the result goes only in conversation.respond and run.complete. Keep it to one sentence and don't restate the plan.
        """
    }

    /// The DYNAMIC half of the planning prompt — the FINAL user turn in the threaded request. Everything
    /// here can change between steps: follow-up instructions the user added mid-run, the rolling
    /// conversation summary, the known facts, the windows on screen, the freshly observed elements, and the
    /// per-attempt retry note. The static doctrine/goal/tools live in `harnessSystemInstructions`; only this
    /// turn-state advances each step, alongside the run's history threaded as real turns.
    public static func harnessTurnState(
        task: HarnessAgentState,
        openWindows: [MacWindowTargetCandidate] = [],
        rollingContext: String? = nil,
        retryNote: String? = nil
    ) -> String {
        let elementsBlock = harnessStepElementsBlock(task.worldModel.elements)
        let windowsBlock = harnessStepWindowsBlock(openWindows)

        // Follow-up instructions the user added after the task started get their own block below, and the
        // machine-readable workspace base dir is executor-only — both are hidden from this generic facts
        // dump centrally via `modelFacingFacts`.
        let displayFacts = task.worldModel.modelFacingFacts
        let factsBlock = displayFacts.isEmpty
            ? ""
            : "\nKnown state:\n" + displayFacts.sorted { $0.key < $1.key }
                .map { "  \($0.key) = \($0.value)" }.joined(separator: "\n") + "\n"

        let followUpInstructions = task.worldModel.facts[HarnessAgentCoordinator.additionalInstructionsFactKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let followUpBlock = followUpInstructions.isEmpty
            ? ""
            : "\nADDITIONAL INSTRUCTIONS FROM THE USER (sent after the task started — fold them into your "
                + "current work; do NOT restart from scratch or redo completed steps):\n"
                + String(followUpInstructions.prefix(800)) + "\n"

        // Cross-turn conversation memory: recent events plus a rolling summary of older turns. Distinct
        // from the step turns — that is what THIS run did; this is what the whole conversation is about,
        // including compacted earlier turns. The full record is on disk.
        let trimmedRollingContext = rollingContext?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rollingContextBlock = trimmedRollingContext.isEmpty
            ? ""
            : "\nCONVERSATION SO FAR (rolling summary of older turns + recent events; the full record is "
                + "on disk):\n\(trimmedRollingContext)\n"

        return """
        \(followUpBlock)\(rollingContextBlock)\(factsBlock)\(windowsBlock)
        \(elementsBlock)

        Choose the single next tool now, given the state above and the steps already taken. Reply with \
        exactly one JSON object in the shape specified.\(retryNote.map { "\nIMPORTANT: \($0)" } ?? "")
        """
    }

    /// One-document rendering of the whole planning prompt — system instructions, the history trail, and
    /// the current turn state, concatenated. The planner sends the SPLIT form (cached instructions + a
    /// threaded conversation); this single-string wrapper backs the prompt-contains tests and any caller
    /// that wants the entire prompt as one value.
    public static func harnessStep(
        task: HarnessAgentState,
        descriptors: [HarnessToolDescriptor],
        appName: String,
        appGuidance: String?,
        understanding: HarnessRequestUnderstanding?,
        skillCatalog: String? = nil,
        preloadedSkillGuides: [String] = [],
        lessons: String? = nil,
        rollingContext: String? = nil,
        retryNote: String? = nil,
        openWindows: [MacWindowTargetCandidate] = []
    ) -> String {
        harnessSystemInstructions(
            task: task, descriptors: descriptors, appName: appName, appGuidance: appGuidance,
            understanding: understanding, skillCatalog: skillCatalog,
            preloadedSkillGuides: preloadedSkillGuides, lessons: lessons
        )
        + "\n\n" + harnessStepHistoryBlock(task.toolHistory) + "\n"
        + harnessTurnState(task: task, openWindows: openWindows, rollingContext: rollingContext, retryNote: retryNote)
    }

    /// The condensed "tool → status" trail for steps older than the detailed window, as one line. Threaded
    /// into the planning conversation as a single preamble turn so a long run keeps sight of where it has
    /// been even though only the most recent steps are sent as full turns.
    public static func harnessStepCondensedHistoryLine(_ evicted: [HarnessToolCallRecord]) -> String {
        let condensed = evicted.map { "\($0.call.name) → \($0.resultStatus.rawValue)" }.joined(separator: "; ")
        return "Earlier steps 1-\(evicted.count) (condensed): \(condensed)"
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
        lines += recent.enumerated().map { index, record in
            // The last recent record is the result the planner is acting on this step — show it in full
            // so a complete small read never reads as truncated and sends the planner re-reading in a loop.
            let cap = index == recent.count - 1 ? harnessLatestResultMaxLength : harnessStepSummaryMaxLength
            let summary = record.summary.count > cap
                ? String(record.summary.prefix(cap)) + contextTrimNotice(fullCharacterCount: record.summary.count)
                : record.summary
            return "  \(record.call.name): \(summary)"
        }
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
        if !understanding.plan.isEmpty {
            // The up-front plan, shown every step so the planner works toward the decisive step instead of
            // re-deriving the task shape and circling acquisition. Advisory — the planner still picks each
            // tool — but it is the agreed route; don't get stuck on step 1 when the point is step 3.
            let steps = understanding.plan.enumerated()
                .map { "    \($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            lines.append("  Plan (the route to the deliverable — aim at the decisive step, don't circle the easy ones):\n\(steps)")
        }
        guard !lines.isEmpty else { return "" }
        return "WHAT THE USER WANTS:\n" + lines.joined(separator: "\n") + "\n"
    }
}
