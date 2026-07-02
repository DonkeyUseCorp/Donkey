import DonkeyContracts
import DonkeyHarness
import Foundation

/// The model boundary behind the generic `video.generate` harness tool. It encodes an optional
/// first-frame image, asks the hosted asset API for a video generation (provider AND model unset, so
/// the backend routes to its configured video model — Veo), then polls until the clip is ready and
/// writes the output file(s) to disk — keeping every provider/model detail behind the backend.
///
/// Video generation is a long-running job: the backend submits it and returns `inProgress` with an
/// operation handle, and this poll loop drives `refreshAssetGeneration` until it completes. The budget
/// is far larger than the image generator's because Veo takes minutes, not the near-instant image path.
public struct HostedVideoGenerator: Sendable {
    private let backend: DonkeyBackendInferenceClient
    private let timeoutSeconds: TimeInterval
    private let maxPixelSize: Int
    private let maxPollAttempts: Int
    private let pollIntervalSeconds: UInt64

    public init(
        backend: DonkeyBackendInferenceClient,
        // Veo clips usually land in 30s–2min, but a cold/queued job can run longer; bound the whole
        // call so the harness step can't hang while still giving a slow generation room to finish.
        timeoutSeconds: TimeInterval = 660,
        maxPixelSize: Int = 4_096,
        maxPollAttempts: Int = 120,
        pollIntervalSeconds: UInt64 = 5
    ) {
        self.backend = backend
        self.timeoutSeconds = timeoutSeconds
        self.maxPixelSize = maxPixelSize
        self.maxPollAttempts = maxPollAttempts
        self.pollIntervalSeconds = pollIntervalSeconds
    }

    public func generate(
        _ request: HarnessVideoGenerationRequest
    ) async -> HarnessVideoGenerationResult? {
        // Encode the optional first-frame image (image-to-video). An unreadable path is fatal only
        // when one was explicitly supplied — a plain text-to-video request carries none. The image
        // tool's encoder is reused so the wire shape (inputs.images = [{ data, mimeType }]) matches
        // what the backend video adapter already parses.
        var inputs: RemoteInferenceJSONObject = [:]
        if let sourcePath = request.inputImagePaths.first {
            guard let encoded = HostedImageGenerator.encodedSourceImage(
                atPath: sourcePath,
                maxPixelSize: maxPixelSize
            ) else {
                return HarnessVideoGenerationResult(
                    savedPaths: [],
                    failureReason: "Could not read the source image at \(sourcePath)."
                )
            }
            inputs["images"] = .array([
                .object([
                    "data": .string(encoded.base64),
                    "mimeType": .string(encoded.mimeType)
                ])
            ])
        }

        let trimmedModel = request.model?.trimmingCharacters(in: .whitespaces)
        let assetRequest = RemoteInferenceAssetGenerationRequest(
            kind: .video,
            provider: nil,
            model: (trimmedModel?.isEmpty == false) ? trimmedModel : nil,
            prompt: request.prompt,
            inputs: inputs,
            parameters: Self.parameters(from: request),
            metadata: ["source": "video-tool"]
        )
        let outputDirectory = HostedImageGenerator.resolvedOutputDirectory(
            request.outputDirectory,
            inputImagePaths: request.inputImagePaths,
            workspaceBaseDir: request.workspaceBaseDir
        )

        let backend = self.backend
        let maxPollAttempts = self.maxPollAttempts
        let pollIntervalSeconds = self.pollIntervalSeconds
        do {
            return try await AIDeadline.enforce(seconds: timeoutSeconds) {
            () -> HarnessVideoGenerationResult in
            var record = try await backend.createAssetGeneration(assetRequest)
            var attempts = 0
            while record.status == .pending || record.status == .inProgress, attempts < maxPollAttempts {
                attempts += 1
                try await Task.sleep(nanoseconds: pollIntervalSeconds * 1_000_000_000)
                do {
                    record = try await backend.refreshAssetGeneration(record)
                } catch {
                    // A transient refresh error shouldn't abort an in-flight generation — keep
                    // polling until it resolves or the attempt budget runs out.
                    continue
                }
            }
            guard record.status == .completed else {
                return HarnessVideoGenerationResult(
                    savedPaths: [],
                    failureReason: Self.failureReason(from: record)
                )
            }
            let saved = await backend.writeOutputsFlat(record.outputs, to: outputDirectory) { index, _ in
                "video-\(index).mp4"
            }
            return HarnessVideoGenerationResult(
                savedPaths: saved,
                failureReason: saved.isEmpty ? "The video model returned no video." : nil
            )
            }
        } catch let error where DonkeyCreditExhaustion.isExhausted(error) {
            return HarnessVideoGenerationResult(
                savedPaths: [],
                failureReason: DonkeyCreditExhaustion.userMessage()
            )
        } catch {
            return HarnessVideoGenerationResult(
                savedPaths: [],
                failureReason: HostedImageGenerator.generationFailureReason("Video generation", for: error)
            )
        }
    }

    /// Maps the typed Veo knobs onto the provider-neutral `parameters` object the backend video
    /// adapter reads. Omitted fields are left out so the model/back-end default stays in place.
    private static func parameters(
        from request: HarnessVideoGenerationRequest
    ) -> RemoteInferenceJSONObject {
        var parameters: RemoteInferenceJSONObject = [:]
        if let tier = request.tier?.trimmingCharacters(in: .whitespaces), !tier.isEmpty {
            parameters["tier"] = .string(tier)
        }
        if let audio = request.audio {
            parameters["generateAudio"] = .bool(audio)
        }
        if let aspectRatio = request.aspectRatio?.trimmingCharacters(in: .whitespaces),
           !aspectRatio.isEmpty {
            parameters["aspectRatio"] = .string(aspectRatio)
        }
        if let durationSeconds = request.durationSeconds {
            parameters["durationSeconds"] = .number(Double(durationSeconds))
        }
        if let negativePrompt = request.negativePrompt?.trimmingCharacters(in: .whitespaces),
           !negativePrompt.isEmpty {
            parameters["negativePrompt"] = .string(negativePrompt)
        }
        return parameters
    }

    private static func failureReason(from record: RemoteInferenceGenerationRecord) -> String {
        if let detail = errorText(record.error) {
            return "Video generation \(record.status.rawValue): \(detail)"
        }
        return "Video generation \(record.status.rawValue)."
    }

    private static func errorText(_ value: RemoteInferenceJSONValue?) -> String? {
        switch value {
        case .string(let text):
            return text
        case .object(let object):
            if case .string(let message)? = object["message"] {
                return message
            }
            return nil
        default:
            return nil
        }
    }
}
