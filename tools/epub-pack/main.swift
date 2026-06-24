// epub-pack — a tiny native CLI that packages a folder of authored XHTML pages
// (plus their images) into a valid EPUB 3, and validates one.
//
// pdf-fill writes PDFs; this writes ebooks. The fiddly, deterministic parts of an
// EPUB — the mimetype-first/stored ZIP layout, the OPF manifest+spine, the EPUB3
// nav and a compatibility toc.ncx — are generated here so the model only has to
// author the page XHTML and a small metadata JSON. It uses only Foundation (a
// self-contained store-only ZIP writer + CRC32), so there is no third-party
// dependency to bundle.
//
// Subcommands (all I/O is JSON so an LLM can drive it):
//   epub-pack build    <pagesDir> --meta <book.json> -o <out.epub>
//   epub-pack validate <file.epub>
//
//   --meta accepts a path or "-" for stdin. Errors print {"error":"…"} to stderr
//   and exit non-zero; success prints a JSON result to stdout.
//
// book.json:
//   { "title": "...", "author": "...", "language": "en",
//     "identifier": "urn:uuid:...",            // optional; a UUID urn is generated if absent
//     "cover": "cover.xhtml",                   // optional; first spine item if absent
//     "coverImage": "img/cover.jpg",            // optional; sets the EPUB cover-image
//     "layout": "fixed" | "reflow",             // default "reflow"; "fixed" for comics/picture books
//     "spine": ["cover.xhtml", "p01.xhtml", ...] // required; reading order, paths relative to <pagesDir>
//   }
//
// Everything inside <pagesDir> is copied under OEBPS/ preserving relative paths, so
// a page that references "img/p01.jpg" resolves once both are placed there. Pages may
// also inline images as data: URIs, in which case <pagesDir> holds only the XHTML.

import Foundation

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
            i += 1
        } else {
            positional.append(arg)
            i += 1
        }
    }
    return (positional, flags)
}

func readData(_ pathOrStdin: String) -> Data {
    if pathOrStdin == "-" {
        return FileHandle.standardInput.readDataToEndOfFile()
    }
    guard let data = FileManager.default.contents(atPath: (pathOrStdin as NSString).expandingTildeInPath) else {
        fail("could not read \(pathOrStdin)")
    }
    return data
}

// MARK: - XML escaping

func xmlEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&apos;"
        default: out.append(ch)
        }
    }
    return out
}

// MARK: - Media types

/// The EPUB manifest media-type for a file extension. Unknown types fall back to a
/// generic binary type so the file is still carried (it just won't be a spine page).
func mediaType(forExtension ext: String) -> String {
    switch ext.lowercased() {
    case "xhtml", "html", "htm": return "application/xhtml+xml"
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "gif": return "image/gif"
    case "svg": return "image/svg+xml"
    case "webp": return "image/webp"
    case "css": return "text/css"
    case "ncx": return "application/x-dtbncx+xml"
    case "ttf": return "application/font-sfnt"
    case "otf": return "application/font-sfnt"
    case "woff": return "application/font-woff"
    case "woff2": return "font/woff2"
    case "js": return "text/javascript"
    default: return "application/octet-stream"
    }
}

func isDocumentExtension(_ ext: String) -> Bool {
    let e = ext.lowercased()
    return e == "xhtml" || e == "html" || e == "htm"
}

// MARK: - CRC32 (IEEE) for the ZIP writer

enum CRC32 {
    static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[idx] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Minimal store-only ZIP writer

/// Writes a ZIP archive using the STORE method (no compression) for every entry.
/// EPUB only *requires* the mimetype entry to be stored-and-first; storing the rest
/// keeps the writer dependency-free and is lossless on already-compressed images.
struct ZipWriter {
    struct Entry {
        let name: String
        let data: Data
        let crc: UInt32
        let offset: UInt32
    }

    private var output = Data()
    private var entries: [Entry] = []

