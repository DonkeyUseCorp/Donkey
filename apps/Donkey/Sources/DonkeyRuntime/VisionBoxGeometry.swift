import CoreGraphics
import DonkeyContracts
import Foundation

/// Geometry for the box-based vision flow. The vision model returns the target as
/// a 2D bounding box in Gemini's convention — `box = [ymin, xmin, ymax, xmax]` in
/// the native 0–1000 normalized space (independent of the screenshot's pixel size,
/// the same property `VisionActionPlanner.screenPoint` relies on). This is the one
/// source of truth shared by clicking (box → screen points) and drawing
/// (box → screenshot-pixel rect/points), so what we click always matches what we
/// annotate.
public enum VisionBoxGeometry {
    public static let normalizedScale = 1_000.0

    /// Ordered click offsets within the target box, as fractions of the box
    /// (fx, fy in [0,1]) — center first, then four inner points. All sit inside the
    /// inner 40% so they remain on the control even when the box is slightly loose.
    public static let clickFractions: [(fx: Double, fy: Double)] = [
        (0.5, 0.5), (0.5, 0.3), (0.5, 0.7), (0.3, 0.5), (0.7, 0.5)
    ]

    /// Validate + unpack a `[ymin, xmin, ymax, xmax]` box. Returns nil if it is the
    /// wrong length or has zero area.
    public static func bounds(
        _ box: [Double]
    ) -> (xmin: Double, ymin: Double, xmax: Double, ymax: Double)? {
        guard box.count == 4 else { return nil }
        let ymin = min(box[0], box[2])
        let xmin = min(box[1], box[3])
        let ymax = max(box[0], box[2])
        let xmax = max(box[1], box[3])
        guard xmax > xmin, ymax > ymin else { return nil }
        return (xmin, ymin, xmax, ymax)
    }

    /// Box → ordered normalized (0–1) image points, center first.
    public static func normalizedPoints(_ box: [Double]) -> [(nx: Double, ny: Double)] {
        guard let b = bounds(box) else { return [] }
        return clickFractions.map { fraction in
            let nx = (b.xmin + fraction.fx * (b.xmax - b.xmin)) / normalizedScale
            let ny = (b.ymin + fraction.fy * (b.ymax - b.ymin)) / normalizedScale
            return (min(max(nx, 0), 1), min(max(ny, 0), 1))
        }
    }

    /// Box → ordered real-screen points for clicking (center first), using the same
    /// `window.x + nx * window.width` mapping as `VisionActionPlanner.screenPoint`.
    public static func screenPoints(_ box: [Double], window: WindowTargetBounds) -> [CGPoint] {
        normalizedPoints(box).map { point in
            CGPoint(
                x: window.x + point.nx * window.width,
                y: window.y + point.ny * window.height
            )
        }
    }

    /// Box → screenshot-pixel rect (top-left origin) for drawing.
    public static func pixelRect(_ box: [Double], imageWidth: Int, imageHeight: Int) -> CGRect? {
        guard let b = bounds(box) else { return nil }
        return CGRect(
            x: b.xmin / normalizedScale * Double(imageWidth),
            y: b.ymin / normalizedScale * Double(imageHeight),
            width: (b.xmax - b.xmin) / normalizedScale * Double(imageWidth),
            height: (b.ymax - b.ymin) / normalizedScale * Double(imageHeight)
        )
    }

    /// Box → ordered screenshot-pixel points (top-left origin, center first) for drawing.
    public static func pixelPoints(_ box: [Double], imageWidth: Int, imageHeight: Int) -> [CGPoint] {
        normalizedPoints(box).map { point in
            CGPoint(x: point.nx * Double(imageWidth), y: point.ny * Double(imageHeight))
        }
    }
}
