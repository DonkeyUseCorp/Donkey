import DonkeyContracts
import Foundation
import Testing
@testable import DonkeyHarness
@testable import DonkeyRuntime

/// The pure workspace record: it tracks what was produced and where, and promotes to a folder when the
/// planner groups files — with no filesystem access or natural-language matching.
@Suite
struct ConversationWorkspaceStructTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func recordSeedsAnchorBaseFromFirstDeliverableParent() {
        var workspace = ConversationWorkspace()
        workspace.record(path: "/Users/x/Downloads/budget.xlsx", kind: "files.write", byteCount: 10, at: now)
        #expect(workspace.anchorBase == "/Users/x/Downloads")
        #expect(workspace.folderPath == nil)
        #expect(workspace.currentBaseDirectory == "/Users/x/Downloads")
        #expect(workspace.deliverables.count == 1)
    }

    @Test
    func recordDedupesRewritesOfSamePath() {
        var workspace = ConversationWorkspace()
        workspace.record(path: "/Users/x/Downloads/a.txt", kind: "files.write", byteCount: 1, at: now)
        workspace.record(path: "/Users/x/Downloads/a.txt", kind: "files.write", byteCount: 5, at: now)
        #expect(workspace.deliverables.count == 1)
        #expect(workspace.deliverables[0].byteCount == 5)
    }

    @Test
    func writingIntoSubfolderOfBasePromotesFolderPath() {
        var workspace = ConversationWorkspace()
        workspace.record(path: "/Users/x/Downloads/report.pdf", kind: "image_render", byteCount: nil, at: now)
        #expect(workspace.folderPath == nil)
        // Planner grouped output into a named subfolder of the base.
        workspace.record(path: "/Users/x/Downloads/quarterly/chart.png", kind: "image_render", byteCount: nil, at: now)
        #expect(workspace.folderPath == "/Users/x/Downloads/quarterly")
        #expect(workspace.currentBaseDirectory == "/Users/x/Downloads/quarterly")
    }

    @Test
    func deeplyNestedWriteAdoptsTopLevelProjectFolder() {
        var workspace = ConversationWorkspace()
        workspace.record(path: "/Users/x/Desktop/readme.md", kind: "files.write", byteCount: nil, at: now)
        workspace.record(path: "/Users/x/Desktop/CpuApp/Sources/App.swift", kind: "files.write", byteCount: nil, at: now)
        #expect(workspace.folderPath == "/Users/x/Desktop/CpuApp")
    }

    @Test
    func jsonRoundTrips() {
        var workspace = ConversationWorkspace()
        workspace.record(path: "/Users/x/Downloads/a.txt", kind: "files.write", byteCount: 3, at: now)
        workspace.record(path: "/Users/x/Downloads/proj/b.txt", kind: "files.write", byteCount: 4, at: now)
        let json = workspace.encodedJSON()
        #expect(json != nil)
        let decoded = ConversationWorkspace.decode(json)
        #expect(decoded == workspace)
    }

    @Test
    func plannerSummaryNamesWorkingDirectoryThenPromotedFolder() {
        var workspace = ConversationWorkspace()
        workspace.record(path: "/Users/x/Downloads/a.txt", kind: "files.write", byteCount: nil, at: now)
        // One loose file sits in the working directory — the summary names the folder to write into, not
        // "<none yet>", and lists the file.
        let working = workspace.plannerSummary()
        #expect(working.contains("put intermediate and output files"))
        #expect(!working.contains("<none yet>"))
        #expect(working.contains("a.txt"))

        workspace.record(path: "/Users/x/Downloads/proj/b.txt", kind: "files.write", byteCount: nil, at: now)
        let promoted = workspace.plannerSummary()
        #expect(promoted.contains("folder="))
        #expect(promoted.contains("proj"))
    }

    @Test
    func currentBaseDirectoryFallsBackToSeededRoot() {
        // Before any deliverable, the seeded working directory is the resolve base.
        let workspace = ConversationWorkspace(root: "/Users/x/Donkey/fill-out-f1120-ab12cd34")
        #expect(workspace.currentBaseDirectory == "/Users/x/Donkey/fill-out-f1120-ab12cd34")
        // A genuinely user-named location the planner wrote to (not a bare scatter root) wins over the root.
        var named = workspace
        named.record(path: "/Users/x/Documents/Taxes/2024/out.pdf", kind: "files.write", byteCount: nil, at: now)
        #expect(named.currentBaseDirectory == "/Users/x/Documents/Taxes/2024")
    }

    // Scatter-root detection keys on the real machine home, so these use it (production paths are
    // home-based too); `/Users/x` literals wouldn't register as scatter roots.
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    @Test
    func scatterRootDeliverableDoesNotClobberDedicatedRoot() {
        // A shell tool (yt-dlp/ffmpeg) writing its output straight into ~/Downloads must NOT migrate the
        // whole workspace there: the dedicated task folder stays the base, so later files group into it
        // instead of scattering loose in Downloads. This is the regression behind the `cd ~/Downloads && …`
        // run — a single scatter-root deliverable used to override `root`.
        let root = home + "/Donkey/clip-the-video-ab12cd34"
        var workspace = ConversationWorkspace(root: root)
        workspace.record(path: home + "/Downloads/clip.webm", kind: "shell_exec", byteCount: nil, at: now)
        #expect(workspace.currentBaseDirectory == root)
        #expect(workspace.plannerSummary().contains("clip-the-video-ab12cd34"))
        // But a real subfolder the planner grouped into is still honored — only the bare scatter root yields.
        workspace.record(path: home + "/Downloads/clip-project/out.mp4", kind: "shell_exec", byteCount: nil, at: now)
        #expect(workspace.currentBaseDirectory == home + "/Downloads/clip-project")
    }

    @Test
    func scatterRootDeliverableWithNoRootStillGroupsThere() {
        // With no dedicated root to fall back on (directory creation failed, or a pre-seeding conversation),
        // a Downloads deliverable still anchors there so the task's files at least stay together.
        var workspace = ConversationWorkspace()
        workspace.record(path: home + "/Downloads/clip.webm", kind: "shell_exec", byteCount: nil, at: now)
        #expect(workspace.currentBaseDirectory == home + "/Downloads")
    }

    @Test
    func defaultRootPathSlugsTheGoalUnderTheWorkspaceParent() {
        let path = ConversationWorkspace.defaultRootPath(
            goal: "Fill out the f1120.pdf form!", conversationID: "AB12CD34-9999"
        )
        let parent = ConversationWorkspace.workspaceParentDirectory().path
        #expect(path.hasPrefix(parent + "/"))
        let name = (path as NSString).lastPathComponent
        #expect(name == "fill-out-the-f1120-pdf-form-ab12cd34")
    }

    @Test
    func defaultRootPathHonorsSuggestedFolderName() {
        let path = ConversationWorkspace.defaultRootPath(
            goal: "Fill out the f1120.pdf form!",
            conversationID: "AB12CD34-9999",
            suggestedFolderName: "Fill out f1120 Cozy"
        )
        let parent = ConversationWorkspace.workspaceParentDirectory().path
        #expect(path.hasPrefix(parent + "/"))
        let name = (path as NSString).lastPathComponent
        #expect(name == "Fill out f1120 Cozy")
    }

    @Test
    func defaultRootPathSanitizesSuggestedFolderName() {
        let path = ConversationWorkspace.defaultRootPath(
            goal: "Fill out the f1120.pdf form!",
            conversationID: "AB12CD34-9999",
            suggestedFolderName: "Fill / out: f1120\0 Cozy"
        )
        let name = (path as NSString).lastPathComponent
        #expect(name == "Fill - out- f1120 Cozy")
    }

    @Test
    func slugSanitizesAndBounds() {
        #expect(ConversationWorkspace.slug("Hello, World! 2025") == "hello-world-2025")
        #expect(ConversationWorkspace.slug("   ") == "")
        #expect(ConversationWorkspace.slug(String(repeating: "a", count: 100)).count <= 40)
    }

    @Test
    func isScatterRootMatchesSharedRootsNotNamedSubfolders() {
        let home = URL(fileURLWithPath: "/Users/x", isDirectory: true)
        #expect(ConversationWorkspace.isScatterRoot(home, home: home))
        for name in ["Downloads", "Desktop", "Documents"] {
            #expect(ConversationWorkspace.isScatterRoot(URL(fileURLWithPath: "/Users/x/\(name)"), home: home))
        }
        // A named subfolder, a different top-level folder, and a nested path are NOT scatter roots.
        #expect(!ConversationWorkspace.isScatterRoot(URL(fileURLWithPath: "/Users/x/Downloads/proj"), home: home))
        #expect(!ConversationWorkspace.isScatterRoot(URL(fileURLWithPath: "/Users/x/Donkey/task"), home: home))
        #expect(!ConversationWorkspace.isScatterRoot(URL(fileURLWithPath: "/Users/x/Documents/Taxes/2024"), home: home))
    }

    @Test
    func preferredParentDefaultsToDownloadsAndHonorsUserChoice() {
        let home = URL(fileURLWithPath: "/Users/x", isDirectory: true)
        let suite = UserDefaults(suiteName: "donkey-ws-\(UUID().uuidString)")!
        defer { suite.removeObject(forKey: ConversationWorkspace.outputLocationDefaultsKey) }
        // Unset → the default, Downloads.
        #expect(ConversationWorkspace.preferredParentDirectory(defaults: suite, home: home).path == "/Users/x/Downloads")
        suite.set("desktop", forKey: ConversationWorkspace.outputLocationDefaultsKey)
        #expect(ConversationWorkspace.preferredParentDirectory(defaults: suite, home: home).path == "/Users/x/Desktop")
        suite.set("documents", forKey: ConversationWorkspace.outputLocationDefaultsKey)
        #expect(ConversationWorkspace.preferredParentDirectory(defaults: suite, home: home).path == "/Users/x/Documents")
        // A custom absolute path is honored verbatim.
        suite.set("/Volumes/Work/out", forKey: ConversationWorkspace.outputLocationDefaultsKey)
        #expect(ConversationWorkspace.preferredParentDirectory(defaults: suite, home: home).path == "/Volumes/Work/out")
        // An unrecognized non-absolute token falls back to the default.
        suite.set("somewhere", forKey: ConversationWorkspace.outputLocationDefaultsKey)
        #expect(ConversationWorkspace.preferredParentDirectory(defaults: suite, home: home).path == "/Users/x/Downloads")
    }
}

