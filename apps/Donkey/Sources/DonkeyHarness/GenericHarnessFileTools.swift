import Foundation

/// The file-understanding layer as a tool. `files.describe` turns a batch of files into structured
/// understanding (kind, summary, extracted text, attributes); the planner then composes the actual
/// operation from general primitives — `llm.generate` to decide names/labels/tags from the
/// understanding, `shell_exec` (`mv`, `sips`, `ffmpeg`) to apply it, `state.verify` to confirm.
///
/// There is deliberately NO per-operation file tool. Understanding is a real primitive because reading
/// content across modalities is hard; the operation ("rename these", "resize those") is just the model
/// reasoning over that understanding, the same way it reasons about any other goal. A `files.rename`
/// or `files.suggest_names` tool would hardcode one ask into the registry — exactly what the planner's
/// general reasoning is supposed to replace.
public enum FileToolSupport {
    static let defaultMaxFiles = 50
    static let hardMaxFiles = 200

    /// The files to describe: an explicit `paths` list wins; otherwise the regular (non-hidden,
    /// non-dir) files directly inside `directory`, capped at `maxFiles`. Returns the URLs and whether
    /// the cap truncated the set.
    public static func resolveFiles(
        directory: String?,
        paths: [String],
        maxFiles: Int,
        fileManager: FileManager = .default
    ) -> (files: [URL], truncated: Bool) {
        var resolved: [URL] = []
        if !paths.isEmpty {
            resolved = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        } else if let directory, !directory.isEmpty {
            let dirURL = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
            let contents = (try? fileManager.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            resolved = contents
                .filter { url in
                    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        let cap = min(max(maxFiles, 1), hardMaxFiles)
        guard resolved.count > cap else { return (resolved, false) }
        return (Array(resolved.prefix(cap)), true)
    }
}

extension BuiltInHarnessToolExecutors {
    /// The understanding path behind `files.describe`: the runtime's `fileUnderstanding` hook (OCR for
    /// images, text for PDFs, …) gets first crack; otherwise the deterministic Foundation understanding.
    static func understanding(
        for url: URL,
        services: HarnessBuiltInToolServices
    ) async -> FileUnderstanding {
        if let hook = services.fileUnderstanding, let understood = await hook(url) {
            return understood
        }
        return FileUnderstandingEngine.foundationUnderstanding(for: url)
    }

    /// `files.describe`: resolve files and return one structured `FileUnderstanding` each so the planner
    /// can reason about what files contain before deciding any operation. Read-only sensing.
    static func filesDescribe(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        let directory = context.call.input["directory"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = (context.call.input["paths"])
            .map { $0.split { $0 == "\n" || $0 == "," }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
            ?? []
        guard (directory?.isEmpty == false) || !paths.isEmpty else {
            return HarnessToolResult(
                callID: context.call.id,
                toolName: context.call.name,
                status: .invalidInput,
                summary: "files.describe requires a `directory` or a `paths` list.",
                metadata: ["executor": "builtInGeneric", "reason": "invalidInput"]
            )
        }
        let maxFiles = context.call.input["maxFiles"].flatMap(Int.init) ?? FileToolSupport.defaultMaxFiles
        let (files, truncated) = FileToolSupport.resolveFiles(directory: directory, paths: paths, maxFiles: maxFiles)
        guard !files.isEmpty else {
            return HarnessToolResult(
                callID: context.call.id,
                toolName: context.call.name,
                status: .failed,
                summary: "No files found to describe.",
                metadata: ["executor": "builtInGeneric", "reason": "noFilesFound"]
            )
        }

        var understandings: [FileUnderstanding] = []
        for url in files {
            understandings.append(await understanding(for: url, services: services))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(understandings)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let preview = understandings.prefix(10)
            .map { "\($0.fileName): \($0.summary)" }
            .joined(separator: "\n")
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .succeeded,
            summary: truncated
                ? "Described \(understandings.count) file(s) (capped).\n\(preview)"
                : "Described \(understandings.count) file(s).\n\(preview)",
            observations: HarnessObservationDelta(
                facts: [
                    "files.describe.count": String(understandings.count),
                    "files.describe.truncated": String(truncated),
                    "lastAcceptedTool": context.call.name
                ]
            ),
            metadata: [
                "executor": "builtInGeneric",
                "understanding": json,
                "count": String(understandings.count),
                "truncated": String(truncated)
            ]
        )
    }
}
