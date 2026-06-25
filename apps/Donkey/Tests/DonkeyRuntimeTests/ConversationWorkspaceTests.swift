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
    func plannerSummaryReflectsLooseThenPromoted() {
        var workspace = ConversationWorkspace()
        workspace.record(path: "/Users/x/Downloads/a.txt", kind: "files.write", byteCount: nil, at: now)
        let loose = workspace.plannerSummary()
        #expect(loose.contains("none yet"))
        #expect(loose.contains("a.txt"))

        workspace.record(path: "/Users/x/Downloads/proj/b.txt", kind: "files.write", byteCount: nil, at: now)
        let promoted = workspace.plannerSummary()
        #expect(promoted.contains("folder="))
        #expect(promoted.contains("proj"))
        #expect(!promoted.contains("none yet"))
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
    func tildePathExpandsToHomeIgnoringBase() {
        let url = BuiltInHarnessToolExecutors.resolveWritePath(
            "~/Desktop/out.txt",
            in: worldModel(baseDir: "/Users/x/Downloads/proj")
        )
        #expect(url.path == NSHomeDirectory() + "/Desktop/out.txt")
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
