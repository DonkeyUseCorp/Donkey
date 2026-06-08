import Foundation

public enum AgentMemoryScope: String, Codable, CaseIterable, Equatable, Sendable {
    case global
    case run
    case target
    case user
}

public enum AgentMemoryKind: String, Codable, CaseIterable, Equatable, Sendable {
    case localItem
    case negativeLookup
    case targetFact
    case userInstruction
    case safetyStop
    case workflowMemory
    case currentGoal
    case activeHint
    case recentState
    case failure
}

public enum AgentMemoryAuthor: String, Codable, CaseIterable, Equatable, Sendable {
    case deterministicRuntime
    case user
    case model
}

public struct AgentMemorySource: Codable, Equatable, Sendable {
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

public struct AgentMemoryEmbeddingMetadata: Codable, Equatable, Sendable {
    public var modelID: String
    public var dimensions: Int

    public init(modelID: String, dimensions: Int) {
        self.modelID = modelID
        self.dimensions = max(0, dimensions)
    }
}

public struct AgentMemoryRecord: Codable, Equatable, Sendable {
    public var id: String
    public var scope: AgentMemoryScope
    public var kind: AgentMemoryKind
    public var targetID: String?
    public var runID: String?
    public var userID: String?
    public var value: String
    public var createdAt: RunTraceTimestamp
    public var expiresAt: RunTraceTimestamp?
    public var durable: Bool
    public var source: AgentMemorySource
    public var metadata: [String: String]
    public var confidence: Double
    public var useCount: Int
    public var lastUsedAt: RunTraceTimestamp?
    public var embedding: AgentMemoryEmbeddingMetadata?

    public init(
        id: String,
        scope: AgentMemoryScope,
        kind: AgentMemoryKind,
        targetID: String? = nil,
        runID: String? = nil,
        userID: String? = nil,
        value: String,
        createdAt: RunTraceTimestamp,
        expiresAt: RunTraceTimestamp? = nil,
        durable: Bool = false,
        source: AgentMemorySource,
        metadata: [String: String] = [:],
        confidence: Double = 1,
        useCount: Int = 0,
        lastUsedAt: RunTraceTimestamp? = nil,
        embedding: AgentMemoryEmbeddingMetadata? = nil
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
        self.confidence = min(max(confidence, 0), 1)
        self.useCount = max(0, useCount)
        self.lastUsedAt = lastUsedAt
        self.embedding = embedding
    }

    public func isExpired(at timestamp: RunTraceTimestamp) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.milliseconds(until: timestamp) != nil
    }

    public var hasRequiredRetention: Bool {
        expiresAt != nil || durable
    }
}

public enum AgentMemoryApprovalIssue: String, Codable, CaseIterable, Equatable, Sendable {
    case emptyValue
    case missingSourceLink
    case missingTargetID
    case missingRunID
    case missingUserID
    case missingRetention
    case sensitiveContent
}

public struct AgentMemoryWriteProposal: Codable, Equatable, Sendable {
    public var id: String
    public var proposedBy: AgentMemoryAuthor
    public var record: AgentMemoryRecord
    public var rationale: String

    public init(
        id: String,
        proposedBy: AgentMemoryAuthor,
        record: AgentMemoryRecord,
        rationale: String
    ) {
        self.id = id
        self.proposedBy = proposedBy
        self.record = record
        self.rationale = rationale
    }
}

public struct AgentMemoryWriteApproval: Codable, Equatable, Sendable {
    public var proposalID: String
    public var approved: Bool
    public var issues: [AgentMemoryApprovalIssue]
    public var decidedAt: RunTraceTimestamp
    public var approver: String

    public init(
        proposalID: String,
        approved: Bool,
        issues: [AgentMemoryApprovalIssue],
        decidedAt: RunTraceTimestamp,
        approver: String = "deterministic-agent-memory-approver-v1"
    ) {
        self.proposalID = proposalID
        self.approved = approved
        self.issues = issues
        self.decidedAt = decidedAt
        self.approver = approver
    }
}

public struct AgentMemoryWriteDecision: Codable, Equatable, Sendable {
    public var proposal: AgentMemoryWriteProposal
    public var approval: AgentMemoryWriteApproval
    public var storedRecord: AgentMemoryRecord?

