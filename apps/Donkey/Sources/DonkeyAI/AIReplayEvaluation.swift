import DonkeyContracts
import Foundation

public struct PlannerHintReplayCase: Codable, Equatable, Sendable {
    public var id: String
    public var trace: ReflexTraceRecord
    public var hint: StructuredPlannerHint?
    public var validationIssues: [PlannerHintValidationIssue]
    public var modelTrace: AIModelCallTrace?
    public var memoryDecisions: [RunMemoryWriteDecision]
    public var fallbackCount: Int
    public var recoverySucceeded: Bool
    public var estimatedCostUSD: Double

    public init(
        id: String,
        trace: ReflexTraceRecord,
        hint: StructuredPlannerHint?,
        validationIssues: [PlannerHintValidationIssue],
        modelTrace: AIModelCallTrace? = nil,
        memoryDecisions: [RunMemoryWriteDecision] = [],
        fallbackCount: Int = 0,
        recoverySucceeded: Bool = false,
        estimatedCostUSD: Double = 0
    ) {
        self.id = id
        self.trace = trace
        self.hint = hint
        self.validationIssues = validationIssues
        self.modelTrace = modelTrace
        self.memoryDecisions = memoryDecisions
        self.fallbackCount = fallbackCount
        self.recoverySucceeded = recoverySucceeded
        self.estimatedCostUSD = estimatedCostUSD
    }
}

public struct AIReplayEvalMetrics: Codable, Equatable, Sendable {
    public var caseCount: Int
    public var schemaValidCount: Int
    public var hintAcceptedCount: Int
    public var memoryWriteAcceptedCount: Int
    public var memoryWriteRejectedCount: Int
    public var fallbackCount: Int
    public var recoverySuccessCount: Int
    public var totalEstimatedCostUSD: Double
    public var averageModelLatencyMS: Double?
    public var p95ModelLatencyMS: Double?

    public init(
        caseCount: Int,
        schemaValidCount: Int,
        hintAcceptedCount: Int,
        memoryWriteAcceptedCount: Int,
        memoryWriteRejectedCount: Int,
        fallbackCount: Int,
        recoverySuccessCount: Int,
        totalEstimatedCostUSD: Double,
        averageModelLatencyMS: Double?,
        p95ModelLatencyMS: Double?
    ) {
        self.caseCount = caseCount
        self.schemaValidCount = schemaValidCount
        self.hintAcceptedCount = hintAcceptedCount
        self.memoryWriteAcceptedCount = memoryWriteAcceptedCount
        self.memoryWriteRejectedCount = memoryWriteRejectedCount
        self.fallbackCount = fallbackCount
        self.recoverySuccessCount = recoverySuccessCount
        self.totalEstimatedCostUSD = totalEstimatedCostUSD
        self.averageModelLatencyMS = averageModelLatencyMS
        self.p95ModelLatencyMS = p95ModelLatencyMS
    }
}

public struct AIReplayEvalReport: Codable, Equatable, Sendable {
    public var suiteID: String
    public var promptVersion: String
    public var modelEntryID: String
    public var generatedAt: RunTraceTimestamp
    public var metrics: AIReplayEvalMetrics
    public var caseIDs: [String]

    public init(
        suiteID: String,
        promptVersion: String,
        modelEntryID: String,
        generatedAt: RunTraceTimestamp,
        metrics: AIReplayEvalMetrics,
        caseIDs: [String]
    ) {
        self.suiteID = suiteID
        self.promptVersion = promptVersion
        self.modelEntryID = modelEntryID
        self.generatedAt = generatedAt
        self.metrics = metrics
        self.caseIDs = caseIDs
    }
}

public struct AIModelUpdateChecklist: Codable, Equatable, Sendable {
    public var modelEntryID: String
    public var promptVersion: String
    public var lastVerifiedAt: Date
    public var docsURLs: [URL]
    public var evalSuiteID: String
    public var rollbackModelID: String
    public var evalReportID: String?
    public var notes: [String]

    public init(
        modelEntryID: String,
        promptVersion: String,
        lastVerifiedAt: Date,
        docsURLs: [URL],
        evalSuiteID: String,
        rollbackModelID: String,
        evalReportID: String? = nil,
        notes: [String] = []
    ) {
        self.modelEntryID = modelEntryID
        self.promptVersion = promptVersion
        self.lastVerifiedAt = lastVerifiedAt
        self.docsURLs = docsURLs
        self.evalSuiteID = evalSuiteID
        self.rollbackModelID = rollbackModelID
        self.evalReportID = evalReportID
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case modelEntryID = "model_entry_id"
        case promptVersion = "prompt_version"
        case lastVerifiedAt = "last_verified_at"
        case docsURLs = "docs_urls"
        case evalSuiteID = "eval_suite_id"
        case rollbackModelID = "rollback_model_id"
        case evalReportID = "eval_report_id"
        case notes
    }
}

public enum PlannerHintReplayEvaluator {
    public static func evaluate(
        suiteID: String,
        promptVersion: String,
        modelEntryID: String,
        cases: [PlannerHintReplayCase],
        generatedAt: RunTraceTimestamp
    ) -> AIReplayEvalReport {
        let latencies = cases.compactMap { $0.modelTrace?.latencyMS }.sorted()
        let acceptedMemoryWrites = cases.flatMap(\.memoryDecisions).filter(\.approval.approved).count
        let rejectedMemoryWrites = cases.flatMap(\.memoryDecisions).filter { !$0.approval.approved }.count

        let metrics = AIReplayEvalMetrics(
            caseCount: cases.count,
            schemaValidCount: cases.filter { $0.hint != nil }.count,
            hintAcceptedCount: cases.filter { $0.hint != nil && $0.validationIssues.isEmpty }.count,
            memoryWriteAcceptedCount: acceptedMemoryWrites,
            memoryWriteRejectedCount: rejectedMemoryWrites,
            fallbackCount: cases.reduce(0) { $0 + $1.fallbackCount },
            recoverySuccessCount: cases.filter(\.recoverySucceeded).count,
            totalEstimatedCostUSD: cases.reduce(0) { $0 + $1.estimatedCostUSD },
            averageModelLatencyMS: average(latencies),
            p95ModelLatencyMS: percentile(latencies, percentile: 0.95)
        )

        return AIReplayEvalReport(
            suiteID: suiteID,
            promptVersion: promptVersion,
            modelEntryID: modelEntryID,
            generatedAt: generatedAt,
            metrics: metrics,
            caseIDs: cases.map(\.id)
        )
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func percentile(_ sortedValues: [Double], percentile: Double) -> Double? {
        guard !sortedValues.isEmpty else { return nil }
        let clamped = max(0, min(1, percentile))
        let index = Int((Double(sortedValues.count - 1) * clamped).rounded(.up))
        return sortedValues[index]
    }
}