/// The `workspace.files` fact: small working-directory text files are inlined so the planner never
/// re-reads them; binaries and large dumps are left out.
@Suite
struct KnownFileContentsFactTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("donkey-files-fact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test
    func inlinesSmallTextAndSkipsBinaryAndLarge() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "Business name: Blue Harbor Logistics Inc.\nEIN: 47-3829156".write(
            to: dir.appendingPathComponent("1120data.txt"), atomically: true, encoding: .utf8
        )
        // A binary file (NUL bytes) must be skipped by the content sniff, not by extension.
        try Data([0x25, 0x50, 0x44, 0x46, 0x00, 0x01, 0x02]).write(to: dir.appendingPathComponent("f1120.pdf"))
        // An oversized text file (a field dump) must be skipped so it never bloats the prompt.
        try String(repeating: "x", count: 20_000).write(
            to: dir.appendingPathComponent("fields.json"), atomically: true, encoding: .utf8
        )

        var cache: [String: (mtime: Date, content: String)] = [:]
        let block = HarnessAgentCoordinator.knownFileContentsBlock(workingDirectory: dir.path, cache: &cache)

        let text = try #require(block)
        #expect(text.contains("Blue Harbor Logistics"))
        #expect(text.contains("1120data.txt"))
        #expect(text.contains("do not re-open"))
        #expect(!text.contains("f1120.pdf"))   // binary skipped
        #expect(!text.contains("fields.json")) // oversized skipped
    }

    @Test
    func emptyDirectoryProducesNoFact() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var cache: [String: (mtime: Date, content: String)] = [:]
        #expect(HarnessAgentCoordinator.knownFileContentsBlock(workingDirectory: dir.path, cache: &cache) == nil)
    }

    /// A `-o`/`--output` file the command actually wrote is a deliverable; a `>`-redirect scratch dump is
    /// not. This distinction is what lets the runtime tell "produced the result" from "only scouted".
    @Test
    func explicitOutputFileDetectsDeliverableNotScratch() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "filled".write(to: dir.appendingPathComponent("out.pdf"), atomically: true, encoding: .utf8)
        try "filled".write(to: dir.appendingPathComponent("out2.pdf"), atomically: true, encoding: .utf8)
        try "filled".write(to: dir.appendingPathComponent("tax return.pdf"), atomically: true, encoding: .utf8)
        try "page view".write(to: dir.appendingPathComponent("page0.txt"), atomically: true, encoding: .utf8)

        // `-o out.pdf` → the produced output file (resolved against the working directory).
        #expect(
            DonkeyCommandBackends.explicitOutputFile(
                command: "pdf-fill set f1120.pdf --data map.json -o out.pdf", workingDirectory: dir.path
            ) == dir.appendingPathComponent("out.pdf").path
        )
        // A quoted path with a space is ONE token (whitespace tokenizing must honor the quotes).
        #expect(
            DonkeyCommandBackends.explicitOutputFile(
                command: "pdf-fill set f1120.pdf -o 'tax return.pdf'", workingDirectory: dir.path
            ) == dir.appendingPathComponent("tax return.pdf").path
        )
        // The equals-attached long-option form (`--output=out2.pdf`).
        #expect(
            DonkeyCommandBackends.explicitOutputFile(
                command: "pdf-fill set f1120.pdf --output=out2.pdf", workingDirectory: dir.path
            ) == dir.appendingPathComponent("out2.pdf").path
        )
        // A `>`-redirect scratch dump has no output flag — not a deliverable.
        #expect(
            DonkeyCommandBackends.explicitOutputFile(
                command: "pdf-fill form f1120.pdf --page 0 > page0.txt", workingDirectory: dir.path
            ) == nil
        )
        // A `-o` whose file was not actually written returns nil (nothing produced).
        #expect(
            DonkeyCommandBackends.explicitOutputFile(
                command: "pdf-fill set f1120.pdf --data map.json -o missing.pdf", workingDirectory: dir.path
            ) == nil
        )
        // Tools that overload `-o` for something other than output: even though `out.pdf` exists, grep's
        // only-matching and sort's in-place `-o` must not register it as a freshly produced deliverable.
        #expect(
            DonkeyCommandBackends.explicitOutputFile(
                command: "grep -o out.pdf data.txt", workingDirectory: dir.path
            ) == nil
        )
        #expect(
            DonkeyCommandBackends.explicitOutputFile(
                command: "sort -o out.pdf data.txt", workingDirectory: dir.path
            ) == nil
        )
    }

    /// The small INPUT data must survive even when the agent has just written several larger scratch dumps.
    /// Newest-first selection let those fresh dumps eat the budget and evict the data file, so the planner
    /// re-read the data every step; smallest-first keeps the data pinned. This locks that fix.
    @Test
    func smallInputSurvivesLargerNewerScratchDumps() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = Date(timeIntervalSince1970: 1_000)
        // The small data file, copied in first (oldest).
        let data = dir.appendingPathComponent("1120data.txt")
        try "Business name: Blue Harbor Logistics Inc.\nEIN: 47-3829156".write(to: data, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: data.path)
        // Several larger scratch files the agent wrote afterward (newer, each near the per-file cap).
        for (index, name) in ["form_view.txt", "page0.txt", "page1.txt", "page2.txt"].enumerated() {
            let url = dir.appendingPathComponent(name)
            try String(repeating: "y", count: 1_800).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: old.addingTimeInterval(Double(index + 1) * 60)], ofItemAtPath: url.path
            )
        }

        var cache: [String: (mtime: Date, content: String)] = [:]
        let text = try #require(HarnessAgentCoordinator.knownFileContentsBlock(workingDirectory: dir.path, cache: &cache))
        #expect(text.contains("1120data.txt"))
        #expect(text.contains("Blue Harbor Logistics"))
    }
}

