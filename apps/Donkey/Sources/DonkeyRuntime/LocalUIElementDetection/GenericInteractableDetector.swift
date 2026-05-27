import Foundation

struct GenericInteractableBox: Codable, Equatable, Sendable {
    var id: Int
    var x1: Int
    var y1: Int
    var x2: Int
    var y2: Int
    var text: String
    var kind: String
    var confidence: Double
    var source: String
    var width: Int { max(0, x2 - x1) }
    var height: Int { max(0, y2 - y1) }
    var area: Int { width * height }
}

struct GenericInteractableDetectionResult: Equatable, Sendable {
    var boxes: [GenericInteractableBox]
    var summary: String
}

struct GenericInteractableDetector: Sendable {
    private var magickPath: String?
    private var tesseractPath: String?

    init(
        magickPath: String? = nil,
        tesseractPath: String? = nil
    ) {
        self.magickPath = magickPath
        self.tesseractPath = tesseractPath
    }

    func detect(
        inputURL: URL,
        outputDirectory: URL
    ) throws -> GenericInteractableDetectionResult {
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw GenericInteractableDetectorError.noFile(inputURL.path)
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let size = try readPNGSize(inputURL)

        let preprocessed = outputDirectory.appendingPathComponent("swift_preprocessed_high_contrast.png")
        let pgm = outputDirectory.appendingPathComponent("swift_gray.pgm")
        let originalPGM = outputDirectory.appendingPathComponent("swift_original_gray.pgm")
        let magick = executablePath(
            preferred: magickPath ?? "/opt/imagemagick/bin/magick",
            env: "DONKEY_MAGICK_PATH",
            fallbacks: ["/opt/homebrew/bin/magick", "/usr/local/bin/magick"]
        )
        let tesseract = executablePath(
            preferred: tesseractPath ?? "/usr/bin/tesseract",
            env: "DONKEY_TESSERACT_PATH",
            fallbacks: ["/opt/homebrew/bin/tesseract", "/usr/local/bin/tesseract"]
        )

        _ = try shell(magick, [inputURL.path, "-colorspace", "Gray", "-contrast-stretch", "2%x2%", "-sharpen", "0x1", preprocessed.path])
        _ = try shell(magick, [preprocessed.path, "-depth", "8", pgm.path])
        _ = try shell(magick, [inputURL.path, "-colorspace", "Gray", "-depth", "8", originalPGM.path])

        let tsv = try shell(tesseract, [inputURL.path, "stdout", "--psm", "11", "tsv"])
        let words = parseTesseractTSV(tsv)

        let globalRows = groupWordsIntoRows(words)
        var boxes = globalRows.compactMap { classifyOCRRow($0, size: size) }

        let pgmData = try parsePGM(pgm)
        let comps = connectedComponentsForeground(pixels: pgmData.pixels, w: pgmData.w, h: pgmData.h, threshold: 175)
        boxes += comps.compactMap { classifyComponent($0, size: size) }

        let originalGray = try parsePGM(originalPGM)
        let midtone = connectedComponentsRange(pixels: originalGray.pixels, w: originalGray.w, h: originalGray.h, low: 28, high: 70)
        let containers = midtone.compactMap { classifyMidtoneContainer($0, size: size) }
        boxes += containers

        boxes += inferRowsInsideContainers(from: words, containers: containers, size: size)
        boxes = filterComponentDuplicates(boxes)
        boxes = clampBoxes(boxes, size: size)
        boxes += addInferredContainers(from: boxes, size: size)
        boxes = dedupe(boxes)

        let jsonURL = outputDirectory.appendingPathComponent("swift_boxes.json")
        let csvURL = outputDirectory.appendingPathComponent("swift_boxes.csv")
        let svg = outputDirectory.appendingPathComponent("swift_overlay.svg")
        try writeJSON(boxes, jsonURL)
        try writeCSV(boxes, csvURL)
        try writeSVG(input: inputURL, size: size, boxes: boxes, to: svg)

        return GenericInteractableDetectionResult(
            boxes: boxes,
            summary: [
                "image=\(size.width)x\(size.height)",
                "boxes=\(boxes.count)",
                "preprocessed=\(preprocessed.path)",
                "json=\(jsonURL.path)",
                "csv=\(csvURL.path)",
                "svg=\(svg.path)"
            ].joined(separator: "\n")
        )
    }

