import Foundation

/// Checks a functional run's RESULT by reading the files the agent produced with the same kind of tools a
/// person would — `qpdf` for page counts, `sips` for image size, `ffprobe` for audio, `pdf-fill` for form
/// values, `jq` for JSON. Each check scans the produced files and passes if any one satisfies it, so the
/// assertion is "the agent produced an artifact of the right shape", not "it used a particular file name".
enum FunctionalEvalVerifier {
    struct Outcome {
        var ok: Bool
        var detail: String
    }

    static func verify(_ check: FunctionalEvalCheck, producedFiles: [URL], sandbox: URL) -> Outcome {
        switch check.kind {
        case "pdfPageCount":
            return pdfPageCount(check.pageCount, producedFiles: producedFiles, sandbox: sandbox)
        case "imageWidth":
            return imageWidth(check.width, producedFiles: producedFiles, sandbox: sandbox)
        case "audio":
            return audioPresent(producedFiles: producedFiles, sandbox: sandbox)
        case "pdfFields":
            return pdfFields(check.containsAll ?? [], producedFiles: producedFiles, sandbox: sandbox)
        case "jsonMinRecords":
            return jsonMinRecords(check.minRecords, producedFiles: producedFiles, sandbox: sandbox)
        case "fileExists":
            return fileExists(extension: check.ext, producedFiles: producedFiles)
        case "epubValid":
            return epubValid(producedFiles: producedFiles, sandbox: sandbox)
        default:
            return Outcome(ok: false, detail: "unknown check kind '\(check.kind)'")
        }
    }

    // MARK: - Checks

    private static func pdfPageCount(_ expected: Int?, producedFiles: [URL], sandbox: URL) -> Outcome {
        guard let expected else { return Outcome(ok: false, detail: "pdfPageCount missing `pageCount`") }
        let pdfs = producedFiles.filter { $0.pathExtension.lowercased() == "pdf" }
        let counts = pdfs.map { pdf -> Int in
            Int(ShellHelper.run("qpdf --show-npages \(quoted(pdf))", in: sandbox)) ?? -1
        }
        let ok = counts.contains(expected)
        return Outcome(ok: ok, detail: "expected a produced PDF with \(expected) pages; produced pdf page counts: \(counts)")
    }

    private static func imageWidth(_ expected: Int?, producedFiles: [URL], sandbox: URL) -> Outcome {
        guard let expected else { return Outcome(ok: false, detail: "imageWidth missing `width`") }
        let images = producedFiles.filter { ["png", "jpg", "jpeg", "gif", "tiff", "heic", "webp"].contains($0.pathExtension.lowercased()) }
        let widths = images.map { image -> Int in
            let out = ShellHelper.run("sips -g pixelWidth \(quoted(image)) | awk '/pixelWidth/{print $2}'", in: sandbox)
            return Int(out) ?? -1
        }
        let ok = widths.contains(expected)
        return Outcome(ok: ok, detail: "expected a produced image \(expected)px wide; produced image widths: \(widths)")
    }

    private static func audioPresent(producedFiles: [URL], sandbox: URL) -> Outcome {
        let media = producedFiles.filter { ["mp3", "m4a", "aac", "wav", "flac", "mp4", "mov", "mkv"].contains($0.pathExtension.lowercased()) }
        let withAudio = media.filter { file in
            ShellHelper.run(
                "ffprobe -v error -select_streams a -show_entries stream=codec_type -of csv=p=0 \(quoted(file))",
                in: sandbox
            ).contains("audio")
        }
        return Outcome(ok: !withAudio.isEmpty, detail: "expected a produced file with an audio stream; produced media: \(media.map(\.lastPathComponent))")
    }

    private static func pdfFields(_ groups: [[String]], producedFiles: [URL], sandbox: URL) -> Outcome {
        let pdfs = producedFiles.filter { $0.pathExtension.lowercased() == "pdf" }
        let dump = pdfs.map { ShellHelper.run("pdf-fill list \(quoted($0))", in: sandbox) }.joined(separator: "\n")
        if dump.isEmpty {
            return Outcome(ok: false, detail: "no field values could be read from produced PDFs: \(pdfs.map(\.lastPathComponent))")
        }
        let missing = groups.filter { group in !group.contains { dump.contains($0) } }
        return Outcome(ok: missing.isEmpty, detail: "missing field groups (none of each present): \(missing)")
    }

    private static func jsonMinRecords(_ minRecords: Int?, producedFiles: [URL], sandbox: URL) -> Outcome {
        guard let minRecords else { return Outcome(ok: false, detail: "jsonMinRecords missing `minRecords`") }
        let jsons = producedFiles.filter { $0.pathExtension.lowercased() == "json" }
        let counts = jsons.map { json -> Int in
            Int(ShellHelper.run("jq 'length' \(quoted(json)) 2>/dev/null", in: sandbox)) ?? -1
        }
        let ok = counts.contains { $0 >= minRecords }
        return Outcome(ok: ok, detail: "expected a produced JSON with ≥\(minRecords) records; produced json lengths: \(counts)")
    }

    /// A produced `.epub` must exist and pass `epub-pack validate` (mimetype first/stored, container + OPF
    /// present) — the real structural check the same bundled tool the agent used can run.
    private static func epubValid(producedFiles: [URL], sandbox: URL) -> Outcome {
        let epubs = producedFiles.filter { $0.pathExtension.lowercased() == "epub" }
        if epubs.isEmpty {
            return Outcome(ok: false, detail: "expected a produced .epub; produced: \(producedFiles.map(\.lastPathComponent))")
        }
        let results = epubs.map { ShellHelper.run("epub-pack validate \(quoted($0))", in: sandbox) }
        let ok = results.contains { $0.contains("\"valid\" : true") || $0.contains("\"valid\":true") }
        return Outcome(ok: ok, detail: "expected a produced .epub that passes `epub-pack validate`; results: \(results)")
    }

    private static func fileExists(extension ext: String?, producedFiles: [URL]) -> Outcome {
        guard let ext else { return Outcome(ok: false, detail: "fileExists missing `extension`") }
        let matches = producedFiles.filter { $0.pathExtension.lowercased() == ext.lowercased() }
        return Outcome(ok: !matches.isEmpty, detail: "expected a produced .\(ext) file; produced: \(producedFiles.map(\.lastPathComponent))")
    }

    private static func quoted(_ url: URL) -> String { "'\(url.path)'" }
}
