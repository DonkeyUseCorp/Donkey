// ReframePlanner — the pure decision core of the `reframe` tool, with no AVFoundation/Vision/CoreImage
// dependency so it is deterministic and unit-testable. Given per-frame face detections, audio energy,
// and scene-cut flags, it links faces into tracks, decides the active speaker each frame, and produces
// the crop path. The `reframe` CLI (tools/reframe/main.swift) does the Vision detection, audio read, and
// render around this; both compile this same file, so the algorithm under test is the algorithm that ships.
//
// The active-speaker signal is the standard audio-visual one: the talking face is the tracked face whose
// mouth moves while audio is voiced. A face that never moves its mouth is excluded; audio↔lip sync
// correlation breaks close calls; hysteresis + immediate-handoff-on-silence keep the crop from flickering.
// (A trained model such as LR-ASD can replace `activeSpeaker` as a drop-in scorer behind this interface.)

import Foundation

public struct ReframeFaceSample: Sendable, Equatable {
    public var cx: Double       // face-center x in display pixels (0 = left)
    public var cy: Double       // face-center y in display pixels (0 = top)
    public var w: Double        // face width in display pixels
    public var h: Double        // face height in display pixels
    public var openness: Double // inner-lip vertical aperture in face-box units (open mouth -> larger)
    public init(cx: Double, cy: Double, w: Double, h: Double, openness: Double) {
        self.cx = cx; self.cy = cy; self.w = w; self.h = h; self.openness = openness
    }
}

public struct ReframePlan: Sendable {
    public var cropX: [Double]      // left edge of the crop window per bin, clamped to [0, dispW-cropW]
    public var activeTrack: [Int]   // chosen speaker track id per bin (-1 = none)
    public var hardCut: [Bool]      // per bin: cut instantly rather than pan into this bin
    public var trackCount: Int
}

public struct ReframePlanner: Sendable {
    public var dispW: Double
    public var dispH: Double
    public var cropW: Double
    public var sampleFPS: Double

    public init(dispW: Double, dispH: Double, cropW: Double, sampleFPS: Double) {
        self.dispW = dispW; self.dispH = dispH; self.cropW = cropW; self.sampleFPS = sampleFPS
    }

    struct Track { var id: Int; var lastBin: Int; var samples: [Int: ReframeFaceSample] }

