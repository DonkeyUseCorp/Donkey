import DonkeyContracts
import Foundation

/// The model boundary behind `media.caption`'s translation: a list of subtitle lines and a target language
/// in, the same lines translated (in the same order, same count) out. This is the ONE model call the caption
/// pipeline makes when a translation is asked for — the timings come from on-device transcription and the SRT
/// is assembled in code, so the model only ever supplies text, never an SRT it can format wrong. Returns nil
/// (or a wrong-length array, which the caller rejects) on failure; the orchestrator turns that into a clean
/// "could not translate" outcome.
public struct HostedSubtitleTranslator: Sendable {
    private let backend: DonkeyBackendInferenceClient
    private let maxOutputTokens: Int
    private let timeoutSeconds: TimeInterval

    public init(
        backend: DonkeyBackendInferenceClient,
        maxOutputTokens: Int = 4_000,
        timeoutSeconds: TimeInterval = 120
    ) {
        self.backend = backend
        self.maxOutputTokens = maxOutputTokens
        self.timeoutSeconds = timeoutSeconds
    }

    public func translate(lines: [String], to targetLanguage: String) async -> [String]? {
        guard !lines.isEmpty else { return [] }
        let request = RemoteInferenceResponseCreateRequest(
            input: .array([
                .object([
                    "role": .string("user"),
                    "content": .array([
                        .object(["type": .string("input_text"), "text": .string(Self.prompt(lines: lines, targetLanguage: targetLanguage))])
                    ])
                ])
            ]),
            store: false,
            metadata: ["source": "hosted-subtitle-translator", "prompt_version": "caption-translate-v1"],
            parameters: [
                // Deterministic: the same lines should translate the same way each run.
                "temperature": .number(0),
                "max_output_tokens": .number(Double(maxOutputTokens)),
                "thinking_level": .string("low"),
                "response_format": .object(["type": .string("json_object")])
            ]
        )
        let backend = self.backend
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 800_000_000) }
            guard let response = try? await AIDeadline.enforce(seconds: timeoutSeconds, {
                try await backend.createResponse(request)
            }) else { continue }
            guard let text = RemoteInferenceResponseHelpers.outputText(from: response),
                  let translated = Self.decode(from: text, expectedCount: lines.count) else { continue }
            return translated
        }
        return nil
    }

    /// Pull `{"lines":[...]}` out of the reply — tolerant of surrounding prose or a code fence — and accept it
    /// only when it carries exactly the expected number of strings, so a dropped or merged line can't shift
    /// every later cue's timing.
    static func decode(from text: String, expectedCount: Int) -> [String]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["lines"] as? [Any] else {
            return nil
        }
        let strings = raw.map { value -> String? in value as? String }
        guard !strings.contains(nil) else { return nil }
        let lines = strings.compactMap { $0 }
        return lines.count == expectedCount ? lines : nil
    }

    private static func prompt(lines: [String], targetLanguage: String) -> String {
        let numbered = lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return """
        Translate each subtitle line below into \(targetLanguage). Keep each translation concise enough to \
        read as a subtitle, and translate line-by-line so the order and count stay identical.

        Return ONLY a strict JSON object {"lines": [...]} containing EXACTLY \(lines.count) translated strings, \
        in the same order as the input — one translation per input line, no extra lines, no numbering, no prose, \
        no code fence.

        LINES:
        \(numbered)
        """
    }
}
