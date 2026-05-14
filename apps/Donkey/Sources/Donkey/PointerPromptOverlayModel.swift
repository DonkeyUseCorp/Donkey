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

    private let runtimeProvider: any RuntimeStatusProviding
    private let aiProvider: any AIHarnessSnapshotProviding

    init(
        runtimeProvider: any RuntimeStatusProviding = OffTheShelfRunLoopBoundary(),
        aiProvider: any AIHarnessSnapshotProviding = AIHarnessBoundary(),
        theme: PointerPromptTheme = PointerPromptOverlayModel.configuredTheme()
    ) {
        self.runtimeProvider = runtimeProvider
        self.aiProvider = aiProvider

        let runtimeSnapshot = runtimeProvider.snapshot()
        let aiSnapshot = aiProvider.snapshot()
        promptState = PointerPromptState(
            promptText: aiSnapshot.suggestedPromptText,
            isPrimaryActionEnabled: true,
            leadingSignalLevel: runtimeSnapshot.isReady ? .ready : .idle,
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
        case .dismissed:
            promptState.isPrimaryActionEnabled = false
            promptState.isActive = false
        }
    }

    private static func configuredTheme() -> PointerPromptTheme {
        guard let hexColor = ProcessInfo.processInfo.environment["DONKEY_POINTER_ACCENT"],
              let color = PointerPromptColor(hexRGB: hexColor) else {
            return .defaultBlue
        }

        return .accent(color)
    }
}

private extension PointerPromptColor {
    init?(hexRGB: String) {
        let trimmed = hexRGB.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else {
            return nil
        }

        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0,
            alpha: 1
        )
    }
}
