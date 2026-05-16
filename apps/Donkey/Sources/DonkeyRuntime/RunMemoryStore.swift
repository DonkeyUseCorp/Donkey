import DonkeyContracts
import Foundation

public enum TargetMemoryStoreError: Error, Equatable, Sendable {
    case invalidIdentifier(String)
    case missingScopeTarget
    case writeNotApproved([RunMemoryApprovalIssue])
}

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

public actor TargetMemoryJSONLStore {
    private let baseDirectory: URL
    private let fileManager: FileManager

    public init(
        baseDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        self.baseDirectory = try baseDirectory ?? Self.defaultBaseDirectory(fileManager: fileManager)
    }

    public static func defaultBaseDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )

        return applicationSupport
            .appendingPathComponent("Donkey", isDirectory: true)
            .appendingPathComponent("TargetMemory", isDirectory: true)
    }

    @discardableResult
    public func appendApprovedProposal(
        _ proposal: RunMemoryWriteProposal,
        decidedAt: RunTraceTimestamp
    ) throws -> RunMemoryWriteDecision {
        let approval = RunMemoryApprover.evaluate(proposal, decidedAt: decidedAt)
        guard approval.approved else {
            return RunMemoryWriteDecision(
                proposal: proposal,
                approval: approval,
                storedRecord: nil
            )
        }

        let record = proposal.record
        guard record.scope == .target else {
            throw TargetMemoryStoreError.missingScopeTarget
        }
        guard let targetID = record.targetID else {
            throw TargetMemoryStoreError.missingScopeTarget
        }

        try validateIdentifier(targetID)
        try validateIdentifier(record.id)
        try fileManager.createDirectory(
            at: targetDirectory(for: targetID),
            withIntermediateDirectories: true
        )

        var line = try Self.encoder().encode(record)
        line.append(0x0A)

        let url = memoryURL(for: targetID)
        if !fileManager.fileExists(atPath: url.path) {
            try Data().write(to: url, options: .atomic)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)

        return RunMemoryWriteDecision(
            proposal: proposal,
            approval: approval,
            storedRecord: record
        )
    }

    public func records(
        targetID: String,
        now: RunTraceTimestamp? = nil
    ) throws -> [RunMemoryRecord] {
        try validateIdentifier(targetID)
        let url = memoryURL(for: targetID)
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }

        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        return try text
            .split(separator: "\n")
            .map { line in
                try Self.decoder().decode(
                    RunMemoryRecord.self,
                    from: Data(line.utf8)
                )
            }
            .filter { record in
                guard let now else { return true }
                return !record.isExpired(at: now)
            }
    }

    public func records(
        targetID: String,
        runID: String? = nil,
        userID: String? = nil,
        now: RunTraceTimestamp? = nil
    ) throws -> [RunMemoryRecord] {
        if let runID {
            try validateIdentifier(runID)
        }
        if let userID {
            try validateIdentifier(userID)
        }

        return try records(targetID: targetID, now: now).filter { record in
            if let runID, record.runID != runID { return false }
            if let userID, record.userID != userID { return false }
            return true
        }
    }

    @discardableResult
    public func delete(
        targetID: String,
        recordID: String? = nil,
        runID: String? = nil,
        userID: String? = nil
    ) throws -> Int {
        try validateIdentifier(targetID)
        if let recordID {
            try validateIdentifier(recordID)
        }
        if let runID {
            try validateIdentifier(runID)
        }
        if let userID {
            try validateIdentifier(userID)
        }

        let url = memoryURL(for: targetID)
        guard fileManager.fileExists(atPath: url.path) else {
            return 0
        }

        let existing = try records(targetID: targetID)
        let remaining = existing.filter { record in
            if let recordID, record.id == recordID { return false }
            if let runID, record.runID == runID { return false }
            if let userID, record.userID == userID { return false }
            return true
        }
        let deletedCount = existing.count - remaining.count

        var data = Data()
        for record in remaining {
            var line = try Self.encoder().encode(record)
            line.append(0x0A)
            data.append(line)
        }
        try data.write(to: url, options: .atomic)

        return deletedCount
    }

    private func targetDirectory(for targetID: String) -> URL {
        baseDirectory.appendingPathComponent(targetID, isDirectory: true)
    }

    private func memoryURL(for targetID: String) -> URL {
        targetDirectory(for: targetID).appendingPathComponent("memory.jsonl", isDirectory: false)
    }

    private func validateIdentifier(_ value: String) throws {
        let allowedScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let isSafe = !value.isEmpty
            && value.count <= 128
            && value != "."
            && value != ".."
            && value.unicodeScalars.allSatisfy { allowedScalars.contains($0) }

        guard isSafe else {
            throw TargetMemoryStoreError.invalidIdentifier(value)
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        JSONDecoder()
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
