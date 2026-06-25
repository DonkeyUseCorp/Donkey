import AVFoundation
import CoreMedia
import DonkeyAI
import Foundation
import Speech

/// On-device speech-to-text using Apple's local APIs, the preferred transcription
/// path. There are no network calls and audio never leaves the machine.
///
/// - macOS 26+: the modern `SpeechAnalyzer` / `SpeechTranscriber`, which transcribe
///   a whole audio file with an on-device locale model (downloaded on first use).
/// - macOS 14–25: `SFSpeechRecognizer` with `requiresOnDeviceRecognition`, the
///   on-device path available before SpeechAnalyzer shipped.
///
/// Any failure — model/recognizer unavailable, not authorized, or empty output —
/// is surfaced as a thrown error so the composing runtime can fall back to Gemini.
public struct AppleSpeechVoiceTranscriptionRuntime: LocalVoiceTranscriptionRuntime {
    public init() {}

    /// One spoken word with its measured time span (milliseconds from the start of the file). This is
    /// the timing both Apple paths already compute per run/segment — it used to be discarded.
    public struct TranscribedWord: Sendable {
        public let text: String
        public let startMS: Int
        public let endMS: Int
        public let confidence: Double
    }

    /// A full file transcript: the plain text plus the per-word timings the editing flow cuts against.
    public struct FileTranscript: Sendable {
        public let text: String
        public let words: [TranscribedWord]
        public let localeIdentifier: String
        public let backend: String
    }

