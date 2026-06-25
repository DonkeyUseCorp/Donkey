import DonkeyRuntime
import Foundation
import Testing

// Deterministic unit tests for the reframe decision core. ReframePlanner is the exact algorithm the
// bundled `reframe` CLI ships (the CLI compiles this same file), so these protect the real tracking,
// active-speaker, and crop-path logic without needing video I/O or Vision.
@Suite
struct ReframePlannerTests {
    // 1280x720 landscape -> 9:16 (cropW 405). Two people: left at x=320, right at x=960.
    let dispW = 1280.0, dispH = 720.0, cropW = 405.0, fps = 24.0
    let xLeft = 320.0, xRight = 960.0

    func planner() -> ReframePlanner { ReframePlanner(dispW: dispW, dispH: dispH, cropW: cropW, sampleFPS: fps) }
    func center(_ cropX: Double) -> Double { cropX + cropW / 2 }

    // A talking mouth changes shape frame-to-frame (wide range, like speech); a listening mouth only
    // micro-moves (as real faces do — a perfectly frozen face is unrealistic and degenerates the noise
    // floor). Deterministic pseudo-random keeps it reproducible.
    func openness(speaking: Bool, _ i: Int) -> Double {
        guard speaking else { return 0.12 + 0.004 * sin(Double(i)) }
        let r = Double((i &* 1_103_515_245 &+ 12_345) & 0x7FFF) / 32_767.0
        return 0.05 + 0.40 * r
    }
    func face(x: Double, speaking: Bool, _ i: Int) -> ReframeFaceSample {
        ReframeFaceSample(cx: x, cy: 360, w: 160, h: 200, openness: openness(speaking: speaking, i))
    }

    func twoPerson(nBins: Int, leftSpeaking: (Int) -> Bool, rightSpeaking: (Int) -> Bool)
        -> (dets: [[ReframeFaceSample]], energy: [Double]) {
        var dets: [[ReframeFaceSample]] = []
        var energy: [Double] = []
        for i in 0..<nBins {
            dets.append([face(x: xLeft, speaking: leftSpeaking(i), i), face(x: xRight, speaking: rightSpeaking(i), i)])
            energy.append(1.0)   // voiced throughout
        }
        return (dets, energy)
    }

    // The crop follows the talking face, not the still listener.
    @Test
    func cropsToTheTalkingFace() {
        let n = 48
        let (dets, energy) = twoPerson(nBins: n, leftSpeaking: { _ in true }, rightSpeaking: { _ in false })
        let plan = planner().plan(detections: dets, energy: energy, sceneCut: Array(repeating: false, count: n))
        #expect(plan.trackCount == 2)
        let avg = (12..<n).map { center(plan.cropX[$0]) }.reduce(0, +) / Double(n - 12)
        #expect(avg < 500)   // left speaker is ~320; frame middle is 640
    }

    // When the speaker changes, the crop hands off to the new speaker.
    @Test
    func handsOffWhenTheSpeakerChanges() {
        let n = 96
        let (dets, energy) = twoPerson(nBins: n, leftSpeaking: { $0 < n / 2 }, rightSpeaking: { $0 >= n / 2 })
        let plan = planner().plan(detections: dets, energy: energy, sceneCut: Array(repeating: false, count: n))
        let first = (12..<(n / 2 - 4)).map { center(plan.cropX[$0]) }
        let second = ((n / 2 + 10)..<n).map { center(plan.cropX[$0]) }
        let firstAvg = first.reduce(0, +) / Double(first.count)
        let secondAvg = second.reduce(0, +) / Double(second.count)
        #expect(firstAvg < 500)    // left
        #expect(secondAvg > 780)   // right (~960)
    }

    // The crop window never leaves the frame, even for a speaker pinned at the edge.
    @Test
    func cropPathStaysInBounds() {
        let n = 48
        var dets: [[ReframeFaceSample]] = []
        for i in 0..<n { dets.append([face(x: dispW - 30, speaking: true, i)]) }
        let plan = planner().plan(detections: dets, energy: Array(repeating: 1.0, count: n), sceneCut: Array(repeating: false, count: n))
        for x in plan.cropX { #expect(x >= 0 && x <= dispW - cropW) }
    }

    // A scene cut becomes a hard cut (instant recenter, no pan through the cut).
    @Test
    func sceneCutBecomesAHardCut() {
        let n = 48
        let (dets, energy) = twoPerson(nBins: n, leftSpeaking: { _ in true }, rightSpeaking: { _ in false })
        var cuts = Array(repeating: false, count: n); cuts[24] = true
        let plan = planner().plan(detections: dets, energy: energy, sceneCut: cuts)
        #expect(plan.hardCut[24])
    }

    // Inside a continuous run the crop motion is velocity-limited (smooth, no teleport).
    @Test
    func motionIsVelocityLimitedWithinARun() {
        let n = 48
        let (dets, energy) = twoPerson(nBins: n, leftSpeaking: { _ in true }, rightSpeaking: { _ in false })
        let plan = planner().plan(detections: dets, energy: energy, sceneCut: Array(repeating: false, count: n))
        let maxVel = dispW * 0.9 / fps
        for i in 1..<plan.cropX.count where !plan.hardCut[i] {
            #expect(abs(plan.cropX[i] - plan.cropX[i - 1]) <= maxVel + 1e-6)
        }
    }

    // No faces and no audio: a centered crop, no crash.
    @Test
    func emptyInputIsCenteredAndSafe() {
        let n = 24
        let plan = planner().plan(detections: Array(repeating: [], count: n),
                                  energy: Array(repeating: 0, count: n),
                                  sceneCut: Array(repeating: false, count: n))
        #expect(plan.trackCount == 0)
        #expect(plan.cropX.count == n)
        let centered = min(max(dispW / 2 - cropW / 2, 0), dispW - cropW)
        for x in plan.cropX { #expect(abs(x - centered) < 1e-6) }
    }
}
