import AVFoundation
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
            let text = try await Self.runSpeechAnalyzer(fileURL: fileURL, locale: resolved)
            return try Self.transcript(
                text: text,
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
    private static func runSpeechAnalyzer(fileURL: URL, locale: Locale) async throws -> String {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
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
        return String(attributed.characters)
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
    ) async throws -> (text: String, language: String) {
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

        let text: String = try await withCheckedThrowingContinuation { continuation in
            let resume = SingleResume(continuation)
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    resume.fail(error)
                    return
                }
                guard let result, result.isFinal else { return }
                resume.succeed(result.bestTranscription.formattedString)
            }
            // SFSpeechRecognizer can stall without ever invoking the handler; bound it
            // so a hung recognition throws and falls through to Gemini instead of
            // leaving the UI stuck on "Transcribing…".
            resume.start(task: task, timeoutMS: timeoutMS)
        }
        return (text, recognizer.locale.identifier)
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
    private final class SingleResume: @unchecked Sendable {
        private let continuation: CheckedContinuation<String, Error>
        private let lock = NSLock()
        private var resumed = false
        private var task: SFSpeechRecognitionTask?
        private var timeoutTask: Task<Void, Never>?

        init(_ continuation: CheckedContinuation<String, Error>) {
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

        func succeed(_ value: String) { finish(.success(value)) }

        func fail(_ error: Error) { finish(.failure(error)) }

        private func finish(_ result: Result<String, Error>) {
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
