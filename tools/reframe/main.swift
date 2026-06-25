// reframe — a native CLI that turns landscape video into vertical (9:16) short-form
// that tracks the ACTIVE SPEAKER, fully on-device.
//
// ffmpeg crops a fixed rectangle; this follows the person who is talking. The whole
// pipeline uses only Apple system frameworks (AVFoundation + Vision + CoreImage), so
// there is no model file to bundle and no network call:
//
//   1. Analyze — sample frames, detect faces + lip landmarks (Vision), and a scene-cut flag.
//   2. Audio   — read PCM, compute per-bin energy.
//   3+4. Plan  — ReframePlanner (shared, unit-tested) links faces into tracks, picks the
//      active speaker each frame, and builds the smoothed crop path with hard cuts.
//   5. Render  — AVAssetExportSession + a video composition of transform ramps, so the
//      original audio is retained and the motion is sub-pixel smooth.
//
// The active-speaker decision and crop path live in ReframePlanner.swift (compiled in
// alongside this file), which has no AVFoundation/Vision dependency and is unit-tested in
// DonkeyRuntimeTests — so the algorithm under test is the algorithm that ships here.
//
// Usage:
//   reframe --input IN.mp4 --output OUT.mp4 [--aspect 9:16] [--height 1920] [--fps 24] [--plan plan.json]
//
// All I/O is JSON so an LLM can drive it: success prints a JSON summary to stdout; errors
// print {"error":"…"} to stderr and exit non-zero.

import Foundation
import AVFoundation
import Vision
import CoreImage
import CoreMedia

// MARK: - I/O helpers

func parseArgs(_ argv: [String]) -> [String: String] {
    var flags: [String: String] = [:]
    var i = 0
    while i < argv.count {
        let a = argv[i]
        if a.hasPrefix("--") {
            let key = String(a.dropFirst(2))
            if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") { flags[key] = argv[i + 1]; i += 2 }
            else { flags[key] = "true"; i += 1 }
        } else { i += 1 }
    }
    return flags
}

func fail(_ message: String) -> Never {
    let payload = ["error": message]
    if let data = try? JSONSerialization.data(withJSONObject: payload),
       let text = String(data: data, encoding: .utf8) {
        FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
    }
    exit(1)
}

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { fail("could not serialize output") }
    print(text)
}

func loadSync<T>(_ op: @escaping () async throws -> T) -> T? {
    let sem = DispatchSemaphore(value: 0)
    var out: T?
    Task { out = try? await op(); sem.signal() }
    sem.wait()
    return out
}

// MARK: - inputs

let flags = parseArgs(Array(CommandLine.arguments.dropFirst()))
guard let inPath = flags["input"], let outPath = flags["output"] else {
    fail("usage: reframe --input IN.mp4 --output OUT.mp4 [--aspect 9:16] [--height 1920] [--fps 24]")
}
let aspect = flags["aspect"] ?? "9:16"
let aspParts = aspect.split(separator: ":").compactMap { Double($0) }
guard aspParts.count == 2, aspParts[0] > 0, aspParts[1] > 0 else { fail("bad --aspect (expected like 9:16)") }
let arN = aspParts[0], arD = aspParts[1]
let sampleFPS = max(6, Double(flags["fps"] ?? "24") ?? 24.0)
let outH = max(64, Double(flags["height"] ?? "1920") ?? 1920)

let inURL = URL(fileURLWithPath: (inPath as NSString).expandingTildeInPath)
let outURL = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
guard FileManager.default.fileExists(atPath: inURL.path) else { fail("input not found: \(inPath)") }
let asset = AVURLAsset(url: inURL)

guard let vTrack = (loadSync({ try await asset.loadTracks(withMediaType: .video).first }) ?? nil) else {
    fail("no video track in \(inPath)")
}
let durationCM = loadSync({ try await asset.load(.duration) }) ?? .zero
let duration = durationCM.seconds
guard duration > 0 else { fail("zero-duration video") }
let naturalSize = loadSync({ try await vTrack.load(.naturalSize) }) ?? .zero
let preferred = loadSync({ try await vTrack.load(.preferredTransform) }) ?? .identity
let nominalFPSRaw = loadSync({ try await vTrack.load(.nominalFrameRate) }) ?? 30
let videoFPS = nominalFPSRaw > 1 ? Double(nominalFPSRaw) : 30.0

