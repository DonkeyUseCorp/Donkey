import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation
import SwiftUI

@MainActor
final class PointerPromptOverlayModel: ObservableObject, PointerPromptIntentSink {
    @Published private(set) var promptState: PointerPromptState
    @Published var messageText = ""
    @Published var placement: PointerPromptPlacement = .bottomRight
    @Published var inputTextHeight = PointerPromptLayout.composerInputTextMinimumHeight

    private let runtimeProvider: any RuntimeStatusProviding
    private let aiProvider: any AIHarnessSnapshotProviding

    init(
        runtimeProvider: any RuntimeStatusProviding = OffTheShelfRunLoopBoundary(),
        aiProvider: any AIHarnessSnapshotProviding = AIHarnessBoundary(),
        theme: PointerPromptTheme = PointerPromptOverlayModel.bundledTheme()
    ) {
        self.runtimeProvider = runtimeProvider
        self.aiProvider = aiProvider

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
            promptState.leadingSignalLevel = .thinking
        case .inputTextHeightChanged(let height):
            let clampedHeight = max(PointerPromptLayout.composerInputTextMinimumHeight, height)
            guard abs(inputTextHeight - clampedHeight) > 0.5 else { return }
            inputTextHeight = clampedHeight
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
