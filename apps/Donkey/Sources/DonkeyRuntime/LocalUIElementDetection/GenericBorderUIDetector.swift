import Foundation

struct GenericBorderUIBox: Codable, Equatable, Sendable {
    var id: Int
    var x1: Int
    var y1: Int
    var x2: Int
    var y2: Int
    var text: String
    var kind: String
    var confidence: Double
    var source: String
    var borderStrength: Double
    var fillDensity: Double
    var childCount: Int
    var textCount: Int

    var width: Int { max(0, x2 - x1) }
    var height: Int { max(0, y2 - y1) }
    var area: Int { width * height }
}

struct GenericBorderUIDetectionResult: Equatable, Sendable {
    var boxes: [GenericBorderUIBox]
    var summary: String
}

struct GenericBorderUIDetector: Sendable {
    private var magickPath: String?
    private var tesseractPath: String?
    private var useOCR: Bool
    private var inferRowsInsideContainers: Bool
    private var maxBoxes: Int

    init(
        magickPath: String? = nil,
        tesseractPath: String? = nil,
        useOCR: Bool = true,
        inferRowsInsideContainers: Bool = true,
        maxBoxes: Int = 350
    ) {
        self.magickPath = magickPath
        self.tesseractPath = tesseractPath
        self.useOCR = useOCR
        self.inferRowsInsideContainers = inferRowsInsideContainers
        self.maxBoxes = maxBoxes
    }

    func detect(
        inputURL: URL,
        outputDirectory: URL
    ) throws -> GenericBorderUIDetectionResult {
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw GenericBorderUIDetectorError.noFile(inputURL.path)
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let size = try readPNGSize(inputURL)
        let magick = executablePath(
            preferred: magickPath ?? "magick",
            env: "DONKEY_MAGICK_PATH",
            fallbacks: ["/opt/homebrew/bin/magick", "/usr/local/bin/magick", "/opt/imagemagick/bin/magick"]
        )
        let preprocessed = try preprocess(input: inputURL, outDir: outputDirectory, magick: magick)
        let words = runOCRIfAvailable(input: inputURL)

        var boxes = extractVisualCandidates(
            gray: preprocessed.gray,
            edge: preprocessed.edge,
            size: size,
            minBoxArea: 36
        )
        boxes = attachTextAndCounts(boxes: boxes, words: words)
        boxes = computeChildCounts(boxes)
        boxes = classifyBoxes(boxes: boxes, size: size)

        if inferRowsInsideContainers {
            let rowBoxes = inferRowsInsideContainers(boxes: boxes, words: words, size: size)
            boxes.append(contentsOf: rowBoxes)
            boxes = attachTextAndCounts(boxes: boxes, words: words)
            boxes = computeChildCounts(boxes)
            boxes = classifyBoxes(boxes: boxes, size: size)
        }

        boxes = dedupeAndPrune(boxes, size: size, maxBoxes: maxBoxes)

        let jsonURL = outputDirectory.appendingPathComponent("border_boxes.json")
        let csvURL = outputDirectory.appendingPathComponent("border_boxes.csv")
        let svgURL = outputDirectory.appendingPathComponent("border_overlay.svg")
        try writeJSON(boxes, jsonURL)
        try writeCSV(boxes, csvURL)
        try writeSVG(input: inputURL, size: size, boxes: boxes, to: svgURL)

        return GenericBorderUIDetectionResult(
            boxes: boxes,
            summary: [
                "status=ok",
                "image=\(size.width)x\(size.height)",
                "boxes=\(boxes.count)",
                "json=\(jsonURL.path)",
                "csv=\(csvURL.path)",
                "svg=\(svgURL.path)",
                "preprocessed=\(preprocessed.highContrastURL.path)"
            ].joined(separator: "\n")
        )
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
        if preferred.contains("/"), fm.isExecutableFile(atPath: preferred) {
            return preferred
        }
        if !preferred.contains("/") {
            for prefix in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
                let candidate = "\(prefix)/\(preferred)"
                if fm.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        for fallback in fallbacks where fm.isExecutableFile(atPath: fallback) {
            return fallback
        }
        return preferred
    }

    private func shell(_ executable: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()

        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw GenericBorderUIDetectorError.commandFailed(
                ([executable] + args).joined(separator: " "),
                process.terminationStatus,
                stderr
            )
        }
        return stdout
    }

