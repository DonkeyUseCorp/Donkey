// pdf-fill — a tiny native PDFKit CLI for filling PDFs headlessly.
//
// litparse (`lit`) reads PDFs; this writes them. It reads and sets AcroForm form
// fields, stamps text onto flat (non-fillable) PDFs at given coordinates, and can
// flatten a filled PDF. It uses only Apple system frameworks (PDFKit/Quartz), so
// there is no third-party dependency to bundle.
//
// Subcommands (all I/O is JSON so an LLM can drive it):
//   pdf-fill list    <in.pdf>                          → fillable fields as JSON
//   pdf-fill pages   <in.pdf>                          → per-page sizes as JSON
//   pdf-fill form    <in.pdf> [--page N]               → reading-order page view (text + fields)
//   pdf-fill set     <in.pdf> --data <map.json> -o <out.pdf>
//   pdf-fill overlay <in.pdf> --data <items.json> -o <out.pdf>
//   pdf-fill flatten <in.pdf> -o <out.pdf>
//
// --data accepts a path or "-" for stdin. Errors print {"error":"…"} to stderr
// and exit non-zero. Coordinates are PDF points from the bottom-left of the page
// (use `pages` to get heights when converting from a top-left parser like lit).

import Foundation
import PDFKit
import Quartz

// MARK: - Output helpers

func fail(_ message: String) -> Never {
    let payload = ["error": message]
    if let data = try? JSONSerialization.data(withJSONObject: payload),
       let text = String(data: data, encoding: .utf8) {
        FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
    }
    exit(1)
}

func emit(_ object: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        fail("could not serialize output")
    }
    print(text)
}

// MARK: - Argument parsing

/// Valueless boolean flags: present means true, and they never consume the next
/// argument. `--pretty` is one because output is always pretty-printed — the `pdf`
/// skill documents `pdf-fill list … --pretty`, and without this the parser tried to
/// read a value for it, failed ("missing value for --pretty"), and wrote an empty
/// field list, so form filling silently had nothing to map.
let booleanFlags: Set<String> = ["pretty", "full"]

/// Pulls `--flag value` pairs out of an argument list, returning the leftover
/// positional arguments and a flag map. Supports `-o` as an alias for `--out`, and
/// valueless boolean flags (see `booleanFlags`) that stand alone.
func parse(_ args: [String]) -> (positional: [String], flags: [String: String]) {
    var positional: [String] = []
    var flags: [String: String] = [:]
    var i = 0
    while i < args.count {
        let arg = args[i]
        let key: String?
        if arg == "-o" { key = "out" }
        else if arg.hasPrefix("--") { key = String(arg.dropFirst(2)) }
        else { key = nil }
        if let key = key {
            if booleanFlags.contains(key) {
                flags[key] = "true"
            } else {
                i += 1
                guard i < args.count else { fail("missing value for --\(key)") }
                flags[key] = args[i]
            }
        } else {
            positional.append(arg)
        }
        i += 1
    }
    return (positional, flags)
}

func loadDocument(_ path: String) -> PDFDocument {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard let document = PDFDocument(url: url) else { fail("could not open PDF: \(path)") }
    if document.isLocked { fail("PDF is password-protected; decrypt it first (qpdf --password=… --decrypt)") }
    return document
}

func readData(_ flags: [String: String]) -> Data {
    guard let source = flags["data"] else { fail("missing --data <file|->") }
    if source == "-" {
        return FileHandle.standardInput.readDataToEndOfFile()
    }
    let url = URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
    guard let data = try? Data(contentsOf: url) else { fail("could not read --data file: \(source)") }
    return data
}

func outputURL(_ flags: [String: String]) -> URL {
    guard let out = flags["out"] else { fail("missing -o/--out <out.pdf>") }
    return URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
}

// MARK: - AcroForm field model

let kFieldName = PDFAnnotationKey(rawValue: "/T")
let kChoiceOptions = PDFAnnotationKey(rawValue: "/Opt")

/// A short, stable type label for a widget annotation.
func fieldType(_ annotation: PDFAnnotation) -> String {
    switch annotation.widgetFieldType {
    case .text: return "text"
    case .button: return "button"
    case .choice: return "choice"
    case .signature: return "signature"
    default: return "unknown"
    }
}