    public init(
        proposal: AgentMemoryWriteProposal,
        approval: AgentMemoryWriteApproval,
        storedRecord: AgentMemoryRecord?
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
    public var userInstructions: [AgentMemoryRecord]
    public var safetyStops: [AgentMemoryRecord]
    public var targetRecords: [AgentMemoryRecord]

    public init(
        currentGoal: String? = nil,
        activeHints: [RunPlannerHint] = [],
        recentStates: [RunWorldStateSummary] = [],
        recentFailures: [RunFailureSummary] = [],
        userInstructions: [AgentMemoryRecord] = [],
        safetyStops: [AgentMemoryRecord] = [],
        targetRecords: [AgentMemoryRecord] = []
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

public struct AgentMemoryRetrievalBudget: Codable, Equatable, Sendable {
    public var maxRecords: Int
    public var maxPromptCharacters: Int
    public var minRelevance: Double

    public init(
        maxRecords: Int = 6,
        maxPromptCharacters: Int = 2_000,
        minRelevance: Double = 0.2
    ) {
        self.maxRecords = max(0, maxRecords)
        self.maxPromptCharacters = max(0, maxPromptCharacters)
        self.minRelevance = min(max(minRelevance, 0), 1)
    }
}

public struct AgentMemoryQuery: Codable, Equatable, Sendable {
    public var text: String
    public var targetID: String?
    public var runID: String?
    public var userID: String?
    public var scope: AgentMemoryScope?
    public var kinds: [AgentMemoryKind]
    public var budget: AgentMemoryRetrievalBudget
    public var metadata: [String: String]

    public init(
        text: String,
        targetID: String? = nil,
        runID: String? = nil,
        userID: String? = nil,
        scope: AgentMemoryScope? = nil,
        kinds: [AgentMemoryKind] = [],
        budget: AgentMemoryRetrievalBudget = AgentMemoryRetrievalBudget(),
        metadata: [String: String] = [:]
    ) {
        self.text = text
        self.targetID = targetID
        self.runID = runID
        self.userID = userID
        self.scope = scope
        self.kinds = kinds
        self.budget = budget
        self.metadata = metadata
    }
}

public struct AgentMemorySearchResult: Codable, Equatable, Sendable {
    public var record: AgentMemoryRecord
    public var relevance: Double
    public var embeddingModelID: String?
    public var lexicalScore: Double
    public var vectorScore: Double
    public var rankScore: Double
    public var metadata: [String: String]

    public init(
        record: AgentMemoryRecord,
        relevance: Double,
        embeddingModelID: String? = nil,
        lexicalScore: Double = 0,
        vectorScore: Double = 0,
        rankScore: Double? = nil,
        metadata: [String: String] = [:]
    ) {
        self.record = record
        self.relevance = min(max(relevance, 0), 1)
        self.embeddingModelID = embeddingModelID
        self.lexicalScore = min(max(lexicalScore, 0), 1)
        self.vectorScore = min(max(vectorScore, 0), 1)
        self.rankScore = rankScore ?? self.relevance
        self.metadata = metadata
    }
}

public enum AgentMemoryApprover {
    public static func evaluate(
        _ proposal: AgentMemoryWriteProposal,
        decidedAt: RunTraceTimestamp
    ) -> AgentMemoryWriteApproval {
        var issues: [AgentMemoryApprovalIssue] = []
        let record = proposal.record

        if record.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.emptyValue)
        }

        if containsSensitiveContent(record.value) {
            issues.append(.sensitiveContent)
        }

        if !record.source.isLinked {
            issues.append(.missingSourceLink)
        }

        switch record.scope {
        case .global:
            break
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

        return AgentMemoryWriteApproval(
            proposalID: proposal.id,
            approved: issues.isEmpty,
            issues: Array(Set(issues)).sorted { $0.rawValue < $1.rawValue },
            decidedAt: decidedAt
        )
    }

    private static func containsSensitiveContent(_ value: String) -> Bool {
        let patterns = [
            #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            #"\b(?:\d[ -]*?){13,16}\b"#,
            #"(?i)(password|token|api[_ -]?key)\s*[:=]\s*\S+"#
        ]
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return patterns.contains { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return false
            }
            return regex.firstMatch(in: value, range: range) != nil
        }
    }
}

public typealias RunMemoryScope = AgentMemoryScope
public typealias RunMemoryKind = AgentMemoryKind
public typealias RunMemoryAuthor = AgentMemoryAuthor
public typealias RunMemorySource = AgentMemorySource
public typealias RunMemoryRecord = AgentMemoryRecord
public typealias RunMemoryApprovalIssue = AgentMemoryApprovalIssue
public typealias RunMemoryWriteProposal = AgentMemoryWriteProposal
public typealias RunMemoryWriteApproval = AgentMemoryWriteApproval
public typealias RunMemoryWriteDecision = AgentMemoryWriteDecision
public typealias RunMemoryRetrievalBudget = AgentMemoryRetrievalBudget
public typealias RunMemorySemanticQuery = AgentMemoryQuery
public typealias RunMemorySemanticResult = AgentMemorySearchResult
public typealias RunMemoryApprover = AgentMemoryApprover
