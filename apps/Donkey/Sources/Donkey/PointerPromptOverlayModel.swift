import DonkeyAI
import DonkeyContracts
import Foundation
import SwiftUI

@MainActor
final class PointerPromptOverlayModel: ObservableObject, PointerPromptIntentSink {
    @Published private(set) var promptState: PointerPromptState
    @Published var messageText = ""
    @Published var placement: PointerPromptPlacement = .bottomRight
    @Published var inputTextHeight = PointerPromptLayout.composerInputTextMinimumHeight
    @Published var isInputExpanded = false
    @Published var notchCommandText = ""
    @Published private(set) var notchCommandInputTextHeight = PointerPromptLayout.composerInputTextMinimumHeight
    @Published private(set) var isNotchCommandInputExpanded = true
    @Published private(set) var notchAccentIndex = Int.random(in: 0..<8)
    @Published private(set) var isCurrentTaskPaused = false
    @Published private(set) var updateState: PointerPromptUpdateState

    private let commandHandler: any PointerPromptCommandHandling
    private let voiceTranscriber: LocalVoiceTranscriptionAdapter
    private var updateChecker: any DonkeyUpdateChecking
    private let documentReviewController: DocumentFormFillReviewWindowController

    init(
        aiProvider: any AIHarnessSnapshotProviding = AIHarnessBoundary(),
        commandHandler: any PointerPromptCommandHandling = LocalAppPointerPromptCommandHandler(),
        voiceTranscriber: LocalVoiceTranscriptionAdapter = LocalVoiceTranscriptionAdapter(
            runtime: ProcessBackedParakeetTranscriptionRuntime()
        ),
        updateChecker: any DonkeyUpdateChecking = SparkleUpdateController(),
        documentReviewController: DocumentFormFillReviewWindowController = DocumentFormFillReviewWindowController(),
        theme: PointerPromptTheme = PointerPromptOverlayModel.bundledTheme()
    ) {
        self.commandHandler = commandHandler
        self.voiceTranscriber = voiceTranscriber
        self.updateChecker = updateChecker
        self.documentReviewController = documentReviewController
        updateState = PointerPromptUpdateState(
            currentVersion: updateChecker.currentVersion
        )
        let aiSnapshot = aiProvider.snapshot()
        promptState = PointerPromptState(
            promptText: aiSnapshot.suggestedPromptText,
            isPrimaryActionEnabled: true,
            leadingSignalLevel: .idle,
            isActive: false,
            theme: theme
        )
        self.updateChecker.updateStateChanged = { [weak self] state in
            self?.updateState = state
        }
        updateChecker.start()
        checkForUpdates()
    }

    func activate() {
        promptState.isActive = true
        promptState.isPrimaryActionEnabled = true
        promptState.leadingSignalLevel = .ready
    }

    func updateVoiceWaveformLevels(_ levels: [Double]) {
        let normalizedLevels = levels.map { min(max($0, 0), 1) }
        guard promptState.voiceWaveformLevels != normalizedLevels else { return }

        promptState.voiceWaveformLevels = normalizedLevels
    }

    func checkForUpdates() {
        updateChecker.checkForUpdatesInBackground()
    }

    func showUpdateUI() {
        updateChecker.showUpdateUI()
    }

    func handle(_ intent: PointerPromptIntent) {
        switch intent {
        case .addContextRequested:
            promptState.leadingSignalLevel = .ready
        case .voiceInputRequested:
            promptState.leadingSignalLevel = .ready
            promptState.promptText = "Listening..."
        case .primaryActionRequested:
            isCurrentTaskPaused = false
            promptState.leadingSignalLevel = .thinking
        case .messageSubmitted(let text):
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { return }

            submitCommand(trimmedText)
        case .inputTextHeightChanged(let height):
            let clampedHeight = PointerPromptLayout.clampedComposerInputTextHeight(height)
            guard abs(inputTextHeight - clampedHeight) > 0.5 else { return }
            inputTextHeight = clampedHeight
        case .inputExpansionChanged(let isExpanded):
            let shouldExpand = !messageText.isEmpty && (isExpanded || messageText.contains("\n"))
            guard isInputExpanded != shouldExpand else { return }
            isInputExpanded = shouldExpand
        case .dismissed:
            promptState.isPrimaryActionEnabled = false
            promptState.isActive = false
        }
    }