/// `files.write` path resolution: relative paths anchor to the workspace, explicit paths are honored.
@Suite
struct FilesWritePathResolutionTests {
    private func worldModel(baseDir: String?) -> HarnessWorldModel {
        var model = HarnessWorldModel()
        if let baseDir { model.facts[ConversationWorkspace.baseDirFactKey] = baseDir }
        return model
    }

    @Test
    func relativePathResolvesUnderWorkspaceBase() {
        let url = BuiltInHarnessToolExecutors.resolveWritePath(
            "report/chart.svg",
            in: worldModel(baseDir: "/Users/x/Downloads/proj")
        )
        #expect(url.path == "/Users/x/Downloads/proj/report/chart.svg")
    }

    @Test
    func absolutePathIsHonoredExactlyIgnoringBase() {
        let url = BuiltInHarnessToolExecutors.resolveWritePath(
            "/Users/x/Desktop/out.txt",
            in: worldModel(baseDir: "/Users/x/Downloads/proj")
        )
        #expect(url.path == "/Users/x/Desktop/out.txt")
    }

    @Test
    func tildeDesktopRootWriteIsReRootedIntoWorkspace() {
        // A bare ~/Desktop write is a scatter root → grouped into the task folder, not left loose on Desktop.
        let url = BuiltInHarnessToolExecutors.resolveWritePath(
            "~/Desktop/out.txt",
            in: worldModel(baseDir: "/Users/x/Downloads/proj")
        )
        #expect(url.path == "/Users/x/Downloads/proj/out.txt")
    }

