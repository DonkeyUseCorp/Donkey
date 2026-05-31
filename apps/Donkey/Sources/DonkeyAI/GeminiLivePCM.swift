import Foundation

/// Audio conversion for Gemini Live input: mono float32 samples → raw 16kHz
/// PCM16 little-endian (no WAV header, which is what the Live socket expects).
public enum GeminiLivePCM {
    public static let targetSampleRate = 16_000

    /// Convert mono float32 samples at `sourceRate` to raw 16kHz PCM16 LE.
    public static func pcm16Mono16k(from samples: [Float], sourceRate: Int) -> Data {
        let resampled = resample(samples, sourceRate: sourceRate, targetRate: targetSampleRate)
        var data = Data(capacity: resampled.count * MemoryLayout<Int16>.size)
        for sample in resampled {
            let clamped = min(max(sample, -1), 1)
            var value = Int16(clamped * Float(Int16.max)).littleEndian
            data.append(Data(bytes: &value, count: MemoryLayout<Int16>.size))
        }
        return data
    }

    /// Linear-interpolation resample (matches the local transcription path).
    static func resample(_ samples: [Float], sourceRate: Int, targetRate: Int) -> [Float] {
        guard sourceRate > 0, targetRate > 0, sourceRate != targetRate else { return samples }
        guard samples.count > 1 else { return samples }

        let outputCount = max(1, Int((Double(samples.count) * Double(targetRate) / Double(sourceRate)).rounded()))
        let sourceStep = Double(sourceRate) / Double(targetRate)
        return (0..<outputCount).map { outputIndex in
            let sourcePosition = Double(outputIndex) * sourceStep
            let lowerIndex = min(samples.count - 1, Int(sourcePosition.rounded(.down)))
            let upperIndex = min(samples.count - 1, lowerIndex + 1)
            let fraction = Float(sourcePosition - Double(lowerIndex))
            return samples[lowerIndex] + (samples[upperIndex] - samples[lowerIndex]) * fraction
        }
    }
}
