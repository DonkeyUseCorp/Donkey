import DonkeyContracts
import Foundation

enum RemoteInferenceResponseHelpers {
    static func outputText(from value: RemoteInferenceJSONValue) -> String? {
        if let outputText = value.objectValue?["output_text"]?.stringValue,
           !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return outputText
        }

        guard let output = value.objectValue?["output"]?.arrayValue else {
            return nil
        }
        for item in output {
            guard let content = item.objectValue?["content"]?.arrayValue else { continue }
            for contentItem in content {
                guard contentItem.objectValue?["type"]?.stringValue == "output_text",
                      let text = contentItem.objectValue?["text"]?.stringValue,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    continue
                }
                return text
            }
        }
        return nil
    }

    /// The provider-reported finish reason for the first candidate that has one, read from the raw
    /// provider payload the backend echoes back (`provider_output.candidates[].finishReason`). This is
    /// how an empty reply names its exact cause — RECITATION, SAFETY, MAX_TOKENS — instead of
    /// surfacing as a generic missing-output failure. nil when the payload carries no finish reason.
    static func providerFinishReason(from value: RemoteInferenceJSONValue) -> String? {
        guard let candidates = value.objectValue?["provider_output"]?.objectValue?["candidates"]?.arrayValue else {
            return nil
        }
        for candidate in candidates {
            if let reason = candidate.objectValue?["finishReason"]?.stringValue,
               !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return reason
            }
        }
        return nil
    }

    /// The model's thought summary, when thinking was enabled. The backend separates this from
    /// `output_text` (which carries the structured tool-call JSON), so reasoning can be persisted to
    /// the thread without corrupting the decision parse. nil/empty when thinking was off.
    static func reasoningText(from value: RemoteInferenceJSONValue) -> String? {
        guard let text = value.objectValue?["reasoning_text"]?.stringValue,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return text
    }

    static func jsonValue(_ value: Any) -> RemoteInferenceJSONValue {
        switch value {
        case let string as String:
            return .string(string)
        case let bool as Bool:
            return .bool(bool)
        case let int as Int:
            return .number(Double(int))
        case let double as Double:
            return .number(double)
        case let array as [Any]:
            return .array(array.map(jsonValue))
        case let object as [String: Any]:
            return .object(object.mapValues(jsonValue))
        default:
            return .null
        }
    }
}