    @Test
    func relativePathWithNoWorkspaceFallsBackToHome() {
        let url = BuiltInHarnessToolExecutors.resolveWritePath("notes.txt", in: worldModel(baseDir: nil))
        #expect(url.path == NSHomeDirectory() + "/notes.txt")
    }

    @Test
    func relativeTraversalCannotEscapeWorkspaceBase() {
        let url = BuiltInHarnessToolExecutors.resolveWritePath(
            "../../secret/notes.md",
            in: worldModel(baseDir: "/Users/x/Downloads/proj")
        )
        #expect(url.path == "/Users/x/Downloads/proj/secret/notes.md")
    }

    @Test
    func absoluteHomeRootWriteIsReRootedIntoWorkspace() {
        // The model reflexively writes an intermediate next to where it found an input (`~/fields.json`).
        // With a workspace, that bare-home-root write is re-rooted into the working directory.
        let home = NSHomeDirectory()
        let url = BuiltInHarnessToolExecutors.resolveWritePath(
            home + "/fields.json",
            in: worldModel(baseDir: "/Users/x/Donkey/task")
        )
        #expect(url.path == "/Users/x/Donkey/task/fields.json")
    }

    @Test
    func absoluteHomeRootWriteWithoutWorkspaceIsHonored() {
        // No working directory to re-root into → the path is left exactly as given.
        let home = NSHomeDirectory()
        let url = BuiltInHarnessToolExecutors.resolveWritePath(home + "/fields.json", in: worldModel(baseDir: nil))
        #expect(url.path == home + "/fields.json")
    }

