import DonkeyContracts
import DonkeyRuntime
import Foundation

/// The model boundary behind `shorts.make`: a timestamped transcript in, the clip-worthy spans out. This is
/// the ONE bounded inference the shorts pipeline makes — the planner never drives the download/cut/reframe/
/// caption steps itself, so the whole run costs a single decision instead of a model call at every step.
/// Returns nil on any failure; the orchestrator turns nil into a clean "could not find moments" outcome.
public struct HostedMomentSelector: Sendable {
    private let backend: DonkeyBackendInferenceClient
    private let maxOutputTokens: Int
    private let timeoutSeconds: TimeInterval

    public init(
        backend: DonkeyBackendInferenceClient,
        maxOutputTokens: Int = 2_000,
        timeoutSeconds: TimeInterval = 120
    ) {
        self.backend = backend
        self.maxOutputTokens = maxOutputTokens
        self.timeoutSeconds = timeoutSeconds
    }

    public func select(transcript: String, desiredCount: Int?) async -> [MomentSpan]? {
        let request = RemoteInferenceResponseCreateRequest(
            input: .array([
                .object([
                    "role": .string("user"),
                    "content": .array([
                        .object(["type": .string("input_text"), "text": .string(Self.prompt(transcript: transcript, desiredCount: desiredCount))])
                    ])
                ])
            ]),
            store: false,
            metadata: ["source": "hosted-moment-selector", "prompt_version": "shorts-moments-v1"],
            parameters: [
                // Low temperature: picking the same strong moments from the same transcript should be stable.
                "temperature": .number(0.2),
                "max_output_tokens": .number(Double(maxOutputTokens)),
                "thinking_level": .string("medium"),
                // json_object, NOT a strict schema — constrained-schema decoding corrupts structured output
                // on this backend, so ask for a bare JSON object and parse it tolerantly.
                "response_format": .object(["type": .string("json_object")])
            ]
        )
        let backend = self.backend
        // The one network call in the shorts pipeline; the backend can drop a request under load, so retry a
        // couple of times before giving up. Low temperature, so a retry costs only latency.
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 800_000_000) }
            guard let response = try? await AIDeadline.enforce(seconds: timeoutSeconds, {
                try await backend.createResponse(request)
            }) else { continue }
            guard let text = RemoteInferenceResponseHelpers.outputText(from: response),
                  let spans = Self.decode(from: text), !spans.isEmpty else { continue }
            return spans
        }
        return nil
    }

    /// Pull `{"moments":[{"start","end","title"}]}` out of the reply — tolerant of surrounding prose or a code
    /// fence by slicing from the first `{` to the last `}`. `start`/`end` may be seconds (a number) or an
    /// `m:ss`/`h:mm:ss` string. Drops any span whose end is not strictly after its start.
    static func decode(from text: String) -> [MomentSpan]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["moments"] as? [Any] else {
            return nil
        }
        var spans: [MomentSpan] = []
        for case let entry as [String: Any] in raw {
            guard let startSec = seconds(entry["start"]), let endSec = seconds(entry["end"]), endSec > startSec else {
                continue
            }
            let title = (entry["title"] as? String) ?? ""
            spans.append(MomentSpan(startSec: startSec, endSec: endSec, title: title))
        }
        return spans.isEmpty ? nil : spans
    }

    /// Coerce a JSON value to seconds: a number passes through; an `m:ss`/`h:mm:ss` string is parsed.
    private static func seconds(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        guard let string = value as? String else { return nil }
        let parts = string.split(separator: ":").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        if parts.contains(nil) { return Double(string) }
        let numbers = parts.compactMap { $0 }
        switch numbers.count {
        case 1: return numbers[0]
        case 2: return numbers[0] * 60 + numbers[1]
        case 3: return numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
        default: return nil
        }
    }

    private static func prompt(transcript: String, desiredCount: Int?) -> String {
        let countClause = desiredCount.map { "Choose exactly \($0) moment\($0 == 1 ? "" : "s") — the very strongest." }
            ?? "Choose up to 5 of the strongest moments."
        return """
        You pick the strongest short-form moments from a timestamped transcript. Each line is "[m:ss] words". \
        Choose self-contained spans — a complete thought with a hook and a payoff, usually 15–60 seconds — \
        that would stand alone as a TikTok/Reel/Short. Do not cut mid-sentence; favor a strong opening line \
        and a clear payoff. \(countClause)

        Return ONLY a strict JSON object: {"moments":[{"start": <seconds>, "end": <seconds>, "title": \
        "<3–6 word label>"}]} — start and end are seconds from the beginning of the source as numbers, with \
        end strictly greater than start. No prose, no code fence.

        TRANSCRIPT:
        \(transcript)
        """
    }
}
