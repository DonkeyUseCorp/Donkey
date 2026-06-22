import CoreGraphics
import Foundation
import ImageIO

/// A compact, scale-normalized fingerprint of a screenshot used to decide whether a window
/// changed enough to justify re-running an expensive vision parse.
///
/// We deliberately do NOT use an exact byte hash (e.g. SHA256 of the JPEG): a live window is
/// almost never byte-identical between frames — a blinking caret, the menu-bar clock, cursor
/// motion, or a sub-pixel resize all flip bytes and defeat exact matching, forcing a re-parse
/// every cadence tick. Instead we downscale to a fixed small grayscale grid and compare with a
/// per-pixel noise floor, counting the *fraction* of cells that changed. That ignores trivial
/// churn while still tripping on a localized UI change (a new button, dialog, or panel).
public struct ScreenshotSignature: Equatable, Sendable {
    /// Edge length of the normalized grayscale grid. Fixed so capture-height jitter (e.g. 672 vs
    /// 704px) never matters and the comparison is always defined.
    public static let dimension = 64

    /// Row-major grayscale luma, `dimension * dimension` bytes.
    public let pixels: [UInt8]
    public let dimension: Int

    public init(pixels: [UInt8], dimension: Int) {
        self.pixels = pixels
        self.dimension = dimension
    }

    /// Build a signature from encoded image data (PNG, JPEG, anything ImageIO decodes).
    /// Returns nil if the data cannot be decoded.
    public static func make(
        fromImageData data: Data,
        dimension: Int = dimension
    ) -> ScreenshotSignature? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return make(from: image, dimension: dimension)
    }

    /// Build a signature by downscaling a CGImage into a fixed grayscale grid.
    public static func make(
        from image: CGImage,
        dimension: Int = dimension
    ) -> ScreenshotSignature? {
        guard dimension > 0 else { return nil }
        let count = dimension * dimension
        var buffer = [UInt8](repeating: 0, count: count)
        let grayspace = CGColorSpaceCreateDeviceGray()
        let built: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: dimension,
                height: dimension,
                bitsPerComponent: 8,
                bytesPerRow: dimension,
                space: grayspace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            // Low interpolation averages source pixels into each cell, smoothing out sub-pixel
            // noise and antialiasing flicker that we want to ignore.
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
            return true
        }
        guard built else { return nil }
        return ScreenshotSignature(pixels: buffer, dimension: dimension)
    }

    /// Fraction (0...1) of cells whose absolute luma delta exceeds `perPixelNoise`.
    ///
    /// `perPixelNoise` absorbs small per-cell variation (compression artifacts, antialiasing,
    /// a flickering caret). Returns 1 (treated as fully changed) when the signatures are not
    /// directly comparable, so callers conservatively re-parse.
    public func changedFraction(
        from other: ScreenshotSignature,
        perPixelNoise: UInt8 = 12
    ) -> Double {
        guard dimension == other.dimension,
              pixels.count == other.pixels.count,
              !pixels.isEmpty else {
            return 1
        }
        let noise = Int(perPixelNoise)
        var changed = 0
        for index in pixels.indices where abs(Int(pixels[index]) - Int(other.pixels[index])) > noise {
            changed += 1
        }
        return Double(changed) / Double(pixels.count)
    }

    /// Whether `other` differs enough from this signature to warrant re-processing.
    public func changed(
        from other: ScreenshotSignature,
        perPixelNoise: UInt8 = 12,
        changedFractionThreshold: Double = 0.012
    ) -> Bool {
        changedFraction(from: other, perPixelNoise: perPixelNoise) > changedFractionThreshold
    }
}