// display-oriented size (after preferredTransform)
let dispRect = CGRect(origin: .zero, size: naturalSize).applying(preferred)
let dispW = abs(dispRect.width)
let dispH = abs(dispRect.height)
guard dispW > 0, dispH > 0 else { fail("could not read video dimensions") }

// crop window (full height vertical slice; letterbox-ish clamp if the target is wider than source)
var cropW = (dispH * arN / arD).rounded()
var cropH = dispH
if cropW > dispW { cropW = dispW; cropH = (dispW * arD / arN).rounded() }
let outW = (outH * arN / arD).rounded()
let scaleS = outW / cropW

let nBins = max(1, Int((duration * sampleFPS).rounded(.up)))
func binTime(_ i: Int) -> Double { (Double(i) + 0.5) / sampleFPS }

// MARK: - Pass 1: faces + lip openness + scene cuts via Vision

let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
generator.maximumSize = CGSize(width: 960, height: 960)   // smaller = faster Vision; boxes stay normalized

func lipOpenness(_ lm: VNFaceLandmarks2D?) -> Double {
    guard let lips = lm?.innerLips ?? lm?.outerLips, lips.pointCount >= 4 else { return 0 }
    let ys = lips.normalizedPoints.map { Double($0.y) }
    return ys.max()! - ys.min()!   // inner-lip vertical aperture in face-box units (open mouth -> larger)
}

func sceneDiff(_ a: CGImage, _ b: CGImage) -> Double {
    let w = 32, h = 18
    func gray(_ img: CGImage) -> [Double]? {
        var buf = [UInt8](repeating: 0, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf.map { Double($0) / 255.0 }
    }
    guard let ga = gray(a), let gb = gray(b) else { return 0 }
    var s = 0.0
    for k in 0..<ga.count { s += abs(ga[k] - gb[k]) }
    return s / Double(ga.count)
}

var detections = [[ReframeFaceSample]](repeating: [], count: nBins)
var sceneCut = [Bool](repeating: false, count: nBins)
var prevSampleImage: CGImage?
for i in 0..<nBins {
    let cm = CMTime(seconds: binTime(i), preferredTimescale: 600)
    guard let cg = try? generator.copyCGImage(at: cm, actualTime: nil) else { continue }
    if let prev = prevSampleImage, sceneDiff(prev, cg) > 0.18 { sceneCut[i] = true }
    prevSampleImage = cg
    let req = VNDetectFaceLandmarksRequest()
    let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
    try? handler.perform([req])
    // Vision boxes are normalized with a bottom-left origin; convert to display pixels (top-left y).
    detections[i] = (req.results ?? []).map { f in
        let bb = f.boundingBox
        return ReframeFaceSample(
            cx: Double(bb.midX) * dispW,
            cy: (1.0 - Double(bb.midY)) * dispH,
            w: Double(bb.width) * dispW,
            h: Double(bb.height) * dispH,
            openness: lipOpenness(f.landmarks)
        )
    }
}

// MARK: - Pass 2: audio energy per bin

var energy = [Double](repeating: 0, count: nBins)
if let aTrack = (loadSync({ try await asset.loadTracks(withMediaType: .audio).first }) ?? nil) {
    let reader = try? AVAssetReader(asset: asset)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVNumberOfChannelsKey: 1,
        AVSampleRateKey: 16000.0,
    ]
    let output = AVAssetReaderTrackOutput(track: aTrack, outputSettings: settings)
    if let reader, reader.canAdd(output) {
        reader.add(output)
        reader.startReading()
        var sumSq = [Double](repeating: 0, count: nBins)
        var cnt = [Double](repeating: 0, count: nBins)
        let sr = 16000.0
        while let sb = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sb) else { continue }
            var lengthAtOffset = 0; var totalLength = 0; var dataPtr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                        totalLengthOut: &totalLength, dataPointerOut: &dataPtr)
            guard let dataPtr else { continue }
            let count = totalLength / MemoryLayout<Float32>.size
            dataPtr.withMemoryRebound(to: Float32.self, capacity: count) { fp in
                for n in 0..<count {
                    let bin = Int((pts + Double(n) / sr) * sampleFPS)
                    if bin >= 0 && bin < nBins { let v = Double(fp[n]); sumSq[bin] += v * v; cnt[bin] += 1 }
                }
            }
        }
        for i in 0..<nBins { energy[i] = cnt[i] > 0 ? (sumSq[i] / cnt[i]).squareRoot() : 0 }
    }
}