/// The widget's partial field name (the PDF "/T" entry). Good enough for the flat,
/// non-hierarchical AcroForms that make up the vast majority of real-world forms.
func fieldName(_ annotation: PDFAnnotation) -> String? {
    annotation.value(forAnnotationKey: kFieldName) as? String
}

func currentValue(_ annotation: PDFAnnotation) -> String {
    switch annotation.widgetFieldType {
    case .button:
        return annotation.buttonWidgetState == .onState ? annotation.buttonWidgetStateString : ""
    default:
        return annotation.widgetStringValue ?? ""
    }
}

func widgetAnnotations(_ document: PDFDocument) -> [(page: Int, annotation: PDFAnnotation)] {
    var result: [(Int, PDFAnnotation)] = []
    for index in 0..<document.pageCount {
        guard let page = document.page(at: index) else { continue }
        // Only true form widgets are fillable; skip plain markup annotations.
        for annotation in page.annotations where annotation.type == "Widget" {
            result.append((index, annotation))
        }
    }
    return result
}

// MARK: - Commands

func commandList(_ path: String) {
    let document = loadDocument(path)
    var fields: [[String: Any]] = []
    for (page, annotation) in widgetAnnotations(document) {
        guard let name = fieldName(annotation) else { continue }
        let bounds = annotation.bounds
        var entry: [String: Any] = [
            "name": name,
            "type": fieldType(annotation),
            "value": currentValue(annotation),
            "page": page,
            "rect": [bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height],
        ]
        if let options = annotation.value(forAnnotationKey: kChoiceOptions) as? [Any] {
            entry["options"] = options.compactMap { $0 as? String }
        }
        fields.append(entry)
    }
    emit(fields)
}

func commandPages(_ path: String) {
    let document = loadDocument(path)
    var pages: [[String: Any]] = []
    for index in 0..<document.pageCount {
        guard let page = document.page(at: index) else { continue }
        let box = page.bounds(for: .mediaBox)
        pages.append(["page": index, "width": box.size.width, "height": box.size.height])
    }
    emit(pages)
}

// MARK: - Reading-order page view

/// Groups a page's characters into words with their on-page bounds. PDFKit's
/// `characterBounds(at:)` returns rects in the same bottom-left coordinate space
/// as widget annotations, so words and fields can be merged without any flip.
func words(on page: PDFPage) -> [(rect: CGRect, text: String)] {
    let count = page.numberOfCharacters
    guard count > 0, let text = page.string as NSString? else { return [] }
    var out: [(CGRect, String)] = []
    var current = ""
    var rect = CGRect.null
    func flush() {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !rect.isNull { out.append((rect, trimmed)) }
        current = ""
        rect = .null
    }
    for index in 0..<count {
        let char = index < text.length ? text.substring(with: NSRange(location: index, length: 1)) : " "
        if char == " " || char == "\n" || char == "\t" || char == "\r" { flush(); continue }
        current += char
        let bounds = page.characterBounds(at: index)
        rect = rect.isNull ? bounds : rect.union(bounds)
    }
    flush()
    return out
}

/// The short, unique id shown for a field and accepted by `set`: the leaf of the
/// fully-qualified name, keeping the trailing widget index so paired checkbox widgets
/// (`c1_11[0]` vs `c1_11[1]`) stay distinct. The full name on a real form is ~56
/// characters (`topmostSubform[0].Page1[0].NameFieldsReadOrder[0].f1_4[0]`), which
/// is far too verbose to repeat for every field in a page view bound by a small
/// output budget — the leaf (`f1_4[0]`) carries the same identity in a handful of
/// characters, and `set` maps it back.
func leafName(_ fullName: String) -> String {
    fullName.split(separator: ".").last.map(String.init) ?? fullName
}

