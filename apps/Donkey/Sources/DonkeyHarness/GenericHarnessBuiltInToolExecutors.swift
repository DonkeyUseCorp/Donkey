import DonkeyContracts
import Foundation

public struct HarnessMemoryEntry: Codable, Equatable, Sendable {
    public var id: String
    public var summary: String
    public var value: String
    public var metadata: [String: String]

    public init(
        id: String,
        summary: String,
        value: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.summary = summary
        self.value = value
        self.metadata = metadata
    }
}

public enum HarnessGeneratedScriptLanguage: String, Codable, Equatable, Sendable {
    case appleScript
    case shell
    case javaScript
    case python
    case swift
    case unknown
}

public struct HarnessGeneratedScriptArtifact: Codable, Equatable, Sendable {
    public var id: String
    public var language: HarnessGeneratedScriptLanguage
    public var source: String
    public var validationStatus: HarnessSkillScriptValidationStatus
    public var createdByToolName: String
    public var ownerSkillID: String?
    public var metadata: [String: String]

    public init(
        id: String,
        language: HarnessGeneratedScriptLanguage,
        source: String,
        validationStatus: HarnessSkillScriptValidationStatus = .pendingValidation,
        createdByToolName: String,
        ownerSkillID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.language = language
        self.source = source
        self.validationStatus = validationStatus
        self.createdByToolName = createdByToolName
        self.ownerSkillID = ownerSkillID
        self.metadata = metadata
    }
}

public struct HarnessScriptExecutionOutcome: Equatable, Sendable {
    public var succeeded: Bool
    public var summary: String
    public var output: String
    public var metadata: [String: String]

    public init(
        succeeded: Bool,
        summary: String,
        output: String = "",
        metadata: [String: String] = [:]
    ) {
        self.succeeded = succeeded
        self.summary = summary
        self.output = output
        self.metadata = metadata
    }
}

public struct HarnessScriptGenerationRequest: Equatable, Sendable {
    public var language: HarnessGeneratedScriptLanguage
    public var targetApp: String
    public var bundleIdentifier: String?
    public var goal: String
    public var entities: [String: String]
    public var allowedActions: String
    public var verification: String
    /// The target app's real scripting-dictionary terminology (bounded digest). When present, the
    /// generator must write against these declared commands instead of guessing terminology.
    public var scriptingDictionaryDigest: String
    public var worldFacts: [String: String]
    public var sourceTraceID: String?
    public var metadata: [String: String]

    public init(
        language: HarnessGeneratedScriptLanguage,
        targetApp: String,
        bundleIdentifier: String? = nil,
        goal: String,
        entities: [String: String] = [:],
        allowedActions: String = "",
        verification: String = "",
        scriptingDictionaryDigest: String = "",
        worldFacts: [String: String] = [:],
        sourceTraceID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.language = language
        self.targetApp = targetApp
        self.bundleIdentifier = bundleIdentifier
        self.goal = goal
        self.entities = entities
        self.allowedActions = allowedActions
        self.verification = verification
        self.scriptingDictionaryDigest = scriptingDictionaryDigest
        self.worldFacts = worldFacts
        self.sourceTraceID = sourceTraceID
        self.metadata = metadata
    }
}

/// What the runtime knows about the target app's scripting dictionary, handed to the harness so
/// AppleScript generation is grounded in declared terminology and validation can cross-check the
/// commands a generated script claims to use.
public struct HarnessScriptingDictionarySnapshot: Equatable, Sendable {
    public var digest: String
    public var commandNames: [String]

    public init(digest: String, commandNames: [String] = []) {
        self.digest = digest
        self.commandNames = commandNames
    }
}

public struct HarnessScriptGenerationOutcome: Equatable, Sendable {
    public var succeeded: Bool
    public var source: String
    public var summary: String
    public var metadata: [String: String]

    public init(
        succeeded: Bool,
        source: String = "",
        summary: String,
        metadata: [String: String] = [:]
    ) {
        self.succeeded = succeeded
        self.source = source
        self.summary = summary
        self.metadata = metadata
    }
}

/// Result of deterministically compiling an AppleScript artifact against the target app's real
/// dictionary, without executing it. AppleScript resolves terminology at compile time, so this is
/// a 100%-accurate syntax+terminology gate; failures carry the actual compiler message so the
/// planner can regenerate with the precise error in context.
public struct HarnessScriptCompileOutcome: Equatable, Sendable {
    public var compiled: Bool
    public var errorMessage: String
    public var errorRangeDescription: String
    public var metadata: [String: String]

    public init(
        compiled: Bool,
        errorMessage: String = "",
        errorRangeDescription: String = "",
        metadata: [String: String] = [:]
    ) {
        self.compiled = compiled
        self.errorMessage = errorMessage
        self.errorRangeDescription = errorRangeDescription
        self.metadata = metadata
    }
}

public actor HarnessGeneratedScriptStore {
    private var artifactsByID: [String: HarnessGeneratedScriptArtifact]

    public init(artifacts: [HarnessGeneratedScriptArtifact] = []) {
        self.artifactsByID = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.id, $0) })
    }

    public func upsert(_ artifact: HarnessGeneratedScriptArtifact) {
        artifactsByID[artifact.id] = artifact
    }

    public func artifact(id: String) -> HarnessGeneratedScriptArtifact? {
        artifactsByID[id]
    }

    public func artifacts(ownerSkillID: String? = nil) -> [HarnessGeneratedScriptArtifact] {
        artifactsByID.values
            .filter { artifact in
                guard let ownerSkillID else { return true }
                return artifact.ownerSkillID == ownerSkillID
            }
            .sorted { $0.id < $1.id }
    }

    public func validate(
        id: String,
        metadata: [String: String] = [:]
    ) -> HarnessGeneratedScriptArtifact? {
        guard var artifact = artifactsByID[id] else { return nil }
        artifact.validationStatus = .validated
        artifact.metadata.merge(metadata) { current, _ in current }
        artifactsByID[id] = artifact
        return artifact
    }

    public func reject(
        id: String,
        reason: String
    ) -> HarnessGeneratedScriptArtifact? {
        guard var artifact = artifactsByID[id] else { return nil }
        artifact.validationStatus = .rejected
        artifact.metadata["rejection.reason"] = reason
        artifactsByID[id] = artifact
        return artifact
    }
}

/// A request to a generative image model behind the `image.edit` / `image.generate` tools.
/// `inputImagePaths` is empty for generation-from-scratch, the source image first (then any
/// reference images) for an edit. Kept provider-neutral: the adapter that fulfills it names the model.
public struct HarnessImageGenerationRequest: Sendable {
    public var prompt: String
    public var inputImagePaths: [String]
    public var model: String?
    public var outputDirectory: String?
    /// The conversation workspace folder, when one exists. Used as the default output base so a generated
    /// image lands beside the turn's other deliverables instead of in ~/Downloads.
    public var workspaceBaseDir: String?

    public init(
        prompt: String,
        inputImagePaths: [String] = [],
        model: String? = nil,
        outputDirectory: String? = nil,
        workspaceBaseDir: String? = nil
    ) {
        self.prompt = prompt
        self.inputImagePaths = inputImagePaths
        self.model = model
        self.outputDirectory = outputDirectory
        self.workspaceBaseDir = workspaceBaseDir
    }
}

public struct HarnessImageGenerationResult: Sendable {
    public var savedPaths: [String]
    /// Set when no image was produced — the provider/model's reason, surfaced to the planner so it
    /// can adjust (e.g. reword the prompt) rather than being told a flat "no image, do not retry".
    public var failureReason: String?

    public init(savedPaths: [String], failureReason: String? = nil) {
        self.savedPaths = savedPaths
        self.failureReason = failureReason
    }
}

public struct HarnessVideoGenerationRequest: Sendable {
    public var prompt: String
    /// Optional first-frame image to animate (image-to-video). Empty for plain text-to-video.
    public var inputImagePaths: [String]
    public var model: String?
    public var outputDirectory: String?
    /// Optional speed/quality tier (e.g. "fast", "standard", "high") the user picked. The backend maps it
    /// to its configured per-tier video model; nil uses the default model.
    public var tier: String?
    /// Whether to generate audio with the video. nil uses the backend default (on).
    public var audio: Bool?
    /// Veo knobs the planner may set; nil leaves the model/back-end default in place.
    public var aspectRatio: String?
    public var durationSeconds: Int?
    public var negativePrompt: String?
    /// The conversation workspace folder, when one exists. Used as the default output base so a generated
    /// clip lands beside the turn's other deliverables instead of in ~/Downloads.
    public var workspaceBaseDir: String?

    public init(
        prompt: String,
        inputImagePaths: [String] = [],
        model: String? = nil,
        outputDirectory: String? = nil,
        tier: String? = nil,
        audio: Bool? = nil,
        aspectRatio: String? = nil,
        durationSeconds: Int? = nil,
        negativePrompt: String? = nil,
        workspaceBaseDir: String? = nil
    ) {
        self.prompt = prompt
        self.inputImagePaths = inputImagePaths
        self.model = model
        self.outputDirectory = outputDirectory
        self.tier = tier
        self.audio = audio
        self.aspectRatio = aspectRatio
        self.durationSeconds = durationSeconds
        self.negativePrompt = negativePrompt
        self.workspaceBaseDir = workspaceBaseDir
    }
}

public struct HarnessVideoGenerationResult: Sendable {
    public var savedPaths: [String]
    /// Set when no video was produced — the provider/model's reason, surfaced to the planner so it
    /// can adjust rather than being told a flat "no video, do not retry".
    public var failureReason: String?

    public init(savedPaths: [String], failureReason: String? = nil) {
        self.savedPaths = savedPaths
        self.failureReason = failureReason
    }
}

/// One spoken word with its on-device-measured time span. The precise per-word boundary the planner
/// needs to cut filler words or silence, or to find an exact spoken moment — accurate to tens of
/// milliseconds, far tighter than a model-authored SRT.
public struct HarnessTranscriptionWord: Sendable {
    public var text: String
    public var startMS: Int
    public var endMS: Int
    public var confidence: Double

    public init(text: String, startMS: Int, endMS: Int, confidence: Double = 1) {
        self.text = text
        self.startMS = startMS
        self.endMS = endMS
        self.confidence = confidence
    }
}

/// Request for `transcribe`: a local audio (or directly-readable) file to transcribe on-device, with
/// an optional BCP-47 locale override. The runtime supplies the backend; without it the tool reports
/// unavailable.
public struct HarnessTranscriptionRequest: Sendable {
    public var filePath: String
    public var localeIdentifier: String?

    public init(filePath: String, localeIdentifier: String? = nil) {
        self.filePath = filePath
        self.localeIdentifier = localeIdentifier
    }
}

/// Result of an on-device transcription: the plain transcript plus per-word timings. `failureReason`
/// is set (with empty words/text) when the file could not be transcribed — surfaced so the planner
/// can adjust (e.g. extract compact audio first) instead of being told a flat "no transcript".
public struct HarnessTranscriptionResult: Sendable {
    public var text: String
    public var words: [HarnessTranscriptionWord]
    public var localeIdentifier: String?
    public var backend: String
    public var failureReason: String?

    public init(
        text: String,
        words: [HarnessTranscriptionWord],
        localeIdentifier: String? = nil,
        backend: String,
        failureReason: String? = nil
    ) {
        self.text = text
        self.words = words
        self.localeIdentifier = localeIdentifier
        self.backend = backend
        self.failureReason = failureReason
    }
}

/// Request for `media.cut`: a deterministic editor that removes spans from a media file and rejoins the
/// kept parts frame-accurate (the Descript/auto-editor approach, in code, not composed by the model).
/// Removals come from any combination of filler words (matched in the `transcribe` JSON at
/// `transcriptPath`), detected silence, and explicit caller-judged spans.
public struct HarnessMediaCutRequest: Sendable {
    public var inputPath: String
    public var outputPath: String?
    public var removeFillers: Bool
    public var removeSilence: Bool
    public var transcriptPath: String?
    /// Lexicon override for filler matching; empty uses the engine's default unambiguous set.
    public var fillerWords: [String]
    /// Caller-judged removal spans as `"start-end,start-end"` seconds (e.g. a discourse "like").
    public var explicitRemovals: String?
    /// The conversation's workspace folder, so the engine confines its ffmpeg spawns there (the seatbelt
    /// jail) and lands the cut output inside it rather than beside an input that may sit outside the folder.
    public var workingDirectory: String?

    public init(
        inputPath: String,
        outputPath: String? = nil,
        removeFillers: Bool = false,
        removeSilence: Bool = false,
        transcriptPath: String? = nil,
        fillerWords: [String] = [],
        explicitRemovals: String? = nil,
        workingDirectory: String? = nil
    ) {
        self.inputPath = inputPath
        self.outputPath = outputPath
        self.removeFillers = removeFillers
        self.removeSilence = removeSilence
        self.transcriptPath = transcriptPath
        self.fillerWords = fillerWords
        self.explicitRemovals = explicitRemovals
        self.workingDirectory = workingDirectory
    }
}

/// Result of a `media.cut`: the written file, how many spans were cut, and the before/after durations so
/// the planner can verify the edit landed. `failureReason` is set (with no usable output) when the cut
/// could not be produced. `removedSpanCount == 0` is a clean outcome (nothing matched), not a failure.
public struct HarnessMediaCutResult: Sendable {
    public var outputPath: String
    public var removedSpanCount: Int
    public var inputDurationSec: Double
    public var outputDurationSec: Double
    public var failureReason: String?

    public init(
        outputPath: String,
        removedSpanCount: Int,
        inputDurationSec: Double,
        outputDurationSec: Double,
        failureReason: String? = nil
    ) {
        self.outputPath = outputPath
        self.removedSpanCount = removedSpanCount
        self.inputDurationSec = inputDurationSec
        self.outputDurationSec = outputDurationSec
        self.failureReason = failureReason
    }
}

/// The typed request for the `web.automate` hosted tool: a natural-language task,
/// an optional starting URL, and an optional JSON-schema string for structured
/// output. Declared in DonkeyHarness so the executor can pass it across the
/// closure boundary without importing the DonkeyAI implementation.
public struct HarnessWebAutomateRequest: Sendable {
    public var task: String
    public var startURL: String?
    public var structuredOutputSchemaJSON: String?

