import DonkeyContracts
import DonkeyRuntime
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
    case invalidOutput(String)
}

public enum LocalVoiceAudioNormalizer {
    public static func parakeetCompatibleAudio(
        from audio: LocalVoiceAudioBuffer
    ) -> LocalVoiceAudioBuffer {
        let normalizedFormat = audio.format.lowercased()
        if ["wav", "flac"].contains(normalizedFormat),
           audio.sampleRateHz == 16_000,
           audio.channelCount == 1 {
            return audio.withMetadata([
                "audio.normalization.status": "notRequired",
                "audio.normalization.target": "parakeet-16khz-mono"
            ])
        }

        guard normalizedFormat == "pcm_f32le",
              audio.channelCount == 1,
              audio.sampleRateHz > 0,
              !audio.data.isEmpty
        else {
            return audio.withMetadata([
                "audio.normalization.status": "unsupportedInputFormat",
                "audio.normalization.target": "parakeet-16khz-mono",
                "audio.normalization.sourceFormat": audio.format,
                "audio.normalization.sourceSampleRateHz": String(audio.sampleRateHz),
                "audio.normalization.sourceChannelCount": String(audio.channelCount)
            ])
        }

        let samples = float32Samples(from: audio.data)
        guard !samples.isEmpty else {
            return audio.withMetadata([
                "audio.normalization.status": "emptyPCM",
                "audio.normalization.target": "parakeet-16khz-mono"
            ])
        }

        let resampled = resample(samples, sourceRate: audio.sampleRateHz, targetRate: 16_000)
        let wavData = wavPCM16Data(samples: resampled, sampleRateHz: 16_000)
        let durationMS = Double(resampled.count) / 16_000 * 1_000
        return LocalVoiceAudioBuffer(
            id: audio.id,
            format: "wav",
            sampleRateHz: 16_000,
            channelCount: 1,
            durationMS: durationMS,
            data: wavData,
            metadata: audio.metadata.merging([
                "audio.normalization.status": "converted",
                "audio.normalization.target": "parakeet-16khz-mono-wav",
                "audio.normalization.sourceFormat": audio.format,
                "audio.normalization.sourceSampleRateHz": String(audio.sampleRateHz),
                "audio.normalization.sourceChannelCount": String(audio.channelCount),
                "audio.normalization.sourceByteCount": String(audio.data.count),
                "audio.normalization.outputByteCount": String(wavData.count)
            ]) { current, _ in current }
        )
    }

    private static func float32Samples(from data: Data) -> [Float] {
        let sampleCount = data.count / MemoryLayout<UInt32>.size
        guard sampleCount > 0 else { return [] }

        var samples: [Float] = []
        samples.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            let offset = index * MemoryLayout<UInt32>.size
            let bits = data[offset..<(offset + MemoryLayout<UInt32>.size)].reduce(UInt32(0)) { value, byte in
                (value >> 8) | (UInt32(byte) << 24)
            }
            samples.append(Float(bitPattern: UInt32(littleEndian: bits)))
        }
        return samples
    }

    private static func resample(
        _ samples: [Float],
        sourceRate: Int,
        targetRate: Int
    ) -> [Float] {
        guard sourceRate != targetRate else { return samples }
        let outputCount = max(1, Int((Double(samples.count) * Double(targetRate) / Double(sourceRate)).rounded()))
        guard samples.count > 1 else {
            return Array(repeating: samples.first ?? 0, count: outputCount)
        }

        let sourceStep = Double(sourceRate) / Double(targetRate)
        return (0..<outputCount).map { outputIndex in
            let sourcePosition = Double(outputIndex) * sourceStep
            let lowerIndex = min(samples.count - 1, Int(sourcePosition.rounded(.down)))
            let upperIndex = min(samples.count - 1, lowerIndex + 1)
            let fraction = Float(sourcePosition - Double(lowerIndex))
            return samples[lowerIndex] + (samples[upperIndex] - samples[lowerIndex]) * fraction
        }
    }

    private static func wavPCM16Data(samples: [Float], sampleRateHz: Int) -> Data {
        var pcmData = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let clamped = min(max(sample, -1), 1)
            var value = Int16(clamped * Float(Int16.max)).littleEndian
            pcmData.append(Data(bytes: &value, count: MemoryLayout<Int16>.size))
        }

        var data = Data()
        appendASCII("RIFF", to: &data)
        appendUInt32(UInt32(36 + pcmData.count), to: &data)
        appendASCII("WAVE", to: &data)
        appendASCII("fmt ", to: &data)
        appendUInt32(16, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(1, to: &data)
        appendUInt32(UInt32(sampleRateHz), to: &data)
        appendUInt32(UInt32(sampleRateHz * 2), to: &data)
        appendUInt16(2, to: &data)
        appendUInt16(16, to: &data)
        appendASCII("data", to: &data)
        appendUInt32(UInt32(pcmData.count), to: &data)
        data.append(pcmData)
        return data
    }

    private static func appendASCII(_ value: String, to data: inout Data) {
        data.append(contentsOf: value.utf8)
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        data.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        data.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
    }
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

        let preparedAudio = LocalVoiceAudioNormalizer.parakeetCompatibleAudio(from: request.audio)
        do {
            let transcript = try await runtime.transcribe(audio: preparedAudio, model: entry)
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
                    metadata: metadata(for: request.audio, preparedAudio: preparedAudio, transcript: transcript)
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
                    metadata: metadata(for: request.audio, preparedAudio: preparedAudio)
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
                    metadata: metadata(for: request.audio, preparedAudio: preparedAudio).merging([
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
        preparedAudio: LocalVoiceAudioBuffer? = nil,
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
        if let preparedAudio {
            values["audio.prepared.format"] = preparedAudio.format
            values["audio.prepared.sampleRateHz"] = String(preparedAudio.sampleRateHz)
            values["audio.prepared.channelCount"] = String(preparedAudio.channelCount)
            values["audio.prepared.durationMS"] = String(preparedAudio.durationMS)
            values["audio.prepared.byteCount"] = String(preparedAudio.data.count)
            values.merge(preparedAudio.metadata.filter { key, _ in
                key.hasPrefix("audio.normalization.")
            }) { current, _ in current }
        }
        if let transcript {
            values["transcript.confidence"] = String(transcript.confidence)
            values["transcript.language"] = transcript.language ?? ""
            values["transcript.segmentCount"] = String(transcript.segments.count)
            // Surface which backend actually answered (apple-speechanalyzer / apple-sfspeech / gemini)
            // so the trace reflects reality: a fallback to a network backend is not local-only.
            values.merge(transcript.metadata) { _, new in new }
            if let backend = transcript.metadata["transcript.backend"] {
                values["localOnly"] = backend.hasPrefix("apple") ? "true" : "false"
            }
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

private extension LocalVoiceAudioBuffer {
    func withMetadata(_ values: [String: String]) -> LocalVoiceAudioBuffer {
        LocalVoiceAudioBuffer(
            id: id,
            format: format,
            sampleRateHz: sampleRateHz,
            channelCount: channelCount,
            durationMS: durationMS,
            data: data,
            metadata: metadata.merging(values) { current, _ in current }
        )
    }
}
