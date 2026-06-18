import DonkeyAI
import DonkeyContracts
import DonkeyRuntime
import Foundation
import Testing

@Suite
struct VoiceTranscriptionRuntimeTests {
    // MARK: - Fallback ordering

    @Test
    func fallbackUsesSecondRuntimeWhenFirstThrows() async throws {
        let runtime = FallbackVoiceTranscriptionRuntime(runtimes: [
            ThrowingVoiceRuntime(error: LocalVoiceTranscriptionRuntimeError.runtimeUnavailable("apple")),
            StaticVoiceRuntime(text: "from gemini")
        ])

        let transcript = try await runtime.transcribe(audio: Self.audio(), model: Self.entry())

        #expect(transcript.text == "from gemini")
    }

    @Test
    func fallbackUsesSecondRuntimeWhenFirstReturnsEmpty() async throws {
        let runtime = FallbackVoiceTranscriptionRuntime(runtimes: [
            StaticVoiceRuntime(text: ""),
            StaticVoiceRuntime(text: "from gemini")
        ])

        let transcript = try await runtime.transcribe(audio: Self.audio(), model: Self.entry())

        #expect(transcript.text == "from gemini")
    }

    @Test
    func fallbackStopsAtFirstSuccess() async throws {
        let second = CountingVoiceRuntime(text: "second")
        let runtime = FallbackVoiceTranscriptionRuntime(runtimes: [
            StaticVoiceRuntime(text: "first"),
            second
        ])

        let transcript = try await runtime.transcribe(audio: Self.audio(), model: Self.entry())

        #expect(transcript.text == "first")
        #expect(await second.callCount == 0)
    }

    @Test
    func fallbackRethrowsLastErrorWhenAllFail() async {
        let runtime = FallbackVoiceTranscriptionRuntime(runtimes: [
            ThrowingVoiceRuntime(error: LocalVoiceTranscriptionRuntimeError.runtimeUnavailable("apple")),
            ThrowingVoiceRuntime(error: LocalVoiceTranscriptionRuntimeError.emptyTranscript)
        ])

        await #expect(throws: LocalVoiceTranscriptionRuntimeError.emptyTranscript) {
            _ = try await runtime.transcribe(audio: Self.audio(), model: Self.entry())
        }
    }

    @Test
    func fallbackStopsImmediatelyOnCancellation() async {
        let second = CountingVoiceRuntime(text: "second")
        let runtime = FallbackVoiceTranscriptionRuntime(runtimes: [
            ThrowingVoiceRuntime(error: CancellationError()),
            second
        ])

        await #expect(throws: CancellationError.self) {
            _ = try await runtime.transcribe(audio: Self.audio(), model: Self.entry())
        }
        #expect(await second.callCount == 0)
    }

    // MARK: - Gemini request shape

    @Test
    func geminiDeveloperAPIRequestSendsInlineWavAndDecodesTranscript() async throws {
        let http = FakeVoiceHTTPClient(
            data: Data(#"{"candidates":[{"content":{"parts":[{"text":"  hello world  "}]}}]}"#.utf8),
            statusCode: 200
        )
        let runtime = GeminiVoiceTranscriptionRuntime(
            apiKey: "test-key",
            model: "gemini-test",
            httpClient: http,
            environment: [:]
        )

        let transcript = try await runtime.transcribe(
            audio: Self.audio(data: Data([1, 2, 3])),
            model: Self.entry()
        )

        #expect(transcript.text == "hello world")
        #expect(transcript.metadata["transcript.backend"] == "gemini")
        #expect(transcript.metadata["transcript.model"] == "gemini-test")

        let request = try #require(http.requests.first)
        let urlString = try #require(request.url?.absoluteString)
        #expect(urlString.contains("generativelanguage.googleapis.com/v1beta/models/gemini-test:generateContent"))
        #expect(urlString.contains("key=test-key"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)

        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let parts = try #require(
            ((json["contents"] as? [[String: Any]])?.first?["parts"]) as? [[String: Any]]
        )
        let inlineData = try #require(parts.compactMap { $0["inlineData"] as? [String: Any] }.first)
        #expect(inlineData["mimeType"] as? String == "audio/wav")
        #expect(inlineData["data"] as? String == Data([1, 2, 3]).base64EncodedString())
    }

    @Test
    func geminiThrowsEmptyTranscriptWhenNoText() async {
        let http = FakeVoiceHTTPClient(
            data: Data(#"{"candidates":[{"content":{"parts":[{"text":"   "}]}}]}"#.utf8),
            statusCode: 200
        )
        let runtime = GeminiVoiceTranscriptionRuntime(
            apiKey: "test-key",
            httpClient: http,
            environment: [:]
        )

        await #expect(throws: LocalVoiceTranscriptionRuntimeError.emptyTranscript) {
            _ = try await runtime.transcribe(audio: Self.audio(), model: Self.entry())
        }
    }

    // MARK: - Fixtures

    private static func audio(data: Data = Data([0, 1, 2, 3])) -> LocalVoiceAudioBuffer {
        LocalVoiceAudioBuffer(
            id: "audio-fixture",
            format: "wav",
            sampleRateHz: 16_000,
            channelCount: 1,
            durationMS: 250,
            data: data
        )
    }

    private static func entry() -> AIModelRegistryEntry {
        AIModelRegistryEntry(
            id: "local-voice-transcription-apple-on-device",
            role: .voiceTranscription,
            provider: .localRuntime,
            modelID: "apple-on-device",
            endpoint: URL(string: "local://apple/speech-on-device")!,
            capabilities: [.audioInput],
            timeoutMS: 15_000,
            promptVersion: "voice-transcription-v1",
            evalStatus: .candidate,
            docsURL: URL(string: "donkey://docs/guides/agent-harness")!
        )
    }
}

private struct ThrowingVoiceRuntime: LocalVoiceTranscriptionRuntime {
    let error: Error

    func transcribe(audio: LocalVoiceAudioBuffer, model: AIModelRegistryEntry) async throws -> LocalVoiceTranscript {
        throw error
    }
}

private struct StaticVoiceRuntime: LocalVoiceTranscriptionRuntime {
    let text: String

    func transcribe(audio: LocalVoiceAudioBuffer, model: AIModelRegistryEntry) async throws -> LocalVoiceTranscript {
        LocalVoiceTranscript(text: text, confidence: 1)
    }
}

private actor CountingVoiceRuntime: LocalVoiceTranscriptionRuntime {
    private let text: String
    private(set) var callCount = 0

    init(text: String) {
        self.text = text
    }

    func transcribe(audio: LocalVoiceAudioBuffer, model: AIModelRegistryEntry) async throws -> LocalVoiceTranscript {
        callCount += 1
        return LocalVoiceTranscript(text: text, confidence: 1)
    }
}

private final class FakeVoiceHTTPClient: AIHTTPClient, @unchecked Sendable {
    let data: Data
    let statusCode: Int
    private(set) var requests: [URLRequest] = []

    init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (
            data,
            HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        )
    }
}
