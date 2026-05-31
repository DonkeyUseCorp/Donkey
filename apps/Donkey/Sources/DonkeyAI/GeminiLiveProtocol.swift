import Foundation

/// Builders and parsers for the Gemini Live `BidiGenerateContent` websocket
/// protocol. Uses `JSONSerialization` rather than fully-typed Codable because
/// the Live wire schema is still evolving; we build exactly the messages we send
/// and tolerantly parse the fields we care about.
public enum GeminiLiveProtocol {
    /// Audio Gemini Live expects on input: 16kHz mono PCM16 little-endian.
    public static let inputAudioMimeType = "audio/pcm;rate=16000"
    public static let imageMimeType = "image/jpeg"

    // MARK: - Outbound messages

    /// First message: declares model, modalities, tools, and session policies.
    public static func setupMessage(
        model: String,
        systemInstruction: String,
        functionDeclarations: [[String: Any]],
        includeAudioResponse: Bool,
        resumptionHandle: String?
    ) -> Data {
        // Vertex passes a fully-qualified `projects/.../models/...` path; the
        // Developer API wants a bare id prefixed with `models/`.
        let modelName = model.contains("/") ? model : "models/\(model)"
        var setup: [String: Any] = [
            "model": modelName,
            "generationConfig": [
                "responseModalities": includeAudioResponse ? ["AUDIO"] : ["TEXT"]
            ],
            "systemInstruction": ["parts": [["text": systemInstruction]]],
            // Keep long sessions alive past the hard duration limits.
            "contextWindowCompression": ["slidingWindow": [:]],
            // Always request transcripts so text input/output stay observable.
            "inputAudioTranscription": [:],
            "outputAudioTranscription": [:]
        ]
        if !functionDeclarations.isEmpty {
            setup["tools"] = [["functionDeclarations": functionDeclarations]]
        }
        var resumption: [String: Any] = [:]
        if let resumptionHandle, !resumptionHandle.isEmpty {
            resumption["handle"] = resumptionHandle
        }
        setup["sessionResumption"] = resumption
        return encode(["setup": setup])
    }

    /// A text turn from the user.
    public static func clientTextMessage(_ text: String) -> Data {
        encode([
            "clientContent": [
                "turns": [["role": "user", "parts": [["text": text]]]],
                "turnComplete": true
            ]
        ])
    }

    /// A streamed media chunk (audio or image) as realtime input.
    public static func realtimeMediaMessage(base64Data: String, mimeType: String) -> Data {
        encode([
            "realtimeInput": [
                "mediaChunks": [["mimeType": mimeType, "data": base64Data]]
            ]
        ])
    }

    /// Responses to one or more tool calls.
    public static func toolResponseMessage(_ results: [AIRealtimeToolResult]) -> Data {
        let functionResponses = results.map { result -> [String: Any] in
            [
                "id": result.id,
                "name": result.name,
                "response": result.response
            ]
        }
        return encode(["toolResponse": ["functionResponses": functionResponses]])
    }

    // MARK: - Inbound parsing

    /// Parse a server frame into zero or more realtime events.
    public static func parseServerEvents(_ data: Data) -> [AIRealtimeEvent] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        var events: [AIRealtimeEvent] = []

        if root["setupComplete"] != nil {
            events.append(.connected)
        }

        if let toolCall = root["toolCall"] as? [String: Any],
           let functionCalls = toolCall["functionCalls"] as? [[String: Any]] {
            let calls = functionCalls.compactMap { call -> AIRealtimeToolCall? in
                guard let name = call["name"] as? String else { return nil }
                let id = (call["id"] as? String) ?? name
                let args = (call["args"] as? [String: Any]) ?? [:]
                return AIRealtimeToolCall(id: id, name: name, arguments: stringifyArguments(args))
            }
            if !calls.isEmpty {
                events.append(.toolCalls(calls))
            }
        }

        if let serverContent = root["serverContent"] as? [String: Any] {
            if (serverContent["interrupted"] as? Bool) == true {
                events.append(.interrupted)
            }
            if let inputTranscription = serverContent["inputTranscription"] as? [String: Any],
               let text = inputTranscription["text"] as? String, !text.isEmpty {
                events.append(.partialTranscript(text))
            }
            if let modelTurn = serverContent["modelTurn"] as? [String: Any],
               let parts = modelTurn["parts"] as? [[String: Any]] {
                for part in parts {
                    if let inlineData = part["inlineData"] as? [String: Any],
                       let base64 = inlineData["data"] as? String,
                       let audio = Data(base64Encoded: base64) {
                        events.append(.audioOut(audio))
                    }
                }
            }
            if (serverContent["generationComplete"] as? Bool) == true {
                events.append(.generationComplete)
            }
            if (serverContent["turnComplete"] as? Bool) == true {
                if let outputTranscription = serverContent["outputTranscription"] as? [String: Any],
                   let text = outputTranscription["text"] as? String, !text.isEmpty {
                    events.append(.finalTranscript(text))
                }
            }
        }

        if let resumptionUpdate = root["sessionResumptionUpdate"] as? [String: Any],
           let handle = resumptionUpdate["newHandle"] as? String, !handle.isEmpty {
            events.append(.resumptionHandle(handle))
        }

        if let goAway = root["goAway"] as? [String: Any] {
            events.append(.goAway(timeLeftMS: durationMS(goAway["timeLeft"])))
        }

        return events
    }

    // MARK: - Helpers

    private static func stringifyArguments(_ args: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in args {
            switch value {
            case let string as String:
                result[key] = string
            case let bool as Bool:
                result[key] = bool ? "true" : "false"
            case let number as NSNumber:
                result[key] = number.stringValue
            default:
                if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
                   let string = String(data: data, encoding: .utf8) {
                    result[key] = string
                }
            }
        }
        return result
    }

    /// Parse Live duration values, which arrive as `"5s"` strings or numbers.
    private static func durationMS(_ value: Any?) -> Int {
        if let number = value as? NSNumber {
            return Int(number.doubleValue * 1000)
        }
        if let string = value as? String {
            let seconds = Double(string.replacingOccurrences(of: "s", with: "")) ?? 0
            return Int(seconds * 1000)
        }
        return 0
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}