    @Test
    func absoluteDownloadsRootWriteIsReRootedIntoWorkspace() {
        // The model reflexively drops output in ~/Downloads; with a workspace, that scatter-root write is
        // grouped into the task folder instead of left loose in Downloads.
        let home = NSHomeDirectory()
        let url = BuiltInHarnessToolExecutors.resolveWritePath(
            home + "/Downloads/out.pdf",
            in: worldModel(baseDir: "/Users/x/Donkey/task")
        )
        #expect(url.path == "/Users/x/Donkey/task/out.pdf")
    }

    @Test
    func absoluteUserNamedSubfolderIsHonored() {
        // A genuinely user-named subfolder (not a bare scatter root) is left exactly where it was aimed.
        let home = NSHomeDirectory()
        let url = BuiltInHarnessToolExecutors.resolveWritePath(
            home + "/Documents/Taxes/out.pdf",
            in: worldModel(baseDir: "/Users/x/Donkey/task")
        )
        #expect(url.path == home + "/Documents/Taxes/out.pdf")
    }
}

/// The runtime capture + projection: a succeeded file-producing step is recorded into the conversation
/// workspace and surfaced as world-model facts.
@Suite
struct ConversationWorkspaceCoordinatorTests {
    private func succeeded(tool: String, metadata: [String: String]) -> HarnessToolResult {
        HarnessToolResult(callID: "c1", toolName: tool, status: .succeeded, summary: "ok", metadata: metadata)
    }