    private func shell(_ executable: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run(); p.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
            throw GenericInteractableDetectorError.commandFailed(
                ([executable] + args).joined(separator: " "),
                p.terminationStatus,
                stderr
            )
        }
        return stdout
    }

    private func executablePath(
        preferred: String,
        env: String,
        fallbacks: [String]
    ) -> String {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment[env],
           fm.isExecutableFile(atPath: override) {
            return override
        }
        if fm.isExecutableFile(atPath: preferred) {
            return preferred
        }
        for fallback in fallbacks where fm.isExecutableFile(atPath: fallback) {
            return fallback
        }
        return preferred
    }

    private func readPNGSize(_ url: URL) throws -> PNGSize {
        let d = try Data(contentsOf: url)
        guard d.count >= 24 && Array(d[0..<8]) == [137,80,78,71,13,10,26,10] else {
            throw GenericInteractableDetectorError.badPNG(url.path)
        }
        func be32(_ i: Int) -> UInt32 { (UInt32(d[i]) << 24) | (UInt32(d[i+1]) << 16) | (UInt32(d[i+2]) << 8) | UInt32(d[i+3]) }
        return PNGSize(width: Int(be32(16)), height: Int(be32(20)))
    }

    private func parseTesseractTSV(_ s: String) -> [OCRWord] {
        var words: [OCRWord] = []
        for (idx, line) in s.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if idx == 0 { continue }
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if cols.count < 12 { continue }
            guard cols[0] == "5",
                  let block = Int(cols[2]), let par = Int(cols[3]), let ln = Int(cols[4]),
                  let left = Int(cols[6]), let top = Int(cols[7]), let width = Int(cols[8]), let height = Int(cols[9]),
                  let conf = Double(cols[10]) else { continue }
            var text = cols[11].trimmingCharacters(in: .whitespacesAndNewlines)
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201C}\u{201D}\u{2018}\u{2019}`"))
            if text.isEmpty || conf < 20 { continue }
            words.append(OCRWord(text: text, conf: conf, x: left, y: top, w: width, h: height, block: block, par: par, line: ln))
        }
        return words
    }

    private func avg(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0,+) / Double(xs.count) }
    private func medianInt(_ xs: [Int]) -> Int {
        if xs.isEmpty { return 0 }
        let s = xs.sorted()
        return s[s.count/2]
    }

    private func contains(_ a: GenericInteractableBox, _ b: GenericInteractableBox, pad: Int = 0) -> Bool {
        a.x1 - pad <= b.x1 && a.y1 - pad <= b.y1 && a.x2 + pad >= b.x2 && a.y2 + pad >= b.y2
    }

    private func wordInside(_ w: OCRWord, _ r: GenericInteractableBox, pad: Int = 0) -> Bool {
        let cx = w.x + w.w / 2
        let cy = w.y + w.h / 2
        return cx >= r.x1 - pad && cx <= r.x2 + pad && cy >= r.y1 - pad && cy <= r.y2 + pad
    }

    private func groupWordsIntoRows(_ words: [OCRWord], region: GenericInteractableBox? = nil, maxGap: Int = 42, rowTol: Int = 11) -> [GenericInteractableBox] {
        let ws = words.filter { w in
            if let r = region { return wordInside(w, r, pad: 6) }
            return true
        }
        if ws.isEmpty { return [] }

        let sorted = ws.sorted { a, b in
            let acy = a.y + a.h / 2
            let bcy = b.y + b.h / 2
            if abs(acy - bcy) > rowTol { return acy < bcy }
            return a.x < b.x
        }

        var rows: [[OCRWord]] = []
        for w in sorted {
            let cy = w.y + w.h / 2
            if let last = rows.last {
                let lastCenter = Int(avg(last.map { Double($0.y + $0.h / 2) }))
                let tol = max(rowTol, medianInt(last.map { $0.h }) / 2)
                if abs(cy - lastCenter) <= tol {
                    rows[rows.count - 1].append(w)
                } else {
                    rows.append([w])
                }
            } else {
                rows.append([w])
            }
        }

        var segments: [GenericInteractableBox] = []
        for row in rows {
            let rowWords = row.sorted { $0.x < $1.x }
            var current: [OCRWord] = []
            for w in rowWords {
                if current.isEmpty {
                    current.append(w)
                    continue
                }
                let prev = current.last!
                let gap = w.x - (prev.x + prev.w)
                let localTol = max(maxGap, max(prev.h, w.h) * 2)
                if gap > localTol {
                    let box = rowSegmentToBox(current)
                    if let b = box { segments.append(b) }
                    current = [w]
                } else {
                    current.append(w)
                }
            }
            if let b = rowSegmentToBox(current) { segments.append(b) }
        }

        return segments.sorted { $0.y1 == $1.y1 ? $0.x1 < $1.x1 : $0.y1 < $1.y1 }
    }

    private func rowSegmentToBox(_ ws: [OCRWord]) -> GenericInteractableBox? {
        guard !ws.isEmpty else { return nil }
        let sorted = ws.sorted { $0.x < $1.x }
        let text = sorted.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count < 1 { return nil }
        let x1 = sorted.map { $0.x }.min() ?? 0
        let y1 = sorted.map { $0.y }.min() ?? 0
        let x2 = sorted.map { $0.x + $0.w }.max() ?? 0
        let y2 = sorted.map { $0.y + $0.h }.max() ?? 0
        let conf = avg(sorted.map { $0.conf }) / 100.0
        return GenericInteractableBox(id: 0, x1: x1, y1: y1, x2: x2, y2: y2, text: text, kind: "ocr_row", confidence: min(0.99, max(0.2, conf)), source: "tesseract_rows")
    }

    private func isMostlyText(_ s: String) -> Bool {
        s.rangeOfCharacter(from: .letters) != nil || s.rangeOfCharacter(from: .decimalDigits) != nil
    }

    private func classifyOCRRow(_ b: GenericInteractableBox, size: PNGSize) -> GenericInteractableBox? {
        let w = Double(size.width), h = Double(size.height)
        let cx = Double(b.x1 + b.x2) / 2.0
        let lower = b.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let isShort = b.text.count <= 40
        if !isMostlyText(b.text) { return nil }
        if lower.count <= 3 && Double(b.y1) > h * 0.05 { return nil }

        var out = b
        out.source = "ocr+geometry"

        if Double(b.y1) < h * 0.040 {
            out.kind = cx < w * 0.38 ? "menu_bar_item" : "menu_bar_status"
            out.confidence = max(out.confidence, 0.72)
            out.x1 = max(0, b.x1 - 8); out.x2 = min(size.width, b.x2 + 8)
            out.y1 = max(0, b.y1 - 8); out.y2 = min(size.height, b.y2 + 8)
            return out
        }

        if Double(b.x1) < w * 0.20 && isShort {
            if ["pinned", "projects"].contains(lower) { return nil }
            out.kind = "left_nav_row"
            out.confidence = max(out.confidence, 0.80)
            out.x1 = max(0, Int(Double(b.x1) - w * 0.015)); out.x2 = min(size.width, Int(Double(b.x2) + w * 0.035))
            out.y1 = max(0, b.y1 - 8); out.y2 = min(size.height, b.y2 + 8)
            return out
        }

        if Double(b.x1) > w * 0.72 && Double(b.y1) > h * 0.09 && Double(b.y1) < h * 0.45 && isShort {
            if ["environment", "sources"].contains(lower) { return nil }
            out.kind = "right_panel_row"
            out.confidence = max(out.confidence, 0.78)
            out.x1 = max(0, b.x1 - 28); out.x2 = min(size.width, b.x2 + 28)
            out.y1 = max(0, b.y1 - 8); out.y2 = min(size.height, b.y2 + 8)
            return out
        }

        if Double(b.y1) > h * 0.84 && Double(b.x1) > w * 0.25 && Double(b.x1) < w * 0.82 && isShort {
            if lower.contains("auto-review") {
                out.kind = "composer_control"
            } else if lower.contains("review") || lower.contains("files changed") || lower.contains("changed") {
                out.kind = "review_button_or_status"
            } else if lower.contains("ask") || lower.contains("follow") || lower.contains("chang") {
                out.kind = "text_input_placeholder"
            } else {
                out.kind = "composer_control"
            }
            out.confidence = max(out.confidence, 0.82)
            out.x1 = max(0, b.x1 - 14); out.x2 = min(size.width, b.x2 + 16)
            out.y1 = max(0, b.y1 - 10); out.y2 = min(size.height, b.y2 + 10)
            return out
        }

        if isShort && b.width < Int(w * 0.25) {
            let buttonWords = ["review", "commit", "pull", "changes", "local", "main", "settings", "search", "new chat", "auto-review"]
            if buttonWords.contains(where: { lower.contains($0) }) {
                out.kind = "text_button_or_row"
                out.confidence = max(out.confidence, 0.70)
                out.x1 = max(0, b.x1 - 12); out.x2 = min(size.width, b.x2 + 12)
                out.y1 = max(0, b.y1 - 8); out.y2 = min(size.height, b.y2 + 8)
                return out
            }
        }

        return nil
    }

    private func parsePGM(_ url: URL) throws -> (w: Int, h: Int, pixels: [UInt8]) {
        let data = try Data(contentsOf: url)
        var idx = 0
        func nextToken() -> String? {
            while idx < data.count {
                let c = data[idx]
                if c == 35 { while idx < data.count && data[idx] != 10 { idx += 1 } }
                if idx < data.count && data[idx] <= 32 { idx += 1; continue }
                break
            }
            if idx >= data.count { return nil }
            let start = idx
            while idx < data.count && data[idx] > 32 { idx += 1 }
            return String(data: data[start..<idx], encoding: .ascii)
        }
        guard nextToken() == "P5", let sw = nextToken(), let sh = nextToken(), let sm = nextToken(), let w = Int(sw), let h = Int(sh), Int(sm) != nil else {
            throw GenericInteractableDetectorError.badPGM(url.path)
        }
        if idx < data.count && data[idx] <= 32 { idx += 1 }
        let expected = w * h
        guard data.count - idx >= expected else { throw GenericInteractableDetectorError.badPGM(url.path) }
        return (w, h, Array(data[idx..<(idx+expected)]))
    }

    private func connectedComponentsForeground(pixels: [UInt8], w: Int, h: Int, threshold: UInt8 = 175) -> [CC] {
        var visited = Array(repeating: false, count: w*h)
        var comps: [CC] = []
        let dirs = [(1,0),(-1,0),(0,1),(0,-1)]
        for y in 0..<h {
            for x in 0..<w {
                let start = y*w+x
                if visited[start] || pixels[start] < threshold { continue }
                var q = [(x,y)], head = 0
                visited[start] = true
                var minX = x, maxX = x, minY = y, maxY = y, area = 0
                while head < q.count {
                    let (cx,cy) = q[head]; head += 1; area += 1
                    minX = min(minX,cx); maxX = max(maxX,cx); minY = min(minY,cy); maxY = max(maxY,cy)
                    for (dx,dy) in dirs {
                        let nx = cx + dx, ny = cy + dy
                        if nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
                        let ni = ny*w + nx
                        if visited[ni] || pixels[ni] < threshold { continue }
                        visited[ni] = true; q.append((nx,ny))
                    }
                }
                comps.append(CC(x: minX, y: minY, w: maxX-minX+1, h: maxY-minY+1, area: area))
            }
        }
        return comps
    }

    private func connectedComponentsRange(pixels: [UInt8], w: Int, h: Int, low: UInt8, high: UInt8) -> [CC] {
        var visited = Array(repeating: false, count: w*h)
        var comps: [CC] = []
        let dirs = [(1,0),(-1,0),(0,1),(0,-1)]
        for y in 0..<h {
            for x in 0..<w {
                let start = y*w+x
                let v = pixels[start]
                if visited[start] || v < low || v > high { continue }
                var q = [(x,y)], head = 0
                visited[start] = true
                var minX = x, maxX = x, minY = y, maxY = y, area = 0
                while head < q.count {
                    let (cx,cy) = q[head]; head += 1; area += 1
                    minX = min(minX,cx); maxX = max(maxX,cx); minY = min(minY,cy); maxY = max(maxY,cy)
                    for (dx,dy) in dirs {
                        let nx = cx + dx, ny = cy + dy
                        if nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
                        let ni = ny*w + nx
                        let nv = pixels[ni]
                        if visited[ni] || nv < low || nv > high { continue }
                        visited[ni] = true; q.append((nx,ny))
                    }
                }
                comps.append(CC(x: minX, y: minY, w: maxX-minX+1, h: maxY-minY+1, area: area))
            }
        }
        return comps
    }

    private func classifyMidtoneContainer(_ c: CC, size: PNGSize) -> GenericInteractableBox? {
        let W = Double(size.width), H = Double(size.height)
        if c.area < 800 || c.w < 70 || c.h < 20 { return nil }
        if c.w > Int(W * 0.98) && c.h > Int(H * 0.8) { return nil }

        let inComposer = Double(c.y) > H * 0.80 && Double(c.x) > W * 0.20 && Double(c.x) < W * 0.82
        let inRightFloatingPanel = Double(c.x) > W * 0.70 && Double(c.y) > H * 0.06 && Double(c.y) < H * 0.55
        let inMessageBubble = Double(c.x) > W * 0.25 && Double(c.x) < W * 0.82 && c.w < Int(W * 0.45) && c.h < 80

        if inComposer && c.w > Int(W * 0.20) {
            return GenericInteractableBox(id: 0, x1: c.x, y1: c.y, x2: c.x + c.w, y2: c.y + c.h, text: "bottom input/composer container", kind: "text_input_container", confidence: 0.70, source: "midtone_component")
        }
        if inRightFloatingPanel && c.w > Int(W * 0.10) && c.h > 80 {
            return GenericInteractableBox(id: 0, x1: c.x, y1: c.y, x2: c.x + c.w, y2: c.y + c.h, text: "floating side panel", kind: "panel_container", confidence: 0.68, source: "midtone_component")
        }
        if inMessageBubble {
            return GenericInteractableBox(id: 0, x1: c.x, y1: c.y, x2: c.x + c.w, y2: c.y + c.h, text: "button/bubble-like container", kind: "visual_container", confidence: 0.50, source: "midtone_component")
        }
        return nil
    }

    private func classifyComponent(_ c: CC, size: PNGSize) -> GenericInteractableBox? {
        let W = Double(size.width), H = Double(size.height)
        let aspect = Double(c.w) / Double(max(1, c.h))
        if c.area < 12 || c.w < 4 || c.h < 4 { return nil }
        if aspect > 18 || aspect < 0.12 { return nil }
        if c.w > Int(W * 0.35) || c.h > Int(H * 0.20) { return nil }

        let inTopChrome = Double(c.y) < H * 0.09
        let inLeftRail = Double(c.x) < W * 0.20
        let inRightPanel = Double(c.x) > W * 0.75 && Double(c.y) > H * 0.08 && Double(c.y) < H * 0.45
        let inComposer = Double(c.y) > H * 0.86 && Double(c.x) > W * 0.25 && Double(c.x) < W * 0.78

        if c.w <= 42 && c.h <= 42 && (inTopChrome || inLeftRail || inRightPanel || inComposer) {
            let kind = inComposer ? "composer_icon_button" : "icon_button"
            return GenericInteractableBox(id: 0, x1: max(0,c.x - 4), y1: max(0,c.y - 4), x2: c.x + c.w + 4, y2: c.y + c.h + 4, text: kind, kind: kind, confidence: 0.56, source: "connected_component")
        }

        if c.w >= 40 && c.w <= Int(W * 0.30) && c.h >= 16 && c.h <= 62 && (inComposer || inRightPanel || inLeftRail) {
            return GenericInteractableBox(id: 0, x1: max(0,c.x - 6), y1: max(0,c.y - 6), x2: c.x + c.w + 6, y2: c.y + c.h + 6, text: "visual control", kind: "visual_control", confidence: 0.45, source: "connected_component")
        }
        return nil
    }

    private func iou(_ a: GenericInteractableBox, _ b: GenericInteractableBox) -> Double {
        let ix1 = max(a.x1,b.x1), iy1 = max(a.y1,b.y1), ix2 = min(a.x2,b.x2), iy2 = min(a.y2,b.y2)
        let inter = max(0, ix2-ix1) * max(0, iy2-iy1)
        let u = a.area + b.area - inter
        return u > 0 ? Double(inter) / Double(u) : 0
    }

    private func shouldKeepNested(_ b: GenericInteractableBox) -> Bool {
        ["icon_button","composer_icon_button","composer_control","text_input_placeholder","composer_dropdown","model_selector","review_button_or_status","right_panel_row","left_nav_row"].contains(b.kind)
    }

    private func clampBoxes(_ boxes: [GenericInteractableBox], size: PNGSize) -> [GenericInteractableBox] {
        boxes.map { b in
            GenericInteractableBox(id: b.id,
                  x1: max(0, min(size.width, b.x1)),
                  y1: max(0, min(size.height, b.y1)),
                  x2: max(0, min(size.width, b.x2)),
                  y2: max(0, min(size.height, b.y2)),
                  text: b.text, kind: b.kind, confidence: b.confidence, source: b.source)
        }.filter { $0.x2 > $0.x1 && $0.y2 > $0.y1 }
    }

    private func filterComponentDuplicates(_ boxes: [GenericInteractableBox]) -> [GenericInteractableBox] {
        let textish = boxes.filter { $0.source.contains("ocr") }
        return boxes.filter { b in
            if !b.source.contains("connected_component") { return true }
            let cx = (b.x1 + b.x2) / 2
            let cy = (b.y1 + b.y2) / 2
            for t in textish {
                if cx >= t.x1 - 8 && cx <= t.x2 + 8 && cy >= t.y1 - 8 && cy <= t.y2 + 8 {
                    return false
                }
            }
            return true
        }
    }

    private func addInferredContainers(from boxes: [GenericInteractableBox], size: PNGSize) -> [GenericInteractableBox] {
        var out: [GenericInteractableBox] = []
        let composerKids = boxes.filter { ($0.kind.contains("composer") || $0.kind == "text_input_placeholder") && !$0.kind.contains("review") }
        if composerKids.count >= 2 {
            let x1 = max(0, (composerKids.map{$0.x1}.min() ?? 0) - Int(Double(size.width)*0.02))
            let x2 = min(size.width, (composerKids.map{$0.x2}.max() ?? 0) + Int(Double(size.width)*0.02))
            let y1 = max(0, (composerKids.map{$0.y1}.min() ?? 0) - Int(Double(size.height)*0.015))
            let y2 = min(size.height, (composerKids.map{$0.y2}.max() ?? 0) + Int(Double(size.height)*0.015))
            out.append(GenericInteractableBox(id: 0, x1: x1, y1: y1, x2: x2, y2: y2, text: "composer/input container", kind: "text_input_container", confidence: 0.62, source: "inferred_from_children"))
        }
        return out
    }

    private func inferRowsInsideContainers(from words: [OCRWord], containers: [GenericInteractableBox], size: PNGSize) -> [GenericInteractableBox] {
        var out: [GenericInteractableBox] = []
        for c in containers {
            let rows = groupWordsIntoRows(words, region: c, maxGap: 32, rowTol: 10)
            for r0 in rows {
                var r = r0
                let lower = r.text.lowercased()
                if lower.isEmpty || lower.count <= 2 { continue }
                if c.kind == "panel_container" {
                    if ["environment", "sources"].contains(lower) { continue }
                    if lower.contains("no sources yet") { continue }
                    r.kind = "right_panel_row"
                    r.source = "panel_row_inference"
                    r.confidence = max(r.confidence, 0.86)
                    r.x1 = max(c.x1, r.x1 - 38)
                    r.x2 = min(c.x2, r.x2 + 18)
                    r.y1 = max(c.y1, r.y1 - 8)
                    r.y2 = min(c.y2, r.y2 + 8)
                    out.append(r)
                } else if c.kind == "text_input_container" {
                    if lower.contains("ask") || lower.contains("follow") || lower.contains("chang") {
                        r.kind = "text_input_placeholder"
                    } else {
                        r.kind = "composer_control"
                    }
                    r.source = "container_child_inference"
                    r.confidence = max(r.confidence, 0.84)
                    r.x1 = max(c.x1, r.x1 - 10)
                    r.x2 = min(c.x2, r.x2 + 12)
                    r.y1 = max(c.y1, r.y1 - 8)
                    r.y2 = min(c.y2, r.y2 + 8)
                    out.append(r)
                }
            }
        }
        return out
    }

    private func dedupe(_ boxes: [GenericInteractableBox]) -> [GenericInteractableBox] {
        func priority(_ b: GenericInteractableBox) -> Int {
            if b.kind == "right_panel_row" || b.kind == "left_nav_row" || b.kind == "composer_control" || b.kind == "text_input_placeholder" { return 4 }
            if b.kind.contains("container") { return 1 }
            if b.source.contains("ocr") || b.source.contains("inference") { return 3 }
            if b.source.contains("connected_component") { return 2 }
            return 0
        }
        let sorted = boxes.sorted { a,b in
            if priority(a) != priority(b) { return priority(a) > priority(b) }
            if abs(a.confidence - b.confidence) > 0.001 { return a.confidence > b.confidence }
            return a.area > b.area
        }
        var kept: [GenericInteractableBox] = []
        for b in sorted {
            var suppress = false
            for e in kept {
                let overlap = iou(b,e)
                if overlap > 0.76 { suppress = true; break }
                if b.source.contains("connected_component") && e.source.contains("connected_component") {
                    if contains(e,b,pad:3) || (overlap > 0.35) {
                        suppress = true; break
                    }
                    let sameBand = abs((b.y1+b.y2)/2 - (e.y1+e.y2)/2) <= 8
                    let near = abs(b.x1 - e.x1) <= 6 && abs(b.x2 - e.x2) <= 6
                    if sameBand && near { suppress = true; break }
                }
                if contains(e,b,pad:3) && !shouldKeepNested(b) {
                    if b.kind == e.kind || e.kind.contains("container") { suppress = true; break }
                }
            }
            if !suppress { kept.append(b) }
        }
        var result = kept.sorted { $0.y1 == $1.y1 ? $0.x1 < $1.x1 : $0.y1 < $1.y1 }
        for i in result.indices { result[i].id = i + 1 }
        return result
    }

    private func color(_ kind: String) -> String {
        if kind.contains("menu") { return "#50C8FF" }
        if kind.contains("left") { return "#34C759" }
        if kind.contains("right") { return "#FFCC00" }
        if kind.contains("composer") || kind.contains("input") { return "#BF5AF2" }
        if kind.contains("icon") { return "#FF9500" }
        if kind.contains("container") { return "#64D2FF" }
        return "#64D2FF"
    }

    private func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func writeJSON(_ boxes: [GenericInteractableBox], _ url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted,.sortedKeys]
        try enc.encode(boxes).write(to: url)
    }

    private func writeCSV(_ boxes: [GenericInteractableBox], _ url: URL) throws {
        var lines = ["id,x1,y1,x2,y2,text,kind,confidence,source"]
        for b in boxes { lines.append("\(b.id),\(b.x1),\(b.y1),\(b.x2),\(b.y2),\"\(b.text.replacingOccurrences(of: "\"", with: "\"\""))\",\(b.kind),\(String(format: "%.3f", b.confidence)),\(b.source)") }
        try lines.joined(separator:"\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeSVG(input: URL, size: PNGSize, boxes: [GenericInteractableBox], to url: URL) throws {
        let b64 = try Data(contentsOf: input).base64EncodedString()
        var s = """
        <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(size.width)\" height=\"\(size.height)\" viewBox=\"0 0 \(size.width) \(size.height)\"> 
          <image href=\"data:image/png;base64,\(b64)\" x=\"0\" y=\"0\" width=\"\(size.width)\" height=\"\(size.height)\" preserveAspectRatio=\"none\"/>
        """
        for b in boxes {
            let c = color(b.kind)
            s += "\n  <g>"
            s += "\n    <rect x=\"\(b.x1)\" y=\"\(b.y1)\" width=\"\(b.width)\" height=\"\(b.height)\" fill=\"none\" stroke=\"\(c)\" stroke-width=\"2\"/>"
            s += "\n    <text x=\"\(b.x1)\" y=\"\(max(12,b.y1-4))\" font-family=\"Arial\" font-size=\"12\" fill=\"\(c)\">\(b.id)</text>"
            s += "\n    <title>\(b.id): \(xml(b.text)) - \(xml(b.kind)) [\(b.x1),\(b.y1),\(b.x2),\(b.y2)]</title>"
            s += "\n  </g>"
        }
        s += "\n</svg>\n"
        try s.write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct PNGSize: Equatable, Sendable { let width: Int; let height: Int }
private struct OCRWord: Equatable, Sendable { let text: String; let conf: Double; let x: Int; let y: Int; let w: Int; let h: Int; let block: Int; let par: Int; let line: Int }
private struct CC: Equatable, Sendable { let x: Int; let y: Int; let w: Int; let h: Int; let area: Int }

private enum GenericInteractableDetectorError: Error, CustomStringConvertible {
    case noFile(String)
    case commandFailed(String, Int32, String)
    case badPNG(String)
    case badPGM(String)

    var description: String {
        switch self {
        case .noFile(let p): return "File not found: \(p)"
        case .commandFailed(let c, let code, let err): return "Command failed (\(code)): \(c)\n\(err)"
        case .badPNG(let p): return "Could not read PNG size: \(p)"
        case .badPGM(let p): return "Could not parse PGM: \(p)"
        }
    }
}
