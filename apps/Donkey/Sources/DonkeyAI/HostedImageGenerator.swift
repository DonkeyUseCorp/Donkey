import CoreGraphics
import DonkeyContracts
import DonkeyHarness
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The model boundary behind the generic `image.edit` / `image.generate` harness tools. It encodes
/// the source image(s), asks the hosted asset API for an image generation (provider AND model unset,
/// so the backend routes to its configured image model), waits for the result, and writes the output
/// file(s) to disk — keeping every provider/model detail behind the backend, not the app.
public struct HostedImageGenerator: Sendable {
    private let backend: DonkeyBackendInferenceClient
    private let timeoutSeconds: TimeInterval
    private let maxPixelSize: Int
    private let maxPollAttempts: Int

    public init(
        backend: DonkeyBackendInferenceClient,
        timeoutSeconds: TimeInterval = 120,
        // A generous longest-edge ceiling for edit/reference source images: only larger images are
        // downscaled (to bound request size); a normal-resolution source is sent at full detail.
        maxPixelSize: Int = 4_096,
        maxPollAttempts: Int = 30
    ) {
        self.backend = backend
        self.timeoutSeconds = timeoutSeconds
        self.maxPixelSize = maxPixelSize
        self.maxPollAttempts = maxPollAttempts
    }

    public func generate(
        _ request: HarnessImageGenerationRequest
    ) async -> HarnessImageGenerationResult? {
        // Encode inputs: the first path (an edit's source) is required if present; extra reference
        // paths are best-effort — an unreadable reference is skipped, not fatal to the whole edit.
        var images: [RemoteInferenceJSONValue] = []
        for (index, path) in request.inputImagePaths.enumerated() {
            if let encoded = Self.encodedSourceImage(atPath: path, maxPixelSize: maxPixelSize) {
                images.append(.object([
                    "data": .string(encoded.base64),
                    "mimeType": .string(encoded.mimeType)
                ]))
            } else if index == 0 {
                return HarnessImageGenerationResult(
                    savedPaths: [],
                    failureReason: "Could not read the source image at \(path)."
                )
            }
        }
        var inputs: RemoteInferenceJSONObject = [:]
        if !images.isEmpty {
            inputs["images"] = .array(images)
        }

        let trimmedModel = request.model?.trimmingCharacters(in: .whitespaces)
        let assetRequest = RemoteInferenceAssetGenerationRequest(
            kind: .image,
            provider: nil,
            model: (trimmedModel?.isEmpty == false) ? trimmedModel : nil,
            prompt: request.prompt,
            inputs: inputs,
            metadata: ["source": "image-tool"]
        )
        let outputDirectory = Self.resolvedOutputDirectory(
            request.outputDirectory,
            inputImagePaths: request.inputImagePaths
        )

        let backend = self.backend
        let maxPollAttempts = self.maxPollAttempts
        // One deadline over the whole call (create + poll + write); the request was synchronous in
        // practice, but polling/writing stay bounded so the harness step can't hang.
        let outcome = try? await AIDeadline.enforce(seconds: timeoutSeconds) {
            () -> HarnessImageGenerationResult in
            var record = try await backend.createAssetGeneration(assetRequest)
            var attempts = 0
            while record.status == .pending || record.status == .inProgress, attempts < maxPollAttempts {
                attempts += 1
                try await Task.sleep(nanoseconds: 1_000_000_000)
                do {
                    record = try await backend.refreshAssetGeneration(record)
                } catch {
                    // A transient refresh error shouldn't abort an in-flight generation — keep
                    // polling until it resolves or the attempt budget runs out.
                    continue
                }
            }
            guard record.status == .completed else {
                return HarnessImageGenerationResult(
                    savedPaths: [],
                    failureReason: Self.failureReason(from: record)
                )
            }
            let saved = await backend.writeOutputsFlat(record.outputs, to: outputDirectory) { index, _ in
                "image-\(index).png"
            }
            return HarnessImageGenerationResult(
                savedPaths: saved,
                failureReason: saved.isEmpty ? "The image model returned no image." : nil
            )
        }

        return outcome ?? HarnessImageGenerationResult(
            savedPaths: [],
            failureReason: "Image generation timed out or could not reach the model."
        )
    }

    /// Resolves where outputs are written. An absolute `outDir` is used as-is; a relative one resolves
    /// against the source image's folder (so "edited" lands next to the source) or, with no source,
    /// against Downloads. With no `outDir`, an edit writes next to its source and a generation writes
    /// to Downloads. Outputs are written FLAT into this directory (no per-generation nesting).
    static func resolvedOutputDirectory(
        _ outDir: String?,
        inputImagePaths: [String]
    ) -> URL {
        let fileManager = FileManager.default
        let sourceDir = inputImagePaths.first.map { path in
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath).deletingLastPathComponent()
        }
        let downloads = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)

        guard let outDir, !outDir.trimmingCharacters(in: .whitespaces).isEmpty else {
            return sourceDir ?? downloads
        }
        let expanded = (outDir as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return (sourceDir ?? downloads).appendingPathComponent(expanded, isDirectory: true)
    }

    private static func failureReason(from record: RemoteInferenceGenerationRecord) -> String {
        if let detail = errorText(record.error) {
            return "Image generation \(record.status.rawValue): \(detail)"
        }
        return "Image generation \(record.status.rawValue)."
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

    /// Encodes an edit/reference SOURCE image while preserving detail: a transparent image is encoded
    /// losslessly as PNG (alpha kept), an opaque one as high-quality JPEG. Only downscales when the
    /// longest edge exceeds `maxPixelSize`, so a normal-resolution source is sent unshrunk. Returns the
    /// base64 payload and MIME type, or nil when the file can't be read as an image.
    static func encodedSourceImage(
        atPath path: String,
        maxPixelSize: Int
    ) -> (base64: String, mimeType: String)? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = Self.image(from: source, maxPixelSize: maxPixelSize)
        else {
            return nil
        }
        if Self.hasAlpha(image), let png = Self.encodedPNG(image) {
            return (png.base64EncodedString(), "image/png")
        }
        guard let jpeg = Self.encodedJPEG(image, quality: 0.95) else { return nil }
        return (jpeg.base64EncodedString(), "image/jpeg")
    }

    /// Decodes the first image, downscaling (never upscaling) only if its longest edge exceeds
    /// `maxPixelSize`. Using the thumbnail path with a max-pixel hint keeps decode bounded.
    private static func image(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Thumbnail creation never upscales, so a smaller source is returned at its native size.
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            return true
        default:
            return false
        }
    }

    private static func encodedPNG(_ image: CGImage) -> Data? {
        encodedImageData(image, type: UTType.png.identifier as CFString, properties: nil)
    }

    private static func encodedJPEG(_ image: CGImage, quality: Double) -> Data? {
        encodedImageData(
            image,
            type: UTType.jpeg.identifier as CFString,
            properties: [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
    }

    private static func encodedImageData(_ image: CGImage, type: CFString, properties: CFDictionary?) -> Data? {
        guard let data = NSMutableData() as CFMutableData?,
              let destination = CGImageDestinationCreateWithData(data, type, 1, nil)
        else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
