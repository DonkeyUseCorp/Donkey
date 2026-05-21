import DonkeyContracts
import Foundation

public actor InMemoryRunMemory {
    private let runID: String
    private let targetID: String
    private let capacity: Int
    private var currentGoal: String?
    private var activeHints: [RunPlannerHint] = []
    private var recentStates: [RunWorldStateSummary] = []
    private var recentFailures: [RunFailureSummary] = []
    private var records: [RunMemoryRecord] = []

    public init(
        runID: String,
        targetID: String,
        currentGoal: String? = nil,
        capacity: Int = 20
    ) {
        self.runID = runID
        self.targetID = targetID
        self.currentGoal = currentGoal
        self.capacity = max(1, capacity)
    }

    public func updateGoal(_ goal: String?) {
        currentGoal = goal
    }

    public func setActiveHints(_ hints: [RunPlannerHint]) {
        activeHints = Array(hints.filter(\.isValid).suffix(capacity))
    }

    public func rememberState(_ state: RunWorldStateSummary) {
        recentStates.append(state)
        recentStates = Array(recentStates.suffix(capacity))
    }

    public func rememberFailure(_ failure: RunFailureSummary) {
        recentFailures.append(failure)
        recentFailures = Array(recentFailures.suffix(capacity))
    }

    public func append(_ record: RunMemoryRecord) {
        records.append(record)
        records = Array(records.suffix(capacity))
    }

    public func delete(recordID: String) {
        records.removeAll { $0.id == recordID }
    }

    public func snapshot(now: RunTraceTimestamp? = nil) -> RunMemorySnapshot {
        let liveRecords = records.filter { record in
            guard let now else { return true }
            return !record.isExpired(at: now)
        }

        return RunMemorySnapshot(
            currentGoal: currentGoal,
            activeHints: activeHints,
            recentStates: Array(recentStates.suffix(capacity)),
            recentFailures: Array(recentFailures.suffix(capacity)),
            userInstructions: liveRecords.filtered(kind: .userInstruction, runID: runID, targetID: targetID),
            safetyStops: liveRecords.filtered(kind: .safetyStop, runID: runID, targetID: targetID),
            targetRecords: liveRecords.filter { $0.scope == .target && $0.targetID == targetID }
        )
    }
}

private extension Array where Element == RunMemoryRecord {
    func filtered(kind: RunMemoryKind, runID: String, targetID: String) -> [RunMemoryRecord] {
        filter { record in
            record.kind == kind
                && (record.runID == nil || record.runID == runID)
                && (record.targetID == nil || record.targetID == targetID)
        }
    }
}