    private mutating func le16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { output.append(contentsOf: $0) } }
    private mutating func le32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { output.append(contentsOf: $0) } }

    mutating func add(_ name: String, _ data: Data) {
        let offset = UInt32(output.count)
        let crc = CRC32.checksum(data)
        let nameBytes = Array(name.utf8)
        // Local file header.
        le32(0x0403_4b50)            // signature
        le16(20)                     // version needed
        le16(0)                      // flags
        le16(0)                      // method: store
        le16(0)                      // mod time
        le16(0)                      // mod date
        le32(crc)                    // crc32
        le32(UInt32(data.count))     // compressed size
        le32(UInt32(data.count))     // uncompressed size
        le16(UInt16(nameBytes.count))// name length
        le16(0)                      // extra length
        output.append(contentsOf: nameBytes)
        output.append(data)
        entries.append(Entry(name: name, data: data, crc: crc, offset: offset))
    }

    mutating func finish() -> Data {
        let centralStart = UInt32(output.count)
        for e in entries {
            let nameBytes = Array(e.name.utf8)
            le32(0x0201_4b50)            // central dir signature
            le16(20)                     // version made by
            le16(20)                     // version needed
            le16(0)                      // flags
            le16(0)                      // method: store
            le16(0)                      // mod time
            le16(0)                      // mod date
            le32(e.crc)                  // crc32
            le32(UInt32(e.data.count))   // compressed size
            le32(UInt32(e.data.count))   // uncompressed size
            le16(UInt16(nameBytes.count))// name length
            le16(0)                      // extra length
            le16(0)                      // comment length
            le16(0)                      // disk number start
            le16(0)                      // internal attributes
            le32(0)                      // external attributes
            le32(e.offset)               // local header offset
            output.append(contentsOf: nameBytes)
        }
        let centralSize = UInt32(output.count) - centralStart
        // End of central directory record.
        le32(0x0605_4b50)
        le16(0)                          // this disk
        le16(0)                          // central dir disk
        le16(UInt16(entries.count))      // entries on this disk
        le16(UInt16(entries.count))      // total entries
        le32(centralSize)
        le32(centralStart)
        le16(0)                          // comment length
        return output
    }
}

// MARK: - book.json model

struct Meta {
    var title: String
    var author: String
    var language: String
    var identifier: String
    var cover: String?
    var coverImage: String?
    var layout: String     // "fixed" | "reflow"
    var spine: [String]
}

