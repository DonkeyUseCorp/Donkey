import DonkeyContracts
import Foundation

/// A focused, one-shot "understand the request" boundary that runs ONCE before the harness loop.
///
/// It does not plan or pick tools. It turns the raw user command into a small typed understanding the
/// loop can act on: a restated goal, the app to operate, the key parameters, observable success
/// criteria, and a clarify gate. The per-step `HostedHarnessStepPlanner` still chooses every tool —
/// this only sharpens what "the goal" means and which app to drive, so the planner stops re-deriving
/// intent from a raw string on every step.
public struct HarnessRequestUnderstanding: Sendable, Equatable {
    /// The user's request restated as one concrete imperative goal.
    public var restatedGoal: String
    /// The macOS app the request needs to operate through its GUI. Left nil/empty for pure
    /// conversation, for whatever app is already frontmost, and for tasks an expert would do with
    /// system tools (finding files, launching/quitting apps, reading or changing settings/state) —
    /// those have no GUI target and the planner drives them with shell_exec.
    public var targetAppName: String?
    /// Structured parameters extracted from the request (e.g. title, recipient, query).
    public var parameters: [String: String]
    /// What, observable on screen, would mean the goal is done.
    public var successCriteria: String?
    /// True only when the request is genuinely ambiguous or missing critical detail and cannot be
    /// safely resolved with reasonable defaults.
    public var needsClarification: Bool
    /// The question to ask when `needsClarification` is true.
    public var clarifyingQuestion: String?

    public init(
        restatedGoal: String,
        targetAppName: String? = nil,
        parameters: [String: String] = [:],
        successCriteria: String? = nil,
        needsClarification: Bool = false,
        clarifyingQuestion: String? = nil
    ) {
        self.restatedGoal = restatedGoal
        self.targetAppName = targetAppName
        self.parameters = parameters
        self.successCriteria = successCriteria
        self.needsClarification = needsClarification
        self.clarifyingQuestion = clarifyingQuestion
    }
}

/// Makes the single hosted call that produces a `HarnessRequestUnderstanding`. Mirrors the request /
/// decode shape of `HostedHarnessStepPlanner` (one `createResponse`, a JSON-schema response, scalar
/// coercion on decode) so both boundaries stay consistent.
@MainActor
public final class HostedHarnessRequestUnderstanding {
    private let backend: DonkeyBackendInferenceClient

    public init(backend: DonkeyBackendInferenceClient) {
        self.backend = backend
    }

    /// Returns the parsed understanding, or `nil` on any provider/decode failure so the caller can
    /// degrade to driving the raw command directly rather than dead-ending.
    public func understand(command: String, frontmostAppName: String) async -> HarnessRequestUnderstanding? {
        do {
            let response = try await backend.createResponse(responseRequest(command: command, frontmostAppName: frontmostAppName))
            guard let text = RemoteInferenceResponseHelpers.outputText(from: response), !text.isEmpty else {
                return nil
            }
            let json = DebugUIInspectionResponseDecoder.jsonObjectSubstring(text)
            let wire = try JSONDecoder().decode(UnderstandingWire.self, from: Data(json.utf8))
            let restated = wire.restatedGoal?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let restated, !restated.isEmpty else { return nil }
            return HarnessRequestUnderstanding(
                restatedGoal: restated,
                targetAppName: wire.targetAppName.flatMap { $0.isEmpty ? nil : $0 },
                parameters: wire.parameters ?? [:],
                successCriteria: wire.successCriteria.flatMap { $0.isEmpty ? nil : $0 },
                needsClarification: wire.needsClarification ?? false,
                clarifyingQuestion: wire.clarifyingQuestion.flatMap { $0.isEmpty ? nil : $0 }
            )
        } catch {
            return nil
        }
    }

    // MARK: - Wire

    private struct UnderstandingWire: Decodable {
        var restatedGoal: String?
        var targetAppName: String?
        var parameters: [String: String]?
        var successCriteria: String?
        var needsClarification: Bool?
        var clarifyingQuestion: String?

        private enum CodingKeys: String, CodingKey {
            case restatedGoal, targetAppName, parameters, successCriteria, needsClarification, clarifyingQuestion
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            restatedGoal = try container.decodeIfPresent(String.self, forKey: .restatedGoal)
            targetAppName = try container.decodeIfPresent(String.self, forKey: .targetAppName)
            successCriteria = try container.decodeIfPresent(String.self, forKey: .successCriteria)
            clarifyingQuestion = try container.decodeIfPresent(String.self, forKey: .clarifyingQuestion)
            needsClarification = try container.decodeIfPresent(Bool.self, forKey: .needsClarification)
            // The schema is non-strict, so a parameter value may arrive as a number or boolean. Coerce
            // scalars to strings instead of failing the whole decode.
            parameters = try container.decodeIfPresent([String: ScalarString].self, forKey: .parameters)?
                .mapValues(\.value)
        }
    }

    /// A JSON scalar (string, number, boolean, or null) decoded into its string form.
    private struct ScalarString: Decodable {
        let value: String

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                value = string
            } else if let bool = try? container.decode(Bool.self) {
                value = String(bool)
            } else if let int = try? container.decode(Int.self) {
                value = String(int)
            } else if let double = try? container.decode(Double.self) {
                value = String(double)
            } else if container.decodeNil() {
                value = ""
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Parameter value is not a JSON scalar"
                )
            }
        }
    }

    private func responseRequest(command: String, frontmostAppName: String) -> RemoteInferenceResponseCreateRequest {
        RemoteInferenceResponseCreateRequest(
            input: .array([
                .object([
                    "role": .string("user"),
                    "content": .array([
                        .object([
                            "type": .string("input_text"),
                            "text": .string(DonkeyPrompts.requestUnderstanding(
                                command: command,
                                frontmostAppName: frontmostAppName
                            ))
                        ])
                    ])
                ])
            ]),
            store: false,
            text: [
                "format": .object([
                    "type": .string("json_schema"),
                    "name": .string("harness_request_understanding_v1"),
                    "strict": .bool(false),
                    "schema": .object([
                        "type": .string("object"),
                        "additionalProperties": .bool(false),
                        "required": .array([.string("restatedGoal"), .string("needsClarification")]),
                        "properties": .object([
                            "restatedGoal": .object(["type": .string("string")]),
                            "targetAppName": .object(["type": .string("string")]),
                            "parameters": .object([
                                "type": .string("object"),
                                "additionalProperties": .object(["type": .string("string")])
                            ]),
                            "successCriteria": .object(["type": .string("string")]),
                            "needsClarification": .object(["type": .string("boolean")]),
                            "clarifyingQuestion": .object(["type": .string("string")])
                        ])
                    ])
                ])
            ],
            metadata: ["source": "hosted-harness-request-understanding", "prompt_version": "harness-request-understanding-v1"],
            parameters: [
                "temperature": .number(0),
                // Headroom for medium thinking PLUS the JSON understanding; tight caps starve the output.
                "max_output_tokens": .number(2_500),
                // Gemini 3.x honors thinking_level, not the integer thinking_budget (which it ignores).
                "thinking_level": .string("medium")
            ]
        )
    }

}
