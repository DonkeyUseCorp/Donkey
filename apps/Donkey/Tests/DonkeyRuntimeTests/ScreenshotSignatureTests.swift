import CoreGraphics
@testable import DonkeyRuntime
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite
struct ScreenshotSignatureTests {
    /// Draw a solid-color image, optionally painting a filled rect on top so we can simulate a
    /// localized UI change of a controllable size.
    private func image(
        width: Int,
        height: Int,
        background: CGFloat = 0.5,
        patch: CGRect? = nil,
        patchColor: CGFloat = 0.0
    ) -> CGImage {
        let space = CGColorSpaceCreateDeviceGray()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: space,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.setFillColor(gray: background, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let patch {
            context.setFillColor(gray: patchColor, alpha: 1)
            context.fill(patch)
        }
        return context.makeImage()!
    }

    @Test("identical frames report zero change")
    func identicalFramesUnchanged() {
        let a = ScreenshotSignature.make(from: image(width: 400, height: 300))!
        let b = ScreenshotSignature.make(from: image(width: 400, height: 300))!
        #expect(a.changedFraction(from: b) == 0)
        #expect(!a.changed(from: b))
    }

    @Test("capture-height jitter on identical content stays below threshold")
    func scaleJitterStaysUnchanged() {
        // Same content, different capture heights (the 672 vs 704 case from the logs).
        let a = ScreenshotSignature.make(from: image(width: 1_280, height: 672))!
        let b = ScreenshotSignature.make(from: image(width: 1_280, height: 704))!
        #expect(!a.changed(from: b))
    }

    @Test("a tiny localized change is ignored, a large one is caught")
    func thresholdSeparatesNoiseFromRealChange() {
        let base = ScreenshotSignature.make(from: image(width: 640, height: 480))!

        // ~1px-ish blip in a 640x480 frame — like a blinking caret. Below threshold.
        let blip = ScreenshotSignature.make(
            from: image(width: 640, height: 480, patch: CGRect(x: 10, y: 10, width: 4, height: 12))
        )!
        #expect(!base.changed(from: blip))

        // A large panel appearing covers a big fraction of the frame — above threshold.
        let panel = ScreenshotSignature.make(
            from: image(width: 640, height: 480, patch: CGRect(x: 0, y: 0, width: 320, height: 480))
        )!
        #expect(base.changed(from: panel))
    }

    @Test("decodes encoded image data")
    func decodesEncodedData() throws {
        let cg = image(width: 200, height: 200)
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
        let signature = ScreenshotSignature.make(fromImageData: data as Data)
        #expect(signature != nil)
    }

    // MARK: - Live capture (opt-in)

    /// Runs against real screen captures when paths are provided, e.g. captures of the Spotify
    /// window. Set env vars to two frames that should read as "unchanged" (e.g. progress bar
    /// advancing during playback) and, optionally, a third "changed" frame (a different view).
    ///   SCREENSHOT_SIG_UNCHANGED_A, SCREENSHOT_SIG_UNCHANGED_B, SCREENSHOT_SIG_CHANGED
    @Test("real captures: small churn skips, real change re-parses")
    func liveCaptureBehaves() throws {
        let env = ProcessInfo.processInfo.environment
        guard let pathA = env["SCREENSHOT_SIG_UNCHANGED_A"],
              let pathB = env["SCREENSHOT_SIG_UNCHANGED_B"] else {
            return // not provided — skip
        }
        let a = try #require(ScreenshotSignature.make(fromImageData: Data(contentsOf: URL(fileURLWithPath: pathA))))
        let b = try #require(ScreenshotSignature.make(fromImageData: Data(contentsOf: URL(fileURLWithPath: pathB))))

        let churn = a.changedFraction(from: b)
        print("[ScreenshotSignature] unchanged-pair changedFraction=\(churn)")
        #expect(!a.changed(from: b), "near-identical frames should be treated as unchanged (was \(churn))")

        if let pathC = env["SCREENSHOT_SIG_CHANGED"] {
            let c = try #require(ScreenshotSignature.make(fromImageData: Data(contentsOf: URL(fileURLWithPath: pathC))))
            let delta = a.changedFraction(from: c)
            print("[ScreenshotSignature] changed-pair changedFraction=\(delta)")
            #expect(a.changed(from: c), "a different view should trip a re-parse (was \(delta))")
        }
    }
}