func loadMeta(_ raw: Data) -> Meta {
    guard let obj = try? JSONSerialization.jsonObject(with: raw),
          let dict = obj as? [String: Any] else {
        fail("--meta is not a JSON object")
    }
    func str(_ key: String) -> String? { (dict[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }

    let title = str("title") ?? "Untitled"
    let author = str("author") ?? "Unknown"
    let language = str("language") ?? "en"
    let identifier = str("identifier") ?? "urn:uuid:\(UUID().uuidString.lowercased())"
    let layoutRaw = (str("layout") ?? "reflow").lowercased()
    let layout = (layoutRaw == "fixed" || layoutRaw == "pre-paginated") ? "fixed" : "reflow"

    // spine accepts ["a.xhtml", ...] or [{"file":"a.xhtml"}, ...].
    guard let rawSpine = dict["spine"] as? [Any], !rawSpine.isEmpty else {
        fail("book.json needs a non-empty \"spine\" array of page file names")
    }
    let spine: [String] = rawSpine.compactMap { item in
        if let s = item as? String { return s }
        if let d = item as? [String: Any], let f = d["file"] as? String { return f }
        return nil
    }
    guard spine.count == rawSpine.count else { fail("every spine entry must be a string or an object with a \"file\"") }

    return Meta(
        title: title, author: author, language: language, identifier: identifier,
        cover: str("cover"), coverImage: str("coverImage"), layout: layout, spine: spine
    )
}

// MARK: - Manifest scanning

struct ManifestItem {
    let id: String
    let href: String        // relative to OEBPS/
    let mediaType: String
    let data: Data
}

/// Recursively collect every file under `pagesDir`, returning manifest items keyed by
/// their path relative to the directory (which becomes the OEBPS-relative href).
func scanPages(_ pagesDir: String) -> [ManifestItem] {
    let base = URL(fileURLWithPath: (pagesDir as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDir), isDir.boolValue else {
        fail("pages directory not found: \(pagesDir)")
    }
    guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else {
        fail("could not read pages directory: \(pagesDir)")
    }
    var items: [ManifestItem] = []
    var index = 0
    for case let url as URL in enumerator {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else { continue }
        if url.lastPathComponent.hasPrefix(".") { continue }   // skip .DS_Store and friends
        let rel = String(url.standardizedFileURL.path.dropFirst(base.path.count + 1))
        guard let data = FileManager.default.contents(atPath: url.path) else {
            fail("could not read \(rel)")
        }
        index += 1
        items.append(ManifestItem(
            id: "item\(index)",
            href: rel,
            mediaType: mediaType(forExtension: url.pathExtension),
            data: data
        ))
    }
    if items.isEmpty { fail("pages directory is empty: \(pagesDir)") }
    return items
}

// MARK: - Generated XML documents

func containerXML() -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """
}

func contentOPF(meta: Meta, items: [ManifestItem], modified: String) -> String {
    let byHref = Dictionary(uniqueKeysWithValues: items.map { ($0.href, $0) })

    var manifest = ""
    for item in items.sorted(by: { $0.href < $1.href }) {
        var props = ""
        if let coverImage = meta.coverImage, item.href == coverImage {
            props = " properties=\"cover-image\""
        }
        manifest += "    <item id=\"\(item.id)\" href=\"\(xmlEscape(item.href))\" media-type=\"\(item.mediaType)\"\(props)/>\n"
    }
    manifest += "    <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n"
    manifest += "    <item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>\n"

    var spine = ""
    for href in meta.spine {
        guard let item = byHref[href] else {
            fail("spine entry \"\(href)\" is not present in the pages directory")
        }
        guard isDocumentExtension((href as NSString).pathExtension) else {
            fail("spine entry \"\(href)\" must be an XHTML document")
        }
        spine += "    <itemref idref=\"\(item.id)\"/>\n"
    }

    let renditionMeta = meta.layout == "fixed"
        ? "    <meta property=\"rendition:layout\">pre-paginated</meta>\n    <meta property=\"rendition:orientation\">auto</meta>\n    <meta property=\"rendition:spread\">auto</meta>\n"
        : ""
    let coverMeta = meta.coverImage != nil
        ? "    <meta name=\"cover\" content=\"\(byHref[meta.coverImage!]?.id ?? "")\"/>\n"
        : ""

    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id" prefix="rendition: http://www.idpf.org/vocab/rendition/#">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="pub-id">\(xmlEscape(meta.identifier))</dc:identifier>
        <dc:title>\(xmlEscape(meta.title))</dc:title>
        <dc:creator>\(xmlEscape(meta.author))</dc:creator>
        <dc:language>\(xmlEscape(meta.language))</dc:language>
        <meta property="dcterms:modified">\(modified)</meta>
    \(renditionMeta)\(coverMeta)  </metadata>
      <manifest>
    \(manifest)  </manifest>
      <spine toc="ncx">
    \(spine)  </spine>
    </package>
    """
}

func navXHTML(meta: Meta) -> String {
    var lis = ""
    for (i, href) in meta.spine.enumerated() {
        lis += "        <li><a href=\"\(xmlEscape(href))\">Page \(i + 1)</a></li>\n"
    }
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(xmlEscape(meta.language))">
      <head><title>\(xmlEscape(meta.title))</title></head>
      <body>
        <nav epub:type="toc" id="toc">
          <h1>\(xmlEscape(meta.title))</h1>
          <ol>
    \(lis)      </ol>
        </nav>
      </body>
    </html>
    """
}

func tocNCX(meta: Meta) -> String {
    var points = ""
    for (i, href) in meta.spine.enumerated() {
        points += """
            <navPoint id="nav\(i + 1)" playOrder="\(i + 1)">
              <navLabel><text>Page \(i + 1)</text></navLabel>
              <content src="\(xmlEscape(href))"/>
            </navPoint>

        """
    }
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
      <head>
        <meta name="dtb:uid" content="\(xmlEscape(meta.identifier))"/>
      </head>
      <docTitle><text>\(xmlEscape(meta.title))</text></docTitle>
      <navMap>
    \(points)  </navMap>
    </ncx>
    """
}

// MARK: - build

func runBuild(_ positional: [String], _ flags: [String: String]) {
    guard positional.count >= 1 else { fail("usage: epub-pack build <pagesDir> --meta <book.json> -o <out.epub>") }
    let pagesDir = positional[0]
    guard let metaPath = flags["meta"] else { fail("build requires --meta <book.json>") }
    guard let outPath = flags["out"] else { fail("build requires -o <out.epub>") }

    let meta = loadMeta(readData(metaPath))
    let items = scanPages(pagesDir)

    // ISO-8601 UTC, no fractional seconds — the form dcterms:modified requires.
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.formatOptions = [.withInternetDateTime]
    let modified = formatter.string(from: Date())

    var zip = ZipWriter()
    // mimetype MUST be the first entry and stored uncompressed.
    zip.add("mimetype", Data("application/epub+zip".utf8))
    zip.add("META-INF/container.xml", Data(containerXML().utf8))
    zip.add("OEBPS/content.opf", Data(contentOPF(meta: meta, items: items, modified: modified).utf8))
    zip.add("OEBPS/nav.xhtml", Data(navXHTML(meta: meta).utf8))
    zip.add("OEBPS/toc.ncx", Data(tocNCX(meta: meta).utf8))
    for item in items {
        zip.add("OEBPS/\(item.href)", item.data)
    }
    let archive = zip.finish()

    let outURL = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
    do {
        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try archive.write(to: outURL, options: .atomic)
    } catch {
        fail("could not write \(outPath): \(error.localizedDescription)")
    }

    emit([
        "out": outURL.path,
        "pageCount": meta.spine.count,
        "fileCount": items.count,
        "layout": meta.layout,
        "bytes": archive.count,
    ])
}

// MARK: - validate

/// A pragmatic structural check (not a full unzip): the file must begin with a local
/// file header for `mimetype`, stored (method 0), whose content is `application/epub+zip`,
/// and the archive must contain the container and the OPF.
func runValidate(_ positional: [String]) {
    guard positional.count >= 1 else { fail("usage: epub-pack validate <file.epub>") }
    let path = (positional[0] as NSString).expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: path) else { fail("could not read \(positional[0])") }

    var problems: [String] = []
    func le16(_ off: Int) -> Int { Int(data[off]) | (Int(data[off + 1]) << 8) }

    if data.count < 38 || data[0] != 0x50 || data[1] != 0x4B || data[2] != 0x03 || data[3] != 0x04 {
        problems.append("not a ZIP archive (missing local file header)")
    } else {
        let method = le16(8)
        let nameLen = le16(26)
        let extraLen = le16(28)
        let nameStart = 30
        let name = String(data: data.subdata(in: nameStart..<min(nameStart + nameLen, data.count)), encoding: .utf8) ?? ""
        if name != "mimetype" { problems.append("first entry is \"\(name)\", expected \"mimetype\"") }
        if method != 0 { problems.append("mimetype is compressed (method \(method)); it must be stored") }
        let contentStart = nameStart + nameLen + extraLen
        let content = String(data: data.subdata(in: contentStart..<min(contentStart + 20, data.count)), encoding: .utf8) ?? ""
        if !content.hasPrefix("application/epub+zip") { problems.append("mimetype content is \"\(content)\"") }
    }

    // Substring scan for the required structural entries (central-directory names).
    func contains(_ needle: String) -> Bool {
        data.range(of: Data(needle.utf8)) != nil
    }
    if !contains("META-INF/container.xml") { problems.append("missing META-INF/container.xml") }
    if !contains("OEBPS/content.opf") { problems.append("missing OEBPS/content.opf") }

    if problems.isEmpty {
        emit(["valid": true, "file": path])
    } else {
        emit(["valid": false, "file": path, "problems": problems])
        exit(2)
    }
}

// MARK: - Entry point

let argv = Array(CommandLine.arguments.dropFirst())
guard let sub = argv.first else {
    fail("usage: epub-pack <build|validate> ...")
}
let (positional, flags) = parse(Array(argv.dropFirst()))
switch sub {
case "build": runBuild(positional, flags)
case "validate": runValidate(positional)
default: fail("unknown subcommand \"\(sub)\" (expected build or validate)")
}
