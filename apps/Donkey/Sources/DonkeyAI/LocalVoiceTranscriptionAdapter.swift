import DonkeyContracts
import Foundation

public struct LocalVoiceAudioBuffer: Equatable, Sendable {
    public var id: String
    public var format: String
    public var sampleRateHz: Int
    public var channelCount: Int
    public var durationMS: Double
    public var data: Data
    public var metadata: [String: String]

    public init(
        id: String,
        format: String = "wav",
        sampleRateHz: Int = 16_000,
        channelCount: Int = 1,
        durationMS: Double,
        data: Data,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.format = format
        self.sampleRateHz = sampleRateHz
        self.channelCount = channelCount
        self.durationMS = max(0, durationMS)
        self.data = data
        self.metadata = metadata
    }
}

public struct LocalVoiceTranscriptionRequest: Equatable, Sendable {
    public var audio: LocalVoiceAudioBuffer
    public var sourceTraceID: String
    public var routeRequest: AIModelRouteRequest

    public init(
        audio: LocalVoiceAudioBuffer,
        sourceTraceID: String,
        routeRequest: AIModelRouteRequest = AIModelRouteRequest(
            jobType: .voiceTranscription,
            requiredCapabilities: [.audioInput],
            allowedProviders: [.localRuntime]
        )
    ) {
        self.audio = audio
        self.sourceTraceID = sourceTraceID
        self.routeRequest = routeRequest
    }
}

public struct LocalVoiceTranscript: Codable, Equatable, Sendable {
    public var text: String
    public var language: String?
    public var confidence: Double
    public var segments: [String]
    public var metadata: [String: String]

    public init(
        text: String,
        language: String? = nil,
        confidence: Double,
        segments: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = language
        self.confidence = min(max(confidence, 0), 1)
        self.segments = segments
        self.metadata = metadata
    }
}

public struct LocalVoiceTranscriptionResult: Equatable, Sendable {
    public var transcript: LocalVoiceTranscript?
    public var trace: AIModelCallTrace

    public init(transcript: LocalVoiceTranscript?, trace: AIModelCallTrace) {
        self.transcript = transcript
        self.trace = trace
    }
}

public protocol LocalVoiceTranscriptionRuntime: Sendable {
    func transcribe(
        audio: LocalVoiceAudioBuffer,
        model: AIModelRegistryEntry
    ) async throws -> LocalVoiceTranscript
}

public struct UnavailableLocalVoiceTranscriptionRuntime: LocalVoiceTranscriptionRuntime {
    public init() {}

    public func transcribe(
        audio: LocalVoiceAudioBuffer,
        model: AIModelRegistryEntry
    ) async throws -> LocalVoiceTranscript {
        throw LocalVoiceTranscriptionRuntimeError.runtimeUnavailable(model.id)
    }
}

public enum LocalVoiceTranscriptionRuntimeError: Error, Equatable, Sendable {
    case runtimeUnavailable(String)
    case emptyTranscript
}

public struct LocalVoiceTranscriptionAdapter: Sendable {
    public var router: AIModelRouter
    public var runtime: any LocalVoiceTranscriptionRuntime
    public var now: @Sendable () -> RunTraceTimestamp

    public init(
        router: AIModelRouter = AIModelRouter(registry: .defaultHybridPlanner),
        runtime: any LocalVoiceTranscriptionRuntime = UnavailableLocalVoiceTranscriptionRuntime(),
        now: @escaping @Sendable () -> RunTraceTimestamp = Self.defaultNow
    ) {
        self.router = router
        self.runtime = runtime
        self.now = now
    }

    public func transcribe(_ request: LocalVoiceTranscriptionRequest) async -> LocalVoiceTranscriptionResult {
        let startedAt = now()
        let entry: AIModelRegistryEntry
        do {
            entry = try router.route(request.routeRequest)
        } catch {
            return LocalVoiceTranscriptionResult(
                transcript: nil,
                trace: trace(
                    model: nil,
                    sourceTraceID: request.sourceTraceID,
                    startedAt: startedAt,
                    status: .providerOutage,
                    validationStatus: "routingFailed",
                    metadata: ["reason": String(describing: error)]
                )
            )
        }

        do {
            let transcript = try await runtime.transcribe(audio: request.audio, model: entry)
            guard !transcript.text.isEmpty else {
                throw LocalVoiceTranscriptionRuntimeError.emptyTranscript
            }
            return LocalVoiceTranscriptionResult(
                transcript: transcript,
                trace: trace(
                    model: entry,
                    sourceTraceID: request.sourceTraceID,
                    startedAt: startedAt,
                    status: .completed,
                    validationStatus: "transcriptDecoded",
                    metadata: metadata(for: request.audio, transcript: transcript)
                )
            )
        } catch is CancellationError {
            return LocalVoiceTranscriptionResult(
                transcript: nil,
                trace: trace(
                    model: entry,
                    sourceTraceID: request.sourceTraceID,
                    startedAt: startedAt,
                    status: .cancelled,
                    validationStatus: "notValidated",
                    metadata: metadata(for: request.audio)
                )
            )
        } catch {
            return LocalVoiceTranscriptionResult(
                transcript: nil,
                trace: trace(
                    model: entry,
                    sourceTraceID: request.sourceTraceID,
                    startedAt: startedAt,
                    status: .providerOutage,
                    validationStatus: "notValidated",
                    metadata: metadata(for: request.audio).merging([
                        "reason": String(describing: error)
                    ]) { current, _ in current }
                )
            )
        }
    }

    private func trace(
        model: AIModelRegistryEntry?,
        sourceTraceID: String,
        startedAt: RunTraceTimestamp,
        status: AIModelCallStatus,
        validationStatus: String,
        metadata: [String: String]
    ) -> AIModelCallTrace {
        let completedAt = now()
        return AIModelCallTrace(
            id: "voice-transcription-\(sourceTraceID)",
            role: .voiceTranscription,
            provider: model?.provider ?? .localRuntime,
            modelID: model?.modelID ?? "unrouted",
            promptVersion: model?.promptVersion ?? "voice-transcription-v1",
            schemaID: "voice-transcript-v1",
            latencyMS: startedAt.milliseconds(until: completedAt),
            timeoutMS: model?.timeoutMS ?? 0,
            status: status,
            validationStatus: validationStatus,
            sourceTraceID: sourceTraceID,
            metadata: metadata.merging([
                "localOnly": "true",
                "transcriptFeedsCommandParser": "true"
            ]) { current, _ in current }
        )
    }

    private func metadata(
        for audio: LocalVoiceAudioBuffer,
        transcript: LocalVoiceTranscript? = nil
    ) -> [String: String] {
        var values = [
            "audio.id": audio.id,
            "audio.format": audio.format,
            "audio.sampleRateHz": String(audio.sampleRateHz),
            "audio.channelCount": String(audio.channelCount),
            "audio.durationMS": String(audio.durationMS),
            "audio.byteCount": String(audio.data.count)
        ]
        if let transcript {
            values["transcript.confidence"] = String(transcript.confidence)
            values["transcript.language"] = transcript.language ?? ""
            values["transcript.segmentCount"] = String(transcript.segments.count)
        }
        return values
    }

    public static func defaultNow() -> RunTraceTimestamp {
        RunTraceTimestamp(
            wallClock: Date(),
            monotonicUptimeNanoseconds: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        )
    }
}
