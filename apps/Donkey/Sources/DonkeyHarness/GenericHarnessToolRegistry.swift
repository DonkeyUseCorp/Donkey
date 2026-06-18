import Foundation

public struct HarnessToolDescriptor: Codable, Equatable, Sendable {
    /// Descriptor metadata key a tool sets to "true" when its successful result is itself
    /// verification evidence (e.g. a shell command returning output and exit code). The runtime's
    /// completion gate accepts such a step as the post-action check; other state-changing tools
    /// need a later read-only observation before `run.complete` is accepted.
    public static let resultIsEvidenceMetadataKey = "resultIsEvidence"

    /// Descriptor metadata key for a multi-action tool (one whose `action` input selects the
    /// operation) naming, comma-separated, the `action` values that are pure reads. The runtime's
    /// duplicate-action guard exempts those calls: re-listing or re-reading is legitimate
    /// verification even when the tool's overall safety class is state-changing, and the guard
    /// must never block the re-read its own rejection message asks for.
    public static let readOnlyActionsMetadataKey = "readOnlyActions"

    public var name: String
    public var pluginID: String
    public var summary: String
    public var inputSchema: [String: String]
    /// Input keys that are optional. Anything in `inputSchema` not listed here is
    /// treated as required. Declared structurally rather than inferred from the
    /// human-readable description text. (Property default keeps Codable decoding
    /// of older payloads that lack the key tolerant.)
    public var optionalInputKeys: [String] = []
    public var outputSchema: [String: String]
    public var requiredPermissions: [HarnessPermission]
    public var safetyClass: HarnessToolSafetyClass
    public var requiredContext: [String]
    public var verificationHints: [String]
    public var metadata: [String: String]

    public init(
        name: String,
        pluginID: String,
        summary: String,
        inputSchema: [String: String] = [:],
        optionalInputKeys: [String] = [],
        outputSchema: [String: String] = [:],
        requiredPermissions: [HarnessPermission] = [],
        safetyClass: HarnessToolSafetyClass,
        requiredContext: [String] = [],
        verificationHints: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.name = name
        self.pluginID = pluginID
        self.summary = summary
        self.inputSchema = inputSchema
        self.optionalInputKeys = optionalInputKeys
        self.outputSchema = outputSchema
        self.requiredPermissions = requiredPermissions
        self.safetyClass = safetyClass
        self.requiredContext = requiredContext
        self.verificationHints = verificationHints
        self.metadata = metadata
    }
}

public struct HarnessToolExecutionContext: Sendable {
    public var taskID: String
    public var call: HarnessToolCall
    public var descriptor: HarnessToolDescriptor
    public var worldModel: HarnessWorldModel
    public var grantedPermissions: Set<HarnessPermission>

    public init(
        taskID: String,
        call: HarnessToolCall,
        descriptor: HarnessToolDescriptor,
        worldModel: HarnessWorldModel,
        grantedPermissions: Set<HarnessPermission>
    ) {
        self.taskID = taskID
        self.call = call
        self.descriptor = descriptor
        self.worldModel = worldModel
        self.grantedPermissions = grantedPermissions
    }
}

public typealias HarnessToolExecutor = @Sendable (HarnessToolExecutionContext) async -> HarnessToolResult

public struct HarnessTool: Sendable {
    public var descriptor: HarnessToolDescriptor
    public var execute: HarnessToolExecutor

    public init(
        descriptor: HarnessToolDescriptor,
        execute: @escaping HarnessToolExecutor
    ) {
        self.descriptor = descriptor
        self.execute = execute
    }
}

