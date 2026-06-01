import CoreGraphics
import Foundation
import ImageIO

/// Cheap "did the screen change" probe for the box-based vision flow. Between the
/// in-turn click attempts (box center, then nearby points) we need to know whether
/// a click landed — without a model round-trip. We downscale both PNGs to a small
/// grayscale thumbnail and compare mean absolute pixel difference, which ignores
/// the cursor and minor rendering noise while still catching a real UI change.
public enum ScreenshotChange {
    /// True when two PNG screenshots differ by more than `threshold` (mean absolute
    /// difference, 0–1) over a small grayscale thumbnail. If either image can't be
    /// decoded, returns true so the caller doesn't get stuck assuming "no change".
    public static func changed(
        _ before: Data,
        _ after: Data,
        threshold: Double = 0.02,
        sampleDimension: Int = 32
    ) -> Bool {
        guard let a = grayscale(before, dimension: sampleDimension),
              let b = grayscale(after, dimension: sampleDimension),
              a.count == b.count, !a.isEmpty
        else { return true }
        var total = 0.0
        for index in a.indices {
            total += abs(Double(a[index]) - Double(b[index]))
        }
        let mean = total / Double(a.count) / 255.0
        return mean > threshold
    }

    private static func grayscale(_ png: Data, dimension: Int) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: dimension
              ] as CFDictionary)
        else { return nil }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
