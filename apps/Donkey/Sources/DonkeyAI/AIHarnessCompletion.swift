import DonkeyContracts
import Foundation

public enum AIHarnessRedactionSurface: String, Codable, Equatable, Sendable {
    case screenshotSummary
    case domSummary
    case modelContext
}

public struct AIHarnessRedactionResult: Codable, Equatable, Sendable {
    public var surface: AIHarnessRedactionSurface
    public var redactedText: String
    public var redactionCount: Int
    public var metadata: [String: String]

    public init(
        surface: AIHarnessRedactionSurface,
        redactedText: String,
        redactionCount: Int,
        metadata: [String: String] = [:]
    ) {
        self.surface = surface
        self.redactedText = redactedText
        self.redactionCount = redactionCount
        self.metadata = metadata
    }
}

public struct AIHarnessRedactor: Sendable {
    public init() {}

    public func redact(
        _ text: String,
        surface: AIHarnessRedactionSurface
    ) -> AIHarnessRedactionResult {
        var redacted = text
        var count = 0
        let patterns = [
            #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#: "[redacted-email]",
            #"\b(?:\d[ -]*?){13,16}\b"#: "[redacted-number]",
            #"(?i)(password|token|api[_ -]?key)\s*[:=]\s*\S+"#: "$1=[redacted-secret]"
        ]

        for (pattern, replacement) in patterns {
            let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let range = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
            let matches = regex?.numberOfMatches(in: redacted, range: range) ?? 0
            guard matches > 0 else { continue }
            redacted = regex?.stringByReplacingMatches(
                in: redacted,
                range: range,
                withTemplate: replacement
            ) ?? redacted
            count += matches
        }

        return AIHarnessRedactionResult(
            surface: surface,
            redactedText: redacted,
            redactionCount: count,
            metadata: [
                "redactor": "ai-harness-redactor-v1",
                "remoteBoundSafe": String(count > 0)
            ]
        )
    }
}

public struct AIModelObservabilityReport: Codable, Equatable, Sendable {
    public var callCount: Int
    public var statusCounts: [String: Int]
    public var providerCounts: [String: Int]
    public var validationStatusCounts: [String: Int]
    public var acceptedCount: Int
    public var recoverySuccessCount: Int
    public var totalEstimatedCostUSD: Double
    public var latencyMS: AIModelLatencyPercentiles
    public var metadata: [String: String]

    public init(
        callCount: Int,
        statusCounts: [String: Int],
        providerCounts: [String: Int],
        validationStatusCounts: [String: Int],
        acceptedCount: Int,
        recoverySuccessCount: Int,
        totalEstimatedCostUSD: Double,
        latencyMS: AIModelLatencyPercentiles,
        metadata: [String: String] = [:]
    ) {
        self.callCount = callCount
        self.statusCounts = statusCounts
        self.providerCounts = providerCounts
        self.validationStatusCounts = validationStatusCounts
        self.acceptedCount = acceptedCount
        self.recoverySuccessCount = recoverySuccessCount
        self.totalEstimatedCostUSD = totalEstimatedCostUSD
        self.latencyMS = latencyMS
        self.metadata = metadata
    }
}

public struct AIModelLatencyPercentiles: Codable, Equatable, Sendable {
    public var p50: Double?
    public var p95: Double?

    public init(p50: Double? = nil, p95: Double? = nil) {
        self.p50 = p50
        self.p95 = p95
    }
}

public enum AIModelObservabilityReportBuilder {
    public static func build(from traces: [AIModelCallTrace]) -> AIModelObservabilityReport {
        AIModelObservabilityReport(
            callCount: traces.count,
            statusCounts: countBy(traces.map { $0.status.rawValue }),
            providerCounts: countBy(traces.map { $0.provider.rawValue }),
            validationStatusCounts: countBy(traces.map(\.validationStatus)),
            acceptedCount: traces.filter { $0.status == .completed && $0.validationStatus != "invalid" }.count,
            recoverySuccessCount: traces.filter { $0.metadata["recovery.success"] == "true" }.count,
            totalEstimatedCostUSD: traces.reduce(0) { total, trace in
                total + (Double(trace.metadata["cost.estimatedUSD"] ?? "") ?? 0)
            },
            latencyMS: percentiles(traces.compactMap(\.latencyMS)),
            metadata: ["report": "ai-model-observability-v1"]
        )
    }

    private static func countBy(_ values: [String]) -> [String: Int] {
        values.reduce(into: [:]) { result, value in
            result[value, default: 0] += 1
        }
    }

    private static func percentiles(_ values: [Double]) -> AIModelLatencyPercentiles {
        guard !values.isEmpty else { return AIModelLatencyPercentiles() }
        let sorted = values.sorted()
        return AIModelLatencyPercentiles(
            p50: percentile(sorted, fraction: 0.50),
            p95: percentile(sorted, fraction: 0.95)
        )
    }

    private static func percentile(_ sortedValues: [Double], fraction: Double) -> Double? {
        let index = min(sortedValues.count - 1, Int(Double(sortedValues.count - 1) * fraction))
        return sortedValues[index]
    }
}

public enum ProviderDecodedMemoryProposalHandler {
    public static func decisions(
        from data: Data,
        decidedAt: RunTraceTimestamp,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> [RunMemoryWriteDecision] {
        let proposals = try decoder.decode([RunMemoryWriteProposal].self, from: data)
        return proposals.map { proposal in
            let approval = RunMemoryApprover.evaluate(proposal, decidedAt: decidedAt)
            return RunMemoryWriteDecision(
                proposal: proposal,
                approval: approval,
                storedRecord: approval.approved ? proposal.record : nil
            )
        }
    }
}