public actor HarnessToolRegistry {
    private var toolsByName: [String: HarnessTool]

    public init(tools: [HarnessTool] = []) {
        self.toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.descriptor.name, $0) })
    }

    public func register(_ tool: HarnessTool) {
        toolsByName[tool.descriptor.name] = tool
    }

    public func descriptor(named name: String) -> HarnessToolDescriptor? {
        toolsByName[name]?.descriptor
    }

    public func descriptors() -> [HarnessToolDescriptor] {
        toolsByName.values
            .map(\.descriptor)
            .sorted { $0.name < $1.name }
    }

    public func execute(
        _ call: HarnessToolCall,
        taskID: String,
        worldModel: HarnessWorldModel,
        grantedPermissions: Set<HarnessPermission>
    ) async -> HarnessToolResult {
        guard let tool = toolsByName[call.name] else {
            return HarnessToolResult(
                callID: call.id,
                toolName: call.name,
                status: .unknownTool,
                summary: "Unknown harness tool: \(call.name)",
                metadata: ["reason": "unknownTool"]
            )
        }

        let missingPermissions = tool.descriptor.requiredPermissions.filter {
            !grantedPermissions.contains($0)
        }
        guard missingPermissions.isEmpty else {
            return HarnessToolResult(
                callID: call.id,
                toolName: call.name,
                status: .permissionDenied,
                summary: "Tool requires permission before it can run.",
                missingPermissions: missingPermissions,
                metadata: [
                    "reason": "missingPermission",
                    "requiredPermissions": missingPermissions.map(\.rawValue).joined(separator: ",")
                ]
            )
        }

        return await tool.execute(
            HarnessToolExecutionContext(
                taskID: taskID,
                call: call,
                descriptor: tool.descriptor,
                worldModel: worldModel,
                grantedPermissions: grantedPermissions
            )
        )
    }
}

