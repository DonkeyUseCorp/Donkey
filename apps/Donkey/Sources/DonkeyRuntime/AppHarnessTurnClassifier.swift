import DonkeyContracts
import Foundation

public enum AppHarnessTurnClassificationKind: String, Equatable, Sendable {
    case actionable
    case answer
    case unknown
}

public struct AppHarnessTurnClassification: Equatable, Sendable {
    public var kind: AppHarnessTurnClassificationKind
    public var response: String?
    public var router: String
    public var missingDetail: String?
    public var metadata: [String: String]

    public init(
        kind: AppHarnessTurnClassificationKind,
        response: String? = nil,
        router: String,
        missingDetail: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.kind = kind
        self.response = response
        self.router = router
        self.missingDetail = missingDetail
        self.metadata = metadata
    }
}

public struct AppHarnessTurnClassifier: Sendable {
    public init() {}

    public func classify(
        text: String,
        request _: AppHarnessTurnRequest,
        catalog _: LocalAppTaskCatalog
    ) -> AppHarnessTurnClassification {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheCandidates = LocalItemResolutionCache.shared.search(query: trimmedText, limit: 3)
        let classifierMetadata = [
            "classifier": "fast-local-v1",
            "cache.candidateKinds": cacheCandidates.map(\.entry.kind).joined(separator: ","),
            "cache.candidateNames": cacheCandidates.map(\.entry.displayName).joined(separator: ",")
        ]
        if let response = Self.simpleArithmeticResponse(for: trimmedText) {
            return AppHarnessTurnClassification(
                kind: .answer,
                response: response,
                router: "simpleArithmetic",
                metadata: classifierMetadata
            )
        }

        return AppHarnessTurnClassification(
            kind: .unknown,
            router: "modelIntentRequired",
            missingDetail: "actionable request",
            metadata: classifierMetadata
        )
    }

    private static func simpleArithmeticResponse(for text: String) -> String? {
        let pattern = #"(-?\d+(?:\.\d+)?)\s*([+\-*/×x÷])\s*(-?\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              let lhsRange = Range(match.range(at: 1), in: text),
              let operatorRange = Range(match.range(at: 2), in: text),
              let rhsRange = Range(match.range(at: 3), in: text),
              let lhs = Double(text[lhsRange]),
              let rhs = Double(text[rhsRange])
        else {
            return nil
        }

        let operation = String(text[operatorRange])
        let value: Double
        switch operation {
        case "+":
            value = lhs + rhs
        case "-":
            value = lhs - rhs
        case "*", "x", "X", "×":
            value = lhs * rhs
        case "/", "÷":
            guard rhs != 0 else { return "I can't divide by zero." }
            value = lhs / rhs
        default:
            return nil
        }

        return "\(formatNumber(lhs)) \(operation) \(formatNumber(rhs)) = \(formatNumber(value))."
    }

    private static func formatNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }
}
