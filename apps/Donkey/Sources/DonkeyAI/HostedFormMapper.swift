import DonkeyContracts
import Foundation

/// The model boundary behind `pdf.fill`: a form rendered in reading order (each fillable field inline)
/// plus the user's data in, a `{field_id: value}` map out. This is the ONE bounded inference the fill
/// pipeline makes — the planner never composes the map step by step, so it cannot stall before the
/// write. Returns nil on any failure; the orchestrator turns nil into a clean "could not map" outcome.
public struct HostedFormMapper: Sendable {
    private let backend: DonkeyBackendInferenceClient
    private let maxOutputTokens: Int
    private let timeoutSeconds: TimeInterval

    public init(
        backend: DonkeyBackendInferenceClient,
        maxOutputTokens: Int = 8_000,
        timeoutSeconds: TimeInterval = 180
    ) {
        self.backend = backend
        self.maxOutputTokens = maxOutputTokens
        self.timeoutSeconds = timeoutSeconds
    }

    public func map(formText: String, dataText: String) async -> [String: String]? {
        let request = RemoteInferenceResponseCreateRequest(
            input: .array([
                .object([
                    "role": .string("user"),
                    "content": .array([
                        .object(["type": .string("input_text"), "text": .string(Self.prompt(formText: formText, dataText: dataText))])
                    ])
                ])
            ]),
            store: false,
            metadata: ["source": "hosted-form-mapper", "prompt_version": "pdf-fill-map-v1"],
            parameters: [
                // Deterministic: a form fill should map the same data the same way every time.
                "temperature": .number(0),
                "max_output_tokens": .number(Double(maxOutputTokens)),
                "thinking_level": .string("medium"),
                // json_object, NOT a strict schema — constrained-schema decoding corrupts the map on this
                // backend, so ask for a bare JSON object and parse it tolerantly.
                "response_format": .object(["type": .string("json_object")])
            ]
        )
        let backend = self.backend
        // This is the one network call in the fill pipeline, and the backend can drop a request under
        // load. A single transient miss here used to fail the whole `pdf.fill` and send the planner back
        // to scouting, so retry a couple of times before giving up. The call is deterministic
        // (temperature 0), so a retry costs only latency, never a different answer.
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 800_000_000) }
            guard let response = try? await AIDeadline.enforce(seconds: timeoutSeconds, {
                try await backend.createResponse(request)
            }) else { continue }
            guard let text = RemoteInferenceResponseHelpers.outputText(from: response),
                  let map = Self.decodeMap(from: text) else { continue }
            return map
        }
        return nil
    }

    /// Pull a `{field_id: value}` object out of the model's reply — tolerant of surrounding prose or a
    /// code fence by slicing from the first `{` to the last `}` — and coerce each scalar value to a
    /// string. Nested objects/arrays/null are skipped (a field value is always a scalar).
    static func decodeMap(from text: String) -> [String: String]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        guard let data = String(text[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var map: [String: String] = [:]
        for (key, value) in object {
            if let string = value as? String {
                map[key] = string
            } else if let number = value as? NSNumber {
                map[key] = scalarString(number)
            }
        }
        return map.isEmpty ? nil : map
    }

    /// Render a JSON scalar without a spurious ".0" on integers (so a money line lands as "120000", not
    /// "120000.0"). Booleans round-trip as "true"/"false" for checkbox on/off.
    private static func scalarString(_ number: NSNumber) -> String {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        let double = number.doubleValue
        if double == double.rounded(), abs(double) < 1e15 {
            return String(Int64(double))
        }
        return number.stringValue
    }

    private static func prompt(formText: String, dataText: String) -> String {
        """
        You fill PDF forms. Below is a form in reading order with each fillable field shown inline as \
        ⟦id⟧ (text field), ⟦x id=on⟧ (checkbox — the value is the on-state shown after =, used to tick \
        it), or ⟦? id=a|b⟧ (dropdown with its options). Map the user's data onto the form's fields.

        Return ONLY a strict JSON object {field_id: value} — no prose, no code fence. Use the exact ids \
        from the markers. Cover the entity name, full address, and ID numbers, plus every money line you \
        can match. COMPUTE the values the data does not state outright — for a Form 1120 that means net \
        receipts (gross − returns), total income, total deductions, taxable income, and tax (21% of \
        taxable income). Text and dropdown values are strings; a checkbox value is the on-state shown \
        after its = . Omit any field you have no value for.

        FORM:
        \(formText)

        DATA:
        \(dataText)
        """
    }
}
