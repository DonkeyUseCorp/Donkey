import CoreGraphics
import DonkeyContracts
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A screenshot compressed for sending to a hosted model: downscaled + JPEG-encoded, with the
/// resulting pixel size (model coordinates are in this space and must be scaled back by callers).
public struct CompressedScreenshot: Sendable {
    public var data: Data
    public var contentType: String
    public var pixelSize: HotLoopSize

    public init(data: Data, contentType: String, pixelSize: HotLoopSize) {
        self.data = data
        self.contentType = contentType
        self.pixelSize = pixelSize
    }

    public var base64DataURL: String {
        "data:\(contentType);base64,\(data.base64EncodedString())"
    }
}

/// Shared screenshot compression for hosted vision requests — downscale to a max dimension and
/// JPEG-compress so payloads stay small. Used by debug UI inspection and the vision action planner
/// so every screenshot we send the model is prepared the same way.
public enum ScreenshotCompression {
    public static func compressedForModel(
        _ screenshot: CapturedWindowScreenshot,
        maxPixelDimension: Int = 896,
        jpegQuality: Double = 0.48
    ) -> CompressedScreenshot {
        let fallback = CompressedScreenshot(
            data: screenshot.pngData,
            contentType: "image/png",
            pixelSize: HotLoopSize(width: Double(screenshot.imageWidth), height: Double(screenshot.imageHeight), space: .window)
        )
        guard let source = CGImageSourceCreateWithData(screenshot.pngData as CFData, nil) else {
            return fallback
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary),
              let encoded = NSMutableData() as CFMutableData?,
              let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            return fallback
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: jpegQuality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return fallback
        }
        return CompressedScreenshot(
            data: encoded as Data,
            contentType: "image/jpeg",
            pixelSize: HotLoopSize(width: Double(image.width), height: Double(image.height), space: .window)
        )
    }
}
