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

    private let commandHandler: any PointerPromptCommandHandling

    init(
        aiProvider: any AIHarnessSnapshotProviding = AIHarnessBoundary(),
        commandHandler: any PointerPromptCommandHandling = LocalAppPointerPromptCommandHandler(),
        theme: PointerPromptTheme = PointerPromptOverlayModel.bundledTheme()
    ) {
        self.commandHandler = commandHandler
        let aiSnapshot = aiProvider.snapshot()
        promptState = PointerPromptState(
            promptText: aiSnapshot.suggestedPromptText,
            isPrimaryActionEnabled: true,
            leadingSignalLevel: .idle,
            isActive: false,
            theme: theme
        )
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

    func handle(_ intent: PointerPromptIntent) {
        switch intent {
        case .addContextRequested:
            promptState.leadingSignalLevel = .ready
        case .voiceInputRequested:
            promptState.leadingSignalLevel = .ready
        case .primaryActionRequested:
            promptState.leadingSignalLevel = .thinking
        case .messageSubmitted(let text):
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { return }

            messageText = ""
            inputTextHeight = PointerPromptLayout.composerInputTextMinimumHeight
            isInputExpanded = false
            promptState.leadingSignalLevel = .thinking
            promptState.promptText = "Working..."
            Task { [weak self, commandHandler] in
                let result = await commandHandler.handleSubmittedCommand(trimmedText)
                await MainActor.run {
                    guard let self else { return }
                    self.promptState.leadingSignalLevel = result.status == .completed ? .ready : .idle
                    self.promptState.promptText = result.summary
                }
            }
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
