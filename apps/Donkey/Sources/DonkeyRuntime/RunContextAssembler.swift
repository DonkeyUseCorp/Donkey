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
        recentFailures: [RunFailureSummary] = [],
        memorySnapshot: RunMemorySnapshot? = nil
    ) -> RunContextPackage {
        let boundedTranscript = bounded(transcriptSummary)
        let validHints = activeHints.filter(\.isValid)

        return RunContextPackage(
            sessionID: session.id,
            userGoal: session.userGoal,
            targetID: session.targetID,
            runtimeProfile: session.runtimeProfile,
            latestWorldState: latestWorldState,
            transcriptSummary: boundedTranscript.text,
            droppedTranscriptCharacterCount: boundedTranscript.droppedCount,
            activeHints: validHints,
            recentFailures: recentFailures,
            memorySnapshot: boundedMemorySnapshot(memorySnapshot, fallbackHints: validHints, fallbackFailures: recentFailures)
        )
    }

    private func bounded(_ text: String) -> (text: String, droppedCount: Int) {
        guard text.count > maxTranscriptCharacters else {
            return (text, 0)
        }

        let suffix = String(text.suffix(maxTranscriptCharacters))
        return (suffix, text.count - suffix.count)
    }

    private func boundedMemorySnapshot(
        _ snapshot: RunMemorySnapshot?,
        fallbackHints: [RunPlannerHint],
        fallbackFailures: [RunFailureSummary]
    ) -> RunMemorySnapshot? {
        guard var snapshot else { return nil }

        snapshot.activeHints = snapshot.activeHints.filter(\.isValid)
        if snapshot.activeHints.isEmpty {
            snapshot.activeHints = fallbackHints
        }
        if snapshot.recentFailures.isEmpty {
            snapshot.recentFailures = fallbackFailures
        }

        snapshot.recentStates = Array(snapshot.recentStates.suffix(5))
        snapshot.recentFailures = Array(snapshot.recentFailures.suffix(5))
        snapshot.userInstructions = Array(snapshot.userInstructions.suffix(5))
        snapshot.safetyStops = Array(snapshot.safetyStops.suffix(5))
        snapshot.targetRecords = Array(snapshot.targetRecords.suffix(10))

        return snapshot
    }
}