/// An inline marker for a form field, placed where the field sits in the page so an
/// LLM can read the surrounding label and bind a value to the field's short id.
/// `⟦id⟧` is a text field, `⟦x id=on⟧` a checkbox (set `id` to `on` to tick it), and
/// `⟦? id=a|b⟧` a dropdown with its options.
func fieldMarker(_ annotation: PDFAnnotation, name: String) -> String {
    let id = leafName(name)
    switch annotation.widgetFieldType {
    case .button:
        let on = annotation.buttonWidgetStateString
        return on.isEmpty ? "⟦x \(id)⟧" : "⟦x \(id)=\(on)⟧"
    case .choice:
        let options = (annotation.value(forAnnotationKey: kChoiceOptions) as? [Any])?.compactMap { $0 as? String } ?? []
        return options.isEmpty ? "⟦? \(id)⟧" : "⟦? \(id)=\(options.joined(separator: "|"))⟧"
    default:
        return "⟦\(id)⟧"
    }
}

/// The reading-order lines for ONE page: printed words and inline field markers, banded
/// top-to-bottom and joined left-to-right. Shared by the paged view and `--full`.
func formLines(for page: PDFPage) -> [String] {
    // A token is a positioned piece of the page — either a printed word or a field marker.
    struct Token { let y: CGFloat; let x: CGFloat; let text: String }
    var tokens: [Token] = []
    for (rect, text) in words(on: page) {
        // Drop dotted leaders ("....") — pure visual fill between a label and its blank,
        // noise in a text view and a large fraction of a dense form's characters.
        if text.allSatisfy({ $0 == "." }) { continue }
        tokens.append(Token(y: rect.midY, x: rect.minX, text: text))
    }
    for annotation in page.annotations where annotation.type == "Widget" {
        guard let name = fieldName(annotation) else { continue }
        tokens.append(Token(y: annotation.bounds.midY, x: annotation.bounds.minX, text: fieldMarker(annotation, name: name)))
    }

    // Top-to-bottom, then left-to-right within a band. Bands grow from their own top
    // edge so a tall field cannot swallow rows far below it. Each band becomes a line.
    tokens.sort { $0.y != $1.y ? $0.y > $1.y : $0.x < $1.x }
    let bandTolerance: CGFloat = 6
    var bands: [[Token]] = []
    for token in tokens {
        if let top = bands.last?.first, top.y - token.y <= bandTolerance {
            bands[bands.count - 1].append(token)
        } else {
            bands.append([token])
        }
    }
    return bands.map { band in band.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ") }
}

let formMarkerLegend = "(⟦id⟧ = text field · ⟦x id=on⟧ = checkbox, set id to its on-value to tick · ⟦? id=a|b⟧ = dropdown. Fill with: pdf-fill set)"

/// Renders ONE page of the form the way a person reads it: top-to-bottom,
/// left-to-right, with the fillable fields interleaved inline among the printed text
/// as short-id markers. This replaces guessing one label per field (which fails on
/// dense grid forms where a field shares a horizontal band with unrelated text) — the
/// model reads the page and binds values to the ids it sees.
///
/// One page at a time (default page 0; `--page N`, 0-indexed) because the model's
/// per-tool-result budget is small and a whole multi-page form floods it. A single
/// dense page can still exceed that budget, so the page is packed into PARTS of whole
/// lines that each fit, navigated with `--part K` — nothing is silently truncated
/// mid-page, and a footer says how to read the rest.
func commandForm(_ path: String, _ flags: [String: String]) {
    let document = loadDocument(path)
    let pageCount = document.pageCount
    let pageIndex = flags["page"].flatMap { Int($0) } ?? 0
    let requestedPart = max(1, flags["part"].flatMap { Int($0) } ?? 1)
    let fileName = (path as NSString).lastPathComponent

    // `--full` dumps the WHOLE form — every page, no part-chunking, no nav footer — for a
    // single mapping pass (the pdf.fill tool). The part/budget logic below exists only to
    // fit the planner's per-result cap, which the one-shot mapper does not have.
    if flags["full"] != nil {
        var out: [String] = [formMarkerLegend]
        for index in 0..<pageCount {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .mediaBox)
            out.append("=== \(fileName) · page \(index) of \(pageCount - 1) (\(Int(box.width))x\(Int(box.height))) ===")
            out.append(contentsOf: formLines(for: page))
        }
        print(out.joined(separator: "\n"))
        return
    }

    guard pageIndex >= 0, pageIndex < pageCount, let page = document.page(at: pageIndex) else {
        fail("no such page \(pageIndex); the form has pages 0…\(pageCount - 1)")
    }
    let box = page.bounds(for: .mediaBox)

    let lines = formLines(for: page)

    // Pack whole lines into parts that each fit the model's per-result budget, so a
    // dense page is read part by part instead of being cut off mid-page.
    let partBudget = 3000
    var parts: [[String]] = [[]]
    var size = 0
    for line in lines {
        if size + line.count > partBudget, !(parts[parts.count - 1].isEmpty) {
            parts.append([])
            size = 0
        }
        parts[parts.count - 1].append(line)
        size += line.count + 1
    }
    let partCount = parts.count
    let part = min(requestedPart, partCount)

    var out: [String] = []
    let partLabel = partCount > 1 ? ", part \(part) of \(partCount)" : ""
    out.append("=== \(fileName) · page \(pageIndex) of \(pageCount - 1)\(partLabel) (\(Int(box.width))x\(Int(box.height))) ===")
    if part == 1 {
        out.append(formMarkerLegend)
    }
    out.append(contentsOf: parts[part - 1])
    var nav: [String] = []
    if part < partCount { nav.append("rest of THIS page → --page \(pageIndex) --part \(part + 1)") }
    if pageIndex < pageCount - 1 { nav.append("NEXT page → --page \(pageIndex + 1)") }
    if !nav.isEmpty { out.append("[\(nav.joined(separator: "   "))]") }
    print(out.joined(separator: "\n"))
}