    /// Transcribe a local audio file on-device into text *with per-word timings*. This is the same
    /// engine the voice path uses, but it keeps the word-level time ranges instead of flattening to a
    /// string. The file must be one the platform audio stack can open directly (wav/m4a/mp3/caf/aiff);
    /// for a video, extract compact audio first — a file it cannot read throws, and the caller surfaces
    /// that so the planner extracts audio and retries. Audio never leaves the machine.
    public func transcribeFile(
        at fileURL: URL,
        preferredLocale: Locale = .current
    ) async throws -> FileTranscript {
        if #available(macOS 26, *) {
            let resolved = try await Self.resolvedSpeechAnalyzerLocale(preferred: preferredLocale)
            let output = try await Self.runSpeechAnalyzer(fileURL: fileURL, locale: resolved)
            let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw LocalVoiceTranscriptionRuntimeError.emptyTranscript }
            return FileTranscript(
                text: text,
                words: output.words,
                localeIdentifier: resolved.identifier,
                backend: "apple-speechanalyzer"
            )
        }

        let result = try await Self.runLegacyRecognizer(
            fileURL: fileURL,
            preferred: preferredLocale,
            timeoutMS: 120_000
        )
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LocalVoiceTranscriptionRuntimeError.emptyTranscript }
        return FileTranscript(
            text: text,
            words: result.words,
            localeIdentifier: result.language,
            backend: "apple-sfspeech"
        )
    }

    /// Download the on-device locale model ahead of time so the first voice command
    /// doesn't pay a multi-second model install under the "Transcribing…" state.
    /// Fire-and-forget; failures are ignored (the live path retries and falls back).
    public static func prewarm() {
        Task.detached(priority: .utility) {
            if #available(macOS 26, *) {
                guard let locale = try? await resolvedSpeechAnalyzerLocale(preferred: Locale.current) else {
                    return
                }
                let transcriber = SpeechTranscriber(
                    locale: locale,
                    transcriptionOptions: [],
                    reportingOptions: [],
                    attributeOptions: []
                )
                try? await ensureModelInstalled(transcriber, locale: locale)
            }
        }
    }

    public func transcribe(
        audio: LocalVoiceAudioBuffer,
        model: AIModelRegistryEntry
    ) async throws -> LocalVoiceTranscript {
        let fileURL = try Self.writeTemporaryAudioFile(audio)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        if #available(macOS 26, *) {
            let resolved = try await Self.resolvedSpeechAnalyzerLocale(preferred: Locale.current)
            let output = try await Self.runSpeechAnalyzer(fileURL: fileURL, locale: resolved)
            return try Self.transcript(
                text: output.text,
                language: resolved.identifier,
                backend: "apple-speechanalyzer"
            )
        }

        let result = try await Self.runLegacyRecognizer(
            fileURL: fileURL,
            preferred: Locale.current,
            timeoutMS: model.timeoutMS
        )
        return try Self.transcript(
            text: result.text,
            language: result.language,
            backend: "apple-sfspeech"
        )
    }

    // MARK: - SpeechAnalyzer (macOS 26+)

    @available(macOS 26, *)
    private static func resolvedSpeechAnalyzerLocale(preferred: Locale) async throws -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        let supportedIDs = Set(supported.map { $0.identifier(.bcp47) })
        if supportedIDs.contains(preferred.identifier(.bcp47)) {
            return preferred
        }
        let english = Locale(identifier: "en-US")
        if supportedIDs.contains(english.identifier(.bcp47)) {
            return english
        }
        throw LocalVoiceTranscriptionRuntimeError.runtimeUnavailable("apple-speechanalyzer-locale-unsupported")
    }

    @available(macOS 26, *)
    private static func runSpeechAnalyzer(
        fileURL: URL,
        locale: Locale
    ) async throws -> (text: String, words: [TranscribedWord]) {
        // Ask the transcriber to attach an audio time range to every run so the result carries per-word
        // timing, not just text. Without this option the runs come back untimed.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        try await ensureModelInstalled(transcriber, locale: locale)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: fileURL)

        let collector = Task { () throws -> AttributedString in
            var text = AttributedString()
            for try await result in transcriber.results {
                text += result.text
            }
            return text
        }

        do {
            if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }

        let attributed = try await collector.value
        return (String(attributed.characters), words(from: attributed))
    }

    /// Walk the transcript's runs and turn each timed run into a word. Runs without an audio time range
    /// (or that are pure whitespace) are skipped, so the result is the spoken words with their spans.
    @available(macOS 26, *)
    private static func words(from attributed: AttributedString) -> [TranscribedWord] {
        var words: [TranscribedWord] = []
        for run in attributed.runs {
            guard let timeRange = run.audioTimeRange else { continue }
            let piece = String(attributed[run.range].characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            let startMS = max(0, Int((timeRange.start.seconds * 1000).rounded()))
            let endMS = max(startMS, Int((timeRange.end.seconds * 1000).rounded()))
            words.append(TranscribedWord(text: piece, startMS: startMS, endMS: endMS, confidence: 1))
        }
        return words
    }

    @available(macOS 26, *)
    private static func ensureModelInstalled(_ transcriber: SpeechTranscriber, locale: Locale) async throws {
        let installed = await SpeechTranscriber.installedLocales
        guard !installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            return
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    // MARK: - SFSpeechRecognizer (macOS 14–25)

    private static func runLegacyRecognizer(
        fileURL: URL,
        preferred: Locale,
        timeoutMS: Int
    ) async throws -> (text: String, language: String, words: [TranscribedWord]) {
        try await requestLegacyAuthorization()

        guard let recognizer = SFSpeechRecognizer(locale: preferred)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
            recognizer.isAvailable else {
            throw LocalVoiceTranscriptionRuntimeError.runtimeUnavailable("apple-sfspeech-unavailable")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw LocalVoiceTranscriptionRuntimeError.runtimeUnavailable("apple-sfspeech-no-on-device")
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        // Build the Sendable pieces (text + timed words) inside the recognition handler so a
        // non-Sendable SFTranscription never crosses into the continuation (Swift 6 data-race safety).
        let outcome: (text: String, words: [TranscribedWord]) = try await withCheckedThrowingContinuation { continuation in
            let resume = SingleResume(continuation)
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    resume.fail(error)
                    return
                }
                guard let result, result.isFinal else { return }
                let transcription = result.bestTranscription
                resume.succeed((transcription.formattedString, legacyWords(from: transcription)))
            }
            // SFSpeechRecognizer can stall without ever invoking the handler; bound it
            // so a hung recognition throws and falls through to Gemini instead of
            // leaving the UI stuck on "Transcribing…".
            resume.start(task: task, timeoutMS: timeoutMS)
        }
        return (outcome.text, recognizer.locale.identifier, outcome.words)
    }

    /// Map an SFSpeech transcription's per-segment timing into words. Called inside the recognition
    /// handler so only Sendable values cross the continuation boundary.
    private static func legacyWords(from transcription: SFTranscription) -> [TranscribedWord] {
        transcription.segments.compactMap { segment -> TranscribedWord? in
            let piece = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { return nil }
            let startMS = max(0, Int((segment.timestamp * 1000).rounded()))
            let endMS = max(startMS, Int(((segment.timestamp + segment.duration) * 1000).rounded()))
            let confidence = segment.confidence > 0 ? Double(segment.confidence) : 1
            return TranscribedWord(text: piece, startMS: startMS, endMS: endMS, confidence: confidence)
        }
    }

    private static func requestLegacyAuthorization() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard status == .authorized else {
                throw LocalVoiceTranscriptionRuntimeError.runtimeUnavailable("apple-sfspeech-unauthorized")
            }
        default:
            throw LocalVoiceTranscriptionRuntimeError.runtimeUnavailable("apple-sfspeech-unauthorized")
        }
    }

    /// Guards a checked continuation so the recognition handler — which can fire
    /// more than once, or not at all — resumes it exactly once, and enforces a
    /// timeout that cancels a stalled recognition.
    private final class SingleResume<Value: Sendable>: @unchecked Sendable {
        private let continuation: CheckedContinuation<Value, Error>
        private let lock = NSLock()
        private var resumed = false
        private var task: SFSpeechRecognitionTask?
        private var timeoutTask: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<Value, Error>) {
            self.continuation = continuation
        }

        func start(task: SFSpeechRecognitionTask, timeoutMS: Int) {
            lock.lock()
            if resumed {
                lock.unlock()
                task.cancel()
                return
            }
            self.task = task
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(1, timeoutMS)) * 1_000_000)
                self?.fail(LocalVoiceTranscriptionRuntimeError.runtimeUnavailable("apple-sfspeech-timeout"))
            }
            lock.unlock()
        }

        func succeed(_ value: Value) { finish(.success(value)) }

        func fail(_ error: Error) { finish(.failure(error)) }

        private func finish(_ result: Result<Value, Error>) {
            lock.lock()
            guard !resumed else {
                lock.unlock()
                return
            }
            resumed = true
            let task = self.task
            let timeoutTask = self.timeoutTask
            lock.unlock()

            // A failure (including timeout) means recognition isn't done; stop it so
            // it doesn't keep running after we've moved on.
            if case .failure = result {
                task?.cancel()
            }
            timeoutTask?.cancel()
            continuation.resume(with: result)
        }
    }

    // MARK: - Shared helpers

    private static func transcript(
        text: String,
        language: String,
        backend: String
    ) throws -> LocalVoiceTranscript {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalVoiceTranscriptionRuntimeError.emptyTranscript
        }
        return LocalVoiceTranscript(
            text: trimmed,
            language: language,
            confidence: 1,
            metadata: ["transcript.backend": backend]
        )
    }

    private static func writeTemporaryAudioFile(_ audio: LocalVoiceAudioBuffer) throws -> URL {
        let fileExtension = audio.format.lowercased()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("donkey-voice-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        try audio.data.write(to: url, options: .atomic)
        return url
    }
}
