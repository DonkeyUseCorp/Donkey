import DonkeyContracts
import Foundation

public struct RunContextAssembler: Equatable, Sendable {
    public var maxTranscriptCharacters: Int

    public init(maxTranscriptCharacters: Int = 2_000) {
        self.maxTranscriptCharacters = max(0, maxTranscriptCharacters)
    }

    public func build(
        session: RunSession,
        latestWorldState: RunWorldStateSummary? = nil,
        transcriptSummary: String = "",
        activeHints: [RunPlannerHint] = [],
        recentFailures: [RunFailureSummary] = []
    ) -> RunContextPackage {
        let boundedTranscript = bounded(transcriptSummary)

        return RunContextPackage(
            sessionID: session.id,
            userGoal: session.userGoal,
            targetID: session.targetID,
            runtimeProfile: session.runtimeProfile,
            latestWorldState: latestWorldState,
            transcriptSummary: boundedTranscript.text,
            droppedTranscriptCharacterCount: boundedTranscript.droppedCount,
            activeHints: activeHints.filter(\.isValid),
            recentFailures: recentFailures
        )
    }

    private func bounded(_ text: String) -> (text: String, droppedCount: Int) {
        guard text.count > maxTranscriptCharacters else {
            return (text, 0)
        }

        let suffix = String(text.suffix(maxTranscriptCharacters))
        return (suffix, text.count - suffix.count)
    }
}
