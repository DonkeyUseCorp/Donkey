import Foundation

/// The file-understanding layer as a tool. `files.describe` turns a batch of files into structured
/// understanding (kind, summary, extracted text, attributes); the planner then composes the actual
/// operation from general primitives — `llm.generate` to decide names/labels/tags from the
/// understanding, `shell_exec` (`mv`, `sips`, `ffmpeg`) to apply it, `state.verify` to confirm.
///
/// The two file primitives are deliberately general, not per-operation. `files.describe` is the read
/// side (understanding content across modalities is hard); `files.write` is the write side (persisting
/// composed text to a path the planner controls). Both are hard primitives the planner composes from —
/// the inverse of each other. What stays OUT of the registry is the per-operation tool: a `files.rename`
/// or `files.suggest_names` would hardcode one ask, which is exactly the reasoning `files.describe` +
/// `llm.generate` + `shell_exec` already cover. "Write this text here" is not such an ask: there is no
/// other primitive for it, and without it the planner cannot persist multi-line content (a subtitle
/// file, a script, a note) at all.
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

    /// `files.write`: write text `content` to `path` (overwrite by default, or append), creating any
    /// missing parent directories. The write side of the file primitives — how the planner persists
    /// anything it composed when the content is multi-line or too long to inline in a shell command.
    static func filesWrite(
        _ context: HarnessToolExecutionContext,
        services: HarnessBuiltInToolServices
    ) async -> HarnessToolResult {
        func reject(_ message: String) -> HarnessToolResult {
            HarnessToolResult(
                callID: context.call.id,
                toolName: context.call.name,
                status: .invalidInput,
                summary: message,
                metadata: ["executor": "builtInGeneric", "reason": "invalidInput"]
            )
        }

        guard
            let rawPath = context.call.input["path"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawPath.isEmpty
        else {
            return reject("files.write requires a `path`.")
        }
        guard let content = context.call.input["content"] else {
            return reject("files.write requires `content` (an empty string is allowed).")
        }
        let mode = context.call.input["mode"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "overwrite"
        guard mode == "overwrite" || mode == "append" else {
            return reject("files.write `mode` must be \"overwrite\" or \"append\".")
        }
        let append = mode == "append"

        let url = Self.resolveWritePath(rawPath, in: context.worldModel)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let newData = Data(content.utf8)
            if append, let existing = try? Data(contentsOf: url) {
                try (existing + newData).write(to: url, options: .atomic)
            } else {
                try newData.write(to: url, options: .atomic)
            }
        } catch {
            return HarnessToolResult(
                callID: context.call.id,
                toolName: context.call.name,
                status: .failed,
                summary: "files.write failed: \(error.localizedDescription)",
                metadata: ["executor": "builtInGeneric", "reason": "writeFailed", "path": url.path]
            )
        }

        let bytes = content.utf8.count
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .succeeded,
            summary: "\(append ? "Appended" : "Wrote") \(bytes) byte(s) to \(url.path).",
            observations: HarnessObservationDelta(
                facts: [
                    "files.write.path": url.path,
                    "lastAcceptedTool": context.call.name
                ]
            ),
            metadata: [
                "executor": "builtInGeneric",
                // `filePath` is the canonical key the workspace tracker reads; `path` is kept for
                // existing callers that already consume it.
                "filePath": url.path,
                "path": url.path,
                "bytes": String(bytes),
                "mode": mode
            ]
        )
    }

    /// Resolve where `files.write` should write. A RELATIVE path resolves against the conversation
    /// workspace's current directory (the `workspace.baseDir` fact the runtime maintains) when one exists,
    /// which is how the planner keeps a task's files together by writing `report/chart.svg`. An absolute or
    /// `~`-prefixed path is normally honored exactly (a path the user named always wins) — with ONE
    /// exception: a write aimed directly at a SCATTER ROOT (the bare home root or the top of the user's
    /// Downloads/Desktop/Documents) is re-rooted into the workspace. The model reflexively drops an
    /// intermediate or output next to where it found an input (`~/fields.json`, `~/Downloads/out.pdf`), and
    /// none of those bare roots is where a careful user wants loose files, so this keeps the task's files in
    /// the one folder it owns. A genuinely user-named subfolder (`~/Documents/Taxes/2024`, a project dir) is
    /// left untouched. See `ConversationWorkspace.isScatterRoot`.
    static func resolveWritePath(_ rawPath: String, in worldModel: HarnessWorldModel) -> URL {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let workspace = (worldModel.facts[ConversationWorkspace.baseDirFactKey]).flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        }
        if expanded.hasPrefix("/") {
            let url = URL(fileURLWithPath: expanded).standardizedFileURL
            if let workspace, ConversationWorkspace.isScatterRoot(url.deletingLastPathComponent()) {
                return workspace.appendingPathComponent(url.lastPathComponent).standardizedFileURL
            }
            return url
        }
        // A relative path stays inside its base — the workspace folder when one exists, else home. Keep
        // only the non-traversal components so a stray `../../x` can't climb out of the workspace; subfolders
        // (`report/chart.svg`) still resolve normally.
        let base = workspace ?? FileManager.default.homeDirectoryForCurrentUser
        let safeComponents = expanded
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != ".." && $0 != "." }
        return safeComponents.reduce(base) { $0.appendingPathComponent(String($1)) }.standardizedFileURL
    }
}