    func submitVoiceAudio(_ audio: LocalVoiceAudioBuffer?) {
        guard let audio else {
            promptState.leadingSignalLevel = .idle
            promptState.promptText = "No voice captured"
            return
        }

        let sourceTraceID = "pointer-prompt-voice-\(UUID().uuidString)"
        promptState.leadingSignalLevel = .thinking
        promptState.promptText = "Transcribing..."
        Task { [weak self, voiceTranscriber] in
            let result = await voiceTranscriber.transcribe(
                LocalVoiceTranscriptionRequest(
                    audio: audio,
                    sourceTraceID: sourceTraceID
                )
            )
            await MainActor.run {
                guard let self else { return }
                guard let transcript = result.transcript,
                      !transcript.text.isEmpty else {
                    self.promptState.leadingSignalLevel = .idle
                    self.promptState.promptText = "Voice unavailable"
                    return
                }

                self.messageText = transcript.text
                self.submitCommand(transcript.text)
            }
        }
    }

    private func submitCommand(_ text: String) {
        let taskLabel = Self.taskLabel(for: text)
        messageText = ""
        inputTextHeight = PointerPromptLayout.composerInputTextMinimumHeight
        isInputExpanded = false
        notchCommandText = ""
        notchCommandInputTextHeight = PointerPromptLayout.composerInputTextMinimumHeight
        isNotchCommandInputExpanded = true
        isCurrentTaskPaused = false
        notchAccentIndex = Self.nextAccentIndex(after: notchAccentIndex)
        promptState.isActive = false
        promptState.leadingSignalLevel = .thinking
        promptState.promptText = taskLabel
        Task { [weak self, commandHandler] in
            let result = await commandHandler.handleSubmittedCommand(text)
            await MainActor.run {
                guard let self else { return }
                self.isCurrentTaskPaused = false
                self.promptState.leadingSignalLevel = result.status == .completed ? .ready : .idle
                self.promptState.promptText = result.taskLabel ?? result.summary
                if let documentReviewRequest = result.documentReviewRequest {
                    self.documentReviewController.show(request: documentReviewRequest)
                }
            }
        }
    }

    func pauseCurrentTask() {
        guard promptState.leadingSignalLevel == .thinking,
              !isCurrentTaskPaused else {
            return
        }

        isCurrentTaskPaused = true
        Task { [commandHandler] in
            await commandHandler.pauseCurrentCommand()
        }
    }

    func resumeCurrentTask() {
        guard isCurrentTaskPaused else { return }

        isCurrentTaskPaused = false
        Task { [commandHandler] in
            await commandHandler.resumeCurrentCommand()
        }
    }

    func updateNotchCommandInputTextHeight(_ height: CGFloat) {
        let clampedHeight = PointerPromptLayout.clampedComposerInputTextHeight(height)
        guard abs(notchCommandInputTextHeight - clampedHeight) > 0.5 else { return }

        notchCommandInputTextHeight = clampedHeight
    }

    func updateNotchCommandInputExpansion(_ isExpanded: Bool) {
        let shouldExpand = true
        guard isNotchCommandInputExpanded != shouldExpand else { return }

        isNotchCommandInputExpanded = shouldExpand
    }

    var notchCommandInputSurfaceHeight: CGFloat {
        max(92, notchCommandInputTextHeight + 60)
    }

    private static func nextAccentIndex(after currentIndex: Int) -> Int {
        let accentCount = 8
        var nextIndex = Int.random(in: 0..<accentCount)
        if nextIndex == currentIndex {
            nextIndex = (nextIndex + 1) % accentCount
        }
        return nextIndex
    }

    private static func taskLabel(for text: String) -> String {
        let collapsed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return "New task" }

        let maxLength = 44
        guard collapsed.count > maxLength else { return collapsed }

        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: maxLength)
        return String(collapsed[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func bundledTheme() -> PointerPromptTheme {
        guard let themeURL = Bundle.module.url(forResource: "theme", withExtension: "json"),
              let themeData = try? Data(contentsOf: themeURL),
              let themeConfig = try? JSONDecoder().decode(PointerPromptThemeConfig.self, from: themeData),
              let theme = PointerPromptTheme.fromConfig(themeConfig) else {
            return .defaultBlue
        }

        return theme
    }
}