/// Coerce a JSON value to a number, accepting either a real JSON number or a
/// numeric string (an LLM may emit `"x":"120"`). Returns nil for anything else.
func numericValue(_ value: Any?) -> NSNumber? {
    if let number = value as? NSNumber { return number }
    if let string = value as? String {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if let double = Double(trimmed) { return NSNumber(value: double) }
    }
    return nil
}

func boolFromString(_ string: String) -> Bool? {
    switch string.lowercased() {
    case "on", "true", "yes", "1", "checked", "x": return true
    case "off", "false", "no", "0", "unchecked", "": return false
    default: return nil
    }
}

/// Apply a value to a button field, which may be a single checkbox or a radio
/// group of several widgets that share one field name. For a multi-widget group,
/// turn ON the widget whose "on" state string matches the requested option and
/// turn the rest OFF, so exactly the chosen option ends up selected. For a single
/// checkbox, interpret the value as a boolean on/off.
func applyButtonField(_ widgets: [PDFAnnotation], _ rawValue: Any) {
    // Try to resolve the value to a specific option name (the widget's on-state).
    let requested: String?
    if let string = rawValue as? String { requested = string }
    else if let number = rawValue as? NSNumber, !(rawValue is Bool) { requested = number.stringValue }
    else { requested = nil }

    // Radio group: more than one widget, each with a distinct on-state string.
    if widgets.count > 1, let option = requested,
       widgets.contains(where: { $0.buttonWidgetStateString == option }) {
        for widget in widgets {
            widget.buttonWidgetState = widget.buttonWidgetStateString == option ? .onState : .offState
        }
        return
    }

    // Single checkbox (or a boolean/unmatched value): toggle every widget on/off.
    let on: Bool
    if let flag = rawValue as? Bool { on = flag }
    else if let string = rawValue as? String, let flag = boolFromString(string) { on = flag }
    else if let number = rawValue as? NSNumber { on = number.boolValue }
    else { on = true }
    for widget in widgets { widget.buttonWidgetState = on ? .onState : .offState }
}

