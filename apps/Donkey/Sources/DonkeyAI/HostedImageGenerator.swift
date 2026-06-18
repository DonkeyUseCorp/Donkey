import CoreGraphics
import DonkeyContracts
import DonkeyHarness
import DonkeyRuntime
import Foundation
import ImageIO

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
        maxPixelSize: Int = 2_048,
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
            if let encoded = Self.encodedImage(atPath: path, maxPixelSize: maxPixelSize) {
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
            let saved = await Self.writeOutputs(record.outputs, to: outputDirectory)
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

    private static func writeOutputs(
        _ outputs: [RemoteInferenceOutputRef],
        to directory: URL
    ) async -> [String] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var saved: [String] = []
        var used = Set<String>()
        for (index, output) in outputs.enumerated() {
            guard let data = await outputData(output) else { continue }
            let preferred = output.filename ?? "image-\(index).png"
            var name = preferred
            var suffix = 1
            while used.contains(name) {
                let base = (preferred as NSString).deletingPathExtension
                let ext = (preferred as NSString).pathExtension
                name = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
                suffix += 1
            }
            used.insert(name)
            let fileURL = directory.appendingPathComponent(name, isDirectory: false)
            if (try? data.write(to: fileURL, options: [.atomic])) != nil {
                saved.append(fileURL.path)
            }
        }
        return saved
    }

    private static func outputData(_ output: RemoteInferenceOutputRef) async -> Data? {
        if let base64 = output.dataBase64, let data = Data(base64Encoded: base64) {
            return data
        }
        if let urlString = output.url, let url = URL(string: urlString) {
            return try? Data(contentsOf: url)
        }
        return nil
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

    /// Loads an image from disk, downscales it to at most `maxPixelSize` on its longest edge, and
    /// re-encodes it as JPEG so the request body stays small. Returns the base64 payload and MIME
    /// type, or nil when the file can't be read as an image.
    static func encodedImage(
        atPath path: String,
        maxPixelSize: Int
    ) -> (base64: String, mimeType: String)? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let encoded = ScreenshotCompression.downscaledJPEG(
                  from: source,
                  maxPixelDimension: maxPixelSize,
                  jpegQuality: 0.9
              )
        else {
            return nil
        }
        return (encoded.data.base64EncodedString(), "image/jpeg")
    }
}
