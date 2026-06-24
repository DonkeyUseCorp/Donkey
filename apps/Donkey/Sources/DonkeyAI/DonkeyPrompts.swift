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
/// `VisionActionPlanner`, `GeminiVertexVisionBoxPlanner`, `DebugUIInspectionHostedAdapter`,
/// `HostedAppleScriptGenerationAdapter`, `HostedConversationFollowUpResolver`, and
/// `HostedLocalAppCatalogProfileGenerator`.
public enum DonkeyPrompts {
    // MARK: - Realtime command session

    /// Cross-tool policy only. Each tool's purpose, parameters, examples, and
    /// safety constraints live in its registered function declaration (see
    /// `CommandLayerFunctionDeclarations` / `DonkeyCommandLayer`), not here.
    public static let realtimeCommandSystemInstruction = """
    You are Donkey, a fast macOS assistant — an expert computer user sitting next \
    to the user. Conversation comes first: if the user is greeting you ("hi", "hey"), \
    thanking you, making small talk, or asking something you can answer in words alone, \
    just reply — do NOT call any tool, and never invent a task they didn't ask for (there \
    is no default action for "hi"). Reach for the tools only when the user actually wants \
    something DONE on the machine. When they do, act directly and immediately with the \
    registered tools, preferring \
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

    public static func requestUnderstanding(
        command: String,
        frontmostAppName: String,
        skillCatalog: String? = nil
    ) -> String {
        let trimmedCatalog = skillCatalog?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let skillsBlock = trimmedCatalog.isEmpty
            ? ""
            : "\nSKILLS (each is an authoritative playbook for its domain; the one(s) you name in "
                + "relevantSkillIDs get loaded for the planner):\n\(trimmedCatalog)\n"
        return """
        You are the first step of a macOS agent. Read the user's request and return a precise, structured
        understanding of EXACTLY what they want. You do not act or choose tools here — a separate planner
        does that. Be broad in what you accept and specific in what you capture.

        The app currently in front of the user is "\(frontmostAppName)".

        USER REQUEST: \(command)
        \(skillsBlock)
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
        You are a fast, friendly macOS assistant who can answer in words and also operate the \
        user's Mac when asked. This turn is plain conversation — a greeting, a thanks, or a question you \
        answer in words. You are NOT doing anything on the computer right now, so do not claim to open, \
        play, run, search, or change anything, and do not narrate steps; just talk.

        Reply in one short, warm sentence. Be natural and welcoming. If the user is just saying hello, \
        greet them back and offer to help — something simple like "I'm here to help, what can I do for \
        you?" Do not introduce yourself, do not state your name, and never mention the notch, the screen, \
        or where you live. Do not list your features. If they asked a question you can answer, answer it \
        directly. If they're clearly about to ask for a task, invite it. Never invent a task they didn't \
        ask for. Plain, present-tense, first person.
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

        Return STRICT JSON and nothing else:
        {"lesson": "<one imperative sentence, or empty string if nothing is worth saving>", "cue": "<short phrase naming the kind of task this applies to>", "confidence": <0.0-1.0>}

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
        - Solve it the way an expert terminal user would. Prefer shell_exec with system tools to find
          files (mdfind, ls -t, find), launch or quit apps (open -a, osascript), read state (date,
          pmset -g batt, system_profiler, defaults read), and change settings (defaults write,
          networksetup). Read-only commands run instantly; state-changing ones ask the user for
          one-time or always-allow consent, so propose them freely rather than avoiding them.
        - Donkey ships these command-line tools and guarantees them on PATH as standalone binaries —
          run the one you need by its BARE NAME and nothing else: \(bundledToolsList). They are not
          Python packages and not optional: never invoke one through `python3 -m …` or `pip`, never
          run `which`/`--version`/any check to confirm it exists, and never probe first — just use it
          directly (e.g. `yt-dlp -P ~/Downloads 'URL'`, then `ffmpeg -i in.mp4 …`). Single-quote any URL.
          A download, transcode, or network call can run far past the default timeout, so pass a generous
          `timeoutSeconds` (up to 120) on the shell_exec call or it is killed mid-run.
        - Discover what ELSE is available by DOING, not by guessing or pre-checking. Run the command you
          need by bare name; don't probe whether a tool exists first. If it fails with `command not
          found`, adapt: reach for another tool that does the job, or — if the task genuinely needs
          that one — report what's missing. Never install software or use a package manager (pip,
          brew, npm, etc.); a missing tool is reported, not fetched.
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
          (set input.question). Clarify only a genuinely missing, user-owned detail (which of two
          accounts, which named file). Never ask the user to choose HOW to accomplish something, to
          pick an intermediate format, or to confirm whether a resource exists — decide the method and
          find out yourself. If the request already names the target, source, or language, use it
          rather than asking again. Low-risk, reversible actions (play, open, search, draft, navigate)
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
        restate the whole plan or repeat the previous step.
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

        // Follow-up instructions the user added after the task started get their own block so they are
        // excluded from the generic facts dump.
        let displayFacts = task.worldModel.facts
            .filter { $0.key != HarnessAgentCoordinator.additionalInstructionsFactKey }
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
        lines += recent.map { record in
            let summary = record.summary.count > harnessStepSummaryMaxLength
                ? String(record.summary.prefix(harnessStepSummaryMaxLength)) + " …[truncated]"
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
        guard !lines.isEmpty else { return "" }
        return "WHAT THE USER WANTS:\n" + lines.joined(separator: "\n") + "\n"
    }
}
