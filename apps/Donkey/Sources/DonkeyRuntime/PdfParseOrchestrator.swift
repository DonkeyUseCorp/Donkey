import DonkeyHarness
import Foundation

/// The deterministic half of `pdf.parse`: resolve the PDF path, run the bundled `lit` (liteparse) in-process
/// via `runBundledTool` — which resolves the binary and sets PDFIUM_LIB_PATH — and hand back the extracted
/// text or JSON. There is NO model call here, and `lit` is never invoked through the model-facing shell, so
/// the planner reads a PDF through one tool and never types `lit` itself.
public struct PdfParseOrchestrator: Sendable {
    public init() {}

    public func parse(_ request: HarnessPdfParseRequest) async -> HarnessPdfParseOutcome {
        let fileManager = FileManager.default
        // Working directory: the conversation's own folder when present, else home — same rule as shell_exec.
        let workingDirectory = DonkeyCommandBackends.resolvedWorkingDirectoryPath(request.workingDirectory)

        // The PDF to read may live anywhere the user pointed at (an attachment, a Downloads file); reading is
        // trusted, so the input path is resolved as-is.
        let filePath = Self.resolve(request.file, against: workingDirectory)
        guard fileManager.fileExists(atPath: filePath) else {
            return HarnessPdfParseOutcome(text: "No PDF at \(request.file).", succeeded: false)
        }

        var arguments = ["parse", filePath]
        if request.format?.lowercased() == "json" {
            arguments += ["--format", "json"]
        }
        if let pages = request.pages, !pages.isEmpty {
            arguments += ["--target-pages", pages]
        }
        if request.noOcr {
            arguments.append("--no-ocr")
        }
        // A written output is confined to the workspace: pdf.parse runs without a consent prompt, so its file
        // never lands outside the agent's own folder even if the model passes an absolute or `..` path.
        var outPath: String?
        if let out = request.out, !out.isEmpty {
            let resolved = Self.confine(out, to: workingDirectory)
            arguments += ["-o", resolved]
            outPath = resolved
        }

        let result = DonkeyCommandBackends.runBundledTool("lit", arguments, workingDirectory: workingDirectory)
        guard result.exitCode == 0 else {
            let why = result.stderr.isEmpty ? result.stdout : result.stderr
            return HarnessPdfParseOutcome(text: "Could not parse \(request.file): \(why)", succeeded: false)
        }

        if let outPath {
            guard fileManager.fileExists(atPath: outPath) else {
                return HarnessPdfParseOutcome(text: "lit reported success but wrote no file to \(outPath).", succeeded: false)
            }
            let bytes = (try? fileManager.attributesOfItem(atPath: outPath))?[.size] as? Int
            let size = bytes.map { " (\($0) bytes)" } ?? ""
            return HarnessPdfParseOutcome(
                text: "Parsed \(request.file) → \(outPath)\(size).",
                succeeded: true,
                outPath: outPath
            )
        }

        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return HarnessPdfParseOutcome(text: "Parsed \(request.file) but it produced no text.", succeeded: false)
        }
        return HarnessPdfParseOutcome(text: text, succeeded: true)
    }

    /// Resolve a read path against the working directory — absolute/`~` honored, a bare name lands in the
    /// workspace.
    private static func resolve(_ path: String, against workingDirectory: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath { return expanded }
        return (workingDirectory as NSString).appendingPathComponent(expanded)
    }

    /// Re-root a write path under the workspace, dropping `..`/absolute escapes.
    private static func confine(_ path: String, to workingDirectory: String) -> String {
        let safe = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != ".." && $0 != "." }
        return safe.reduce(workingDirectory) { ($0 as NSString).appendingPathComponent(String($1)) }
    }
}