func commandSet(_ path: String, _ flags: [String: String]) {
    let document = loadDocument(path)
    let data = readData(flags)
    guard let map = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        fail("--data must be a JSON object of {fieldName: value}")
    }

    // Index ALL widgets per field name. A single field can have multiple widgets:
    // radio groups (one widget per option), or a text field repeated across pages.
    var byName: [String: [PDFAnnotation]] = [:]
    for (_, annotation) in widgetAnnotations(document) {
        if let name = fieldName(annotation) { byName[name, default: []].append(annotation) }
    }
    // Accept the short ids the `form` view shows (`f1_4[0]`, or `f1_4` without the
    // widget index) as well as full names: index leaf → the full names that carry it,
    // so a key can be resolved when it is unambiguous.
    var byLeaf: [String: Set<String>] = [:]
    for name in byName.keys {
        let last = leafName(name)
        byLeaf[last, default: []].insert(name)
        if let bracket = last.firstIndex(of: "["), last.hasSuffix("]") {
            byLeaf[String(last[..<bracket]), default: []].insert(name)
        }
    }

    var applied: [String] = []
    var missing: [String] = []
    var ambiguous: [String] = []
    for (key, rawValue) in map {
        // Resolve the key to a full field name: exact match first, else a unique leaf.
        let fullName: String
        if byName[key] != nil {
            fullName = key
        } else if let names = byLeaf[key], names.count == 1 {
            fullName = names.first!
        } else if let names = byLeaf[key], names.count > 1 {
            ambiguous.append("\(key) → \(names.sorted().joined(separator: ", "))")
            continue
        } else {
            missing.append(key)
            continue
        }
        guard let widgets = byName[fullName], !widgets.isEmpty else { missing.append(key); continue }
        // A field is button-like if any of its widgets is a button (radio/checkbox).
        let isButton = widgets.contains { $0.widgetFieldType == .button }
        if isButton {
            applyButtonField(widgets, rawValue)
        } else {
            let string: String
            if let value = rawValue as? String { string = value }
            else if let flag = rawValue as? Bool { string = flag ? "Yes" : "No" }
            else { string = String(describing: rawValue) }
            // Set on every widget sharing the name (text fields spanning pages).
            for widget in widgets { widget.widgetStringValue = string }
        }
        // Report the caller's OWN key (the short id it passed), not the resolved full field name, so
        // `applied`/`missing`/`ambiguous` are all in one key space and a caller can map an applied id back to
        // the value it sent. Reporting the full name here broke that — the value lookup keyed by short id
        // missed every applied field.
        applied.append(key)
    }

    let out = outputURL(flags)
    guard document.write(to: out) else { fail("could not write output: \(out.path)") }
    var result: [String: Any] = ["out": out.path, "applied": applied.sorted(), "missing": missing.sorted()]
    // Surface ambiguous ids distinctly (with their candidates) so the caller adds the
    // widget index rather than assuming the value silently landed.
    if !ambiguous.isEmpty { result["ambiguous"] = ambiguous.sorted() }
    emit(result)
}

func commandOverlay(_ path: String, _ flags: [String: String]) {
    let document = loadDocument(path)
    let data = readData(flags)
    guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
        fail("--data must be a JSON array of {page, x, y, text, size?}")
    }

    var stamped = 0
    var skipped: [[String: Any]] = []
    for (offset, item) in items.enumerated() {
        guard let pageIndex = numericValue(item["page"])?.intValue,
              let x = numericValue(item["x"])?.doubleValue,
              let y = numericValue(item["y"])?.doubleValue,
              let text = item["text"] as? String else {
            skipped.append(["index": offset, "reason": "needs page, x, y, text (numbers or numeric strings)"])
            continue
        }
        guard let page = document.page(at: pageIndex) else {
            skipped.append(["index": offset, "reason": "no such page: \(pageIndex)"])
            continue
        }
        let size = numericValue(item["size"])?.doubleValue ?? 12
        // Width/height are generous so the text is never clipped; freeText draws
        // top-left within its bounds, so anchor the box's top at the given y.
        let width = numericValue(item["width"])?.doubleValue ?? max(120, Double(text.count) * size * 0.6)
        let height = numericValue(item["height"])?.doubleValue ?? (size * 1.4)
        let bounds = CGRect(x: x, y: y - height, width: width, height: height)
        let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = NSFont.systemFont(ofSize: CGFloat(size))
        annotation.fontColor = .black
        annotation.color = .clear
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        page.addAnnotation(annotation)
        stamped += 1
    }

    // Only abort if nothing at all could be stamped; otherwise write the valid
    // stamps and report which items were skipped and why.
    guard stamped > 0 else {
        fail("no overlay items could be stamped; \(skipped.count) skipped")
    }

    let out = outputURL(flags)
    guard document.write(to: out) else { fail("could not write output: \(out.path)") }
    var result: [String: Any] = ["out": out.path, "stamped": stamped]
    if !skipped.isEmpty { result["skipped"] = skipped }
    emit(result)
}