    @Test
    func recordToolResultCapturesProducedFileAndRefreshSurfacesFacts() async {
        let store = InMemoryHarnessConversationStore()
        let coordinator = HarnessAgentCoordinator(conversationStore: store)
        let agent = await coordinator.createAgent(conversationID: "conv-1", goal: "make a file")

        _ = await coordinator.recordToolResult(
            agentID: agent.id,
            call: HarnessToolCall(name: "files.write"),
            result: succeeded(tool: "files.write", metadata: ["filePath": "/Users/x/Downloads/a.txt", "bytes": "12"])
        )

        let workspace = await coordinator.conversationWorkspace(conversationID: "conv-1")
        #expect(workspace?.deliverables.count == 1)
        #expect(workspace?.anchorBase == "/Users/x/Downloads")

        await coordinator.refreshWorkspaceFact(agentID: agent.id)
        let refreshed = await coordinator.agent(id: agent.id)
        #expect(refreshed?.worldModel.facts[ConversationWorkspace.summaryFactKey]?.contains("a.txt") == true)
        #expect(refreshed?.worldModel.facts[ConversationWorkspace.baseDirFactKey] == "/Users/x/Downloads")
    }

    @Test
    func failedResultIsNotRecorded() async {
        let store = InMemoryHarnessConversationStore()
        let coordinator = HarnessAgentCoordinator(conversationStore: store)
        let agent = await coordinator.createAgent(conversationID: "conv-2", goal: "x")

        let failed = HarnessToolResult(
            callID: "c1", toolName: "files.write", status: .failed, summary: "nope",
            metadata: ["path": "/Users/x/Downloads/a.txt"]
        )
        _ = await coordinator.recordToolResult(agentID: agent.id, call: HarnessToolCall(name: "files.write"), result: failed)
        let workspace = await coordinator.conversationWorkspace(conversationID: "conv-2")
        #expect(workspace == nil)
    }

    @Test
    func secondDeliverableAppendsAcrossCalls() async {
        let store = InMemoryHarnessConversationStore()
        let coordinator = HarnessAgentCoordinator(conversationStore: store)
        let agent = await coordinator.createAgent(conversationID: "conv-3", goal: "x")

        _ = await coordinator.recordToolResult(
            agentID: agent.id, call: HarnessToolCall(name: "files.write"),
            result: succeeded(tool: "files.write", metadata: ["filePath": "/Users/x/Downloads/a.txt"])
        )
        _ = await coordinator.recordToolResult(
            agentID: agent.id, call: HarnessToolCall(name: "image_render"),
            result: succeeded(tool: "image_render", metadata: ["filePath": "/Users/x/Downloads/proj/chart.png"])
        )
        let workspace = await coordinator.conversationWorkspace(conversationID: "conv-3")
        #expect(workspace?.deliverables.count == 2)
        #expect(workspace?.folderPath == "/Users/x/Downloads/proj")
    }