    public init(task: String, startURL: String? = nil, structuredOutputSchemaJSON: String? = nil) {
        self.task = task
        self.startURL = startURL
        self.structuredOutputSchemaJSON = structuredOutputSchemaJSON
    }
}

/// The result of a `web.automate` run: the formatted text block for the agent to read plus whether
/// the run actually succeeded. The executor reports `.failed` (keeping `text` as the failure message)
/// whenever `succeeded` is false, so an errored, timed-out, or unsuccessful run is never reported as
/// a success.
public struct HarnessWebAutomateOutcome: Sendable {
    public var text: String
    public var succeeded: Bool

    public init(text: String, succeeded: Bool) {
        self.text = text
        self.succeeded = succeeded
    }
}

/// The typed request for the `pdf.fill` tool: the form file, the data (a file path OR the data itself
/// as text), an optional output path, and the conversation's working directory (so the orchestrator
/// runs the bundled `pdf-fill` and writes the result inside the agent's own folder). Declared in
/// DonkeyHarness so the executor passes it across the closure boundary without importing the runtime.
public struct HarnessFormFillRequest: Sendable {
    public var form: String
    public var data: String
    public var out: String?
    public var workingDirectory: String?

    public init(form: String, data: String, out: String? = nil, workingDirectory: String? = nil) {
        self.form = form
        self.data = data
        self.out = out
        self.workingDirectory = workingDirectory
    }
}

/// The result of a `pdf.fill` run: a text summary of what was filled, whether it genuinely produced a
/// filled PDF, and the output path. The executor reports `.failed` (keeping `text`) whenever `succeeded`
/// is false, so a run that mapped nothing is never surfaced to the agent as a success.
public struct HarnessFormFillOutcome: Sendable {
    public var text: String
    public var succeeded: Bool
    public var outPath: String?

    public init(text: String, succeeded: Bool, outPath: String? = nil) {
        self.text = text
        self.succeeded = succeeded
        self.outPath = outPath
    }
}

/// The typed request for the `pdf.parse` tool: the PDF to read, the output format (plain text or
/// structured JSON), an optional page range, whether to skip OCR, an optional output file, and the
/// conversation's working directory (so the orchestrator runs the bundled `lit` and resolves paths inside
/// the agent's own folder). Declared in DonkeyHarness so the executor passes it across the closure
/// boundary without importing the runtime.
public struct HarnessPdfParseRequest: Sendable {
    public var file: String
    public var format: String?
    public var pages: String?
    public var noOcr: Bool
    public var out: String?
    public var workingDirectory: String?

    public init(
        file: String,
        format: String? = nil,
        pages: String? = nil,
        noOcr: Bool = false,
        out: String? = nil,
        workingDirectory: String? = nil
    ) {
        self.file = file
        self.format = format
        self.pages = pages
        self.noOcr = noOcr
        self.out = out
        self.workingDirectory = workingDirectory
    }
}

/// The result of a `pdf.parse` run: the extracted text/JSON (or a short summary when it was written to a
/// file), whether parsing succeeded, and the output path when one was written.
public struct HarnessPdfParseOutcome: Sendable {
    public var text: String
    public var succeeded: Bool
    public var outPath: String?

    public init(text: String, succeeded: Bool, outPath: String? = nil) {
        self.text = text
        self.succeeded = succeeded
        self.outPath = outPath
    }
}

/// The typed request for the `shorts.make` tool: the source (a local video path OR a URL to download), an
/// optional clip count, an optional aspect ratio for the vertical crop, and the conversation's working
/// directory (so the pipeline writes its clips inside the agent's own folder). Declared in DonkeyHarness so
/// the executor passes it across the closure boundary without importing the runtime.
public struct HarnessShortsRequest: Sendable {
    public var source: String
    public var desiredCount: Int?
    public var aspect: String?
    public var workingDirectory: String?

    public init(source: String, desiredCount: Int? = nil, aspect: String? = nil, workingDirectory: String? = nil) {
        self.source = source
        self.desiredCount = desiredCount
        self.aspect = aspect
        self.workingDirectory = workingDirectory
    }
}

/// The result of a `shorts.make` run: a text summary, whether it genuinely produced at least one clip, and
/// the finished clip files. The executor reports `.failed` (keeping `text`) whenever `succeeded` is false,
/// so a run that rendered nothing is never surfaced to the agent as a success.
public struct HarnessShortsOutcome: Sendable {
    public var text: String
    public var succeeded: Bool
    public var producedFiles: [String]

    public init(text: String, succeeded: Bool, producedFiles: [String] = []) {
        self.text = text
        self.succeeded = succeeded
        self.producedFiles = producedFiles
    }
}

/// The typed request for the `media.caption` tool: a video (a local path OR a URL), an optional target
/// language to translate the captions into, an optional clip span to caption just part of it, and the
/// conversation's working directory. Declared in DonkeyHarness so the executor passes it across the closure
/// boundary without importing the runtime.
public struct HarnessCaptionRequest: Sendable {
    public var source: String
    public var translateTo: String?
    public var clipStart: String?
    public var clipDuration: String?
    public var workingDirectory: String?

    public init(
        source: String, translateTo: String? = nil, clipStart: String? = nil,
        clipDuration: String? = nil, workingDirectory: String? = nil
    ) {
        self.source = source
        self.translateTo = translateTo
        self.clipStart = clipStart
        self.clipDuration = clipDuration
        self.workingDirectory = workingDirectory
    }
}

/// The result of a `media.caption` run: a text summary, whether it produced a captioned file, and the
/// output path(s). The executor reports `.failed` (keeping `text`) whenever `succeeded` is false.
public struct HarnessCaptionOutcome: Sendable {
    public var text: String
    public var succeeded: Bool
    public var producedFiles: [String]

    public init(text: String, succeeded: Bool, producedFiles: [String] = []) {
        self.text = text
        self.succeeded = succeeded
        self.producedFiles = producedFiles
    }
}

/// Outcome of the multimodal arm of `llm.generate` — a model call over a local audio/video file.
/// Distinguishes the cases a caller can act on (re-chunk a truncated transcript, fix an unreadable,
/// oversized, or non-media file) instead of collapsing every failure to a bare nil.
public enum HarnessMediaGenerationOutcome: Sendable {
    /// Non-empty generated text (e.g. an SRT transcript).
    case text(String)
    /// The output hit the model's token ceiling and was cut off — split the media into shorter chunks.
    case truncated
    /// The file could not be read.
    case unreadableFile
    /// The file is larger than can be sent inline — chunk it. Carries the byte size and the cap.
    case tooLarge(bytes: Int, limit: Int)
    /// The file's resolved type is not audio or video.
    case unsupportedType(String)
    /// The media model call timed out or threw before producing output — retryable (re-chunk / retry),
    /// distinct from `.empty`. Carries a short reason for the trace.
    case timedOut(reason: String)
    /// The model genuinely returned an empty/whitespace string (not a timeout or thrown error).
    case empty
}

public struct HarnessBuiltInToolServices: Sendable {
    public var memoryEntries: [HarnessMemoryEntry]
    public var skillRegistry: HarnessSkillRegistry?
    public var generatedScripts: HarnessGeneratedScriptStore
    public var applicationLearningStore: HarnessApplicationLearningStore
    public var applicationSkillPackWriter: HarnessApplicationSkillPackWriter?
    public var appleScriptGenerator: (@Sendable (HarnessScriptGenerationRequest) async -> HarnessScriptGenerationOutcome)?
    /// The target app's parsed scripting dictionary (digest + command names), or nil when no
    /// dictionary can be read. Grounds `automation.applescript.generate` in real terminology.
    public var scriptingDictionaryProvider: (@Sendable (_ targetApp: String, _ bundleIdentifier: String?) async -> HarnessScriptingDictionarySnapshot?)?
    /// Compiles AppleScript source against the target app's dictionary without executing it.
    /// When absent, validation runs the static checks only.
    public var appleScriptCompiler: (@Sendable (_ source: String, _ targetApp: String?, _ bundleIdentifier: String?) async -> HarnessScriptCompileOutcome)?
    public var appleScriptExecutor: (@Sendable (HarnessGeneratedScriptArtifact, HarnessToolExecutionContext) async -> HarnessScriptExecutionOutcome)?
    public var skillScriptExecutor: (@Sendable (HarnessGeneratedScriptArtifact, HarnessToolExecutionContext) async -> HarnessScriptExecutionOutcome)?
    /// Preflights macOS Automation (Apple Events) consent for a target app bundle id, WITHOUT
    /// prompting. When this returns false, AppleScript execution raises the in-notch permission gate
    /// instead of letting the system dialog fire mid-task. nil means "skip the pre-gate".
    public var automationConsentGranted: (@Sendable (_ bundleIdentifier: String?) async -> Bool)?
    /// Native Donkey Command Layer backend. Returns a result for a recognized
    /// command, or `nil` to let dispatch fall through to `unknownTool`.
    public var commandExecutor: (@Sendable (HarnessToolExecutionContext) async -> HarnessToolResult?)?
    /// A one-off model completion: given a fully-formed prompt, return generated text (or nil on
    /// failure). Backs the `llm.generate` tool, the model boundary the planner can reach for to
    /// compose, transform, summarize, or massage text without leaving the harness.
    public var textGenerator: (@Sendable (String) async -> String?)?
    /// A one-off model call over a local media file (audio/video): a prompt and a file URL in, a typed
    /// outcome out. Backs `llm.generate` when a `filePath` is supplied — the multimodal arm that
    /// transcribes, translates, captions, or answers questions about media. The prompt decides the
    /// output (e.g. an SRT transcript). The outcome distinguishes the failure modes a caller can act on
    /// (re-chunk a truncated transcript, fix an unreadable or oversized file) rather than collapsing
    /// them to nil. nil means the media arm is unwired and such calls fail cleanly.
    public var mediaGenerator: (@Sendable (_ prompt: String, _ file: URL, _ mimeType: String?) async -> HarnessMediaGenerationOutcome)?
    /// Web search: a query in, ranked results as text (title — url, then snippet, per result), or nil
    /// on failure. Backs the `web.search` tool so the agent can find current facts.
    public var webSearcher: (@Sendable (String) async -> String?)?
    /// Web fetch/navigation: a URL in, the page's readable text out, or nil on failure. Backs the
    /// `web.fetch` tool so the agent can read a page it found or was given.
    public var webFetcher: (@Sendable (String) async -> String?)?
    /// Agentic web automation: a task (navigate/click/fill/extract) in, the run's result as a text
    /// block out (final output, status, any recording link), or nil on failure. Backs the
    /// `web.automate` tool, which runs through the hosted Browser Use Cloud backend and bills credits.
    public var webAutomator: (@Sendable (HarnessWebAutomateRequest) async -> HarnessWebAutomateOutcome)?
    /// The file-understanding layer behind `files.describe`: a file URL in, a structured
    /// `FileUnderstanding` out (OCR for images, text for PDFs, dimensions/metadata), or nil to fall
    /// back to the built-in Foundation understanding. The runtime supplies this; without it the tool
    /// still understands text files from their content.
    public var fileUnderstanding: (@Sendable (URL) async -> FileUnderstanding?)?
    /// Generative image editing/generation behind `image.edit` and `image.generate`: a request in,
    /// the saved output file paths out (or nil on failure). The runtime supplies an adapter that
    /// routes through the hosted asset API to an image model; without it the tools report unavailable.
    public var imageGenerator: (@Sendable (HarnessImageGenerationRequest) async -> HarnessImageGenerationResult?)?
    /// Generative text/image-to-video behind `video.generate`: a request in, the saved output file
    /// paths out (or nil on failure). The runtime supplies an adapter that routes through the hosted
    /// asset API to a video model (Veo); without it the tool reports unavailable. Video generation is
    /// a long-running job, so the adapter submits and polls behind this single call.
    public var videoGenerator: (@Sendable (HarnessVideoGenerationRequest) async -> HarnessVideoGenerationResult?)?
    /// On-device, word-level transcription behind `transcribe`: a media file in, the transcript with
    /// per-word timings out (or nil when no backend is wired). The runtime supplies an Apple
    /// speech-to-text adapter; audio never leaves the machine.
    public var transcriber: (@Sendable (HarnessTranscriptionRequest) async -> HarnessTranscriptionResult?)?
    /// Deterministic filler-word/silence editor behind `media.cut`: a request in, the written cut out (or
    /// nil when no backend is wired). The runtime supplies an engine that runs the bundled ffmpeg; the cut
    /// math is fixed code, not composed by the model.
    public var mediaCutter: (@Sendable (HarnessMediaCutRequest) async -> HarnessMediaCutResult?)?
    /// End-to-end PDF form filling behind `pdf.fill`: a form + data in, a filled PDF out. The runtime
    /// supplies an orchestrator that reads the form, makes ONE bounded mapping inference, applies the
    /// values with the bundled `pdf-fill`, and verifies — so the planner fills a form in a single call
    /// instead of a read→map→set loop it tends to abandon before writing. nil ⇒ the tool reports
    /// unavailable.
    public var formFiller: (@Sendable (HarnessFormFillRequest) async -> HarnessFormFillOutcome)?
    /// End-to-end short-form video behind `shorts.make`: a source + clip count in, captioned vertical clips
    /// out. The runtime supplies a deterministic orchestrator that transcribes on-device, makes ONE bounded
    /// inference to pick the moments, then cuts/reframes/captions each clip in fixed code — so the planner
    /// makes a whole shorts run in a single call instead of a ~37-step loop it pays for at every tool. nil ⇒
    /// the tool reports unavailable.
    public var shortsMaker: (@Sendable (HarnessShortsRequest) async -> HarnessShortsOutcome)?
    /// End-to-end subtitling/translation behind `media.caption`: a video in, a captioned video out. The
    /// runtime supplies a deterministic orchestrator that transcribes on-device, optionally translates with
    /// ONE model call, builds the SRT in code, and burns it with a known-good encoder — so the planner
    /// captions a video in a single call instead of hand-building and debugging the ffmpeg/SRT plumbing.
    /// nil ⇒ the tool reports unavailable.
    public var captioner: (@Sendable (HarnessCaptionRequest) async -> HarnessCaptionOutcome)?
    /// PDF text/structured-data extraction behind `pdf.parse`: a PDF in, its text or per-element JSON out.
    /// The runtime supplies an orchestrator that runs the bundled `lit` (liteparse) in-process — resolving
    /// the binary path and PDFIUM_LIB_PATH itself — so the planner reads a PDF through this tool and never
    /// invokes `lit` in a shell. nil ⇒ the tool reports unavailable. Set after construction like the other
    /// injected backends, so it needs no init parameter.
    public var pdfParser: (@Sendable (HarnessPdfParseRequest) async -> HarnessPdfParseOutcome)? = nil

