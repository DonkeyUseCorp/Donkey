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

/// Pulls `--flag value` pairs out of an argument list, returning the leftover
/// positional arguments and a flag map. Supports `-o` as an alias for `--out`.
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
            i += 1
            guard i < args.count else { fail("missing value for --\(key)") }
            flags[key] = args[i]
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

    var applied: [String] = []
    var missing: [String] = []
    for (name, rawValue) in map {
        guard let widgets = byName[name], !widgets.isEmpty else { missing.append(name); continue }
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
        applied.append(name)
    }

    let out = outputURL(flags)
    guard document.write(to: out) else { fail("could not write output: \(out.path)") }
    emit(["out": out.path, "applied": applied.sorted(), "missing": missing.sorted()])
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

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("usage: pdf-fill <list|pages|set|overlay|flatten> <in.pdf> [options]")
}
let rest = Array(arguments.dropFirst())
let (positional, flags) = parse(rest)
guard let input = positional.first else { fail("missing input PDF path") }

switch command {
case "list": commandList(input)
case "pages": commandPages(input)
case "set": commandSet(input, flags)
case "overlay": commandOverlay(input, flags)
case "flatten": commandFlatten(input, flags)
default: fail("unknown command: \(command)")
}