    private func readPNGSize(_ url: URL) throws -> BorderImageSize {
        let data = try Data(contentsOf: url)
        guard data.count >= 24 && Array(data[0..<8]) == [137, 80, 78, 71, 13, 10, 26, 10] else {
            throw GenericBorderUIDetectorError.badPNG(url.path)
        }
        func be32(_ i: Int) -> UInt32 {
            (UInt32(data[i]) << 24)
                | (UInt32(data[i + 1]) << 16)
                | (UInt32(data[i + 2]) << 8)
                | UInt32(data[i + 3])
        }
        return BorderImageSize(width: Int(be32(16)), height: Int(be32(20)))
    }

    private func parsePGM(_ url: URL) throws -> BorderPixelImage {
        let data = try Data(contentsOf: url)
        var i = 0
        func isASCIIWhitespace(_ b: UInt8) -> Bool {
            b == 9 || b == 10 || b == 11 || b == 12 || b == 13 || b == 32
        }
        func nextToken() -> String? {
            while i < data.count {
                if data[i] == 35 {
                    while i < data.count && data[i] != 10 { i += 1 }
                    continue
                }
                if isASCIIWhitespace(data[i]) {
                    i += 1
                    continue
                }
                break
            }
            guard i < data.count else { return nil }
            let start = i
            while i < data.count && !isASCIIWhitespace(data[i]) { i += 1 }
            return String(data: data[start..<i], encoding: .ascii)
        }

        guard nextToken() == "P5",
              let widthToken = nextToken(),
              let heightToken = nextToken(),
              let maxToken = nextToken(),
              let width = Int(widthToken),
              let height = Int(heightToken),
              let maxValue = Int(maxToken),
              maxValue <= 255
        else {
            throw GenericBorderUIDetectorError.badPGM(url.path)
        }

        if i < data.count && isASCIIWhitespace(data[i]) { i += 1 }
        let expected = width * height
        guard data.count - i >= expected else {
            throw GenericBorderUIDetectorError.badPGM(url.path)
        }
        return BorderPixelImage(width: width, height: height, pixels: Array(data[i..<(i + expected)]))
    }

    private func preprocess(
        input: URL,
        outDir: URL,
        magick: String
    ) throws -> (gray: BorderPixelImage, edge: BorderPixelImage, highContrastURL: URL) {
        let grayPGM = outDir.appendingPathComponent("border_gray.pgm")
        let edgePGM = outDir.appendingPathComponent("border_edges.pgm")
        let highContrast = outDir.appendingPathComponent("border_preprocessed_high_contrast.png")

        _ = try shell(magick, [input.path, "-colorspace", "Gray", "-depth", "8", grayPGM.path])
        _ = try shell(magick, [
            input.path,
            "-colorspace", "Gray",
            "-contrast-stretch", "1%x1%",
            "-sharpen", "0x0.8",
            highContrast.path
        ])
        _ = try shell(magick, [
            input.path,
            "-colorspace", "Gray",
            "-contrast-stretch", "1%x1%",
            "-blur", "0x0.6",
            "-edge", "1",
            "-negate",
            "-threshold", "70%",
            "-morphology", "Dilate", "Rectangle:2x2",
            "-morphology", "Close", "Rectangle:5x3",
            "-depth", "8",
            edgePGM.path
        ])

        return (try parsePGM(grayPGM), try parsePGM(edgePGM), highContrast)
    }

    private func runOCRIfAvailable(input: URL) -> [BorderOCRWord] {
        guard useOCR else { return [] }
        let tesseract = executablePath(
            preferred: tesseractPath ?? "tesseract",
            env: "DONKEY_TESSERACT_PATH",
            fallbacks: ["/opt/homebrew/bin/tesseract", "/usr/local/bin/tesseract", "/usr/bin/tesseract"]
        )
        guard FileManager.default.isExecutableFile(atPath: tesseract) else { return [] }
        do {
            let tsv = try shell(tesseract, [input.path, "stdout", "--psm", "11", "tsv"])
            return parseTesseractTSV(tsv)
        } catch {
            return []
        }
    }

