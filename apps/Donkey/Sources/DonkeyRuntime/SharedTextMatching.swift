import DonkeyContracts
import Foundation

/// Case-insensitive, bidirectional app-name matching shared by every place that has to decide
/// whether an observed/installed app is the one the user (or a skill) named. Centralizing it keeps
/// window-target resolution and skill/guidance lookup from drifting apart on casing/substring rules.
public enum AppNameMatching {
    /// True when the two names refer to the same app: equal after normalizing (case, whitespace,
    /// trailing ".app"), or one's word set is a subset of the other's. Matching on whole-word tokens
    /// rather than raw substrings tolerates "Music" vs "Music.app" and "Spotify" vs "Spotify Premium"
    /// while NOT matching unrelated names that merely share a letter run (e.g. "Code" vs "Xcode").
    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalize(lhs)
        let right = normalize(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        let leftTokens = ControlTextRelevance.tokens(in: left)
        let rightTokens = ControlTextRelevance.tokens(in: right)
        guard !leftTokens.isEmpty, !rightTokens.isEmpty else { return false }
        return leftTokens.isSubset(of: rightTokens) || rightTokens.isSubset(of: leftTokens)
    }

    private static func normalize(_ name: String) -> String {
        var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasSuffix(".app") { trimmed = String(trimmed.dropLast(4)) }
        return trimmed
    }
}

/// Text-relevance scoring shared by control grounding (accessibility cursor paths and vision
/// inspection). Both ground a requested control by ranking candidate strings against a query with
/// the same ladder — exact match, then containment, then token overlap — so the scoring lives here
/// once and a tweak (e.g. tokenization, prefix handling) applies to every grounding path at once.
public enum ControlTextRelevance {
    public static let exactScore = 1_000.0
    public static let containmentScore = 500.0

    /// Splits text into lowercase alphanumeric tokens for the overlap fallback.
    public static func tokens(in text: String) -> Set<String> {
        Set(text.split { !$0.isLetter && !$0.isNumber }.map { String($0).lowercased() })
    }

    /// Scores `candidates` (each already normalized to the caller's convention) against
    /// `normalizedQuery`. Returns 0 when nothing matches; ties on score are left for the caller to
    /// break (e.g. toward larger control area or higher model confidence).
    public static func score(
        normalizedQuery: String,
        queryTokens: Set<String>,
        candidates: [String]
    ) -> Double {
        var best = 0.0
        for candidate in candidates where !candidate.isEmpty {
            if candidate == normalizedQuery {
                best = max(best, exactScore)
            } else if candidate.contains(normalizedQuery) || normalizedQuery.contains(candidate) {
                best = max(best, containmentScore)
            } else {
                let overlap = queryTokens.intersection(tokens(in: candidate)).count
                if overlap > 0 { best = max(best, Double(overlap)) }
            }
        }
        return best
    }
}
