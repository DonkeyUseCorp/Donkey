import Foundation

/// Tries a list of transcription runtimes in order, advancing to the next one on a
/// thrown error or an empty transcript and returning the first non-empty result.
///
/// This is how "Apple on-device primary, Gemini automatic fallback" is composed:
/// the router still selects a single registry entry so the adapter's tracing is
/// unchanged, and this runtime owns the provider order. A user cancellation stops
/// the chain immediately rather than falling through to the next provider.
public struct FallbackVoiceTranscriptionRuntime: LocalVoiceTranscriptionRuntime {
    private let runtimes: [any LocalVoiceTranscriptionRuntime]

    public init(runtimes: [any LocalVoiceTranscriptionRuntime]) {
        self.runtimes = runtimes
    }

    public func transcribe(
        audio: LocalVoiceAudioBuffer,
        model: AIModelRegistryEntry
    ) async throws -> LocalVoiceTranscript {
        var lastError: Error?
        for runtime in runtimes {
            do {
                let transcript = try await runtime.transcribe(audio: audio, model: model)
                if !transcript.text.isEmpty {
                    return transcript
                }
                lastError = LocalVoiceTranscriptionRuntimeError.emptyTranscript
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError ?? LocalVoiceTranscriptionRuntimeError.runtimeUnavailable("fallback-no-runtimes")
    }
}