/// Burns annotations (form values, overlays) into page content so the result is
/// non-editable while keeping the original vector text selectable.
func commandFlatten(_ path: String, _ flags: [String: String]) {
    let document = loadDocument(path)
    let out = outputURL(flags)

    let pdfData = NSMutableData()
    guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else { fail("could not create PDF consumer") }
    var firstBox = (document.page(at: 0)?.bounds(for: .mediaBox)) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(consumer: consumer, mediaBox: &firstBox, nil) else { fail("could not create PDF context") }

    let total = document.pageCount
    var processed = 0
    var droppedPages: [Int] = []
    for index in 0..<total {
        guard let page = document.page(at: index) else { droppedPages.append(index); continue }
        var box = page.bounds(for: .mediaBox)
        let pageInfo = [kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)]
        context.beginPDFPage(pageInfo as CFDictionary)
        if let cgPage = page.pageRef {
            context.drawPDFPage(cgPage)
        }
        for annotation in page.annotations {
            annotation.draw(with: .mediaBox, in: context)
        }
        context.endPDFPage()
        processed += 1
    }
    context.closePDF()

    do {
        try pdfData.write(to: out, options: .atomic)
    } catch {
        fail("could not write output: \(out.path)")
    }

    var result: [String: Any] = [
        "out": out.path,
        "flattened": true,
        "processedPages": processed,
        "totalPages": total,
    ]
    // Surface any page loss explicitly so the caller does not mistake a
    // page-dropped output for a clean success.
    if !droppedPages.isEmpty {
        result["droppedPages"] = droppedPages
        result["warning"] = "dropped \(droppedPages.count) of \(total) pages: \(droppedPages.map(String.init).joined(separator: ", "))"
    }
    emit(result)
}

// MARK: - Entry point

/// Usage, printed to stdout (exit 0) for `--help`/`-h`/`help` or a bare invocation.
/// A confused caller that probes `pdf-fill --help` gets oriented instead of a non-zero
/// exit that reads as a broken tool and sends it flailing.
let usageText = """
pdf-fill — fill PDF forms headlessly (native PDFKit, JSON I/O).

  pdf-fill list    <in.pdf>                 fillable fields as JSON {name,type,value,page,rect}
  pdf-fill pages   <in.pdf>                 per-page sizes as JSON
  pdf-fill form    <in.pdf> [--page N] [--part K]
                                            read ONE page like a person: text with fields shown
                                            inline as ⟦id⟧ / ⟦x id=on⟧ / ⟦? id=a|b⟧. Default page 0;
                                            a dense page splits into parts. THIS is how you learn
                                            which id to fill — read it page by page.
  pdf-fill set     <in.pdf> --data <map.json|-> -o <out.pdf>
                                            apply {id: value}. Ids are what `form` shows (e.g.
                                            "f1_4[0]") or full names; checkboxes take the on-value
                                            (or true/false). Reports applied / missing / ambiguous.
  pdf-fill overlay <in.pdf> --data <items.json|-> -o <out.pdf>
                                            stamp text on a flat/scanned form by position
  pdf-fill flatten <in.pdf> -o <out.pdf>    burn values into the page (non-editable)

Typical form fill: pdf-fill form in.pdf  →  read page, build {id:value}  →  pdf-fill set … -o out.pdf  →  next page.
"""

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") || arguments.first == "help" {
    print(usageText)
    exit(0)
}
let command = arguments[0]
let rest = Array(arguments.dropFirst())
let (positional, flags) = parse(rest)
guard let input = positional.first else { fail("missing input PDF path") }

switch command {
case "list": commandList(input)
case "pages": commandPages(input)
case "form": commandForm(input, flags)
case "set": commandSet(input, flags)
case "overlay": commandOverlay(input, flags)
case "flatten": commandFlatten(input, flags)
default: fail("unknown command: \(command); run `pdf-fill --help`")
}
