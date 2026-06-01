import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders the box-based vision flow's decision onto a captured screenshot so a
/// human can verify it: the returned bounding box plus the ordered click points
/// (box center larger, the nearby fallback points smaller) and a short label.
/// Reuses the same `CGContext` + `CGImageDestination` drawing pattern as the debug
/// UI inspection sidecar, including the top-left↔bottom-left y-flip, and derives the
/// rect/points from `VisionBoxGeometry` so the drawing matches what gets clicked.
public enum ScreenshotAnnotation {
    public static func annotatedPNG(
        screenshot: CapturedWindowScreenshot,
        box: [Double],
        label: String
    ) -> Data? {
        annotatedPNG(pngData: screenshot.pngData, box: box, label: label)
    }

    public static func annotatedPNG(pngData: Data, box: [Double], label: String) -> Data? {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Screenshot pixels are top-left origin; CGContext is bottom-left → flip y.
        func flip(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x, y: Double(height) - point.y)
        }

        if let rect = VisionBoxGeometry.pixelRect(box, imageWidth: width, imageHeight: height) {
            let drawRect = CGRect(
                x: rect.minX,
                y: Double(height) - rect.minY - rect.height,
                width: rect.width,
                height: rect.height
            )
            context.setLineWidth(3)
            context.setStrokeColor(NSColor.systemRed.cgColor)
            context.setFillColor(NSColor.systemRed.withAlphaComponent(0.12).cgColor)
            context.fill(drawRect)
            context.stroke(drawRect)

            if !label.isEmpty {
                let labelHeight: CGFloat = 18
                let labelRect = CGRect(
                    x: drawRect.minX,
                    y: min(CGFloat(height) - labelHeight - 2, drawRect.maxY),
                    width: min(CGFloat(width) - drawRect.minX - 2, max(60, CGFloat(label.count) * 6.7 + 10)),
                    height: labelHeight
                )
                context.setFillColor(NSColor.systemRed.withAlphaComponent(0.85).cgColor)
                context.fill(labelRect)
                let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = nsContext
                (label as NSString).draw(
                    in: labelRect.insetBy(dx: 4, dy: 2),
                    withAttributes: [
                        .foregroundColor: NSColor.white,
                        .font: NSFont.systemFont(ofSize: 10, weight: .semibold)
                    ]
                )
                NSGraphicsContext.restoreGraphicsState()
            }
        }

        let points = VisionBoxGeometry.pixelPoints(box, imageWidth: width, imageHeight: height)
        for (index, point) in points.enumerated() {
            let radius: CGFloat = index == 0 ? 9 : 5
            let center = flip(point)
            let dot = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.setFillColor((index == 0 ? NSColor.systemYellow : NSColor.systemGreen).withAlphaComponent(0.9).cgColor)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(1.5)
            context.fillEllipse(in: dot)
            context.strokeEllipse(in: dot)
        }

        guard let output = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, output, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