// MARK: - Pass 3+4: plan tracks, active speaker, and crop path (ReframePlanner)

let plan = ReframePlanner(dispW: dispW, dispH: dispH, cropW: cropW, sampleFPS: sampleFPS)
    .plan(detections: detections, energy: energy, sceneCut: sceneCut)
let cropX = plan.cropX
let hardCut = plan.hardCut

// Optional debug plan.
if let planPath = flags["plan"] {
    var bins: [[String: Any]] = []
    for i in 0..<nBins {
        let center = (cropX[i] + cropW / 2)
        bins.append(["t": binTime(i), "cropX": cropX[i], "center": center,
                     "speaker": plan.activeTrack[i], "hardCut": hardCut[i]])
    }
    let obj: [String: Any] = ["dispW": dispW, "dispH": dispH, "cropW": cropW, "cropH": cropH,
                              "outW": outW, "outH": outH, "tracks": plan.trackCount, "bins": bins]
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
        try? data.write(to: URL(fileURLWithPath: (planPath as NSString).expandingTildeInPath))
    }
}

// MARK: - Pass 5: render via export session + transform ramps

let rOffset = CGAffineTransform(translationX: -dispRect.minX, y: -dispRect.minY)
let rectify = preferred.concatenating(rOffset)
func transformFor(_ cx: Double) -> CGAffineTransform {
    let cropScale = CGAffineTransform(a: scaleS, b: 0, c: 0, d: scaleS, tx: -cx * scaleS, ty: 0)
    return rectify.concatenating(cropScale)
}

let comp = AVMutableVideoComposition()
comp.renderSize = CGSize(width: outW, height: outH)
comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, videoFPS.rounded())))

let instruction = AVMutableVideoCompositionInstruction()
instruction.timeRange = CMTimeRange(start: .zero, duration: durationCM)
let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)

func tAt(_ i: Int) -> CMTime { CMTime(seconds: binTime(i), preferredTimescale: 600) }
layer.setTransform(transformFor(cropX[0]), at: .zero)
for i in 0..<(nBins - 1) {
    let start = i == 0 ? CMTime.zero : tAt(i)
    let end = tAt(i + 1)
    if hardCut[i + 1] {
        layer.setTransformRamp(fromStart: transformFor(cropX[i]), toEnd: transformFor(cropX[i]),
                               timeRange: CMTimeRange(start: start, end: end))
        layer.setTransform(transformFor(cropX[i + 1]), at: end)
    } else {
        layer.setTransformRamp(fromStart: transformFor(cropX[i]), toEnd: transformFor(cropX[i + 1]),
                               timeRange: CMTimeRange(start: start, end: end))
    }
}
instruction.layerInstructions = [layer]
comp.instructions = [instruction]

guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
    fail("could not create export session")
}
export.videoComposition = comp
export.outputURL = outURL
export.outputFileType = .mp4
try? FileManager.default.removeItem(at: outURL)

let sem = DispatchSemaphore(value: 0)
export.exportAsynchronously { sem.signal() }
sem.wait()

guard export.status == .completed else {
    fail("export failed: \(export.error?.localizedDescription ?? "unknown") (status \(export.status.rawValue))")
}

let usedSpeakers = Set(plan.activeTrack.filter { $0 >= 0 }).count
let cuts = hardCut.filter { $0 }.count
emit([
    "out": outURL.path,
    "width": Int(outW),
    "height": Int(outH),
    "durationSeconds": duration,
    "facesTracked": plan.trackCount,
    "speakersFollowed": max(usedSpeakers, plan.trackCount > 0 ? 1 : 0),
    "cuts": cuts,
])
