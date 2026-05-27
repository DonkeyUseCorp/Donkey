import DonkeyContracts
import Foundation

public struct RunContextAssembler: Equatable, Sendable {
    public var maxTranscriptCharacters: Int
    public var maxSummaryCharacters: Int
    public var maxMemoryRecordCharacters: Int

    public init(
        maxTranscriptCharacters: Int = 2_000,
        maxSummaryCharacters: Int = 600,
        maxMemoryRecordCharacters: Int = 600
    ) {
        self.maxTranscriptCharacters = max(0, maxTranscriptCharacters)
        self.maxSummaryCharacters = max(80, maxSummaryCharacters)
        self.maxMemoryRecordCharacters = max(80, maxMemoryRecordCharacters)
    }

    public func build(
        session: RunSession,
        latestWorldState: RunWorldStateSummary? = nil,
        transcriptSummary: String = "",
        activeHints: [RunPlannerHint] = [],
        recentFailures: [RunFailureSummary] = [],
        memorySnapshot: RunMemorySnapshot? = nil,
        semanticMemoryResults: [RunMemorySemanticResult] = []
    ) -> RunContextPackage {
        let boundedTranscript = suffixBounded(transcriptSummary, maxCharacters: maxTranscriptCharacters)
        let validHints = activeHints.filter(\.isValid)

        return compact(
            RunContextPackage(
                sessionID: session.id,
                userGoal: session.userGoal,
                targetID: session.targetID,
                runtimeProfile: session.runtimeProfile,
                latestWorldState: latestWorldState,
                transcriptSummary: boundedTranscript.text,
                droppedTranscriptCharacterCount: boundedTranscript.droppedCount,
                activeHints: validHints,
                recentFailures: recentFailures,
                memorySnapshot: boundedMemorySnapshot(
                    memorySnapshot,
                    fallbackHints: validHints,
                    fallbackFailures: recentFailures
                ),
                semanticMemoryResults: boundedSemanticMemoryResults(semanticMemoryResults)
            )
        )
    }

    public func compact(_ context: RunContextPackage) -> RunContextPackage {
        var context = context
        context.latestWorldState = context.latestWorldState.map(boundedWorldState)
        context.activeHints = context.activeHints.map(boundedHint)
        context.recentFailures = context.recentFailures.map(boundedFailure)
        context.memorySnapshot = context.memorySnapshot.map { snapshot in
            boundedMemorySnapshot(
                snapshot,
                fallbackHints: context.activeHints,
                fallbackFailures: context.recentFailures
            ) ?? snapshot
        }
        context.semanticMemoryResults = boundedSemanticMemoryResults(context.semanticMemoryResults)
        return context
    }

    private func bounded(_ text: String, maxCharacters: Int) -> (text: String, droppedCount: Int) {
        guard text.count > maxCharacters else {
            return (text, 0)
        }

        let marker = "\n...[compacted]...\n"
        guard maxCharacters > marker.count + 2 else {
            let suffix = String(text.suffix(maxCharacters))
            return (suffix, text.count - suffix.count)
        }

        let contentCharacters = maxCharacters - marker.count
        let prefixCharacters = contentCharacters / 2
        let suffixCharacters = contentCharacters - prefixCharacters
        let prefixEnd = text.index(text.startIndex, offsetBy: prefixCharacters)
        let suffixStart = text.index(text.endIndex, offsetBy: -suffixCharacters)
        let compacted = String(text[..<prefixEnd]) + marker + String(text[suffixStart...])
        return (compacted, text.count - compacted.count)
    }

    private func suffixBounded(_ text: String, maxCharacters: Int) -> (text: String, droppedCount: Int) {
        guard text.count > maxCharacters else {
            return (text, 0)
        }

        let suffix = String(text.suffix(maxCharacters))
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
            .map(boundedWorldState)
        snapshot.recentFailures = Array(snapshot.recentFailures.suffix(5))
            .map(boundedFailure)
        snapshot.userInstructions = Array(snapshot.userInstructions.suffix(5))
            .map(boundedMemoryRecord)
        snapshot.safetyStops = Array(snapshot.safetyStops.suffix(5))
            .map(boundedMemoryRecord)
        snapshot.targetRecords = Array(snapshot.targetRecords.suffix(10))
            .map(boundedMemoryRecord)

        return snapshot
    }

    private func boundedSemanticMemoryResults(
        _ results: [RunMemorySemanticResult]
    ) -> [RunMemorySemanticResult] {
        var promptCharacters = 0
        var bounded: [RunMemorySemanticResult] = []
        for result in results.prefix(6) {
            let nextCharacters = promptCharacters + result.record.value.count
            guard nextCharacters <= 2_000 else { break }
            promptCharacters = nextCharacters
            bounded.append(result)
        }
        return bounded
    }

    private func boundedWorldState(_ state: RunWorldStateSummary) -> RunWorldStateSummary {
        let boundedSummary = bounded(state.summary, maxCharacters: maxSummaryCharacters)
        return RunWorldStateSummary(
            stateID: state.stateID,
            summary: boundedSummary.text,
            confidence: state.confidence
        )
    }

    private func boundedHint(_ hint: RunPlannerHint) -> RunPlannerHint {
        RunPlannerHint(
            id: hint.id,
            summary: bounded(hint.summary, maxCharacters: maxSummaryCharacters).text,
            isValid: hint.isValid
        )
    }

    private func boundedFailure(_ failure: RunFailureSummary) -> RunFailureSummary {
        RunFailureSummary(
            traceID: failure.traceID,
            summary: bounded(failure.summary, maxCharacters: maxSummaryCharacters).text
        )
    }

    private func boundedMemoryRecord(_ record: AgentMemoryRecord) -> AgentMemoryRecord {
        let boundedValue = bounded(record.value, maxCharacters: maxMemoryRecordCharacters)
        guard boundedValue.droppedCount > 0 else { return record }

        var record = record
        record.value = boundedValue.text
        record.metadata["compaction.truncated"] = "true"
        record.metadata["compaction.droppedCharacters"] = String(boundedValue.droppedCount)
        return record
    }
}