    private func parseTesseractTSV(_ tsv: String) -> [BorderOCRWord] {
        var words: [BorderOCRWord] = []
        for (lineIndex, rawLine) in tsv.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if lineIndex == 0 { continue }
            let cols = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if cols.count < 12 { continue }
            guard cols[0] == "5",
                  let x = Int(cols[6]),
                  let y = Int(cols[7]),
                  let w = Int(cols[8]),
                  let h = Int(cols[9]),
                  let conf = Double(cols[10])
            else { continue }
            let text = cols[11].trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || conf < 20 || w <= 0 || h <= 0 { continue }
            words.append(BorderOCRWord(text: text, confidence: conf / 100.0, x: x, y: y, w: w, h: h))
        }
        return words
    }

    private func connectedComponents(
        image: BorderPixelImage,
        predicate: (UInt8) -> Bool,
        minArea: Int
    ) -> [BorderConnectedComponent] {
        let width = image.width
        let height = image.height
        var visited = Array(repeating: false, count: width * height)
        var result: [BorderConnectedComponent] = []
        let dirs = [(1, 0), (-1, 0), (0, 1), (0, -1)]

        for y in 0..<height {
            for x in 0..<width {
                let startIndex = y * width + x
                if visited[startIndex] || !predicate(image.pixels[startIndex]) { continue }

                var queue: [(Int, Int)] = [(x, y)]
                var head = 0
                visited[startIndex] = true
                var minX = x, maxX = x, minY = y, maxY = y, area = 0

                while head < queue.count {
                    let (cx, cy) = queue[head]
                    head += 1
                    area += 1
                    minX = min(minX, cx); maxX = max(maxX, cx)
                    minY = min(minY, cy); maxY = max(maxY, cy)

                    for (dx, dy) in dirs {
                        let nx = cx + dx
                        let ny = cy + dy
                        if nx < 0 || ny < 0 || nx >= width || ny >= height { continue }
                        let ni = ny * width + nx
                        if visited[ni] || !predicate(image.pixels[ni]) { continue }
                        visited[ni] = true
                        queue.append((nx, ny))
                    }
                }

                if area >= minArea {
                    result.append(
                        BorderConnectedComponent(
                            x: minX,
                            y: minY,
                            w: maxX - minX + 1,
                            h: maxY - minY + 1,
                            area: area
                        )
                    )
                }
            }
        }

        return result
    }

    private func extractVisualCandidates(
        gray: BorderPixelImage,
        edge: BorderPixelImage,
        size: BorderImageSize,
        minBoxArea: Int
    ) -> [GenericBorderUIBox] {
        var boxes: [GenericBorderUIBox] = []

        let edgeComponents = connectedComponents(image: edge, predicate: { $0 > 160 }, minArea: minBoxArea)
        for component in edgeComponents {
            if let box = componentToBox(component, source: "edgeComponent", size: size, edge: edge, gray: gray) {
                boxes.append(box)
            }
        }

        let bands: [(UInt8, UInt8)] = [
            (0, 24), (25, 48), (49, 72), (73, 96), (97, 124),
            (125, 154), (155, 184), (185, 214), (215, 255)
        ]
        for (low, high) in bands {
            let components = connectedComponents(
                image: gray,
                predicate: { $0 >= low && $0 <= high },
                minArea: max(minBoxArea, 80)
            )
            for component in components {
                if let box = componentToBox(component, source: "filledSurface", size: size, edge: edge, gray: gray) {
                    boxes.append(box)
                }
            }
        }

        return boxes
    }

    private func componentToBox(
        _ component: BorderConnectedComponent,
        source: String,
        size: BorderImageSize,
        edge: BorderPixelImage,
        gray: BorderPixelImage
    ) -> GenericBorderUIBox? {
        let area = component.w * component.h
        if component.w < 4 || component.h < 4 { return nil }
        if area < 36 { return nil }
        if component.w > Int(Double(size.width) * 0.985) && component.h > Int(Double(size.height) * 0.90) { return nil }
        if area > Int(Double(size.width * size.height) * 0.72) { return nil }

        let aspect = Double(component.w) / Double(max(1, component.h))
        if aspect > 45 || aspect < 0.025 { return nil }

        var box = GenericBorderUIBox(
            id: 0,
            x1: component.x,
            y1: component.y,
            x2: component.x2,
            y2: component.y2,
            text: "",
            kind: "unknownControl",
            confidence: 0.35,
            source: source,
            borderStrength: 0,
            fillDensity: component.density,
            childCount: 0,
            textCount: 0
        )

        box = expanded(box, by: source == "edgeComponent" ? 2 : 1, size: size)
        box.borderStrength = perimeterEdgeStrength(box: box, edge: edge)
        let contrast = surroundingContrast(box: box, gray: gray)
        let screenArea = Double(size.width * size.height)
        let areaRatio = Double(box.area) / screenArea
        let smallSquareish = box.width >= 8
            && box.width <= max(80, size.width / 18)
            && box.height >= 8
            && box.height <= max(80, size.height / 18)
            && aspect > 0.55
            && aspect < 1.8
        let controlLike = box.height >= max(12, size.height / 160)
            && box.height <= max(96, size.height / 12)
            && box.width >= 8
        let surfaceLooksReal = source == "filledSurface"
            && component.density >= 0.52
            && (contrast > 0.025 || areaRatio > 0.002)
        let edgeLooksReal = source == "edgeComponent"
            && (box.borderStrength > 0.08 || smallSquareish)

        if !surfaceLooksReal && !edgeLooksReal { return nil }
        if areaRatio < 0.000004 && !smallSquareish { return nil }
        if !controlLike && areaRatio < 0.00008 { return nil }

        box.confidence = min(0.95, 0.30 + box.borderStrength * 0.8 + contrast * 0.6 + min(0.2, component.density * 0.15))
        return box
    }

    private func attachTextAndCounts(
        boxes: [GenericBorderUIBox],
        words: [BorderOCRWord]
    ) -> [GenericBorderUIBox] {
        var out = boxes
        for index in out.indices {
            let inside = textInside(out[index], words: words)
            out[index].textCount = inside.count
            if out[index].text.isEmpty {
                out[index].text = labelForBox(out[index], words: words)
            }
        }
        return out
    }

    private func computeChildCounts(_ boxes: [GenericBorderUIBox]) -> [GenericBorderUIBox] {
        var out = boxes
        for i in out.indices {
            var count = 0
            for j in out.indices where i != j {
                if out[j].area < out[i].area && contains(out[i], out[j], padding: 3) {
                    if Double(out[j].area) / Double(max(1, out[i].area)) < 0.80 {
                        count += 1
                    }
                }
            }
            out[i].childCount = count
        }
        return out
    }

    private func classifyBoxes(
        boxes: [GenericBorderUIBox],
        size: BorderImageSize
    ) -> [GenericBorderUIBox] {
        let screenArea = Double(size.width * size.height)
        let W = Double(size.width)
        let H = Double(size.height)

        return boxes.map { original in
            var box = original
            let areaRatio = Double(box.area) / screenArea
            let aspect = Double(box.width) / Double(max(1, box.height))
            let h = Double(box.height)
            let w = Double(box.width)
            let isSmallSquareish = aspect >= 0.55
                && aspect <= 1.85
                && w >= 8
                && h >= 8
                && w <= max(88, W * 0.055)
                && h <= max(88, H * 0.070)
            let isControlHeight = h >= max(12, H * 0.010) && h <= max(96, H * 0.075)
            let isWideControl = isControlHeight && aspect >= 1.7
            let hasText = box.textCount > 0 || !box.text.isEmpty
            let hasChildren = box.childCount >= 2
            let strongBorder = box.borderStrength > 0.13
            let filledSurface = box.source == "filledSurface" && box.fillDensity > 0.52

            if areaRatio > 0.075 && hasChildren {
                box.kind = "section"
                box.confidence = max(box.confidence, 0.72)
            } else if areaRatio > 0.018 && (hasChildren || filledSurface) {
                box.kind = "panel"
                box.confidence = max(box.confidence, 0.68)
            } else if areaRatio > 0.0045 && (hasChildren || hasText) && aspect < 12 {
                box.kind = "card"
                box.confidence = max(box.confidence, 0.62)
            } else if isSmallSquareish && (strongBorder || filledSurface || box.source == "edgeComponent") {
                box.kind = "iconButton"
                box.confidence = max(box.confidence, 0.58)
            } else if isWideControl && aspect >= 4.0 && (strongBorder || filledSurface) && hasText {
                box.kind = "textField"
                box.confidence = max(box.confidence, 0.64)
            } else if isWideControl && aspect >= 1.35 && aspect <= 12.0 && (strongBorder || filledSurface) {
                box.kind = hasText ? "button" : "unknownControl"
                box.confidence = max(box.confidence, hasText ? 0.62 : 0.46)
            } else if aspect >= 3.0 && h <= max(72, H * 0.065) && hasText {
                box.kind = "row"
                box.confidence = max(box.confidence, 0.56)
            } else if hasChildren {
                box.kind = "controlGroup"
                box.confidence = max(box.confidence, 0.55)
            } else {
                box.kind = "unknownControl"
            }
            return box
        }
    }

    private func inferRowsInsideContainers(
        boxes: [GenericBorderUIBox],
        words: [BorderOCRWord],
        size: BorderImageSize
    ) -> [GenericBorderUIBox] {
        if words.isEmpty { return [] }

        let visualContainers = boxes.filter { box in
            ["section", "panel", "card", "controlGroup"].contains(box.kind)
                && box.area > Int(Double(size.width * size.height) * 0.002)
        }
        var inferred: [GenericBorderUIBox] = []

        for container in visualContainers {
            let localWords = words.filter { word in
                containsPoint(container, x: word.cx, y: word.cy, padding: -2)
            }
            if localWords.count < 2 { continue }

            let rows = groupWordsIntoRows(localWords)
            for rowWords in rows {
                if rowWords.isEmpty { continue }
                let x1 = rowWords.map(\.x).min() ?? 0
                let y1 = rowWords.map(\.y).min() ?? 0
                let x2 = rowWords.map(\.x2).max() ?? 0
                let y2 = rowWords.map(\.y2).max() ?? 0
                let text = rowWords.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ")
                let height = y2 - y1
                let width = x2 - x1
                if text.count < 2 || height < 8 || width < 12 { continue }

                let padX = max(8, min(28, container.width / 24))
                let padY = max(5, min(12, container.height / 50))
                let rowBox = GenericBorderUIBox(
                    id: 0,
                    x1: max(container.x1 + 1, x1 - padX),
                    y1: max(container.y1 + 1, y1 - padY),
                    x2: min(container.x2 - 1, x2 + padX),
                    y2: min(container.y2 - 1, y2 + padY),
                    text: String(text.prefix(140)),
                    kind: "row",
                    confidence: min(0.86, 0.45 + rowWords.map(\.confidence).reduce(0, +) / Double(max(1, rowWords.count)) * 0.35),
                    source: "containerRowInference",
                    borderStrength: 0,
                    fillDensity: 0,
                    childCount: 0,
                    textCount: rowWords.count
                )

                if Double(rowBox.area) / Double(max(1, container.area)) > 0.75 { continue }
                if rowBox.height > max(80, container.height / 3) { continue }
                inferred.append(rowBox)
            }
        }

        return inferred
    }

    private func groupWordsIntoRows(
        _ words: [BorderOCRWord],
        rowTolerance: Int = 10,
        maxGap: Int = 48
    ) -> [[BorderOCRWord]] {
        let sorted = words.sorted {
            if abs($0.cy - $1.cy) > rowTolerance { return $0.cy < $1.cy }
            return $0.x < $1.x
        }

        var rows: [[BorderOCRWord]] = []
        for word in sorted {
            if rows.isEmpty {
                rows.append([word])
                continue
            }
            let lastIndex = rows.count - 1
            let center = rows[lastIndex].map(\.cy).reduce(0, +) / max(1, rows[lastIndex].count)
            let medianH = rows[lastIndex].map(\.h).sorted()[rows[lastIndex].count / 2]
            let tolerance = max(rowTolerance, medianH / 2 + 4)
            if abs(word.cy - center) <= tolerance {
                rows[lastIndex].append(word)
            } else {
                rows.append([word])
            }
        }

        var splitRows: [[BorderOCRWord]] = []
        for row in rows {
            let sortedRow = row.sorted { $0.x < $1.x }
            var current: [BorderOCRWord] = []
            for word in sortedRow {
                if current.isEmpty {
                    current.append(word)
                    continue
                }
                let previous = current.last!
                let gap = word.x - previous.x2
                let localMaxGap = max(maxGap, max(previous.h, word.h) * 3)
                if gap > localMaxGap {
                    splitRows.append(current)
                    current = [word]
                } else {
                    current.append(word)
                }
            }
            if !current.isEmpty { splitRows.append(current) }
        }
        return splitRows
    }

    private func dedupeAndPrune(
        _ input: [GenericBorderUIBox],
        size: BorderImageSize,
        maxBoxes: Int
    ) -> [GenericBorderUIBox] {
        func priority(_ box: GenericBorderUIBox) -> Int {
            switch box.kind {
            case "section": return 20
            case "panel": return 19
            case "card": return 18
            case "textField": return 17
            case "button": return 16
            case "iconButton": return 15
            case "row": return 14
            case "controlGroup": return 10
            case "menuItem": return 9
            default: return 1
            }
        }

        let sorted = input
            .filter { $0.area >= 24 && !isLikelyGlyphFragment($0) }
            .sorted {
                if priority($0) != priority($1) { return priority($0) > priority($1) }
                if abs($0.confidence - $1.confidence) > 0.001 { return $0.confidence > $1.confidence }
                return $0.area > $1.area
            }

        var kept: [GenericBorderUIBox] = []
        for candidate in sorted {
            var suppress = false
            for existing in kept {
                let overlap = iou(candidate, existing)
                let contained = contains(existing, candidate, padding: 3)
                let containsExisting = contains(candidate, existing, padding: 3)
                if overlap > 0.78 {
                    suppress = true
                    break
                }
                if contained {
                    if shouldPreserveNested(candidate) {
                        suppress = false
                        continue
                    }
                    if candidate.kind == existing.kind || isLikelyGlyphFragment(candidate) {
                        suppress = true
                        break
                    }
                }
                if containsExisting && shouldPreserveNested(existing) && candidate.kind == "unknownControl" {
                    suppress = true
                    break
                }
            }
            if !suppress {
                kept.append(candidate)
                if kept.count >= maxBoxes { break }
            }
        }

        var final = kept.sorted {
            if $0.y1 == $1.y1 { return $0.x1 < $1.x1 }
            return $0.y1 < $1.y1
        }
        for index in final.indices { final[index].id = index + 1 }
        return final
    }

    private func iou(_ a: GenericBorderUIBox, _ b: GenericBorderUIBox) -> Double {
        let ix1 = max(a.x1, b.x1)
        let iy1 = max(a.y1, b.y1)
        let ix2 = min(a.x2, b.x2)
        let iy2 = min(a.y2, b.y2)
        let inter = max(0, ix2 - ix1) * max(0, iy2 - iy1)
        let union = a.area + b.area - inter
        return union > 0 ? Double(inter) / Double(union) : 0
    }

    private func contains(_ outer: GenericBorderUIBox, _ inner: GenericBorderUIBox, padding: Int = 0) -> Bool {
        outer.x1 - padding <= inner.x1
            && outer.y1 - padding <= inner.y1
            && outer.x2 + padding >= inner.x2
            && outer.y2 + padding >= inner.y2
    }

    private func containsPoint(_ box: GenericBorderUIBox, x: Int, y: Int, padding: Int = 0) -> Bool {
        x >= box.x1 - padding && x <= box.x2 + padding && y >= box.y1 - padding && y <= box.y2 + padding
    }

    private func expanded(_ box: GenericBorderUIBox, by pad: Int, size: BorderImageSize) -> GenericBorderUIBox {
        var out = box
        out.x1 = clamp(box.x1 - pad, 0, size.width)
        out.y1 = clamp(box.y1 - pad, 0, size.height)
        out.x2 = clamp(box.x2 + pad, 0, size.width)
        out.y2 = clamp(box.y2 + pad, 0, size.height)
        return out
    }

    private func perimeterEdgeStrength(box: GenericBorderUIBox, edge: BorderPixelImage) -> Double {
        if box.width <= 1 || box.height <= 1 { return 0 }
        let x1 = clamp(box.x1, 0, edge.width - 1)
        let y1 = clamp(box.y1, 0, edge.height - 1)
        let x2 = clamp(box.x2 - 1, 0, edge.width - 1)
        let y2 = clamp(box.y2 - 1, 0, edge.height - 1)
        if x2 <= x1 || y2 <= y1 { return 0 }

        var hits = 0
        var total = 0
        func sample(_ x: Int, _ y: Int) {
            total += 1
            if edge.value(x: x, y: y) > 160 { hits += 1 }
        }
        for x in x1...x2 {
            sample(x, y1)
            sample(x, y2)
        }
        for y in y1...y2 {
            sample(x1, y)
            sample(x2, y)
        }
        return total > 0 ? Double(hits) / Double(total) : 0
    }

    private func surroundingContrast(box: GenericBorderUIBox, gray: BorderPixelImage, padding: Int = 4) -> Double {
        let innerX1 = clamp(box.x1, 0, gray.width - 1)
        let innerY1 = clamp(box.y1, 0, gray.height - 1)
        let innerX2 = clamp(box.x2, 0, gray.width)
        let innerY2 = clamp(box.y2, 0, gray.height)
        if innerX2 <= innerX1 || innerY2 <= innerY1 { return 0 }

        var insideSum = 0
        var insideN = 0
        let stepX = max(1, (innerX2 - innerX1) / 20)
        let stepY = max(1, (innerY2 - innerY1) / 20)
        var y = innerY1
        while y < innerY2 {
            var x = innerX1
            while x < innerX2 {
                insideSum += Int(gray.value(x: x, y: y))
                insideN += 1
                x += stepX
            }
            y += stepY
        }

        let outerX1 = clamp(box.x1 - padding, 0, gray.width - 1)
        let outerY1 = clamp(box.y1 - padding, 0, gray.height - 1)
        let outerX2 = clamp(box.x2 + padding, 0, gray.width)
        let outerY2 = clamp(box.y2 + padding, 0, gray.height)
        var outsideSum = 0
        var outsideN = 0

        for x in outerX1..<outerX2 {
            for yy in [outerY1, outerY2 - 1] where yy >= 0 && yy < gray.height {
                outsideSum += Int(gray.value(x: x, y: yy))
                outsideN += 1
            }
        }
        for yy in outerY1..<outerY2 {
            for x in [outerX1, outerX2 - 1] where x >= 0 && x < gray.width {
                outsideSum += Int(gray.value(x: x, y: yy))
                outsideN += 1
            }
        }

        guard insideN > 0, outsideN > 0 else { return 0 }
        let insideMean = Double(insideSum) / Double(insideN)
        let outsideMean = Double(outsideSum) / Double(outsideN)
        return abs(insideMean - outsideMean) / 255.0
    }

    private func textInside(_ box: GenericBorderUIBox, words: [BorderOCRWord]) -> [BorderOCRWord] {
        words.filter { containsPoint(box, x: $0.cx, y: $0.cy, padding: 2) }
    }

    private func labelForBox(_ box: GenericBorderUIBox, words: [BorderOCRWord]) -> String {
        let inside = textInside(box, words: words)
        if inside.isEmpty { return "" }
        let sorted = inside.sorted {
            if abs($0.cy - $1.cy) > 8 { return $0.cy < $1.cy }
            return $0.x < $1.x
        }
        let text = sorted.map(\.text).joined(separator: " ")
        return text.count > 140 ? String(text.prefix(137)) + "..." : text
    }

    private func shouldPreserveNested(_ box: GenericBorderUIBox) -> Bool {
        ["button", "iconButton", "textField", "row", "menuItem"].contains(box.kind)
    }

    private func isLikelyGlyphFragment(_ box: GenericBorderUIBox) -> Bool {
        if box.kind == "iconButton" { return false }
        if box.area < 80 { return true }
        if box.width < 6 || box.height < 6 { return true }
        if box.fillDensity < 0.20 && box.borderStrength < 0.05 && box.textCount == 0 { return true }
        return false
    }

    private func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
        max(low, min(high, value))
    }

    private func color(_ kind: String) -> String {
        switch kind {
        case "section": return "#00C7BE"
        case "panel": return "#64D2FF"
        case "card": return "#FFD60A"
        case "row": return "#34C759"
        case "button": return "#FF9500"
        case "iconButton": return "#FF2D55"
        case "textField": return "#BF5AF2"
        case "controlGroup": return "#5E5CE6"
        case "menuItem": return "#0A84FF"
        default: return "#8E8E93"
        }
    }

    private func xml(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func writeJSON(_ boxes: [GenericBorderUIBox], _ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(boxes).write(to: url)
    }

    private func writeCSV(_ boxes: [GenericBorderUIBox], _ url: URL) throws {
        var lines = ["id,x1,y1,x2,y2,kind,confidence,text,source,borderStrength,fillDensity,childCount,textCount"]
        for box in boxes {
            let escaped = box.text.replacingOccurrences(of: "\"", with: "\"\"")
            lines.append([
                String(box.id),
                String(box.x1),
                String(box.y1),
                String(box.x2),
                String(box.y2),
                box.kind,
                String(format: "%.3f", box.confidence),
                "\"\(escaped)\"",
                box.source,
                String(format: "%.3f", box.borderStrength),
                String(format: "%.3f", box.fillDensity),
                String(box.childCount),
                String(box.textCount)
            ].joined(separator: ","))
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeSVG(input: URL, size: BorderImageSize, boxes: [GenericBorderUIBox], to url: URL) throws {
        let base64 = try Data(contentsOf: input).base64EncodedString()
        var svg = """
        <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(size.width)\" height=\"\(size.height)\" viewBox=\"0 0 \(size.width) \(size.height)\">
          <image href=\"data:image/png;base64,\(base64)\" x=\"0\" y=\"0\" width=\"\(size.width)\" height=\"\(size.height)\" preserveAspectRatio=\"none\"/>
        """
        for box in boxes {
            let color = color(box.kind)
            let label = "\(box.id) \(box.kind)"
            let title = "#\(box.id) \(box.kind) [\(box.x1),\(box.y1),\(box.x2),\(box.y2)] \(box.text)"
            svg += "\n  <g>"
            svg += "\n    <rect x=\"\(box.x1)\" y=\"\(box.y1)\" width=\"\(box.width)\" height=\"\(box.height)\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"2\"/>"
            svg += "\n    <rect x=\"\(box.x1)\" y=\"\(max(0, box.y1 - 16))\" width=\"\(max(38, label.count * 7))\" height=\"14\" fill=\"#000000AA\"/>"
            svg += "\n    <text x=\"\(box.x1 + 2)\" y=\"\(max(11, box.y1 - 5))\" font-family=\"Arial, sans-serif\" font-size=\"11\" fill=\"\(color)\">\(xml(label))</text>"
            svg += "\n    <title>\(xml(title))</title>"
            svg += "\n  </g>"
        }
        svg += "\n</svg>\n"
        try svg.write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct BorderImageSize: Equatable, Sendable {
    var width: Int
    var height: Int
}

private struct BorderPixelImage: Equatable, Sendable {
    var width: Int
    var height: Int
    var pixels: [UInt8]

    func value(x: Int, y: Int) -> UInt8 {
        if x < 0 || y < 0 || x >= width || y >= height { return 0 }
        return pixels[y * width + x]
    }
}

private struct BorderConnectedComponent: Equatable, Sendable {
    var x: Int
    var y: Int
    var w: Int
    var h: Int
    var area: Int

    var x2: Int { x + w }
    var y2: Int { y + h }
    var bboxArea: Int { max(1, w * h) }
    var density: Double { Double(area) / Double(bboxArea) }
}

private struct BorderOCRWord: Equatable, Sendable {
    var text: String
    var confidence: Double
    var x: Int
    var y: Int
    var w: Int
    var h: Int

    var x2: Int { x + w }
    var y2: Int { y + h }
    var cx: Int { x + w / 2 }
    var cy: Int { y + h / 2 }
}

private enum GenericBorderUIDetectorError: Error, CustomStringConvertible {
    case noFile(String)
    case commandFailed(String, Int32, String)
    case badPNG(String)
    case badPGM(String)

    var description: String {
        switch self {
        case .noFile(let path):
            return "File not found: \(path)"
        case .commandFailed(let command, let code, let stderr):
            return "Command failed (\(code)): \(command)\n\(stderr)"
        case .badPNG(let path):
            return "Could not parse PNG size: \(path)"
        case .badPGM(let path):
            return "Could not parse PGM: \(path)"
        }
    }
}