    public init(
        memoryEntries: [HarnessMemoryEntry] = [],
        skillRegistry: HarnessSkillRegistry? = nil,
        generatedScripts: HarnessGeneratedScriptStore = HarnessGeneratedScriptStore(),
        applicationLearningStore: HarnessApplicationLearningStore = HarnessApplicationLearningStore(),
        applicationSkillPackWriter: HarnessApplicationSkillPackWriter? = nil,
        appleScriptGenerator: (@Sendable (HarnessScriptGenerationRequest) async -> HarnessScriptGenerationOutcome)? = nil,
        scriptingDictionaryProvider: (@Sendable (_ targetApp: String, _ bundleIdentifier: String?) async -> HarnessScriptingDictionarySnapshot?)? = nil,
        appleScriptCompiler: (@Sendable (_ source: String, _ targetApp: String?, _ bundleIdentifier: String?) async -> HarnessScriptCompileOutcome)? = nil,
        appleScriptExecutor: (@Sendable (HarnessGeneratedScriptArtifact, HarnessToolExecutionContext) async -> HarnessScriptExecutionOutcome)? = nil,
        skillScriptExecutor: (@Sendable (HarnessGeneratedScriptArtifact, HarnessToolExecutionContext) async -> HarnessScriptExecutionOutcome)? = nil,
        automationConsentGranted: (@Sendable (_ bundleIdentifier: String?) async -> Bool)? = nil,
        commandExecutor: (@Sendable (HarnessToolExecutionContext) async -> HarnessToolResult?)? = nil,
        textGenerator: (@Sendable (String) async -> String?)? = nil,
        mediaGenerator: (@Sendable (_ prompt: String, _ file: URL, _ mimeType: String?) async -> HarnessMediaGenerationOutcome)? = nil,
        webSearcher: (@Sendable (String) async -> String?)? = nil,
        webFetcher: (@Sendable (String) async -> String?)? = nil,
        webAutomator: (@Sendable (HarnessWebAutomateRequest) async -> HarnessWebAutomateOutcome)? = nil,
        fileUnderstanding: (@Sendable (URL) async -> FileUnderstanding?)? = nil,
        imageGenerator: (@Sendable (HarnessImageGenerationRequest) async -> HarnessImageGenerationResult?)? = nil,
        videoGenerator: (@Sendable (HarnessVideoGenerationRequest) async -> HarnessVideoGenerationResult?)? = nil,
        transcriber: (@Sendable (HarnessTranscriptionRequest) async -> HarnessTranscriptionResult?)? = nil,
        mediaCutter: (@Sendable (HarnessMediaCutRequest) async -> HarnessMediaCutResult?)? = nil,
        formFiller: (@Sendable (HarnessFormFillRequest) async -> HarnessFormFillOutcome)? = nil,
        shortsMaker: (@Sendable (HarnessShortsRequest) async -> HarnessShortsOutcome)? = nil,
        captioner: (@Sendable (HarnessCaptionRequest) async -> HarnessCaptionOutcome)? = nil
    ) {
        self.memoryEntries = memoryEntries
        self.skillRegistry = skillRegistry
        self.generatedScripts = generatedScripts
        self.applicationLearningStore = applicationLearningStore
        self.applicationSkillPackWriter = applicationSkillPackWriter
        self.appleScriptGenerator = appleScriptGenerator
        self.scriptingDictionaryProvider = scriptingDictionaryProvider
        self.appleScriptCompiler = appleScriptCompiler
        self.appleScriptExecutor = appleScriptExecutor
        self.skillScriptExecutor = skillScriptExecutor
        self.automationConsentGranted = automationConsentGranted
        self.commandExecutor = commandExecutor
        self.textGenerator = textGenerator
        self.mediaGenerator = mediaGenerator
        self.webSearcher = webSearcher
        self.webFetcher = webFetcher
        self.webAutomator = webAutomator
        self.fileUnderstanding = fileUnderstanding
        self.imageGenerator = imageGenerator
        self.videoGenerator = videoGenerator
        self.transcriber = transcriber
        self.mediaCutter = mediaCutter
        self.formFiller = formFiller
        self.shortsMaker = shortsMaker
        self.captioner = captioner
    }
}

// MARK: - Built-In Tool Executors

public enum BuiltInHarnessToolExecutors {
    public static func tools(
        descriptors: [HarnessToolDescriptor],
        services: HarnessBuiltInToolServices = HarnessBuiltInToolServices()
    ) -> [HarnessTool] {
        descriptors.map { descriptor in
            HarnessTool(descriptor: descriptor) { context in
                await execute(context, services: services)
            }
        }
    }

    private static func execute(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        switch context.call.name {
        case "conversation.respond":
            return conversationRespond(context)
        case "user.clarify":
            return userClarify(context)
        case "user.choose":
            return userChoose(context)
        case "permission.request":
            return permissionRequest(context)
        case "memory.retrieve":
            return memoryRetrieve(context, services: services)
        case "skill.search":
            return await skillSearch(context, services: services)
        case "skill.load":
            return await skillLoad(context, services: services)
        case "skill.script.generate":
            return await scriptGenerate(context, services: services, ownerSkillID: context.call.input["skillID"])
        case "skill.script.validate":
            return await scriptValidate(context, services: services)
        case "skill.script.execute":
            return await scriptExecute(context, services: services, executor: services.skillScriptExecutor)
        case "screen.observe":
            return screenObserve(context)
        case "elements.get":
            return elementsGet(context)
        case "element.perform":
            return elementPerform(context)
        case "text.enter":
            return textEnter(context)
        case "keyboard.press":
            return keyboardPress(context)
        case "agent.path.visualize":
            return agentPathVisualize(context)
        case "automation.applescript.generate":
            return await appleScriptGenerate(context, services: services)
        case "automation.applescript.validate":
            return await scriptValidate(context, services: services)
        case "automation.applescript.execute":
            return await scriptExecute(context, services: services, executor: services.appleScriptExecutor)
        case "application.learning.start":
            return await applicationLearningStart(context, services: services)
        case "application.learning.captureState":
            return await applicationLearningCaptureState(context, services: services)
        case "application.learning.proposeExploration":
            return applicationLearningProposeExploration(context)
        case "application.learning.distill":
            return await applicationLearningDistill(context, services: services)
        case "application.learning.saveSkillPack":
            return await applicationLearningSaveSkillPack(context, services: services)
        case "state.verify":
            return stateVerify(context)
        case "llm.generate":
            return await llmGenerate(context, services: services)
        case "web.search":
            return await webSearch(context, services: services)
        case "web.fetch":
            return await webFetch(context, services: services)
        case "web.automate":
            return await webAutomate(context, services: services)
        case "pdf.fill":
            return await formFill(context, services: services)
        case "pdf.parse":
            return await pdfParse(context, services: services)
        case "shorts.make":
            return await shortsMake(context, services: services)
        case "media.caption":
            return await captionVideo(context, services: services)
        case "files.describe":
            return await filesDescribe(context, services: services)
        case "files.write":
            return await filesWrite(context, services: services)
        case "image.edit":
            return await imageGenerate(context, services: services, requiresInput: true)
        case "image.generate":
            return await imageGenerate(context, services: services, requiresInput: false)
        case "video.generate":
            return await videoGenerate(context, services: services)
        case "transcribe":
            return await transcribe(context, services: services)
        case "media.cut":
            return await mediaCut(context, services: services)
        case "wait":
            return await timingWait(context)
        case "run.pause", "run.resume", "run.recover", "run.cancel", "run.complete", "run.failSafe":
            return lifecycle(context)
        default:
            if let commandExecutor = services.commandExecutor,
               let result = await commandExecutor(context) {
                return result
            }
            return HarnessToolResult(
                callID: context.call.id,
                toolName: context.call.name,
                status: .unknownTool,
                summary: "Unknown harness tool: \(context.call.name)",
                metadata: ["reason": "unknownTool"]
            )
        }
    }

    // MARK: - Conversation & User Interaction

    private static func conversationRespond(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        let response = context.call.input["response"] ?? context.call.input["message"] ?? ""
        return success(
            context,
            summary: "Conversation response recorded.",
            facts: [
                "lastConversationResponseLength": String(response.count),
                "lastAcceptedTool": context.call.name
            ],
            metadata: ["externalAction": "false"]
        )
    }

