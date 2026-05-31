import AVFoundation
import DonkeyAI
import DonkeyContracts
import Foundation

@MainActor
final class MicrophoneWaveformMeter {
    private var engine: AVAudioEngine?
    private let barCount = UserQueryState.defaultVoiceWaveformLevels.count
    private var levels = UserQueryState.defaultVoiceWaveformLevels
    private var isRunning = false
    private var isStarting = false
    private var isRecordingAudio = false
    private var isContinuousListening = false
    private var capturedSamples: [Float] = []
    private var capturedSampleRateHz = 0
    private var capturedStartedAt: Date?

    var onLevelsChanged: (([Double]) -> Void)?
    /// Optional streaming hook: mono float32 samples + their sample rate, delivered
    /// per audio buffer. Used to stream microphone audio into a realtime session.
    var onAudioFrames: (([Float], Double) -> Void)?

    func start() {
        guard !isRunning, !isStarting else { return }

        isStarting = true
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] isGranted in
            Task { @MainActor in
                guard self?.isStarting == true else { return }

                guard isGranted else {
                    self?.isStarting = false
                    self?.isRecordingAudio = false
                    self?.publishSilence()
                    return
                }

                self?.startEngine()
            }
        }
    }

    /// Keep the mic engine running continuously so audio frames stream into a
    /// realtime session beyond the voice-capture window. Used when Live audio
    /// input is enabled.
    func startContinuousListening() {
        isContinuousListening = true
        start()
    }

    func stopContinuousListening() {
        isContinuousListening = false
        stop()
    }

    func stop() {
        // While continuously listening, ignore UI-driven stops so the always-on
        // audio stream survives the prompt closing. Tear down via
        // `stopContinuousListening()`.
        guard !isContinuousListening else { return }
        guard isRunning || isStarting || isRecordingAudio || engine != nil else { return }

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
        isStarting = false
        isRecordingAudio = false
        capturedSamples.removeAll(keepingCapacity: true)
        capturedStartedAt = nil
        publishSilence()
    }

    func startAudioCapture() {
        capturedSamples.removeAll(keepingCapacity: true)
        capturedSampleRateHz = currentInputSampleRateHz()
        capturedStartedAt = Date()
        isRecordingAudio = true
        start()
    }

    func finishAudioCapture() -> LocalVoiceAudioBuffer? {
        guard isRecordingAudio else { return nil }

        isRecordingAudio = false
        let sampleRateHz = capturedSampleRateHz > 0 ? capturedSampleRateHz : 48_000
        let samples = capturedSamples
        let startedAt = capturedStartedAt
        capturedSamples.removeAll(keepingCapacity: true)
        capturedStartedAt = nil
        guard !samples.isEmpty else { return nil }

        let durationMS = startedAt.map { Date().timeIntervalSince($0) * 1_000 }
            ?? (Double(samples.count) / Double(sampleRateHz) * 1_000)
        return LocalVoiceAudioBuffer(
            id: "user-query-audio-\(UUID().uuidString)",
            format: "pcm_f32le",
            sampleRateHz: sampleRateHz,
            channelCount: 1,
            durationMS: durationMS,
            data: Self.float32LittleEndianData(from: samples),
            metadata: [
                "source": "user-query",
                "encoding": "pcm_f32le",
                "sampleLayout": "mono"
            ]
        )
    }

    private func startEngine() {
        guard !isRunning else {
            isStarting = false
            return
        }

        let engine = engine ?? AVAudioEngine()
        self.engine = engine
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        if isRecordingAudio, capturedSampleRateHz == 0 {
            capturedSampleRateHz = Int(format.sampleRate)
        }
        levels = UserQueryState.defaultVoiceWaveformLevels
        publishLevels()

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 512,
            format: format,
            block: Self.makeTapBlock(meter: self)
        )

        engine.prepare()

        do {
            try engine.start()
            isRunning = true
            isStarting = false
        } catch {
            inputNode.removeTap(onBus: 0)
            self.engine = nil
            isRunning = false
            isStarting = false
            isRecordingAudio = false
            publishSilence()
        }
    }

    private func currentInputSampleRateHz() -> Int {
        guard let engine else { return 0 }

        return Int(engine.inputNode.outputFormat(forBus: 0).sampleRate)
    }

    private func append(_ level: Double) {
        levels.append(level)
        if levels.count > barCount {
            levels.removeFirst(levels.count - barCount)
        }

        publishLevels()
    }

    private func appendAudioSamples(_ samples: [Float]) {
        guard isRecordingAudio, !samples.isEmpty else { return }

        capturedSamples.append(contentsOf: samples)
    }

    private func emitAudioFrames(_ samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty, sampleRate > 0 else { return }

        onAudioFrames?(samples, sampleRate)
    }

    private func publishSilence() {
        levels = Array(repeating: 0.08, count: barCount)
        publishLevels()
    }

    private func publishLevels() {
        onLevelsChanged?(levels)
    }

    nonisolated private static func makeTapBlock(meter: MicrophoneWaveformMeter) -> AVAudioNodeTapBlock {
        { [weak meter] buffer, _ in
            let level = Self.normalizedLevel(from: buffer)
            let samples = Self.monoSamples(from: buffer)
            let sampleRate = buffer.format.sampleRate

            Task { @MainActor [weak meter, samples, level, sampleRate] in
                meter?.appendAudioSamples(samples)
                meter?.append(level)
                meter?.emitAudioFrames(samples, sampleRate: sampleRate)
            }
        }
    }

    nonisolated private static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData,
              buffer.frameLength > 0 else {
            return []
        }

        let frameCount = Int(buffer.frameLength)
        let firstChannel = channelData[0]
        return Array(UnsafeBufferPointer(start: firstChannel, count: frameCount))
    }

    nonisolated private static func float32LittleEndianData(from samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<UInt32>.size)
        for sample in samples {
            var bits = sample.bitPattern.littleEndian
            data.append(Data(bytes: &bits, count: MemoryLayout<UInt32>.size))
        }
        return data
    }

    nonisolated private static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData,
              buffer.frameLength > 0 else {
            return 0
        }

        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        var sumOfSquares: Float = 0
        var sampleCount = 0

        for channel in 0..<channelCount {
            let samples = channelData[channel]

            for frame in 0..<frameCount {
                let sample = samples[frame]
                sumOfSquares += sample * sample
            }

            sampleCount += frameCount
        }

        guard sampleCount > 0 else { return 0 }

        let rms = sqrt(sumOfSquares / Float(sampleCount))
        let decibels = 20 * log10(max(rms, 0.000_001))
        let normalized = (Double(decibels) + 55) / 45

        return min(max(normalized, 0), 1)
    }
}