public enum BuiltInHarnessToolCatalog {
    public static var descriptors: [HarnessToolDescriptor] {
        [
            descriptor(
                "conversation.respond",
                pluginID: "core.conversation",
                summary: "Answer the user or chat when the request needs a reply rather than an action. Set 'response' to the message.",
                input: ["response": "The message to say to the user."],
                permissions: [.conversation],
                safety: .readOnly
            ),
            descriptor(
                "user.clarify",
                pluginID: "core.user",
                summary: "Ask the user a specific missing question and stop the task until the answer arrives.",
                input: ["question": "Specific question to ask the user."],
                permissions: [.userPrompt],
                safety: .readOnly
            ),
            descriptor(
                "permission.request",
                pluginID: "core.permission",
                summary: "Ask for a missing runtime permission and stop the task until approval arrives.",
                input: ["permission": "Permission name requested by the tool or plan."],
                permissions: [.userPrompt],
                safety: .readOnly
            ),
            descriptor(
                "memory.retrieve",
                pluginID: "core.memory",
                summary: "Retrieve task-relevant memory after intent is structured.",
                input: ["query": "Structured memory query or target scope."],
                output: ["memory": "Bounded memory snippets."],
                permissions: [.memory],
                safety: .readOnly
            ),
            descriptor(
                "skill.search",
                pluginID: "core.skills",
                summary: "Search registered and discovered skills by structured task need before planning tool use.",
                input: ["query": "Structured skill need, target domain, or capability."],
                output: ["skills": "Ranked skill descriptors with instruction paths and provided tools."],
                permissions: [.skillLookup],
                safety: .readOnly,
                verification: ["planner receives only skill descriptors until a skill is explicitly loaded"]
            ),
            descriptor(
                "skill.load",
                pluginID: "core.skills",
                summary: "Load the selected skill instructions into bounded planning context.",
                input: ["skillID": "Registered skill identifier."],
                output: ["instructions": "Bounded skill instruction excerpt and metadata."],
                permissions: [.skillLookup],
                safety: .readOnly,
                requiredContext: ["registered skill descriptor"]
            ),
            descriptor(
                "skill.script.generate",
                pluginID: "core.skills",
                summary: "Ask a model boundary to generate a reusable script artifact inside a skill pack.",
                input: [
                    "skillID": "Skill pack that should own the generated script.",
                    "language": "Script language such as AppleScript, shell, JavaScript, Python, or Swift.",
                    "purpose": "Reusable task capability the script should provide.",
                    "constraints": "Allowed actions, inputs, outputs, and safety boundaries.",
                    "verification": "How future agents should verify the script worked."
                ],
                output: [
                    "scriptID": "Registered skill script identifier.",
                    "relativePath": "Skill-relative script path.",
                    "scriptSource": "Generated script source for validation/review."
                ],
                permissions: [.skillLookup],
                safety: .sensitive,
                requiredContext: ["loaded skill descriptor", "structured task capability", "model generation boundary"],
                verification: ["script artifact is stored as pendingValidation and is not executable yet"],
                metadata: [
                    "modelBoundary": "required",
                    "directExecution": "false"
                ]
            ),
            descriptor(
                "skill.script.validate",
                pluginID: "core.skills",
                summary: "Validate or reject a generated skill script before any execution path may use it.",
                input: [
                    "skillID": "Skill pack that owns the script.",
                    "scriptID": "Generated script identifier.",
                    "validationPolicy": "Static checks, allowed APIs, target app, permissions, and review state."
                ],
                output: ["validationStatus": "validated or rejected with reason."],
                permissions: [.skillLookup],
                safety: .readOnly,
                requiredContext: ["generated script artifact", "validation policy"],
                verification: ["validated scripts record provenance and policy metadata"]
            ),
            descriptor(
                "skill.script.execute",
                pluginID: "core.skills",
                summary: "Execute a validated script from a loaded skill through the appropriate guarded backend.",
                input: [
                    "skillID": "Skill pack that owns the script.",
                    "scriptID": "Validated script identifier.",
                    "input": "Structured script input."
                ],
                output: ["result": "Execution trace and structured observations."],
                permissions: [.appControl, .input],
                safety: .guardedInput,
                requiredContext: ["loaded skill descriptor", "validated script descriptor", "permission gate"],
                verification: ["post-execution verifier confirms expected outcome"],
                metadata: [
                    "requiresValidatedScript": "true",
                    "directModelScriptExecution": "false"
                ]
            ),
            descriptor(
                "screen.observe",
                pluginID: "core.computer-use",
                summary: "Observe current screen/window state with bounded Accessibility and screenshot evidence.",
                output: ["worldModel": "Visible text, window facts, and evidence metadata."],
                permissions: [.screenCapture],
                safety: .readOnly
            ),
            descriptor(
                "elements.get",
                pluginID: "core.computer-use",
                summary: "Return visible UI elements, preferring Accessibility-backed actionable elements.",
                input: ["scope": "Target app/window or visible screen scope."],
                output: ["elements": "Element IDs, labels, roles, actions, and eligibility."],
                permissions: [.accessibility],
                safety: .readOnly
            ),
            descriptor(
                "element.perform",
                pluginID: "core.computer-use",
                summary: "Perform a guarded action on an Accessibility-backed element.",
                input: [
                    "elementID": "Stable element ID from elements.get.",
                    "action": "Press, setValue, focus, scroll, or equivalent guarded action."
                ],
                output: ["result": "Action trace and post-action observations."],
                permissions: [.accessibility, .input],
                safety: .guardedInput,
                requiredContext: ["focused target", "action-eligible element"],
                verification: ["post-action observation confirms expected state"]
            ),
            descriptor(
                "text.enter",
                pluginID: "core.computer-use",
                summary: "Enter exact text into the currently focused or resolved text element.",
                input: ["text": "Exact text to enter."],
                permissions: [.input],
                safety: .guardedInput,
                requiredContext: ["focused text field or explicit element ID"]
            ),
            descriptor(
                "keyboard.press",
                pluginID: "core.computer-use",
                summary: "Press a validated keyboard key or shortcut.",
                input: ["key": "Key or shortcut to press."],
                permissions: [.input],
                safety: .guardedInput,
                requiredContext: ["focused target"]
            ),
            descriptor(
                "agent.path.visualize",
                pluginID: "core.agent-path",
                summary: "Prepare a visual-only pointer path from grounded harness evidence without performing input.",
                input: [
                    "stepsJSON": "JSON array of AgentPathStep values with grounded normalizedTarget point or bounds.",
                    "title": "Short label for the visual path.",
                    "sourceTraceID": "Trace id that produced the path."
                ],
                output: [
                    "agentPath.traceJSON": "Encoded AgentPathTrace.",
                    "agentVisualization.planJSON": "Encoded AgentVisualizationPlan for pointer playback."
                ],
                permissions: [],
                safety: .readOnly,
                requiredContext: ["grounded app, window, control, or action evidence"],
                verification: [
                    "realPointerMoved=false",
                    "ungrounded steps block instead of inventing motion"
                ]
            ),
            descriptor(
                "automation.applescript.generate",
                pluginID: "core.automation",
                summary: "Ask a child model boundary to generate a small, bounded AppleScript artifact for a doable resolved app task.",
                input: [
                    "scriptArtifactID": "Stable artifact identifier reused by validate and execute steps.",
                    "targetApp": "Resolved app name and bundle identifier.",
                    "goal": "Structured task goal.",
                    "entities": "Resolved task entities.",
                    "allowedActions": "Allowed AppleScript actions and constraints.",
                    "verification": "Expected verification signal after execution."
                ],
                output: [
                    "scriptArtifactID": "Generated script artifact identifier.",
                    "scriptSource": "Bounded AppleScript source for validation/review."
                ],
                permissions: [.appLookup],
                safety: .sensitive,
                requiredContext: ["structured intent", "resolved target app", "allowed backend policy"],
                verification: ["script source validates against target app and allowed action metadata"],
                metadata: [
                    "modelBoundary": "required",
                    "directExecution": "false"
                ]
            ),
            descriptor(
                "automation.applescript.validate",
                pluginID: "core.automation",
                summary: "Validate a generated AppleScript artifact before execution: static safety checks, unresolved-parameter detection, and a real compile against the target app's scripting dictionary, so wrong terminology is rejected here with the actual compiler error instead of failing at execution.",
                input: [
                    "scriptArtifactID": "Generated AppleScript artifact identifier.",
                    "targetApp": "Resolved app name and bundle identifier.",
                    "validationPolicy": "Static checks, allowed APIs, target app, permissions, and review state."
                ],
                output: [
                    "validationStatus": "validated or rejected with reason.",
                    "compile.errorMessage": "The AppleScript compiler's actual error message when the compile gate rejects the script — regenerate with this error in context."
                ],
                permissions: [.appLookup],
                safety: .readOnly,
                requiredContext: ["generated AppleScript artifact", "validation policy"],
                verification: ["validated artifacts record provenance and policy metadata"]
            ),
            descriptor(
                "automation.applescript.execute",
                pluginID: "core.automation",
                summary: "Execute a validated/generated/user-reviewed AppleScript artifact through the guarded automation backend.",
                input: [
                    "scriptArtifactID": "Generated or reviewed script artifact identifier.",
                    "targetApp": "Resolved app name and bundle identifier."
                ],
                output: ["result": "Execution trace and structured observation."],
                permissions: [.appControl, .input],
                safety: .guardedInput,
                requiredContext: ["validated script artifact", "focused or resolvable target app"],
                verification: ["post-execution verifier confirms expected outcome"],
                metadata: [
                    "requiresGeneratedArtifact": "true",
                    "requiresValidation": "true"
                ]
            ),
            descriptor(
                "application.learning.start",
                pluginID: "core.application-learning",
                summary: "Start a reusable skill-producing application learning draft for a resolved app.",
                input: [
                    "appName": "Resolved application display name.",
                    "bundleIdentifier": "Optional resolved bundle identifier.",
                    "goal": "Learning goal or scope.",
                    "skillID": "Optional stable learned skill identifier.",
                    "explorationPolicy": "Safe exploration constraints."
                ],
                output: [
                    "draftID": "Learning draft identifier.",
                    "skillID": "Skill identifier that generated scripts can target."
                ],
                permissions: [.appLookup, .skillLookup],
                safety: .readOnly,
                requiredContext: ["structured intent", "resolved target app"],
                verification: ["draft records safe exploration policy before any app interaction"]
            ),
            descriptor(
                "application.learning.captureState",
                pluginID: "core.application-learning",
                summary: "Record a meaningful app state from screenshot, Accessibility, visible text, elements, and navigation evidence.",
                input: [
                    "draftID": "Learning draft identifier.",
                    "stateID": "Stable state identifier.",
                    "title": "Human-readable state title.",
                    "screenshotArtifactURL": "Optional persisted screenshot artifact URL.",
                    "accessibilityArtifactURL": "Optional persisted Accessibility tree artifact URL.",
                    "navigationPath": "Comma-separated path used to reach this state.",
                    "changedFromPrevious": "Short description of the state transition.",
                    "safetyNotes": "Comma-separated state safety notes."
                ],
                output: ["observationCount": "Number of captured states in the draft."],
                permissions: [.screenCapture, .accessibility],
                safety: .readOnly,
                requiredContext: ["focused target", "screen or Accessibility evidence"],
                verification: ["captured state references bounded artifacts instead of embedding raw screenshots or trees"]
            ),
            descriptor(
                "application.learning.proposeExploration",
                pluginID: "core.application-learning",
                summary: "Propose reversible Accessibility-backed exploration candidates and separate actions that need approval.",
                input: ["draftID": "Optional learning draft identifier for traceability."],
                output: [
                    "safeCandidates": "Element/action pairs that can be explored through guarded element.perform.",
                    "requiresApprovalCandidateIDs": "Action-eligible element IDs that need user approval or richer safety evidence."
                ],
                permissions: [.accessibility],
                safety: .readOnly,
                requiredContext: ["Accessibility element evidence"],
                verification: ["safe candidates come from technical roles/actions or explicit element safety metadata, not raw command text"]
            ),
            descriptor(
                "application.learning.distill",
                pluginID: "core.application-learning",
                summary: "Distill captured application states into an app profile and workflow recipes.",
                input: [
                    "draftID": "Learning draft identifier.",
                    "workflowName": "Workflow recipe name.",
                    "workflowSummary": "Workflow recipe summary.",
                    "verificationCriteria": "Comma-separated verification criteria.",
                    "scriptIDs": "Optional generated script artifact identifiers.",
                    "safetyNotes": "Comma-separated durable safety notes."
                ],
                output: ["profile": "Distilled app profile summary and workflow counts."],
                permissions: [.skillLookup],
                safety: .readOnly,
                requiredContext: ["captured learning observations"],
                verification: ["profile contains at least one captured state before it can be saved"]
            ),
            descriptor(
                "application.learning.saveSkillPack",
                pluginID: "core.application-learning",
                summary: "Save the distilled application profile as a reusable filesystem skill pack.",
                input: [
                    "draftID": "Learning draft identifier.",
                    "scriptIDs": "Optional validated script artifact identifiers to include."
                ],
                output: [
                    "skillID": "Registered learned skill identifier.",
                    "directory": "Filesystem directory containing SKILL.md, profile, workflows, evidence index, and scripts."
                ],
                permissions: [.skillLookup],
                safety: .sensitive,
                requiredContext: ["distilled application profile", "validated generated scripts when included"],
                verification: ["skill pack includes SKILL.md, app-profile.json, workflows.json, evidence index, and only validated scripts"]
            ),
            descriptor(
                "llm.generate",
                pluginID: "core.model",
                summary: "Run a one-off LLM call and return generated text. Use it to compose, transform, summarize, classify, rephrase, or massage text — e.g. produce a tracklist or a clean note body, or rewrite a raw status into a friendly one-line message. Set toFile=true for long output (a tracklist, lyrics, a long note body): the text is written to a temp file and the file path is returned, so it bypasses the shell command-length limit when you then build a note or document from it.",
                input: [
                    "prompt": "The instruction for the model (what to produce).",
                    "input": "Optional source text the prompt operates on.",
                    "toFile": "\"true\" to write the result to a temp file and return its path instead of inline text."
                ],
                output: [
                    "text": "The generated text (a short preview when written to a file).",
                    "filePath": "Path to the file holding the full output, when toFile=true."
                ],
                permissions: [],
                safety: .sensitive,
                verification: ["the returned text (or file) contains the requested content"],
                metadata: [HarnessToolDescriptor.resultIsEvidenceMetadataKey: "true"]
            ),
            descriptor(
                "files.describe",
                pluginID: "core.files",
                summary: "Understand a batch of files: for a `directory` (or explicit `paths`) it returns one structured description per file — kind (text/image/pdf/audio/video/binary), a summary, extracted text (OCR for images, text for PDFs), byte size, and attributes like dimensions. This is the file-understanding layer every file task builds on: call it first to learn what files contain, then carry out the operation yourself with general tools — `llm.generate` to decide new names/labels from the content, `shell_exec` to apply (`mv` to rename, `sips`/`ffmpeg` to resize/convert), and verify. Read-only — it changes nothing.",
                input: [
                    "directory": "Folder whose files should be described (every regular, non-hidden file in it).",
                    "paths": "Explicit comma/newline-separated file paths to describe instead of a whole directory.",
                    "maxFiles": "Optional cap on how many files to process (default 50, max 200)."
                ],
                output: [
                    "understanding": "JSON array of {path, fileName, kind, summary, textContent, byteSize, attributes} per file.",
                    "count": "How many files were described."
                ],
                optionalInputKeys: ["directory", "paths", "maxFiles"],
                permissions: [],
                safety: .sensitive,
                verification: ["the returned understanding covers the requested files"],
                metadata: [HarnessToolDescriptor.resultIsEvidenceMetadataKey: "true"]
            ),
            descriptor(
                "image.edit",
                pluginID: "core.image",
                summary: "Edit an existing image with a generative image model: describe the change in `prompt` and pass the source `inputPath`. Use it for semantic edits that sips/magick cannot do — remove or replace a background, add or remove an object, restyle, relight, or change a scene. To match a reference photo's look, pass the reference(s) as `referencePaths` and ask to match them. Writes a NEW image file and returns its path; it never overwrites the source. Costs image-generation credits per image, so for a batch confirm with the user first, then call once per file.",
                input: [
                    "prompt": "What to change, in plain words (e.g. \"remove the background\", \"make the sky a sunset\").",
                    "inputPath": "Path to the source image to edit.",
                    "referencePaths": "Optional comma/newline-separated reference image paths to condition on (e.g. a style/look reference).",
                    "model": "Optional model id override; omit to use the default image model.",
                    "outDir": "Optional output directory; a relative path like `edited` lands beside the source image. Omit to save next to the source."
                ],
                output: [
                    "paths": "Newline-separated paths to the saved image file(s).",
                    "count": "How many images were saved."
                ],
                optionalInputKeys: ["referencePaths", "model", "outDir"],
                permissions: [],
                safety: .reversible,
                verification: ["the returned image file exists and reflects the requested edit"],
                metadata: [HarnessToolDescriptor.resultIsEvidenceMetadataKey: "true"]
            ),
            descriptor(
                "image.generate",
                pluginID: "core.image",
                summary: "Generate a brand-new image from a text `prompt` with a generative image model — use when there is no source image to edit. Writes a new image file and returns its path. Costs image-generation credits per image.",
                input: [
                    "prompt": "Description of the image to create.",
                    "model": "Optional model id override; omit to use the default image model.",
                    "outDir": "Optional output directory for the result; omit to save to Downloads."
                ],
                output: [
                    "paths": "Newline-separated paths to the saved image file(s).",
                    "count": "How many images were saved."
                ],
                optionalInputKeys: ["model", "outDir"],
                permissions: [],
                safety: .reversible,
                verification: ["the returned image file exists"],
                metadata: [HarnessToolDescriptor.resultIsEvidenceMetadataKey: "true"]
            ),
            descriptor(
                "web.search",
                pluginID: "core.web",
                summary: "Search the web and return ranked results (title, URL, snippet). Use it for current facts the model can't be sure of — an artist's latest album, today's news, a product spec, an address. Follow up with web.fetch to read a result in full.",
                input: ["query": "What to search for.", "count": "How many results (default 5, max 10)."],
                output: ["results": "Ranked results: title — URL, then snippet, per result."],
                permissions: [],
                safety: .readOnly,
                verification: ["the results are relevant to the query"],
                metadata: [HarnessToolDescriptor.resultIsEvidenceMetadataKey: "true"]
            ),
            descriptor(
                "web.fetch",
                pluginID: "core.web",
                summary: "Read a web page and return its main content as clean markdown — nav, ads, and boilerplate removed, with the title, headings, links, and lists kept. Use it to read a page from web.search or a URL the user gave. Set toFile=true for a long page so you build a note/document from the file instead of a length-limited command.",
                input: [
                    "url": "The page URL to read.",
                    "toFile": "\"true\" to write the page content to a temp file and return its path."
                ],
                output: [
                    "text": "The page's main content as markdown (a preview when written to a file).",
                    "filePath": "Path to the file holding the full text, when toFile=true."
                ],
                permissions: [],
                safety: .readOnly,
                verification: ["the fetched text matches the requested page"],
                metadata: [HarnessToolDescriptor.resultIsEvidenceMetadataKey: "true"]
            ),
            descriptor(
                "state.verify",
                pluginID: "core.verification",
                summary: "Verify the expected outcome using world-model evidence and task-specific success criteria.",
                input: ["criteria": "Expected visible state, tool result, app state, or artifact state."],
                output: ["verified": "Boolean-like verification result with evidence."],
                permissions: [.verification],
                safety: .readOnly
            ),
            descriptor(
                "wait",
                pluginID: "core.timing",
                summary: "Pause briefly while the app settles (a page loads, a window opens, an animation finishes), then re-plan. Prefer this over re-observing in a tight loop when the UI is still catching up.",
                input: ["seconds": "How long to wait, 0.1–10 (default 1)."],
                permissions: [],
                safety: .readOnly,
                verification: ["re-observe after waiting to confirm the expected state arrived"]
            ),
            descriptor(
                "run.pause",
                pluginID: "core.lifecycle",
                summary: "Pause a running task.",
                permissions: [.lifecycle],
                safety: .readOnly
            ),
            descriptor(
                "run.resume",
                pluginID: "core.lifecycle",
                summary: "Resume a paused or waiting task from its checkpoint.",
                permissions: [.lifecycle],
                safety: .readOnly
            ),
            descriptor(
                "run.recover",
                pluginID: "core.lifecycle",
                summary: "Recover from a failed verification by re-observing, replanning, or falling back.",
                permissions: [.lifecycle],
                safety: .readOnly
            ),
            descriptor(
                "run.cancel",
                pluginID: "core.lifecycle",
                summary: "Cancel the selected task and clear its pending continuation.",
                input: ["reason": "Reason the task is being cancelled."],
                permissions: [.lifecycle],
                safety: .readOnly
            ),
            descriptor(
                "run.complete",
                pluginID: "core.lifecycle",
                summary: "Mark the selected task complete after verification evidence is recorded.",
                input: ["reason": "Completion summary."],
                permissions: [.lifecycle],
                safety: .readOnly
            ),
            descriptor(
                "run.failSafe",
                pluginID: "core.lifecycle",
                summary: "Stop the selected task in a safe failed state with a reason.",
                input: ["reason": "Reason the task cannot safely continue."],
                permissions: [.lifecycle],
                safety: .readOnly
            )
        ] + DonkeyCommandLayer.descriptors
    }

    public static func registryWithBuiltInExecutors(
        services: HarnessBuiltInToolServices = HarnessBuiltInToolServices()
    ) -> HarnessToolRegistry {
        HarnessToolRegistry(
            tools: BuiltInHarnessToolExecutors.tools(
                descriptors: descriptors,
                services: services
            )
        )
    }

    private static func descriptor(
        _ name: String,
        pluginID: String,
        summary: String,
        input: [String: String] = [:],
        output: [String: String] = [:],
        optionalInputKeys: [String] = [],
        permissions: [HarnessPermission],
        safety: HarnessToolSafetyClass,
        requiredContext: [String] = [],
        verification: [String] = [],
        metadata: [String: String] = [:]
    ) -> HarnessToolDescriptor {
        HarnessToolDescriptor(
            name: name,
            pluginID: pluginID,
            summary: summary,
            inputSchema: input,
            optionalInputKeys: optionalInputKeys,
            outputSchema: output,
            requiredPermissions: permissions,
            safetyClass: safety,
            requiredContext: requiredContext,
            verificationHints: verification,
            metadata: metadata
        )
    }
}
