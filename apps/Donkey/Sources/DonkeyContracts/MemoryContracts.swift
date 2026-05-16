import Foundation

public enum RunMemoryScope: String, Codable, Equatable, Sendable {
    case run
    case target
    case user
}

public enum RunMemoryKind: String, Codable, Equatable, Sendable {
    case currentGoal
    case activeHint
    case recentState
    case failure
    case userInstruction
    case safetyStop
    case targetFact
}

public enum RunMemoryAuthor: String, Codable, Equatable, Sendable {
    case deterministicRuntime
    case user
    case model
}

public struct RunMemorySource: Codable, Equatable, Sendable {
    public var traceID: String?
    public var frameID: String?
    public var stateID: String?
    public var actionID: String?
    public var plannerHintID: String?
    public var modelCallID: String?
    public var eventSequence: Int?
    public var summary: String

    public init(
        traceID: String? = nil,
        frameID: String? = nil,
        stateID: String? = nil,
        actionID: String? = nil,
        plannerHintID: String? = nil,
        modelCallID: String? = nil,
        eventSequence: Int? = nil,
        summary: String
    ) {
        self.traceID = traceID
        self.frameID = frameID
        self.stateID = stateID
        self.actionID = actionID
        self.plannerHintID = plannerHintID
        self.modelCallID = modelCallID
        self.eventSequence = eventSequence
        self.summary = summary
    }

    public var isLinked: Bool {
        traceID != nil
            || frameID != nil
            || stateID != nil
            || actionID != nil
            || plannerHintID != nil
            || modelCallID != nil
            || eventSequence != nil
    }
}

public struct RunMemoryRecord: Codable, Equatable, Sendable {
    public var id: String
    public var scope: RunMemoryScope
    public var kind: RunMemoryKind
    public var targetID: String?
    public var runID: String?
    public var userID: String?
    public var value: String
    public var createdAt: RunTraceTimestamp
    public var expiresAt: RunTraceTimestamp?
    public var durable: Bool
    public var source: RunMemorySource
    public var metadata: [String: String]

    public init(
        id: String,
        scope: RunMemoryScope,
        kind: RunMemoryKind,
        targetID: String? = nil,
        runID: String? = nil,
        userID: String? = nil,
        value: String,
        createdAt: RunTraceTimestamp,
        expiresAt: RunTraceTimestamp? = nil,
        durable: Bool = false,
        source: RunMemorySource,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.scope = scope
        self.kind = kind
        self.targetID = targetID
        self.runID = runID
        self.userID = userID
        self.value = value
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.durable = durable
        self.source = source
        self.metadata = metadata
    }

    public func isExpired(at timestamp: RunTraceTimestamp) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.milliseconds(until: timestamp) != nil
    }

    public var hasRequiredRetention: Bool {
        expiresAt != nil || durable
    }
}

public enum RunMemoryApprovalIssue: String, Codable, Equatable, Sendable {
    case emptyValue
    case missingSourceLink
    case missingTargetID
    case missingRunID
    case missingUserID
    case missingRetention
    case unsupportedScope
}

public struct RunMemoryWriteProposal: Codable, Equatable, Sendable {
    public var id: String
    public var proposedBy: RunMemoryAuthor
    public var record: RunMemoryRecord
    public var rationale: String

    public init(
        id: String,
        proposedBy: RunMemoryAuthor,
        record: RunMemoryRecord,
        rationale: String
    ) {
        self.id = id
        self.proposedBy = proposedBy
        self.record = record
        self.rationale = rationale
    }
}

public struct RunMemoryWriteApproval: Codable, Equatable, Sendable {
    public var proposalID: String
    public var approved: Bool
    public var issues: [RunMemoryApprovalIssue]
    public var decidedAt: RunTraceTimestamp
    public var approver: String

    public init(
        proposalID: String,
        approved: Bool,
        issues: [RunMemoryApprovalIssue],
        decidedAt: RunTraceTimestamp,
        approver: String = "deterministic-memory-approver-v1"
    ) {
        self.proposalID = proposalID
        self.approved = approved
        self.issues = issues
        self.decidedAt = decidedAt
        self.approver = approver
    }
}

public struct RunMemoryWriteDecision: Codable, Equatable, Sendable {
    public var proposal: RunMemoryWriteProposal
    public var approval: RunMemoryWriteApproval
    public var storedRecord: RunMemoryRecord?

    public init(
        proposal: RunMemoryWriteProposal,
        approval: RunMemoryWriteApproval,
        storedRecord: RunMemoryRecord?
    ) {
        self.proposal = proposal
        self.approval = approval
        self.storedRecord = storedRecord
    }
}

public struct RunMemorySnapshot: Codable, Equatable, Sendable {
    public var currentGoal: String?
    public var activeHints: [RunPlannerHint]
    public var recentStates: [RunWorldStateSummary]
    public var recentFailures: [RunFailureSummary]
    public var userInstructions: [RunMemoryRecord]
    public var safetyStops: [RunMemoryRecord]
    public var targetRecords: [RunMemoryRecord]

    public init(
        currentGoal: String? = nil,
        activeHints: [RunPlannerHint] = [],
        recentStates: [RunWorldStateSummary] = [],
        recentFailures: [RunFailureSummary] = [],
        userInstructions: [RunMemoryRecord] = [],
        safetyStops: [RunMemoryRecord] = [],
        targetRecords: [RunMemoryRecord] = []
    ) {
        self.currentGoal = currentGoal
        self.activeHints = activeHints
        self.recentStates = recentStates
        self.recentFailures = recentFailures
        self.userInstructions = userInstructions
        self.safetyStops = safetyStops
        self.targetRecords = targetRecords
    }
}

public enum RunMemoryApprover {
    public static func evaluate(
        _ proposal: RunMemoryWriteProposal,
        decidedAt: RunTraceTimestamp
    ) -> RunMemoryWriteApproval {
        var issues: [RunMemoryApprovalIssue] = []
        let record = proposal.record

        if record.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.emptyValue)
        }

        if !record.source.isLinked {
            issues.append(.missingSourceLink)
        }

        switch record.scope {
        case .run:
            if record.runID == nil {
                issues.append(.missingRunID)
            }
        case .target:
            if record.targetID == nil {
                issues.append(.missingTargetID)
            }
            if !record.hasRequiredRetention {
                issues.append(.missingRetention)
            }
        case .user:
            if record.userID == nil {
                issues.append(.missingUserID)
            }
            if !record.hasRequiredRetention {
                issues.append(.missingRetention)
            }
        }

        return RunMemoryWriteApproval(
            proposalID: proposal.id,
            approved: issues.isEmpty,
            issues: Array(Set(issues)).sorted { $0.rawValue < $1.rawValue },
            decidedAt: decidedAt
        )
    }
}