    /// `detections[bin]` is the faces found in that sampled frame; `energy[bin]` the audio RMS; `sceneCut[bin]`
    /// a hard scene change. All three arrays are bin-aligned and the same length (the bin count).
    public func plan(detections: [[ReframeFaceSample]], energy: [Double], sceneCut: [Bool]) -> ReframePlan {
        let nBins = detections.count
        guard nBins > 0 else { return ReframePlan(cropX: [], activeTrack: [], hardCut: [], trackCount: 0) }
        func binTime(_ i: Int) -> Double { (Double(i) + 0.5) / sampleFPS }

        // --- link detections into per-person tracks (greedy nearest centroid) ---
        var tracks: [Track] = []
        var nextID = 0
        for i in 0..<nBins {
            for det in detections[i] {
                var best = -1; var bestDist = Double.greatestFiniteMagnitude
                for idx in tracks.indices {
                    let tr = tracks[idx]
                    guard binTime(i) - binTime(tr.lastBin) <= 0.5 else { continue }
                    if let last = tr.samples[tr.lastBin] {
                        let d = hypot(det.cx - last.cx, det.cy - last.cy)
                        if d < bestDist && d < max(det.w, 80) * 1.2 { bestDist = d; best = idx }
                    }
                }
                if best >= 0 { tracks[best].samples[i] = det; tracks[best].lastBin = i }
                else { tracks.append(Track(id: nextID, lastBin: i, samples: [i: det])); nextID += 1 }
            }
        }
        tracks = tracks.filter { $0.samples.count >= 2 }

        // --- voiced gate ---
        let peakE = energy.max() ?? 0
        let voicedThresh = max(1e-4, peakE * 0.12)
        func voiced(_ i: Int) -> Bool { i >= 0 && i < energy.count && energy[i] > voicedThresh }

        // --- per-track smoothed openness, mouth-activity envelope, sync correlation ---
        func opennessSmoothed(_ tr: Track) -> [Double?] {
            var s = [Double?](repeating: nil, count: nBins)
            for (bin, fs) in tr.samples { s[bin] = fs.openness }
            let known = (0..<nBins).filter { s[$0] != nil }
            guard known.count >= 2 else { return s }
            for idx in 0..<(known.count - 1) {
                let a = known[idx], b = known[idx + 1]
                if b - a > 1 && b - a <= 4 {
                    let va = s[a]!, vb = s[b]!
                    for k in (a + 1)..<b { s[k] = va + (vb - va) * Double(k - a) / Double(b - a) }
                }
            }
            var out = s
            for k in 0..<nBins where s[k] != nil {
                var acc = 0.0, c = 0.0
                for d in -1...1 { let j = k + d; if j >= 0 && j < nBins, let v = s[j] { acc += v; c += 1 } }
                out[k] = acc / c
            }
            return out
        }
        func activityEnv(_ op: [Double?]) -> [Double] {
            var a = [Double](repeating: 0, count: nBins)
            var last: Double? = nil
            for i in 0..<nBins {
                if let v = op[i] { if let l = last { a[i] = abs(v - l) }; last = v } else { last = nil }
            }
            let w = max(2, Int(sampleFPS * 0.25))
            var e = a
            for i in 0..<nBins {
                let lo = max(0, i - w), hi = min(nBins - 1, i + w)
                e[i] = (lo...hi).reduce(0.0) { $0 + a[$1] } / Double(hi - lo + 1)
            }
            return e
        }
        func corrLag(_ op: [Double?], center i: Int, win w: Int, maxLag: Int) -> Double {
            var best = -2.0
            for lag in -maxLag...maxLag {
                var xs: [Double] = []; var ys: [Double] = []
                for k in (i - w)...(i + w) {
                    let j = k + lag
                    guard k >= 0, k < nBins, j >= 0, j < nBins, let o = op[k] else { continue }
                    xs.append(o); ys.append(energy[j])
                }
                guard xs.count >= 5 else { continue }
                let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
                var num = 0.0, dx = 0.0, dy = 0.0
                for t in 0..<xs.count { let a = xs[t] - mx, b = ys[t] - my; num += a * b; dx += a * a; dy += b * b }
                if dx > 1e-9 && dy > 1e-9 { best = max(best, num / (dx.squareRoot() * dy.squareRoot())) }
            }
            return best
        }
        let trackOpenness = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, opennessSmoothed($0)) })
        let trackActivity = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, activityEnv(trackOpenness[$0.id]!)) })
        let allPositive = trackActivity.values.flatMap { $0 }.filter { $0 > 1e-6 }.sorted()
        let noiseFloor = allPositive.isEmpty ? 1e-4 : max(1e-4, allPositive[Int(0.25 * Double(allPositive.count))])
        let trackMaxAct = trackActivity.mapValues { $0.max() ?? 0 }
        func capable(_ id: Int) -> Bool { (trackMaxAct[id] ?? 0) > noiseFloor * 2 }

        // --- active speaker per bin ---
        let win = max(6, Int(sampleFPS * 0.7))
        let maxLag = max(2, Int(sampleFPS * 0.12))
        let minDwell = max(1, Int(sampleFPS * 0.4))
        var activeTrack = [Int](repeating: -1, count: nBins)
        var lastActive = -1
        var dwell = 0
        func commit(_ i: Int, _ candidate: Int) {
            if candidate == lastActive || lastActive < 0 || dwell >= minDwell {
                activeTrack[i] = candidate; lastActive = candidate; dwell = 0
            } else { activeTrack[i] = lastActive; dwell += 1 }
        }
        for i in 0..<nBins {
            let present = tracks.filter { tr in (max(0, i - 2)...min(nBins - 1, i + 2)).contains { tr.samples[$0] != nil } }
            if present.isEmpty || !voiced(i) { activeTrack[i] = lastActive; dwell += 1; continue }
            let speakers = present.filter { capable($0.id) }
            if speakers.isEmpty { activeTrack[i] = lastActive >= 0 ? lastActive : (present.first?.id ?? -1); dwell += 1; continue }
            if speakers.count == 1 { commit(i, speakers[0].id); continue }
            let scored = speakers.map { ($0.id, trackActivity[$0.id]![i]) }.sorted { $0.1 > $1.1 }
            let best = scored[0]
            let second = scored.count > 1 ? scored[1].1 : 0.0
            var winner = best.0
            if best.1 >= max(noiseFloor, second * 1.3) {
                winner = best.0
            } else if best.1 > noiseFloor {
                winner = speakers.map { ($0.id, corrLag(trackOpenness[$0.id]!, center: i, win: win, maxLag: maxLag)) }
                    .max { $0.1 < $1.1 }!.0
            } else {
                activeTrack[i] = lastActive >= 0 ? lastActive : best.0; dwell += 1; continue
            }
            let curAct = lastActive >= 0 ? (trackActivity[lastActive]?[i] ?? 0) : 0
            if lastActive < 0 || winner == lastActive || curAct < noiseFloor || dwell >= minDwell {
                activeTrack[i] = winner; lastActive = winner; dwell = 0
            } else { activeTrack[i] = lastActive; dwell += 1 }
        }

        // --- focus center -> crop path (with hard cuts and smoothing) ---
        func trackCenter(_ id: Int, _ bin: Int) -> Double? {
            guard let tr = tracks.first(where: { $0.id == id }) else { return nil }
            for d in 0...win {
                if let s = tr.samples[bin] { return s.cx }
                if bin - d >= 0, let s = tr.samples[bin - d] { return s.cx }
                if bin + d < nBins, let s = tr.samples[bin + d] { return s.cx }
            }
            return nil
        }
        var centerX = [Double](repeating: dispW / 2, count: nBins)
        var lastCenter = dispW / 2
        for i in 0..<nBins {
            if activeTrack[i] >= 0, let c = trackCenter(activeTrack[i], i) { lastCenter = c }
            else if let widest = tracks.compactMap({ $0.samples[i] }).max(by: { $0.w < $1.w }) { lastCenter = widest.cx }
            centerX[i] = lastCenter
        }
        var cropX = centerX.map { min(max($0 - cropW / 2, 0), dispW - cropW) }

        var hardCut = [Bool](repeating: false, count: nBins)
        for i in 1..<nBins {
            let switched = activeTrack[i] != activeTrack[i - 1] && activeTrack[i] >= 0 && activeTrack[i - 1] >= 0
            let bigJump = abs(cropX[i] - cropX[i - 1]) > dispW * 0.18
            if (switched && bigJump) || (i < sceneCut.count && sceneCut[i]) { hardCut[i] = true }
        }

        let maxVel = dispW * 0.9 / sampleFPS
        func smoothRun(_ lo: Int, _ hi: Int) {
            guard hi > lo else { return }
            var tmp = Array(cropX[lo...hi])
            for _ in 0..<2 {
                var out = tmp
                for k in tmp.indices {
                    let a = max(0, k - 2), b = min(tmp.count - 1, k + 2)
                    out[k] = (a...b).reduce(0.0) { $0 + tmp[$1] } / Double(b - a + 1)
                }
                tmp = out
            }
            for k in 1..<tmp.count {
                let d = tmp[k] - tmp[k - 1]
                if d > maxVel { tmp[k] = tmp[k - 1] + maxVel }
                if d < -maxVel { tmp[k] = tmp[k - 1] - maxVel }
            }
            for (k, idx) in (lo...hi).enumerated() { cropX[idx] = min(max(tmp[k], 0), dispW - cropW) }
        }
        var runStart = 0
        for i in 1..<nBins where hardCut[i] { smoothRun(runStart, i - 1); runStart = i }
        smoothRun(runStart, nBins - 1)

        return ReframePlan(cropX: cropX, activeTrack: activeTrack, hardCut: hardCut, trackCount: tracks.count)
    }
}