    @Test
    func intermediateScratchUnderTempDirIsSkipped() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("donkey-llm-x.txt").path
        let result = HarnessToolResult(
            callID: "c1", toolName: "llm.generate", status: .succeeded, summary: "ok",
            metadata: ["filePath": tmp]
        )
        #expect(HarnessAgentCoordinator.producedFilePaths(from: result).isEmpty)
    }

    @Test
    func newlineJoinedPathsAreEachCaptured() {
        let result = HarnessToolResult(
            callID: "c1", toolName: "image.generate", status: .succeeded, summary: "ok",
            metadata: ["paths": "/Users/x/Downloads/one.png\n/Users/x/Downloads/two.png"]
        )
        let produced = HarnessAgentCoordinator.producedFilePaths(from: result)
        #expect(produced.map(\.path) == ["/Users/x/Downloads/one.png", "/Users/x/Downloads/two.png"])
    }
}

/// The eval fixture's workspace seed (used to model a follow-up turn) builds the same record shape the
/// runtime would, expanding home-relative paths.
@Suite
struct HarnessEvalWorkspaceSeedTests {
    @Test
    func singleFileSeedStaysLoose() {
        let seed = HarnessEvalWorkspaceSeed(files: [.init(path: "~/Downloads/poster.png", kind: "image_render")])
        let workspace = seed.build()
        #expect(workspace?.folderPath == nil)
        #expect(workspace?.anchorBase == NSHomeDirectory() + "/Downloads")
        #expect(workspace?.deliverables.count == 1)
    }

    @Test
    func emptySeedBuildsNil() {
        #expect(HarnessEvalWorkspaceSeed(files: nil).build() == nil)
        #expect(HarnessEvalWorkspaceSeed(files: []).build() == nil)
    }
}

/// The no-consent capture/render tools resolve their destination through the same workspace-aware rule.
@Suite
struct CommandBackendDestinationTests {
    @Test
    func relativeDestinationResolvesUnderBase() {
        let url = DonkeyCommandBackends.resolveOutputDestination(
            "charts/q3.png", baseDir: "/Users/x/Downloads/report", format: "png", defaultName: "image"
        )
        #expect(url.path == "/Users/x/Downloads/report/charts/q3.png")
    }

    @Test
    func absoluteDestinationIsReRootedUnderBase() {
        // No-consent tool: an absolute destination is confined under base, never honored as-is.
        let url = DonkeyCommandBackends.resolveOutputDestination(
            "/Users/x/Desktop/out.pdf", baseDir: "/Users/x/Downloads/report", format: "pdf", defaultName: "image"
        )
        #expect(url.path == "/Users/x/Downloads/report/Users/x/Desktop/out.pdf")
    }

    @Test
    func traversalDestinationCannotEscapeBase() {
        let url = DonkeyCommandBackends.resolveOutputDestination(
            "../../../../etc/cron.d/evil", baseDir: "/Users/x/Downloads/report", format: "png", defaultName: "image"
        )
        #expect(url.path == "/Users/x/Downloads/report/etc/cron.d/evil.png")
    }

    @Test
    func nilDestinationUsesBaseAndDefaultName() {
        let url = DonkeyCommandBackends.resolveOutputDestination(
            nil, baseDir: "/Users/x/Downloads/report", format: "png", defaultName: "image"
        )
        #expect(url.path == "/Users/x/Downloads/report/image.png")
    }

    @Test
    func nilDestinationAndNoBaseFallsBackToDownloads() {
        let url = DonkeyCommandBackends.resolveOutputDestination(
            nil, baseDir: nil, format: "png", defaultName: "page"
        )
        #expect(url.path == NSHomeDirectory() + "/Downloads/page.png")
    }

    @Test
    func extensionlessDestinationGetsFormatExtension() {
        let url = DonkeyCommandBackends.resolveOutputDestination(
            "summary", baseDir: "/Users/x/Downloads", format: "pdf", defaultName: "image"
        )
        #expect(url.path == "/Users/x/Downloads/summary.pdf")
    }
}
