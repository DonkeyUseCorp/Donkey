import CoreGraphics
import DonkeyContracts
import DonkeyRuntime
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Deterministic, offline coverage for the box-based vision geometry and the
/// in-turn change probe. The live grounding quality is verified separately by
/// `GeminiLiveVisionBoxSpotifySmokeTests` (which saves annotated PNGs for review).
@Suite
struct VisionBoxGeometryTests {
    // box = [ymin, xmin, ymax, xmax] in 0–1000 space.
    private let box: [Double] = [100, 200, 300, 600]

    @Test
    func clickPointsAreCenterFirst() {
        // window maps 0–1000 normalized directly onto 0–1000 screen units here.
        let window = WindowTargetBounds(x: 0, y: 0, width: 1_000, height: 1_000)
        let points = VisionBoxGeometry.screenPoints(box, window: window)
        #expect(points.count == 5)
        // Box center: x = 200 + 0.5*400 = 400; y = 100 + 0.5*200 = 200.
        #expect(points[0] == CGPoint(x: 400, y: 200))
        // All points lie inside the box rect (200…600, 100…300).
        for point in points {
            #expect(point.x >= 200 && point.x <= 600)
            #expect(point.y >= 100 && point.y <= 300)
        }
    }

    @Test
    func screenPointsRespectWindowOffsetAndSize() {
        let window = WindowTargetBounds(x: 100, y: 50, width: 800, height: 600)
        let center = VisionBoxGeometry.screenPoints(box, window: window)[0]
        // nx = 400/1000 = 0.4 → 100 + 0.4*800 = 420; ny = 200/1000 = 0.2 → 50 + 0.2*600 = 170.
        #expect(center == CGPoint(x: 420, y: 170))
    }

    @Test
    func pixelRectScalesToImage() {
        let rect = VisionBoxGeometry.pixelRect(box, imageWidth: 1_000, imageHeight: 1_000)
        #expect(rect == CGRect(x: 200, y: 100, width: 400, height: 200))
    }

    @Test
    func malformedBoxYieldsNoPoints() {
        #expect(VisionBoxGeometry.screenPoints([1, 2, 3], window: WindowTargetBounds(x: 0, y: 0, width: 10, height: 10)).isEmpty)
        #expect(VisionBoxGeometry.bounds([100, 200, 100, 200]) == nil) // zero area
    }

    @Test
    func changeProbeDistinguishesIdenticalFromDifferent() {
        let black = solidPNG(gray: 0)
        let white = solidPNG(gray: 255)
        #expect(ScreenshotChange.changed(black, black) == false)
        #expect(ScreenshotChange.changed(black, white) == true)
    }

    /// A 16x16 solid-gray PNG for the change probe.
    private func solidPNG(gray: UInt8, side: Int = 16) -> Data {
        let value = CGFloat(gray) / 255
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: value, green: value, blue: value, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        _ = CGImageDestinationFinalize(destination)
        return data as Data
    }
}