    private static func userClarify(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        let question = trimmed(context.call.input["question"]) ?? "What detail should I use?"
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .waitingForUser,
            summary: "Task stopped for user clarification.",
            question: question,
            metadata: ["gate": "clarification"]
        )
    }

    /// Surfaces a generative options form (buttons / dropdowns / toggles) and stops the task until the
    /// user submits their choices. The form arrives as JSON in `form`; it's re-serialized into the gate
    /// metadata so the notch can render it, and the title becomes the plain-text fallback question. On
    /// submit the selection comes back as the user's clarification answer ("Selected options: …"), which
    /// the planner reads to make its next call. A malformed/empty form falls back to a plain clarify.
    private static func userChoose(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        guard let formJSON = trimmed(context.call.input["form"]),
              let form = HarnessChoiceForm.decode(fromJSON: formJSON),
              let canonicalJSON = form.encodedJSON() else {
            return invalidInput(
                context,
                "user.choose requires a `form` JSON object with a non-empty `fields` array."
            )
        }
        let question = form.title.isEmpty ? "Choose how I should proceed." : form.title
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .waitingForUser,
            summary: "Task stopped for the user to choose options.",
            question: question,
            metadata: ["gate": "choiceForm", "choiceForm": canonicalJSON]
        )
    }

    private static func permissionRequest(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        let permissions = context.call.input["permission"]
            .map { [$0] }
            ?? context.call.input["permissions"]?
                .split(separator: ",")
                .map(String.init)
            ?? []
        let missing = permissions.compactMap { HarnessPermission(rawValue: trimmed($0) ?? "") }
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .waitingForPermission,
            summary: "Task stopped for permission.",
            missingPermissions: missing,
            metadata: [
                "gate": "permission",
                "requestedPermissions": missing.map(\.rawValue).joined(separator: ",")
            ]
        )
    }

    // MARK: - Memory & Skills

    private static func memoryRetrieve(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) -> HarnessToolResult {
        guard let query = trimmed(context.call.input["query"]) else {
            return invalidInput(context, "memory.retrieve requires a non-empty query.")
        }

        let tokens = tokens(in: query)
        let configuredMatches = services.memoryEntries
            .filter { entry in matches(tokens: tokens, values: [entry.id, entry.summary, entry.value] + Array(entry.metadata.values)) }
            .prefix(8)
            .map { "\($0.id): \($0.summary)" }
        // Show only model-facing facts — the machine-only keys (workspace base dir, raw follow-up
        // instructions) are hidden centrally so they never leak into retrieved snippets.
        let worldFacts = context.worldModel.modelFacingFacts
            .map { "\($0.key): \($0.value)" }
        let worldMatches = (worldFacts + context.worldModel.visibleText.map { "\($0.key): \($0.value)" })
            .filter { matches(tokens: tokens, values: [$0]) }
            .prefix(8)
        let snippets = Array(configuredMatches + worldMatches)

        return success(
            context,
            summary: snippets.isEmpty ? "No relevant memory found." : "Retrieved \(snippets.count) memory snippet(s).",
            facts: [
                "memory.retrieve.query": query,
                "memory.retrieve.count": String(snippets.count),
                "memory.retrieve.snippets": snippets.joined(separator: "\n"),
                "lastAcceptedTool": context.call.name
            ],
            metadata: ["resultCount": String(snippets.count)]
        )
    }

    private static func skillSearch(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard let registry = services.skillRegistry else {
            return failed(context, "Skill registry is not configured.", reason: "missingSkillRegistry")
        }
        let query = trimmed(context.call.input["query"]) ?? context.worldModel.facts["taskType"] ?? context.call.input["skillID"] ?? ""
        let results = await registry.search(query: query)
        let skillIDs = results.map(\.descriptor.id)
        return success(
            context,
            summary: "Found \(skillIDs.count) skill(s).",
            facts: [
                "skill.search.query": query,
                "skill.search.ids": skillIDs.joined(separator: ","),
                "lastAcceptedTool": context.call.name
            ],
            metadata: [
                "resultCount": String(skillIDs.count),
                "skillIDs": skillIDs.joined(separator: ",")
            ]
        )
    }

    private static func skillLoad(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard let registry = services.skillRegistry else {
            return failed(context, "Skill registry is not configured.", reason: "missingSkillRegistry")
        }
        guard let skillID = trimmed(context.call.input["skillID"]) else {
            return invalidInput(context, "skill.load requires a skillID.")
        }
        guard let skill = await registry.descriptor(id: skillID) else {
            return failed(context, "Skill was not found: \(skillID)", reason: "skillNotFound")
        }

        let scriptCatalog = skill.scripts
            .map { "\($0.id) [\($0.language.rawValue)]: \($0.purpose)" }
            .joined(separator: "; ")
        return success(
            context,
            summary: "Loaded skill \(skill.name).",
            facts: [
                "skill.loaded.id": skill.id,
                "skill.loaded.name": skill.name,
                "skill.loaded.tools": skill.providedToolNames.joined(separator: ","),
                "lastAcceptedTool": context.call.name
            ],
            metadata: [
                "skillID": skill.id,
                "instructionPath": skill.instructionPath ?? "",
                "scriptIDs": skill.scripts.map(\.id).joined(separator: ","),
                "scriptCatalog": scriptCatalog,
                // Progressive disclosure: surface the chosen skill's full instructions on load, so a
                // skill discovered from the compact catalog gets its concrete execution detail here.
                "skillInstructions": skill.description
            ]
        )
    }

    private static func scriptGenerate(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices,
        ownerSkillID: String?
    ) async -> HarnessToolResult {
        guard let language = generatedLanguage(context.call.input["language"]) else {
            return invalidInput(context, "\(context.call.name) requires a supported language.")
        }
        guard let purpose = trimmed(context.call.input["purpose"] ?? context.call.input["goal"]) else {
            return invalidInput(context, "\(context.call.name) requires a purpose or goal.")
        }

        let artifactID = trimmed(context.call.input["scriptID"])
            ?? trimmed(context.call.input["scriptArtifactID"])
            ?? "\(context.call.name.replacingOccurrences(of: ".", with: "-"))-\(stableIDSeed(from: purpose))"
        let source = context.call.input["scriptSource"] ?? context.call.input["source"] ?? ""
        let artifact = HarnessGeneratedScriptArtifact(
            id: artifactID,
            language: language,
            source: source,
            validationStatus: .pendingValidation,
            createdByToolName: context.call.name,
            ownerSkillID: ownerSkillID,
            metadata: context.call.input.merging([
                "directExecution": "false",
                "purpose": purpose
            ]) { current, _ in current }
        )
        await services.generatedScripts.upsert(artifact)

        return success(
            context,
            summary: "Generated script artifact \(artifactID) pending validation.",
            facts: [
                "script.generated.id": artifactID,
                "script.generated.language": language.rawValue,
                "script.generated.validationStatus": HarnessSkillScriptValidationStatus.pendingValidation.rawValue,
                "lastAcceptedTool": context.call.name
            ],
            metadata: [
                "scriptArtifactID": artifactID,
                "language": language.rawValue,
                "validationStatus": HarnessSkillScriptValidationStatus.pendingValidation.rawValue,
                "directExecution": "false"
            ]
        )
    }

    private static func scriptValidate(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard let scriptID = trimmed(context.call.input["scriptID"] ?? context.call.input["scriptArtifactID"]) else {
            return invalidInput(context, "\(context.call.name) requires a scriptID or scriptArtifactID.")
        }
        guard let artifact = await services.generatedScripts.artifact(id: scriptID) else {
            return failed(context, "Script artifact was not found: \(scriptID)", reason: "scriptNotFound")
        }
        guard !artifact.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            _ = await services.generatedScripts.reject(id: scriptID, reason: "emptyScriptSource")
            return failed(context, "Script artifact has no source to validate.", reason: "emptyScriptSource")
        }
        if artifact.language == .appleScript {
            if let rejectionReason = appleScriptValidationRejectionReason(artifact: artifact, context: context) {
                _ = await services.generatedScripts.reject(id: scriptID, reason: rejectionReason)
                return failed(context, "AppleScript artifact failed validation.", reason: rejectionReason)
            }
            if let gateRejection = await appleScriptGateRejection(artifact: artifact, context: context, services: services) {
                return gateRejection
            }
        }

        let validated = await services.generatedScripts.validate(
            id: scriptID,
            metadata: [
                "validation.policy": context.call.input["validationPolicy"] ?? "",
                "validatedBy": context.call.name
            ]
        )

        return success(
            context,
            summary: "Validated script artifact \(scriptID).",
            facts: [
                "script.validated.id": scriptID,
                "script.validated.status": validated?.validationStatus.rawValue ?? HarnessSkillScriptValidationStatus.validated.rawValue,
                "lastAcceptedTool": context.call.name
            ],
            metadata: [
                "scriptArtifactID": scriptID,
                "validationStatus": HarnessSkillScriptValidationStatus.validated.rawValue
            ]
        )
    }

    private static func scriptExecute(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices,
        executor: (@Sendable (HarnessGeneratedScriptArtifact, HarnessToolExecutionContext) async -> HarnessScriptExecutionOutcome)?
    ) async -> HarnessToolResult {
        guard let scriptID = trimmed(context.call.input["scriptID"] ?? context.call.input["scriptArtifactID"]) else {
            return invalidInput(context, "\(context.call.name) requires a scriptID or scriptArtifactID.")
        }
        guard let artifact = await services.generatedScripts.artifact(id: scriptID) else {
            return failed(context, "Script artifact was not found: \(scriptID)", reason: "scriptNotFound")
        }
        guard artifact.validationStatus == .validated else {
            return failed(context, "Script artifact must be validated before execution.", reason: "scriptNotValidated")
        }
        guard let executor else {
            return failed(context, "No guarded script execution backend is configured.", reason: "missingScriptExecutionBackend")
        }

        // Pre-gate: never let Automation (Apple Events) consent fire as a bare system dialog mid-task.
        // If the target app's automation isn't already granted, raise the in-notch permission gate;
        // the system prompt only happens after the user approves it (then the loop re-runs this tool).
        let targetBundleID = trimmed(artifact.metadata["bundleIdentifier"])
        if let automationConsentGranted = services.automationConsentGranted,
           await automationConsentGranted(targetBundleID) == false {
            let appName = trimmed(artifact.metadata["targetApp"]) ?? "this app"
            return HarnessToolResult(
                callID: context.call.id,
                toolName: context.call.name,
                status: .waitingForPermission,
                summary: "Needs your approval to control \(appName).",
                metadata: [
                    "executor": "guardedScriptBackend",
                    "gate": "systemPermission",
                    "system.permission": "automation",
                    "system.target": targetBundleID ?? "",
                    "scriptArtifactID": scriptID
                ]
            )
        }

        let outcome = await executor(artifact, context)
        if outcome.metadata["clarification.required"] == "true" {
            let question = trimmed(outcome.metadata["clarification.question"])
                ?? "What should I try next?"
            return HarnessToolResult(
                callID: context.call.id,
                toolName: context.call.name,
                status: .waitingForUser,
                summary: outcome.summary,
                observations: HarnessObservationDelta(
                    facts: [
                        "script.executed.id": scriptID,
                        "script.executed.succeeded": String(outcome.succeeded),
                        "script.executed.output": bounded(outcome.output, limit: 500),
                        "lastAcceptedTool": context.call.name
                    ]
                ),
                question: question,
                metadata: outcome.metadata.merging([
                    "scriptArtifactID": scriptID,
                    "executor": "guardedScriptBackend"
                ]) { current, _ in current }
            )
        }
        let status: HarnessToolResultStatus = outcome.succeeded ? .succeeded : .failed
        var resultMetadata = outcome.metadata.merging([
            "scriptArtifactID": scriptID,
            "executor": "guardedScriptBackend"
        ]) { current, _ in current }
        if outcome.succeeded {
            resultMetadata.merge(
                await promoteVerifiedGeneratedScript(artifact: artifact, services: services)
            ) { current, _ in current }
        }
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: status,
            summary: outcome.summary,
            observations: HarnessObservationDelta(
                facts: [
                    "script.executed.id": scriptID,
                    "script.executed.succeeded": String(outcome.succeeded),
                    "script.executed.output": bounded(outcome.output, limit: 500),
                    "lastAcceptedTool": context.call.name
                ]
            ),
            metadata: resultMetadata
        )
    }

    // MARK: - Promotion of verified generated scripts

    /// A dynamically generated AppleScript that compiled, executed, and reported success is proven
    /// terminology for this app on this machine. Promote it into a learned skill pack so the next
    /// run of the same task goes `app_skill` → `skill_run` with zero model-generated script: fully
    /// deterministic on the second run. Returns promotion metadata for the tool result (empty when
    /// promotion doesn't apply or no skill-pack writer is configured).
    private static func promoteVerifiedGeneratedScript(
        artifact: HarnessGeneratedScriptArtifact,
        services: HarnessBuiltInToolServices
    ) async -> [String: String] {
        guard artifact.createdByToolName == "automation.applescript.generate",
              artifact.validationStatus == .validated,
              let writer = services.applicationSkillPackWriter,
              let appName = trimmed(artifact.metadata["targetApp"])
        else {
            return [:]
        }
        let bundleIdentifier = trimmed(artifact.metadata["bundleIdentifier"])
        let purpose = artifact.metadata["purpose"] ?? artifact.metadata["goal"] ?? artifact.id
        let usedCommands = (artifact.metadata["generation.usedCommands"] ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Dedup key: same app + same dictionary-command signature lands in the same pack, so a
        // repeat success updates the promoted script instead of accumulating duplicates.
        let dedupSeed = usedCommands.isEmpty
            ? "\(appName) \(purpose)"
            : "\(appName) \(usedCommands.joined(separator: " "))"
        let skillID = "promoted-\(stableIDSeed(from: dedupSeed))"

        let bindings = (artifact.metadata["generation.parameterBindings"] ?? "")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let (promotedSource, parameterized) = parameterizedPromotionSource(artifact.source, bindings: bindings)

        let promoted = HarnessGeneratedScriptArtifact(
            id: "\(skillID)-run",
            language: .appleScript,
            source: promotedSource,
            validationStatus: .validated,
            createdByToolName: artifact.createdByToolName,
            ownerSkillID: skillID,
            metadata: [
                "purpose": purpose,
                "targetApp": appName,
                "bundleIdentifier": bundleIdentifier ?? "",
                "generation.usedCommands": usedCommands.joined(separator: "\n"),
                "promotion.sourceArtifactID": artifact.id,
                "promotion.parameterized": parameterized ? "true" : "false",
                "validation.policy": "promotedVerifiedScript",
                "validation.provenance": artifact.metadata["generation.backend"] ?? "dynamicAppleScriptGenerator"
            ]
        )
        let profile = HarnessApplicationProfile(
            skillID: skillID,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            learningGoal: purpose,
            observations: [],
            workflowRecipes: [
                HarnessApplicationWorkflowRecipe(
                    id: "\(skillID)-workflow",
                    name: purpose,
                    summary: "Run the promoted verified script via skill_run (skillID=\(skillID), scriptID=\(promoted.id))\(parameterized ? ", passing the task's value as `input`" : "").",
                    steps: [
                        HarnessApplicationWorkflowStep(
                            id: "run-promoted-script",
                            summary: "Execute the verified AppleScript for: \(purpose)",
                            toolName: "skill_run",
                            inputHints: parameterized
                                ? ["skillID": skillID, "scriptID": promoted.id, "input": "the task's user-specific value"]
                                : ["skillID": skillID, "scriptID": promoted.id],
                            safetyClass: .guardedInput,
                            verification: "the script reports a successful structured status"
                        )
                    ],
                    verificationCriteria: ["script output reports success"],
                    metadata: ["source": "appleScriptPromotion"]
                )
            ],
            generatedScriptIDs: [promoted.id],
            metadata: [
                "source": "appleScriptPromotion",
                "promotion.sourceArtifactID": artifact.id
            ]
        )
        guard let saved = try? writer.save(profile: profile, scripts: [promoted]) else { return [:] }
        return [
            "promotion.skillID": saved.skill.id,
            "promotion.scriptID": saved.skill.scripts.first?.id ?? promoted.id,
            "promotion.parameterized": parameterized ? "true" : "false"
        ]
    }

    /// Turns one task-specific value back into a reusable template: when a generator-reported
    /// parameter binding's value appears as a quoted string literal in the source, replace it with
    /// the `{query}` token the skill executor substitutes from `input` at run time. Matching is
    /// quote-bounded so command words are never rewritten; with no recoverable binding the script
    /// is promoted as-is (a fixed, still-deterministic workflow).
    private static func parameterizedPromotionSource(
        _ source: String,
        bindings: [String]
    ) -> (source: String, parameterized: Bool) {
        for binding in bindings {
            let parts = binding.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count >= 2 else { continue }
            let quoted = "\"\(appleScriptStringEscaped(value))\""
            if source.contains(quoted) {
                return (source.replacingOccurrences(of: quoted, with: "\"{query}\""), true)
            }
        }
        return (source, false)
    }

    /// Mirrors the runtime template renderer's escaping so a promoted `{query}` slot re-renders to
    /// exactly the literal the verified script contained.
    private static func appleScriptStringEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    // MARK: - Screen & Elements

    private static func screenObserve(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        let hasEvidence = context.worldModel.focusedApp != nil
            || context.worldModel.focusedWindowTitle != nil
            || !context.worldModel.visibleText.isEmpty
            || !context.worldModel.elements.isEmpty
        var facts = context.worldModel.facts
        facts["screen.observe.hasPriorEvidence"] = String(hasEvidence)
        facts["screen.observe.elementCount"] = String(context.worldModel.elements.count)
        facts["lastAcceptedTool"] = context.call.name

        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .succeeded,
            summary: hasEvidence ? "Observed current world-model screen evidence." : "No screen evidence is currently available.",
            observations: HarnessObservationDelta(
                focusedApp: context.worldModel.focusedApp,
                focusedWindowTitle: context.worldModel.focusedWindowTitle,
                visibleText: context.worldModel.visibleText,
                elements: context.worldModel.elements,
                facts: facts,
                uncertainty: hasEvidence ? [] : ["screen evidence has not been captured by a desktop backend"]
            ),
            metadata: [
                "evidenceSource": "worldModel",
                "elementCount": String(context.worldModel.elements.count)
            ]
        )
    }

    private static func elementsGet(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        let elements = scopedElements(context)
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .succeeded,
            summary: "Returned \(elements.count) element(s).",
            observations: HarnessObservationDelta(
                elements: elements,
                facts: [
                    "elements.get.count": String(elements.count),
                    "elements.get.scope": context.call.input["scope"] ?? "",
                    "lastAcceptedTool": context.call.name
                ]
            ),
            metadata: ["elementIDs": elements.map(\.id).joined(separator: ",")]
        )
    }

    private static func elementPerform(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        guard let elementID = trimmed(context.call.input["elementID"]) else {
            return invalidInput(context, "element.perform requires an elementID.")
        }
        guard let requestedAction = trimmed(context.call.input["action"]) else {
            return invalidInput(context, "element.perform requires an action.")
        }
        guard let element = context.worldModel.elements.first(where: { $0.id == elementID }) else {
            return failed(context, "Element was not found in the current world model.", reason: "elementNotFound")
        }
        guard element.isActionEligible else {
            return failed(context, "Element is not action eligible.", reason: "elementNotActionEligible")
        }
        guard actionAllowed(requestedAction, elementActions: element.actions) else {
            return failed(context, "Requested action is not allowed for this element.", reason: "actionNotAllowed")
        }

        return success(
            context,
            summary: "Performed guarded \(requestedAction) on \(element.label).",
            facts: [
                "element.perform.elementID": elementID,
                "element.perform.action": requestedAction,
                "element.perform.label": element.label,
                "lastAcceptedTool": context.call.name
            ],
            metadata: [
                "elementID": elementID,
                "action": requestedAction,
                "role": element.role
            ]
        )
    }

    private static func textEnter(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        guard let text = context.call.input["text"], !text.isEmpty else {
            return invalidInput(context, "text.enter requires non-empty text.")
        }
        if let elementID = trimmed(context.call.input["elementID"]) {
            guard let element = context.worldModel.elements.first(where: { $0.id == elementID }) else {
                return failed(context, "Text target element was not found.", reason: "elementNotFound")
            }
            guard element.isActionEligible else {
                return failed(context, "Text target element is not action eligible.", reason: "elementNotActionEligible")
            }
        } else if context.worldModel.focusedApp == nil {
            return failed(context, "Text input requires a focused app or explicit elementID.", reason: "missingFocusedTarget")
        }

        return success(
            context,
            summary: "Entered text through guarded input.",
            facts: [
                "text.enter.characterCount": String(text.count),
                "text.enter.elementID": context.call.input["elementID"] ?? "",
                "lastAcceptedTool": context.call.name
            ],
            metadata: [
                "characterCount": String(text.count),
                "elementID": context.call.input["elementID"] ?? ""
            ]
        )
    }

    private static func keyboardPress(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        guard let key = trimmed(context.call.input["key"]) else {
            return invalidInput(context, "keyboard.press requires a key.")
        }
        guard key.count <= 40 else {
            return invalidInput(context, "keyboard.press key is too long.")
        }
        guard context.worldModel.focusedApp != nil || context.call.input["targetID"] != nil else {
            return failed(context, "Keyboard input requires a focused target.", reason: "missingFocusedTarget")
        }

        return success(
            context,
            summary: "Pressed guarded keyboard input.",
            facts: [
                "keyboard.press.key": key,
                "lastAcceptedTool": context.call.name
            ],
            metadata: ["key": key]
        )
    }

    private static func agentPathVisualize(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        guard let stepsJSON = trimmed(context.call.input["stepsJSON"] ?? context.call.input["steps"]) else {
            return invalidInput(context, "agent.path.visualize requires stepsJSON.")
        }
        guard let stepData = stepsJSON.data(using: .utf8) else {
            return invalidInput(context, "agent.path.visualize stepsJSON must be UTF-8 JSON.")
        }

        let steps: [AgentPathStep]
        do {
            steps = try JSONDecoder().decode([AgentPathStep].self, from: stepData)
        } catch {
            return invalidInput(context, "agent.path.visualize stepsJSON did not match AgentPathStep.")
        }
        guard !steps.isEmpty else {
            return invalidInput(context, "agent.path.visualize requires at least one path step.")
        }

        let ungroundedStepIDs = steps
            .filter { !$0.hasGroundedTarget }
            .map(\.id)
        guard ungroundedStepIDs.isEmpty else {
            return HarnessToolResult(
                callID: context.call.id,
                toolName: context.call.name,
                status: .failed,
                summary: "Agent path visualization stopped before showing ungrounded motion.",
                observations: HarnessObservationDelta(
                    facts: [
                        "agent.path.visualize.status": "blocked",
                        "agent.path.visualize.ungroundedStepIDs": ungroundedStepIDs.joined(separator: ","),
                        "lastAcceptedTool": context.call.name
                    ],
                    uncertainty: ["ungrounded pointer step(s): \(ungroundedStepIDs.joined(separator: ","))"]
                ),
                metadata: [
                    "executor": "builtInGeneric",
                    "reason": "ungroundedAgentPathStep",
                    "ungroundedStepIDs": ungroundedStepIDs.joined(separator: ","),
                    "realPointerMoved": "false"
                ]
            )
        }

        let trace = AgentPathTrace(
            id: trimmed(context.call.input["traceID"] ?? context.call.input["agentPathTraceID"])
                ?? "agent-path-\(context.agentID)-\(context.call.id)",
            agentID: context.agentID,
            title: trimmed(context.call.input["title"]) ?? context.worldModel.facts["genericHarness.intent.goal"] ?? "Agent path",
            sourceTraceID: trimmed(context.call.input["sourceTraceID"] ?? context.call.metadata["traceID"]) ?? context.call.id,
            steps: steps,
            metadata: context.call.input.filter { key, _ in
                key.hasPrefix("target.") || key.hasPrefix("agentPath.") || key == "targetApp"
            }.merging([
                "source": "agent.path.visualize",
                "realPointerMoved": "false"
            ]) { current, _ in current }
        )
        guard let plan = trace.visualizationPlan() else {
            return failed(context, "Agent path visualization did not contain any grounded cursor targets.", reason: "noGroundedTargets")
        }

        return success(
            context,
            summary: "Prepared visual-only agent path with \(trace.groundedSteps.count) grounded step(s).",
            facts: [
                "agent.path.visualize.status": "ready",
                "agent.path.visualize.traceID": trace.id,
                "agent.path.visualize.stepCount": String(trace.steps.count),
                "agent.path.visualize.groundedStepCount": String(trace.groundedSteps.count),
                "agent.path.visualize.realPointerMoved": "false",
                "lastAcceptedTool": context.call.name
            ],
            metadata: [
                "agentPath.traceID": trace.id,
                "agentPath.traceJSON": jsonString(trace),
                "agentVisualization.planID": plan.id,
                "agentVisualization.planJSON": jsonString(plan),
                "agentVisualization.stepCount": String(plan.steps.count),
                "realPointerMoved": "false"
            ]
        )
    }

    // MARK: - AppleScript Automation

    private static func appleScriptGenerate(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard let targetApp = trimmed(context.call.input["targetApp"]) else {
            return invalidInput(context, "automation.applescript.generate requires a targetApp.")
        }
        guard let goal = trimmed(context.call.input["goal"]) else {
            return invalidInput(context, "automation.applescript.generate requires a goal.")
        }
        var input = context.call.input
        input["language"] = HarnessGeneratedScriptLanguage.appleScript.rawValue
        input["purpose"] = goal
        if trimmed(input["scriptSource"] ?? input["source"]) == nil {
            guard let generator = services.appleScriptGenerator else {
                return failed(context, "No dynamic AppleScript generation backend is configured.", reason: "missingAppleScriptGenerationBackend")
            }
            // Ground generation in the app's real scripting dictionary when one can be read, and
            // record the grounding on the artifact so validation can cross-check used commands.
            let dictionary = await services.scriptingDictionaryProvider?(
                targetApp,
                trimmed(context.call.input["bundleIdentifier"])
            )
            input["generation.dictionaryGrounded"] = dictionary == nil ? "false" : "true"
            if let dictionary, !dictionary.commandNames.isEmpty {
                input["dictionary.commandNames"] = dictionary.commandNames.joined(separator: "\n")
            }
            let outcome = await generator(
                HarnessScriptGenerationRequest(
                    language: .appleScript,
                    targetApp: targetApp,
                    bundleIdentifier: trimmed(context.call.input["bundleIdentifier"]),
                    goal: goal,
                    entities: scriptGenerationEntities(from: context),
                    allowedActions: context.call.input["allowedActions"] ?? "",
                    verification: context.call.input["verification"] ?? "",
                    scriptingDictionaryDigest: dictionary?.digest ?? "",
                    worldFacts: context.worldModel.facts,
                    sourceTraceID: context.call.metadata["traceID"],
                    metadata: context.call.input
                )
            )
            guard outcome.succeeded,
                  let generatedSource = trimmed(outcome.source)
            else {
                return failed(
                    context,
                    outcome.summary.isEmpty ? "Dynamic AppleScript generation failed." : outcome.summary,
                    reason: outcome.metadata["reason"] ?? "appleScriptGenerationFailed"
                )
            }
            input["scriptSource"] = generatedSource
            input.merge(
                Dictionary(uniqueKeysWithValues: outcome.metadata.map { key, value in
                    ("generation.\(key)", value)
                })
            ) { current, _ in current }
            input["generation.summary"] = outcome.summary
            input["generation.backend"] = outcome.metadata["generator"] ?? "dynamicAppleScriptGenerator"
        }
        let generatedContext = HarnessToolExecutionContext(
            agentID: context.agentID,
            call: HarnessToolCall(
                id: context.call.id,
                name: context.call.name,
                input: input,
                metadata: context.call.metadata
            ),
            descriptor: context.descriptor,
            worldModel: context.worldModel,
            grantedPermissions: context.grantedPermissions
        )
        return await scriptGenerate(generatedContext, services: services, ownerSkillID: nil)
    }

    /// Template tokens the runtime's script renderer substitutes. Matching is against this known
    /// set only — never generic `{…}`, which AppleScript uses for list/record literals.
    private static let appleScriptTemplateTokens = [
        "{query}", "{rawQuery}", "{queryLiteral}",
        "{entityValue}", "{rawEntityValue}",
        "{targetApp}", "{rawTargetApp}",
        "{bundleIdentifier}", "{rawBundleIdentifier}",
        "{input}"
    ]

    /// Deterministic gates for dynamically generated AppleScript, beyond the static text checks:
    /// unresolved template tokens (a parameter was never bound), commands the target app's
    /// dictionary doesn't declare, and a real compile against the app's terminology. Skill-pack
    /// template artifacts are exempt — they legitimately carry tokens until execution renders them.
    private static func appleScriptGateRejection(
        artifact: HarnessGeneratedScriptArtifact,
        context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult? {
        guard artifact.createdByToolName == "automation.applescript.generate" else { return nil }

        if let token = appleScriptTemplateTokens.first(where: artifact.source.contains) {
            let reason = "unresolvedTemplatePlaceholder:\(token)"
            _ = await services.generatedScripts.reject(id: artifact.id, reason: reason)
            return failed(
                context,
                "Generated AppleScript still contains the unresolved template token \(token); every parameter must be bound to a concrete value before validation.",
                reason: reason
            )
        }

        if let unknownCommand = commandNotInDictionary(artifact: artifact) {
            let reason = "commandNotInDictionary:\(unknownCommand)"
            _ = await services.generatedScripts.reject(id: artifact.id, reason: reason)
            return failed(
                context,
                "Generated AppleScript uses the command \"\(unknownCommand)\", which the target app's scripting dictionary does not declare. Regenerate using only commands from the dictionary digest.",
                reason: reason
            )
        }

        guard let compiler = services.appleScriptCompiler else { return nil }
        let targetApp = trimmed(context.call.input["targetApp"] ?? artifact.metadata["targetApp"])
        let bundleIdentifier = trimmed(context.call.input["bundleIdentifier"] ?? artifact.metadata["bundleIdentifier"])
        let compile = await compiler(artifact.source, targetApp, bundleIdentifier)
        guard !compile.compiled else { return nil }
        _ = await services.generatedScripts.reject(id: artifact.id, reason: "appleScriptCompileFailed")
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .failed,
            summary: compile.errorMessage.isEmpty
                ? "AppleScript failed to compile against the target app's dictionary."
                : "AppleScript failed to compile: \(compile.errorMessage)",
            metadata: compile.metadata.merging([
                "reason": "appleScriptCompileFailed",
                "compile.errorMessage": compile.errorMessage,
                "compile.errorRange": compile.errorRangeDescription
            ]) { current, _ in current }
        )
    }

    /// Cross-checks the commands the generator CLAIMED to use against the dictionary command list
    /// stamped on the artifact at generation time. Structured-output-on-structured-data matching:
    /// a cheap hallucination catch before the (heavier) compile gate.
    private static func commandNotInDictionary(artifact: HarnessGeneratedScriptArtifact) -> String? {
        guard let usedRaw = artifact.metadata["generation.usedCommands"],
              let declaredRaw = artifact.metadata["dictionary.commandNames"]
        else {
            return nil
        }
        let declared = Set(
            declaredRaw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        )
        guard !declared.isEmpty else { return nil }
        return usedRaw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .first { !declared.contains($0.lowercased()) }
    }

    private static func appleScriptValidationRejectionReason(
        artifact: HarnessGeneratedScriptArtifact,
        context: HarnessToolExecutionContext
    ) -> String? {
        let source = artifact.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = source.lowercased()
        guard source.count <= 6_000 else {
            return "appleScriptTooLarge"
        }
        guard lowercased.contains("tell application")
                || lowercased.contains("using terms from application")
        else {
            return "missingAppleScriptApplicationScope"
        }
        let deniedFragments = [
            "do shell script",
            "system events",
            "keystroke",
            "key code",
            "delete ",
            "erase ",
            "empty trash",
            "shutdown",
            "restart",
            "quit ",
            "eppc://"
        ]
        if let denied = deniedFragments.first(where: lowercased.contains) {
            return "disallowedAppleScriptFragment:\(denied)"
        }
        if let targetApp = trimmed(
            context.call.input["targetApp"]
                ?? artifact.metadata["targetApp"]
        ) {
            let normalizedSource = normalized(source)
            let normalizedTarget = normalized(targetApp)
            let bundleIdentifier = trimmed(
                context.call.input["bundleIdentifier"]
                    ?? artifact.metadata["bundleIdentifier"]
            ).map(normalized)
            guard normalizedSource.contains(normalizedTarget)
                    || bundleIdentifier.map({ normalizedSource.contains($0) }) == true
            else {
                return "targetAppNotReferenced"
            }
        }
        return nil
    }

    private static func scriptGenerationEntities(
        from context: HarnessToolExecutionContext
    ) -> [String: String] {
        var entities = context.worldModel.visibleText
        for (key, value) in context.call.input {
            if key.hasPrefix("entity.") {
                entities[String(key.dropFirst("entity.".count))] = value
            }
        }
        if let input = trimmed(context.call.input["input"]) {
            entities["input"] = input
        }
        if let inputEntity = trimmed(context.call.input["inputEntity"]),
           let value = trimmed(context.call.input[inputEntity] ?? context.call.input["input"]) {
            entities[inputEntity] = value
        }
        if let rawEntities = context.call.input["entities"],
           let data = rawEntities.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            entities.merge(decoded) { _, new in new }
        }
        return entities
    }

    // MARK: - Application Learning

    private static func applicationLearningStart(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard let appName = trimmed(context.call.input["appName"] ?? context.call.input["targetApp"] ?? context.worldModel.focusedApp) else {
            return invalidInput(context, "application.learning.start requires a target app.")
        }
        let skillID = trimmed(context.call.input["skillID"]) ?? "learned-\(stableIDSeed(from: appName))"
        let draftID = trimmed(context.call.input["draftID"]) ?? "\(context.agentID)-\(skillID)"
        let learningGoal = trimmed(context.call.input["goal"]) ?? "Learn \(appName)."
        let policy = trimmed(context.call.input["explorationPolicy"])
            ?? "Safe exploration only: observe, inspect Accessibility elements, open reversible menus/tabs/fields, and ask before destructive, send, purchase, or save-overwrite actions."

        let draft = await services.applicationLearningStore.begin(
            draftID: draftID,
            agentID: context.agentID,
            skillID: skillID,
            appName: appName,
            bundleIdentifier: trimmed(context.call.input["bundleIdentifier"]),
            learningGoal: learningGoal,
            explorationPolicy: policy,
            metadata: [
                "createdBy": context.call.name,
                "safeExploration": "true"
            ]
        )

        return success(
            context,
            summary: "Started application learning draft for \(appName).",
            facts: [
                "application.learning.draftID": draft.id,
                "application.learning.skillID": draft.skillID,
                "application.learning.appName": draft.appName,
                "application.learning.explorationPolicy": draft.explorationPolicy,
                "lastAcceptedTool": context.call.name
            ],
            metadata: [
                "draftID": draft.id,
                "skillID": draft.skillID,
                "appName": draft.appName,
                "bundleIdentifier": draft.bundleIdentifier ?? ""
            ]
        )
    }

    private static func applicationLearningCaptureState(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard let draftID = trimmed(context.call.input["draftID"] ?? context.worldModel.facts["application.learning.draftID"]) else {
            return invalidInput(context, "application.learning.captureState requires a learning draftID.")
        }
        guard await services.applicationLearningStore.draft(id: draftID) != nil else {
            return failed(context, "Application learning draft was not found: \(draftID)", reason: "learningDraftNotFound")
        }

        let stateID = trimmed(context.call.input["stateID"])
            ?? "state-\(stableIDSeed(from: context.call.input["title"] ?? context.worldModel.focusedWindowTitle ?? UUID().uuidString))"
        let title = trimmed(context.call.input["title"])
            ?? context.worldModel.focusedWindowTitle
            ?? context.worldModel.focusedApp
            ?? stateID
        let observation = HarnessApplicationLearningObservation(
            id: stateID,
            title: title,
            focusedApp: context.worldModel.focusedApp,
            focusedWindowTitle: context.worldModel.focusedWindowTitle,
            screenshotArtifactURL: trimmed(
                context.call.input["screenshotArtifactURL"]
                    ?? context.worldModel.facts["screenshotArtifactURL"]
                    ?? context.worldModel.facts["screen.observe.screenshotArtifactURL"]
            ),
            accessibilityArtifactURL: trimmed(
                context.call.input["accessibilityArtifactURL"]
                    ?? context.worldModel.facts["accessibilityArtifactURL"]
                    ?? context.worldModel.facts["screen.observe.accessibilityArtifactURL"]
            ),
            visibleText: context.worldModel.visibleText,
            elements: context.worldModel.elements,
            navigationPath: listValues(context.call.input["navigationPath"]),
            changedFromPrevious: context.call.input["changedFromPrevious"] ?? "",
            safetyNotes: listValues(context.call.input["safetyNotes"]),
            metadata: [
                "capturedBy": context.call.name,
                "elementCount": String(context.worldModel.elements.count),
                "visibleTextRegionCount": String(context.worldModel.visibleText.count)
            ]
        )

        guard let draft = await services.applicationLearningStore.record(
            draftID: draftID,
            observation: observation
        ) else {
            return failed(context, "Application learning draft was not found: \(draftID)", reason: "learningDraftNotFound")
        }

        return success(
            context,
            summary: "Captured learned app state \(observation.title).",
            facts: [
                "application.learning.draftID": draft.id,
                "application.learning.lastStateID": observation.id,
                "application.learning.observationCount": String(draft.observations.count),
                "application.learning.lastStateElementCount": String(observation.elements.count),
                "lastAcceptedTool": context.call.name
            ],
            metadata: [
                "draftID": draft.id,
                "stateID": observation.id,
                "observationCount": String(draft.observations.count),
                "screenshotArtifactURL": observation.screenshotArtifactURL ?? "",
                "accessibilityArtifactURL": observation.accessibilityArtifactURL ?? ""
            ]
        )
    }

    private static func applicationLearningProposeExploration(
        _ context: HarnessToolExecutionContext
    ) -> HarnessToolResult {
        let candidates = context.worldModel.elements.compactMap { element -> String? in
            guard element.isActionEligible,
                  let action = safeExplorationAction(for: element)
            else {
                return nil
            }
            return "\(element.id):\(action)"
        }
        let approvalCandidates = context.worldModel.elements.compactMap { element -> String? in
            guard element.isActionEligible,
                  safeExplorationAction(for: element) == nil,
                  !element.actions.isEmpty
            else {
                return nil
            }
            return element.id
        }

        return success(
            context,
            summary: "Proposed \(candidates.count) safe exploration candidate(s).",
            facts: [
                "application.learning.safeExplorationCandidateCount": String(candidates.count),
                "application.learning.safeExplorationCandidates": candidates.joined(separator: ","),
                "application.learning.requiresApprovalCandidateIDs": approvalCandidates.joined(separator: ","),
                "lastAcceptedTool": context.call.name
            ],
            metadata: [
                "safeCandidateCount": String(candidates.count),
                "safeCandidates": candidates.joined(separator: ","),
                "requiresApprovalCandidateIDs": approvalCandidates.joined(separator: ",")
            ]
        )
    }

    private static func applicationLearningDistill(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard let draftID = trimmed(context.call.input["draftID"] ?? context.worldModel.facts["application.learning.draftID"]) else {
            return invalidInput(context, "application.learning.distill requires a learning draftID.")
        }
        let workflowName = trimmed(context.call.input["workflowName"]) ?? "Safe inspection"
        let workflowSummary = trimmed(context.call.input["workflowSummary"])
            ?? "Use learned observations to inspect the application before taking guarded action."
        let recipe = HarnessApplicationWorkflowRecipe(
            id: stableIDSeed(from: workflowName),
            name: workflowName,
            summary: workflowSummary,
            verificationCriteria: listValues(context.call.input["verificationCriteria"]),
            metadata: ["createdBy": context.call.name]
        )
        let scriptIDs = listValues(context.call.input["scriptIDs"])
        guard let profile = await services.applicationLearningStore.distill(
            draftID: draftID,
            workflowRecipes: [recipe],
            generatedScriptIDs: scriptIDs,
            safetyNotes: listValues(context.call.input["safetyNotes"]),
            metadata: ["distilledBy": context.call.name]
        ) else {
            return failed(context, "Application learning draft has no observations to distill.", reason: "learningDraftNotReady")
        }

        return success(
            context,
            summary: "Distilled learned app profile for \(profile.appName).",
            facts: [
                "application.learning.draftID": draftID,
                "application.learning.skillID": profile.skillID,
                "application.learning.profile.appName": profile.appName,
                "application.learning.profile.observationCount": String(profile.observations.count),
                "application.learning.profile.workflowCount": String(profile.workflowRecipes.count),
                "lastAcceptedTool": context.call.name
            ],
            metadata: [
                "draftID": draftID,
                "skillID": profile.skillID,
                "observationCount": String(profile.observations.count),
                "workflowCount": String(profile.workflowRecipes.count)
            ]
        )
    }

    private static func applicationLearningSaveSkillPack(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard let draftID = trimmed(context.call.input["draftID"] ?? context.worldModel.facts["application.learning.draftID"]) else {
            return invalidInput(context, "application.learning.saveSkillPack requires a learning draftID.")
        }
        guard let draft = await services.applicationLearningStore.draft(id: draftID) else {
            return failed(context, "Application learning draft was not found: \(draftID)", reason: "learningDraftNotFound")
        }
        let profile: HarnessApplicationProfile
        if let existingProfile = draft.profile {
            profile = existingProfile
        } else if let distilledProfile = await services.applicationLearningStore.distill(draftID: draftID) {
            profile = distilledProfile
        } else {
            return failed(context, "Application learning draft has no observations to save.", reason: "learningDraftNotReady")
        }

        let requestedScriptIDs = Set(listValues(context.call.input["scriptIDs"]))
        let ownerScripts = await services.generatedScripts.artifacts(ownerSkillID: profile.skillID)
        let extraScripts = requestedScriptIDs.isEmpty
            ? []
            : await services.generatedScripts.artifacts().filter { requestedScriptIDs.contains($0.id) }
        let scripts = Array(
            Dictionary(uniqueKeysWithValues: (ownerScripts + extraScripts).map { ($0.id, $0) })
                .values
        )
        .sorted { $0.id < $1.id }
        let writer = services.applicationSkillPackWriter
            ?? HarnessApplicationSkillPackWriter(rootDirectory: HarnessApplicationSkillPackWriter.defaultRootDirectory())

        do {
            let result = try writer.save(profile: profile, scripts: scripts)
            await services.skillRegistry?.register(result.skill)

            return success(
                context,
                summary: "Saved learned application skill pack for \(profile.appName).",
                facts: [
                    "application.learning.skillID": result.skill.id,
                    "application.learning.skillDirectory": result.directoryPath,
                    "application.learning.writtenFileCount": String(result.writtenFiles.count),
                    "application.learning.validatedScriptCount": String(result.scriptCount),
                    "lastAcceptedTool": context.call.name
                ],
                metadata: [
                    "skillID": result.skill.id,
                    "directory": result.directoryPath,
                    "writtenFiles": result.writtenFiles.joined(separator: "\n"),
                    "scriptCount": String(result.scriptCount)
                ]
            )
        } catch {
            return failed(context, "Failed to save learned application skill pack: \(error)", reason: "skillPackWriteFailed")
        }
    }

    // MARK: - Verification & Lifecycle

    /// Tools that observe/plan/converse rather than change app state. A criteria-less `state.verify`
    /// must not treat one of these succeeding as evidence the task's action actually happened.
    private static let nonActionVerifyTools: Set<String> = [
        "state.verify",
        "screen.observe",
        "app.observe",
        "elements.get",
        "skill.load",
        "skill.list",
        "app.list",
        "app.lookup"
    ]

    /// Generic LLM call: compose/transform text via the model boundary, or — when a `filePath` is
    /// given — transcribe/translate/analyze a local audio or video file through the media boundary.
    /// Long output can be written to a temp file (toFile=true) so the caller builds a note, subtitle
    /// file, or document from the file instead of passing a huge string through a length-limited shell
    /// command.
    private static func llmGenerate(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard let prompt = trimmed(context.call.input["prompt"]) else {
            return invalidInput(context, "llm.generate requires a `prompt`.")
        }

        // Optional source text the prompt operates on — folded into the prompt for both the text and
        // the media arm, so passing `input` alongside `filePath` (e.g. a glossary of names to spell) is
        // not silently dropped.
        let source = context.call.input["input"].map { "\n\nINPUT:\n\($0)" } ?? ""
        let generated: String?
        if let filePath = trimmed(context.call.input["filePath"]) {
            guard let mediaGenerator = services.mediaGenerator else {
                return failed(context, "No media model boundary is wired for llm.generate with a filePath.", reason: "mediaGeneratorUnavailable")
            }
            let fileURL = URL(fileURLWithPath: filePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return invalidInput(context, "llm.generate `filePath` does not exist: \(filePath).")
            }
            switch await mediaGenerator(prompt + source, fileURL, trimmed(context.call.input["mimeType"])) {
            case .text(let value):
                generated = value
            case .truncated:
                return failed(context, "The transcript hit the model's output limit and was cut off — split the media into shorter chunks and transcribe each.", reason: "mediaOutputTruncated")
            case .unreadableFile:
                return failed(context, "Could not read the media file: \(filePath).", reason: "mediaFileUnreadable")
            case .tooLarge(let bytes, let limit):
                return failed(context, "The media file is \(bytes / 1_000_000)MB, over the \(limit / 1_000_000)MB inline limit — extract compact audio or split it into chunks.", reason: "mediaFileTooLarge")
            case .unsupportedType(let mime):
                return failed(context, "llm.generate `filePath` must be audio or video; got \(mime). Pass an explicit `mimeType` if the extension is unusual.", reason: "mediaUnsupportedType")
            case .timedOut(let reason):
                // A timeout or thrown error is retryable — surface it as such rather than as "no text"
                // so the planner re-chunks or retries instead of giving up.
                return failed(context, "The media model call did not finish (\(reason)) — split the media into shorter chunks and retry.", reason: "mediaTimedOut")
            case .empty:
                generated = nil
            }
        } else {
            guard let generator = services.textGenerator else {
                return failed(context, "No model boundary is wired for llm.generate.", reason: "textGeneratorUnavailable")
            }
            generated = await generator(prompt + source)
        }
        guard let text = generated, !text.isEmpty else {
            return failed(context, "The model returned no text.", reason: "emptyGeneration")
        }

        let toFile = (context.call.input["toFile"] ?? "").lowercased() == "true"
        if toFile {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("donkey-llm-\(context.call.id).txt")
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                return failed(context, "Could not write generated text to a file: \(error)", reason: "fileWriteFailed")
            }
            let preview = String(text.prefix(200))
            return success(
                context,
                summary: "Generated \(text.count) characters → \(url.path)",
                facts: ["lastAcceptedTool": context.call.name],
                metadata: ["filePath": url.path, "text": preview, "characterCount": String(text.count)]
            )
        }
        return success(
            context,
            summary: text.count > 400 ? String(text.prefix(400)) + "…" : text,
            facts: ["lastAcceptedTool": context.call.name],
            metadata: ["text": text, "characterCount": String(text.count)]
        )
    }

    private static func imageGenerate(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices,
        requiresInput: Bool
    ) async -> HarnessToolResult {
        guard let generator = services.imageGenerator else {
            return failed(context, "No image model is wired for \(context.call.name).", reason: "imageGeneratorUnavailable")
        }
        guard let prompt = trimmed(context.call.input["prompt"]) else {
            return invalidInput(context, "\(context.call.name) requires a `prompt` describing the image.")
        }
        var inputPaths: [String] = []
        if let inputPath = trimmed(context.call.input["inputPath"]) {
            inputPaths.append(inputPath)
        }
        if let references = trimmed(context.call.input["referencePaths"]) {
            inputPaths.append(contentsOf: references
                .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "\r" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
        }
        if requiresInput && inputPaths.isEmpty {
            return invalidInput(context, "image.edit requires an `inputPath` to the image to edit.")
        }
        let request = HarnessImageGenerationRequest(
            prompt: prompt,
            inputImagePaths: inputPaths,
            model: trimmed(context.call.input["model"]),
            outputDirectory: trimmed(context.call.input["outDir"]),
            workspaceBaseDir: context.worldModel.facts[ConversationWorkspace.baseDirFactKey]
                .flatMap { $0.isEmpty ? nil : $0 }
        )
        guard let result = await generator(request) else {
            return failed(context, "The image model is unavailable right now.", reason: "imageGeneratorUnavailable")
        }
        guard !result.savedPaths.isEmpty else {
            return failed(
                context,
                result.failureReason ?? "The image model returned no image.",
                reason: "imageGenerationFailed"
            )
        }
        let joined = result.savedPaths.joined(separator: ", ")
        return success(
            context,
            summary: "Saved \(result.savedPaths.count) image(s) → \(joined)",
            facts: ["lastAcceptedTool": context.call.name],
            metadata: [
                "paths": result.savedPaths.joined(separator: "\n"),
                "count": String(result.savedPaths.count)
            ]
        )
    }

    private static func videoGenerate(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard let generator = services.videoGenerator else {
            return failed(context, "No video model is wired for \(context.call.name).", reason: "videoGeneratorUnavailable")
        }
        guard let prompt = trimmed(context.call.input["prompt"]) else {
            return invalidInput(context, "\(context.call.name) requires a `prompt` describing the video.")
        }
        var inputPaths: [String] = []
        if let inputPath = trimmed(context.call.input["inputPath"]) {
            inputPaths.append(inputPath)
        }
        let audio = trimmed(context.call.input["audio"]).map { boolFlag($0) }
        let request = HarnessVideoGenerationRequest(
            prompt: prompt,
            inputImagePaths: inputPaths,
            model: trimmed(context.call.input["model"]),
            outputDirectory: trimmed(context.call.input["outDir"]),
            tier: trimmed(context.call.input["tier"]),
            audio: audio,
            aspectRatio: trimmed(context.call.input["aspectRatio"]),
            durationSeconds: trimmed(context.call.input["durationSeconds"]).flatMap { Int($0) },
            negativePrompt: trimmed(context.call.input["negativePrompt"]),
            workspaceBaseDir: context.worldModel.facts[ConversationWorkspace.baseDirFactKey]
                .flatMap { $0.isEmpty ? nil : $0 }
        )
        guard let result = await generator(request) else {
            return failed(context, "The video model is unavailable right now.", reason: "videoGeneratorUnavailable")
        }
        guard !result.savedPaths.isEmpty else {
            return failed(
                context,
                result.failureReason ?? "The video model returned no video.",
                reason: "videoGenerationFailed"
            )
        }
        let joined = result.savedPaths.joined(separator: ", ")
        return success(
            context,
            summary: "Saved \(result.savedPaths.count) video(s) → \(joined)",
            facts: ["lastAcceptedTool": context.call.name],
            metadata: [
                "paths": result.savedPaths.joined(separator: "\n"),
                "count": String(result.savedPaths.count)
            ]
        )
    }

    /// On-device transcription with per-word timings behind `transcribe`. Writes the transcript and its
    /// word timings as a JSON file (so a long transcript bypasses the shell command-length limit) and
    /// returns its path, plus the plain text inline. The word timings are what the media skill reads
    /// back to cut filler words or silence; an empty result carries the backend's reason so the planner
    /// can extract compact audio and retry rather than give up.
    private static func transcribe(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard let transcriber = services.transcriber else {
            return failed(context, "No on-device transcription backend is wired for transcribe.", reason: "transcriberUnavailable")
        }
        guard let filePath = trimmed(context.call.input["filePath"]) else {
            return invalidInput(context, "transcribe requires a `filePath` to a local audio or video file.")
        }
        let fileURL = URL(fileURLWithPath: (filePath as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return invalidInput(context, "transcribe `filePath` does not exist: \(filePath).")
        }
        let request = HarnessTranscriptionRequest(
            filePath: fileURL.path,
            localeIdentifier: trimmed(context.call.input["locale"])
        )
        guard let result = await transcriber(request) else {
            return failed(context, "On-device transcription is unavailable right now.", reason: "transcriberUnavailable")
        }
        guard !result.words.isEmpty || !result.text.isEmpty else {
            let hint = "extract compact audio first (e.g. ffmpeg -i in.mp4 -vn -ac 1 audio.m4a) and transcribe that"
            let reason = result.failureReason.map { "Transcription failed: \($0). Then \(hint)." }
                ?? "Transcription produced no words — \(hint)."
            return failed(context, reason, reason: "transcriptionFailed")
        }

        // Persist text + per-word timings (seconds) as JSON the planner reads back to build the cut list.
        let wordObjects: [[String: Any]] = result.words.map { word in
            [
                "text": word.text,
                "start": Double(word.startMS) / 1000.0,
                "end": Double(word.endMS) / 1000.0
            ]
        }
        let payload: [String: Any] = [
            "text": result.text,
            "locale": result.localeIdentifier ?? "",
            "backend": result.backend,
            "wordCount": result.words.count,
            "words": wordObjects
        ]
        // Write into the conversation workspace (not the temp dir): the per-word-timing JSON is a real
        // deliverable the planner must hand to media.cut as `transcriptPath`, and the workspace tracker
        // skips temp-dir paths — a transcript left in temp never enters the workspace summary, so after
        // context compaction the planner loses the path and can't run the filler-word cut it transcribed for.
        let url = Self.resolveWritePath("donkey-transcript-\(context.call.id).json", in: context.worldModel)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            return failed(context, "Could not write the transcript file: \(error)", reason: "fileWriteFailed")
        }
        let preview = result.text.count > 400 ? String(result.text.prefix(400)) + "…" : result.text
        return success(
            context,
            summary: "Transcribed \(result.words.count) timed words (\(result.backend)) → \(url.path)",
            facts: ["lastAcceptedTool": context.call.name],
            metadata: [
                "filePath": url.path,
                "text": preview,
                "wordCount": String(result.words.count)
            ]
        )
    }

    /// Deterministic filler-word/silence editor behind `media.cut`. The planner says WHAT to remove
    /// (fillers via the transcript, silence, explicit spans); the wired engine does the span math, builds
    /// the ffmpeg filtergraph, and renders the cut — none of it composed here. `removedSpanCount == 0`
    /// (nothing matched) is reported as a clean no-op, not a failure.
    private static func mediaCut(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard let cutter = services.mediaCutter else {
            return failed(context, "No media-cut engine is wired for media.cut.", reason: "mediaCutterUnavailable")
        }
        guard let inputPath = trimmed(context.call.input["inputPath"]) else {
            return invalidInput(context, "media.cut requires an `inputPath` to the video or audio file.")
        }
        let inputURL = URL(fileURLWithPath: (inputPath as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            return invalidInput(context, "media.cut `inputPath` does not exist: \(inputPath).")
        }
        let removeFillers = boolFlag(context.call.input["removeFillers"])
        let removeSilence = boolFlag(context.call.input["removeSilence"])
        let explicit = trimmed(context.call.input["removeSpans"])
        guard removeFillers || removeSilence || explicit != nil else {
            return invalidInput(context, "media.cut needs at least one of removeFillers=true, removeSilence=true, or removeSpans.")
        }
        let transcriptPath = trimmed(context.call.input["transcriptPath"]).map { ($0 as NSString).expandingTildeInPath }
        if removeFillers, transcriptPath == nil {
            return invalidInput(context, "media.cut removeFillers=true requires `transcriptPath` to the transcribe JSON.")
        }
        // Split on commas/newlines only — NOT spaces — so a multi-word filler phrase like "you know"
        // stays one entry instead of shattering into the common words "you" and "know".
        let fillerWords = (trimmed(context.call.input["fillerWords"]) ?? "")
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let request = HarnessMediaCutRequest(
            inputPath: inputURL.path,
            outputPath: trimmed(context.call.input["outputPath"]).map { ($0 as NSString).expandingTildeInPath },
            removeFillers: removeFillers,
            removeSilence: removeSilence,
            transcriptPath: transcriptPath,
            fillerWords: fillerWords,
            explicitRemovals: explicit,
            workingDirectory: context.worldModel.facts[ConversationWorkspace.baseDirFactKey]
        )
        guard let result = await cutter(request) else {
            return failed(context, "The media-cut engine is unavailable right now.", reason: "mediaCutterUnavailable")
        }
        if let reason = result.failureReason {
            return failed(context, "media.cut failed: \(reason)", reason: "mediaCutFailed")
        }
        let removedSec = max(0, result.inputDurationSec - result.outputDurationSec)
        if result.removedSpanCount == 0 {
            return success(
                context,
                summary: "media.cut found nothing to remove — left \(result.outputPath) unchanged.",
                facts: ["lastAcceptedTool": context.call.name],
                metadata: ["filePath": result.outputPath, "removedSpans": "0"]
            )
        }
        return success(
            context,
            summary: String(
                format: "Cut %d span(s), removed %.1fs — %.1fs → %.1fs → %@",
                result.removedSpanCount, removedSec, result.inputDurationSec, result.outputDurationSec, result.outputPath
            ),
            facts: ["lastAcceptedTool": context.call.name],
            metadata: [
                "filePath": result.outputPath,
                "removedSpans": String(result.removedSpanCount),
                "inputDurationSec": String(format: "%.3f", result.inputDurationSec),
                "outputDurationSec": String(format: "%.3f", result.outputDurationSec)
            ]
        )
    }

    /// A loose boolean flag from a tool input — "true"/"on"/"yes"/"1" (case-insensitive) is true.
    private static func boolFlag(_ value: String?) -> Bool {
        ["true", "on", "yes", "1"].contains((value ?? "").trimmingCharacters(in: .whitespaces).lowercased())
    }

    private static func webSearch(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard let searcher = services.webSearcher else {
            return failed(context, "Web search is not configured.", reason: "webSearchUnavailable")
        }
        guard let query = trimmed(context.call.input["query"]) else {
            return invalidInput(context, "web.search requires a `query`.")
        }
        guard let results = await searcher(query), !results.isEmpty else {
            return failed(context, "No results for \"\(query)\".", reason: "noWebResults")
        }
        return success(
            context,
            summary: results.count > 600 ? String(results.prefix(600)) + "…" : results,
            facts: ["lastAcceptedTool": context.call.name],
            metadata: ["results": results, "query": query]
        )
    }

    private static func webFetch(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard let fetcher = services.webFetcher else {
            return failed(context, "Web fetch is not configured.", reason: "webFetchUnavailable")
        }
        guard let url = trimmed(context.call.input["url"]) else {
            return invalidInput(context, "web.fetch requires a `url`.")
        }
        guard let text = await fetcher(url), !text.isEmpty else {
            return failed(context, "Could not read \(url).", reason: "webFetchFailed")
        }
        if (context.call.input["toFile"] ?? "").lowercased() == "true" {
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("donkey-web-\(context.call.id).txt")
            do {
                try text.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                return failed(context, "Could not write page text to a file: \(error)", reason: "fileWriteFailed")
            }
            return success(
                context,
                summary: "Fetched \(text.count) characters → \(fileURL.path)",
                facts: ["lastAcceptedTool": context.call.name],
                metadata: ["filePath": fileURL.path, "text": String(text.prefix(200)), "characterCount": String(text.count)]
            )
        }
        return success(
            context,
            summary: text.count > 600 ? String(text.prefix(600)) + "…" : text,
            facts: ["lastAcceptedTool": context.call.name],
            metadata: ["text": text, "characterCount": String(text.count)]
        )
    }

    private static func webAutomate(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard let automator = services.webAutomator else {
            return failed(context, "Web automation is not configured.", reason: "webAutomateUnavailable")
        }
        guard let task = trimmed(context.call.input["task"]) else {
            return invalidInput(context, "web.automate requires a `task` describing what to do.")
        }
        let request = HarnessWebAutomateRequest(
            task: task,
            startURL: trimmed(context.call.input["startUrl"]),
            structuredOutputSchemaJSON: trimmed(context.call.input["schema"])
        )
        let outcome = await automator(request)
        let result = outcome.text
        // Report failure (keeping the diagnostic text) whenever the run did not genuinely succeed —
        // an errored, timed-out, or unsuccessful run must never be surfaced to the agent as a success.
        guard outcome.succeeded, !result.isEmpty else {
            let message = result.isEmpty ? "The browser task did not complete." : result
            return failed(
                context,
                message.count > 600 ? String(message.prefix(600)) + "…" : message,
                reason: "webAutomateFailed",
                metadata: ["text": message]
            )
        }
        return success(
            context,
            summary: result.count > 600 ? String(result.prefix(600)) + "…" : result,
            facts: ["lastAcceptedTool": context.call.name],
            metadata: ["text": result]
        )
    }

    /// `pdf.fill` — fill a fillable PDF form end to end. The planner gives the form and the data; the
    /// injected orchestrator reads the form, maps every value in ONE bounded inference, writes the filled
    /// PDF with the bundled `pdf-fill`, and verifies. This exists because the read→map→set loop, left to
    /// the planner, reliably stalls before the write — here the write is not the planner's decision.
    private static func formFill(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard let filler = services.formFiller else {
            return failed(context, "PDF form filling is not configured.", reason: "formFillUnavailable")
        }
        guard let form = trimmed(context.call.input["form"]) else {
            return invalidInput(context, "pdf.fill requires a `form` — the path to the fillable PDF.")
        }
        guard let data = trimmed(context.call.input["data"]) else {
            return invalidInput(context, "pdf.fill requires `data` — a path to the data file, or the data itself as text.")
        }
        let workingDirectory = context.worldModel.facts[ConversationWorkspace.baseDirFactKey]
        let request = HarnessFormFillRequest(
            form: form,
            data: data,
            out: trimmed(context.call.input["out"]),
            workingDirectory: (workingDirectory?.isEmpty == false) ? workingDirectory : nil
        )
        let outcome = await filler(request)
        guard outcome.succeeded else {
            let message = outcome.text.isEmpty ? "The form could not be filled." : outcome.text
            return failed(context, message, reason: "formFillFailed", metadata: ["text": message])
        }
        var metadata = ["text": outcome.text]
        if let outPath = outcome.outPath { metadata["filePath"] = outPath }
        return success(
            context,
            summary: outcome.text,
            facts: ["lastAcceptedTool": context.call.name],
            metadata: metadata
        )
    }

    /// `pdf.parse` — extract a PDF's text or structured data. The injected orchestrator runs the bundled
    /// `lit` (liteparse) in-process, resolving its path and PDFIUM_LIB_PATH, so the planner never types
    /// `lit` into a shell. OCR is built in, so a scanned PDF reads the same as a digital one.
    private static func pdfParse(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard let parser = services.pdfParser else {
            return failed(context, "PDF parsing is not configured.", reason: "pdfParseUnavailable")
        }
        guard let file = trimmed(context.call.input["file"]) else {
            return invalidInput(context, "pdf.parse requires a `file` — the path to the PDF to read.")
        }
        let workingDirectory = context.worldModel.facts[ConversationWorkspace.baseDirFactKey]
        let request = HarnessPdfParseRequest(
            file: file,
            format: trimmed(context.call.input["format"]),
            pages: trimmed(context.call.input["pages"]),
            noOcr: boolFlag(context.call.input["noOcr"]),
            out: trimmed(context.call.input["out"]),
            workingDirectory: (workingDirectory?.isEmpty == false) ? workingDirectory : nil
        )
        let outcome = await parser(request)
        guard outcome.succeeded else {
            let message = outcome.text.isEmpty ? "The PDF could not be parsed." : outcome.text
            return failed(context, message, reason: "pdfParseFailed", metadata: ["text": message])
        }
        var metadata = ["text": outcome.text]
        if let outPath = outcome.outPath { metadata["filePath"] = outPath }
        return success(
            context,
            summary: outcome.text,
            facts: ["lastAcceptedTool": context.call.name],
            metadata: metadata
        )
    }

    /// `shorts.make` — turn a long video into captioned vertical clips end to end. The planner gives the
    /// source and an optional clip count; the injected orchestrator transcribes on-device, makes ONE bounded
    /// inference to pick the moments, then cuts/reframes/captions each clip in fixed code and returns the
    /// finished files. This exists because the download→transcribe→cut→reframe→caption recipe, left to the
    /// planner, costs a model round-trip at every step and clip — here the whole run is one tool call.
    private static func shortsMake(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard let maker = services.shortsMaker else {
            return failed(context, "Short-form video is not configured.", reason: "shortsUnavailable")
        }
        guard let source = trimmed(context.call.input["source"]) else {
            return invalidInput(context, "shorts.make requires a `source` — a local video path or a URL.")
        }
        let count = trimmed(context.call.input["count"]).flatMap { Int($0) }
        let workingDirectory = context.worldModel.facts[ConversationWorkspace.baseDirFactKey]
        let request = HarnessShortsRequest(
            source: source,
            desiredCount: count,
            aspect: trimmed(context.call.input["aspect"]),
            workingDirectory: (workingDirectory?.isEmpty == false) ? workingDirectory : nil
        )
        let outcome = await maker(request)
        guard outcome.succeeded else {
            let message = outcome.text.isEmpty ? "No clips could be produced." : outcome.text
            return failed(context, message, reason: "shortsFailed", metadata: ["text": message])
        }
        var metadata = ["text": outcome.text]
        if !outcome.producedFiles.isEmpty {
            metadata["paths"] = outcome.producedFiles.joined(separator: "\n")
        }
        return success(
            context,
            summary: outcome.text,
            facts: ["lastAcceptedTool": context.call.name],
            metadata: metadata
        )
    }

    /// `media.caption` — subtitle or translate a video end to end. The planner gives the video (and a target
    /// language to translate into); the injected orchestrator transcribes on-device, optionally translates in
    /// ONE call, builds the SRT in code, and burns it with a known-good encoder. This exists because the
    /// transcribe→SRT→burn recipe, left to the planner, reliably explodes into a model-authored-SRT cleanup
    /// loop and encoder/duration debugging — dozens of round-trips for a five-step job.
    private static func captionVideo(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        guard let captioner = services.captioner else {
            return failed(context, "Video captioning is not configured.", reason: "captionUnavailable")
        }
        guard let source = trimmed(context.call.input["source"]) else {
            return invalidInput(context, "media.caption requires a `source` — a local video path or a URL.")
        }
        let workingDirectory = context.worldModel.facts[ConversationWorkspace.baseDirFactKey]
        let request = HarnessCaptionRequest(
            source: source,
            translateTo: trimmed(context.call.input["translateTo"]),
            clipStart: trimmed(context.call.input["clipStart"]),
            clipDuration: trimmed(context.call.input["clipDuration"]),
            workingDirectory: (workingDirectory?.isEmpty == false) ? workingDirectory : nil
        )
        let outcome = await captioner(request)
        guard outcome.succeeded else {
            let message = outcome.text.isEmpty ? "The video could not be captioned." : outcome.text
            return failed(context, message, reason: "captionFailed", metadata: ["text": message])
        }
        var metadata = ["text": outcome.text]
        if !outcome.producedFiles.isEmpty {
            metadata["paths"] = outcome.producedFiles.joined(separator: "\n")
        }
        return success(
            context,
            summary: outcome.text,
            facts: ["lastAcceptedTool": context.call.name],
            metadata: metadata
        )
    }

    private static func timingWait(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        let requested = context.call.input["seconds"].flatMap(Double.init) ?? 1
        let seconds = min(max(requested, 0.1), 10)
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return success(
            context,
            summary: "Waited \(String(format: "%.1f", seconds))s for the app to settle.",
            facts: ["lastAcceptedTool": context.call.name],
            metadata: ["seconds": String(format: "%.1f", seconds)]
        )
    }

    private static func stateVerify(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        guard let criteria = trimmed(context.call.input["criteria"]) else {
            // Planners sometimes append a verify step without echoing explicit criteria. Verify against
            // the evidence the run produced: a guarded script that explicitly reported failure fails;
            // otherwise pass when SOME prior action (script OR accessibility/UI) actually succeeded.
            // A criteria-less verify with no prior action at all (e.g. ordered before anything ran) has
            // nothing to attest to, so it does not report success vacuously.
            let scriptOutcome = context.worldModel.facts["script.executed.succeeded"]
            let hadSucceededAction = context.worldModel.attemptedToolCalls.contains { record in
                record.resultStatus == .succeeded && !Self.nonActionVerifyTools.contains(record.call.name)
            }
            let verified = scriptOutcome != "false" && (scriptOutcome == "true" || hadSucceededAction)
            let summary: String
            if !verified, scriptOutcome == "false" {
                summary = "Prior action reported failure."
            } else if !verified {
                summary = "Verification has no criteria and no prior action evidence to confirm."
            } else {
                summary = "Verification succeeded from prior action evidence (no explicit criteria)."
            }
            return HarnessToolResult(
                callID: context.call.id,
                toolName: context.call.name,
                status: verified ? .succeeded : .failed,
                summary: summary,
                observations: HarnessObservationDelta(
                    facts: [
                        "state.verify.criteria": "inferred:priorActionEvidence",
                        "state.verify.verified": String(verified),
                        "lastAcceptedTool": context.call.name
                    ],
                    uncertainty: verified ? [] : ["no explicit criteria and no successful prior action to verify against"]
                ),
                metadata: ["verified": String(verified), "criteria.inferred": "true"]
            )
        }
        // Keep the machine-only keys out of the evidence the planner reads (the `workspace` summary fact,
        // which lists produced files, still counts).
        let evidence = (
            context.worldModel.modelFacingFacts
                .map { "\($0.key): \($0.value)" }
                + context.worldModel.visibleText.map { "\($0.key): \($0.value)" }
                + context.worldModel.attemptedToolCalls.map { "\($0.call.name): \($0.summary)" }
        ).joined(separator: "\n")
        let verified = evidenceMatches(criteria: criteria, evidence: evidence)
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: verified ? .succeeded : .failed,
            summary: verified ? "Verification succeeded." : "Verification did not find matching evidence.",
            observations: HarnessObservationDelta(
                facts: [
                    "state.verify.criteria": criteria,
                    "state.verify.verified": String(verified),
                    "lastAcceptedTool": context.call.name
                ],
                uncertainty: verified ? [] : ["verification evidence did not satisfy criteria"]
            ),
            metadata: ["verified": String(verified)]
        )
    }

    private static func lifecycle(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        success(
            context,
            summary: "Lifecycle operation accepted: \(context.call.name).",
            facts: [
                "lifecycle.lastOperation": context.call.name,
                "lifecycle.reason": context.call.input["reason"] ?? "",
                "lastAcceptedTool": context.call.name
            ],
            metadata: ["lifecycleOperation": context.call.name]
        )
    }

    // MARK: - Result Helpers

    private static func success(
        _ context: HarnessToolExecutionContext,
        summary: String,
        facts: [String: String],
        metadata: [String: String] = [:]
    ) -> HarnessToolResult {
        HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .succeeded,
            summary: summary,
            observations: HarnessObservationDelta(facts: facts),
            metadata: metadata.merging(["executor": "builtInGeneric"]) { current, _ in current }
        )
    }

    private static func failed(
        _ context: HarnessToolExecutionContext,
        _ summary: String,
        reason: String,
        metadata: [String: String] = [:]
    ) -> HarnessToolResult {
        HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .failed,
            summary: summary,
            metadata: metadata.merging([
                "executor": "builtInGeneric",
                "reason": reason
            ]) { _, reserved in reserved }
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
            metadata: [
                "executor": "builtInGeneric",
                "reason": "invalidInput"
            ]
        )
    }

    // MARK: - Utility

    private static func scopedElements(_ context: HarnessToolExecutionContext) -> [HarnessWorldElement] {
        guard let scope = trimmed(context.call.input["scope"]) else {
            return context.worldModel.elements
        }
        let scopeTokens = tokens(in: scope)
        guard !scopeTokens.isEmpty else { return context.worldModel.elements }
        return context.worldModel.elements.filter { element in
            matches(tokens: scopeTokens, values: [element.id, element.label, element.role] + Array(element.metadata.values))
        }
    }

    private static func actionAllowed(_ action: String, elementActions: [String]) -> Bool {
        let normalizedAction = normalized(action)
        let aliases: [String: Set<String>] = [
            "press": ["press", "axpress"],
            "click": ["click", "press", "axpress"],
            "focus": ["focus", "axraise"],
            "setvalue": ["setvalue", "axsetvalue"],
            "scroll": ["scroll", "axscroll"]
        ]
        let accepted = aliases[normalizedAction] ?? [normalizedAction]
        let available = Set(elementActions.map(normalized))
        return !accepted.isDisjoint(with: available)
    }

    private static func safeExplorationAction(for element: HarnessWorldElement) -> String? {
        let safety = normalized(element.metadata["learning.explorationSafety"] ?? element.metadata["safetyClass"] ?? "")
        if ["destructive", "sensitive", "requiresapproval"].contains(safety) {
            return nil
        }
        let actions = Set(element.actions.map(normalized))
        if safety == "safe" || safety == "reversible" || safety == "readonly" {
            if !actions.isDisjoint(with: ["focus", "axraise"]) { return "focus" }
            if !actions.isDisjoint(with: ["press", "axpress"]) { return "press" }
            if !actions.isDisjoint(with: ["scroll", "axscroll"]) { return "scroll" }
        }

        let role = normalized(element.role)
        let reversibleRoles: Set<String> = [
            "axmenu",
            "axmenubaritem",
            "axmenuitem",
            "axpopupbutton",
            "axtab",
            "axtabgroup",
            "axdisclosuretriangle"
        ]
        if reversibleRoles.contains(role),
           !actions.isDisjoint(with: ["press", "axpress"]) {
            return "press"
        }
        if !actions.isDisjoint(with: ["focus", "axraise"]) {
            return "focus"
        }
        if !actions.isDisjoint(with: ["scroll", "axscroll"]) {
            return "scroll"
        }
        return nil
    }

    private static func evidenceMatches(criteria: String, evidence: String) -> Bool {
        let normalizedCriteria = normalized(criteria)
        let normalizedEvidence = normalized(evidence)
        guard !normalizedCriteria.isEmpty, !normalizedEvidence.isEmpty else { return false }
        if normalizedEvidence.contains(normalizedCriteria) { return true }
        let criteriaTokens = tokens(in: criteria)
        guard !criteriaTokens.isEmpty else { return false }
        return criteriaTokens.allSatisfy { normalizedEvidence.contains($0) }
    }

    private static func matches(tokens: [String], values: [String]) -> Bool {
        guard !tokens.isEmpty else { return true }
        let haystack = normalized(values.joined(separator: " "))
        return tokens.allSatisfy { haystack.contains($0) }
    }

    private static func generatedLanguage(_ value: String?) -> HarnessGeneratedScriptLanguage? {
        switch normalized(value ?? "") {
        case "applescript", "apple script":
            return .appleScript
        case "shell", "bash", "sh":
            return .shell
        case "javascript", "js":
            return .javaScript
        case "python", "py":
            return .python
        case "swift":
            return .swift
        default:
            return nil
        }
    }

    private static func stableIDSeed(from value: String) -> String {
        let slug = normalized(value)
            .split(separator: " ")
            .prefix(6)
            .joined(separator: "-")
        return slug.isEmpty ? UUID().uuidString : slug
    }

    private static func listValues(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .split { character in
                character == "," || character == "\n" || character == ";"
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func tokens(in value: String) -> [String] {
        normalized(value)
            .split(separator: " ")
            .map(String.init)
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .map { character in
                character.isLetter || character.isNumber ? character : " "
            }
            .reduce(into: "") { result, character in
                if character == " ", result.last == " " {
                    return
                }
                result.append(character)
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit))
    }

    private static func jsonString<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }
}
