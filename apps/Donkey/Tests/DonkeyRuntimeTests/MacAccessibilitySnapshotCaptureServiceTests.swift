import DonkeyContracts
@testable import DonkeyRuntime
import Foundation
import Testing

@Suite
struct MacAccessibilitySnapshotCaptureServiceTests {
    @Test
    func snapshotTreeBuilderBoundsChildrenDepthTotalNodesAndRedactsLongText() {
        let longText = "abcdefghijklmnopqrstuvwxyz"
        let rawTree = RawMacAccessibilitySnapshotNode(
            role: "AXWindow",
            title: " Main Window ",
            valueSummary: longText,
            children: [
                RawMacAccessibilitySnapshotNode(
                    role: "AXButton",
                    title: "First",
                    children: [
                        RawMacAccessibilitySnapshotNode(role: "AXStaticText", title: "Grandchild")
                    ]
                ),
                RawMacAccessibilitySnapshotNode(role: "AXButton", title: "Second"),
                RawMacAccessibilitySnapshotNode(role: "AXButton", title: "Third")
            ]
        )

        let tree = MacAccessibilitySnapshotTreeBuilder.build(
            root: rawTree,
            limits: MacAccessibilitySnapshotLimits(
                maxDepth: 1,
                maxChildrenPerNode: 2,
                maxTotalNodes: 3,
                maxTextLength: 8
            )
        )

        #expect(tree.root.nodeID == "ax-1")
        #expect(tree.root.title == "[redacted length=11]")
        #expect(tree.root.valueSummary == "[redacted length=26]")
        #expect(tree.root.children.map(\.nodeID) == ["ax-1.1", "ax-1.2"])
        #expect(tree.root.children.map(\.title) == ["First", "Second"])
        #expect(tree.root.isChildrenTruncated)
        #expect(tree.root.children.first?.isChildrenTruncated == true)
        #expect(tree.totalNodeCount == 3)
        #expect(tree.isTreeTruncated)
    }

    @Test
    func snapshotContractsRoundTripThroughJSON() throws {
        let snapshot = MacAccessibilitySnapshot(
            target: targetCandidate(windowID: 42, processID: 9001, appName: "Notes"),
            limits: MacAccessibilitySnapshotLimits(maxDepth: 1),
            root: MacAccessibilitySnapshotNode(
                nodeID: "ax-1",
                role: "AXWindow",
                title: "Project",
                actions: ["AXPress"]
            ),
            totalNodeCount: 1,
            isTreeTruncated: false
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(
            MacAccessibilitySnapshot.self,
            from: data
        )

        #expect(decoded == snapshot)
    }

    @Test
    func trustedCaptureWritesJsonAndRecordsArtifactMetadata() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try LocalRunArtifactStore(baseDirectory: root)
        _ = try await store.prepareRun(
            session: RunSession(id: "run-ax", userGoal: "capture", targetID: "target-1"),
            traceID: "trace-ax"
        )
        let capturer = FakeMacAccessibilitySnapshotCapturer(
            tree: MacAccessibilitySnapshotTreeBuilder.build(
                root: RawMacAccessibilitySnapshotNode(
                    role: "AXWindow",
                    title: "Plan",
                    frame: WindowTargetBounds(x: 0, y: 0, width: 100, height: 100),
                    isEnabled: true,
                    isFocused: true,
                    actions: ["AXRaise"],
                    children: [
                        RawMacAccessibilitySnapshotNode(role: "AXButton", title: "OK")
                    ]
                ),
                limits: .default
            )
        )
        let service = makeService(
            store: store,
            windows: [
                fixtureWindow(windowID: 10, processID: 100, appName: "Notes", title: "Plan")
            ],
            frontmostProcessID: 100,
            capturer: capturer
        )

        let outcome = try await service.captureSnapshot(
            runID: "run-ax",
            artifactID: "accessibility-1"
        )

        guard case .captured(let result) = outcome else {
            Issue.record("Expected captured outcome")
            return
        }

        #expect(result.target.windowID == 10)
        #expect(result.artifact.relativePath == "accessibility/accessibility-1.json")
        #expect(result.artifact.kind == .accessibilitySnapshot)
        #expect(result.artifact.contentType == "application/json")
        #expect(result.snapshot.root.role == "AXWindow")
        #expect(result.snapshot.root.children.first?.title == "OK")
        #expect(capturer.capturedWindowIDs == [10])

        let fileURL = root
            .appendingPathComponent("run-ax", isDirectory: true)
            .appendingPathComponent("accessibility/accessibility-1.json")
        let storedSnapshot = try JSONDecoder().decode(
            MacAccessibilitySnapshot.self,
            from: Data(contentsOf: fileURL)
        )
        #expect(storedSnapshot == result.snapshot)

        let summary = try await store.summary(runID: "run-ax")
        #expect(summary.artifacts.count == 1)
        #expect(summary.artifacts.first?.metadata["runID"] == "run-ax")
        #expect(summary.artifacts.first?.metadata["traceID"] == "trace-ax")
        #expect(summary.artifacts.first?.metadata["target.windowID"] == "10")
        #expect(summary.artifacts.first?.metadata["target.appName"] == "Notes")
        #expect(summary.artifacts.first?.metadata["accessibility.trustStatus"] == "trusted")
        #expect(summary.artifacts.first?.metadata["accessibility.nodeCount"] == "2")
        #expect(summary.eventCount == 0)
    }

    @Test
    func explicitWindowSelectionIsPassedToAccessibilityCapturer() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try LocalRunArtifactStore(baseDirectory: root)
        _ = try await store.prepareRun(
            session: RunSession(id: "run-ax-explicit", userGoal: "capture", targetID: "target-1"),
            traceID: "trace-ax-explicit"
        )
        let capturer = FakeMacAccessibilitySnapshotCapturer()
        let service = makeService(
            store: store,
            windows: [
                fixtureWindow(windowID: 1, processID: 100, appName: "Terminal"),
                fixtureWindow(windowID: 2, processID: 200, appName: "Safari")
            ],
            frontmostProcessID: 100,
            capturer: capturer
        )

        let outcome = try await service.captureSnapshot(
            runID: "run-ax-explicit",
            selection: MacWindowSelectionRequest(windowID: 2),
            artifactID: "accessibility-explicit"
        )

        guard case .captured(let result) = outcome else {
            Issue.record("Expected captured outcome")
            return
        }
        #expect(result.target.windowID == 2)
        #expect(capturer.capturedWindowIDs == [2])
    }

    @Test
    func missingAccessibilityTrustAppendsPartialRunEventAndNoArtifact() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try LocalRunArtifactStore(baseDirectory: root)
        _ = try await store.prepareRun(
            session: RunSession(id: "run-ax-denied", userGoal: "capture", targetID: "target-1"),
            traceID: "trace-ax-denied"
        )
        let capturer = FakeMacAccessibilitySnapshotCapturer(trustStatus: .notTrusted)
        let service = makeService(
            store: store,
            windows: [
                fixtureWindow(windowID: 10, processID: 100, appName: "Notes")
            ],
            frontmostProcessID: 100,
            capturer: capturer
        )

        let outcome = try await service.captureSnapshot(
            runID: "run-ax-denied",
            artifactID: "accessibility-denied"
        )

        guard case .permissionDenied(let result) = outcome else {
            Issue.record("Expected permission denied outcome")
            return
        }

        #expect(result.target.windowID == 10)
        #expect(result.eventRecord.runID == "run-ax-denied")
        #expect(result.eventRecord.traceID == "trace-ax-denied")
        #expect(result.eventRecord.event.sequence == 1)
        #expect(result.eventRecord.event.stream == .tool)
        #expect(result.eventRecord.event.summary == "Accessibility permission is not granted")
        #expect(result.eventRecord.event.metadata["target.windowID"] == "10")
        #expect(capturer.capturedWindowIDs.isEmpty)

        guard case .tool(let payload) = result.eventRecord.event.payload else {
            Issue.record("Expected tool event payload")
            return
        }
        #expect(payload.capability == .accessibility)
        #expect(!payload.decision.isAllowed)
        #expect(payload.toolName == "mac-accessibility-snapshot")

        let summary = try await store.summary(runID: "run-ax-denied")
        #expect(summary.eventCount == 1)
        #expect(summary.artifacts.isEmpty)
        #expect(!fileExists(root
            .appendingPathComponent("run-ax-denied", isDirectory: true)
            .appendingPathComponent("accessibility/accessibility-denied.json")))

        let records = try jsonlRecords(from: root
            .appendingPathComponent("run-ax-denied", isDirectory: true)
            .appendingPathComponent("events.jsonl"))
        #expect(records.map(\.event.sequence) == [1])
    }

    @Test
    func unsafeTargetRefusesBeforeTrustCheckOrCapture() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try LocalRunArtifactStore(baseDirectory: root)
        _ = try await store.prepareRun(
            session: RunSession(id: "run-ax-unsafe", userGoal: "capture", targetID: "target-1"),
            traceID: "trace-ax-unsafe"
        )
        let capturer = FakeMacAccessibilitySnapshotCapturer()
        let service = makeService(
            store: store,
            windows: [
                fixtureWindow(windowID: 10, processID: 100, appName: "Safari", title: "Checkout Payment")
            ],
            frontmostProcessID: 100,
            capturer: capturer
        )

        do {
            _ = try await service.captureSnapshot(
                runID: "run-ax-unsafe",
                artifactID: "accessibility-unsafe"
            )
            Issue.record("Expected unsafe target to be refused")
        } catch MacAccessibilitySnapshotCaptureError.unsafeTarget(let windowID, let status) {
            #expect(windowID == 10)
            #expect(status == .blocked)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let summary = try await store.summary(runID: "run-ax-unsafe")
        #expect(summary.eventCount == 0)
        #expect(summary.artifacts.isEmpty)
        #expect(capturer.capturedWindowIDs.isEmpty)
    }

    @Test
    func missingPreparedRunFailsWithoutWritingFile() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try LocalRunArtifactStore(baseDirectory: root)
        let capturer = FakeMacAccessibilitySnapshotCapturer()
        let service = makeService(
            store: store,
            windows: [
                fixtureWindow(windowID: 10, processID: 100, appName: "Notes")
            ],
            frontmostProcessID: 100,
            capturer: capturer
        )

        do {
            _ = try await service.captureSnapshot(
                runID: "missing-run",
                artifactID: "accessibility-missing"
            )
            Issue.record("Expected missing prepared run to fail")
        } catch MacAccessibilitySnapshotCaptureError.missingPreparedRun(let runID) {
            #expect(runID == "missing-run")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(capturer.capturedWindowIDs.isEmpty)
        #expect(!fileExists(root
            .appendingPathComponent("missing-run", isDirectory: true)
            .appendingPathComponent("accessibility/accessibility-missing.json")))
    }

    @Test
    func adapterCaptureFailureCreatesNoArtifactRecord() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try LocalRunArtifactStore(baseDirectory: root)
        _ = try await store.prepareRun(
            session: RunSession(id: "run-ax-failure", userGoal: "capture", targetID: "target-1"),
            traceID: "trace-ax-failure"
        )
        let capturer = FakeMacAccessibilitySnapshotCapturer(
            error: FixtureAccessibilityError.failed
        )
        let service = makeService(
            store: store,
            windows: [
                fixtureWindow(windowID: 10, processID: 100, appName: "Notes")
            ],
            frontmostProcessID: 100,
            capturer: capturer
        )

        do {
            _ = try await service.captureSnapshot(
                runID: "run-ax-failure",
                artifactID: "accessibility-failure"
            )
            Issue.record("Expected capture failure")
        } catch MacAccessibilitySnapshotCaptureError.captureFailed(let windowID, let reason) {
            #expect(windowID == 10)
            #expect(reason.contains("failed"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let summary = try await store.summary(runID: "run-ax-failure")
        #expect(summary.artifacts.isEmpty)
        #expect(capturer.capturedWindowIDs == [10])
    }

    private func makeService(
        store: LocalRunArtifactStore,
        windows: [MacWindowProviderWindow],
        frontmostProcessID: Int32? = nil,
        focusedWindowID: UInt32? = nil,
        capturer: FakeMacAccessibilitySnapshotCapturer
    ) -> MacAccessibilitySnapshotCaptureService {
        MacAccessibilitySnapshotCaptureService(
            artifactStore: store,
            windowResolver: MacWindowResolver(
                provider: FixtureWindowProvider(
                    windows: windows,
                    frontmostProcessID: frontmostProcessID,
                    focusedWindowID: focusedWindowID
                )
            ),
            capturer: capturer
        )
    }

    private func fixtureWindow(
        windowID: UInt32,
        processID: Int32,
        appName: String? = nil,
        bundleIdentifier: String? = nil,
        title: String? = nil,
        bounds: WindowTargetBounds = WindowTargetBounds(
            x: 0,
            y: 0,
            width: 100,
            height: 100
        )
    ) -> MacWindowProviderWindow {
        MacWindowProviderWindow(
            windowID: windowID,
            processID: processID,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            title: title,
            bounds: bounds
        )
    }

    private func targetCandidate(
        windowID: UInt32,
        processID: Int32,
        appName: String
    ) -> MacWindowTargetCandidate {
        MacWindowTargetCandidate(
            windowID: windowID,
            processID: processID,
            appName: appName,
            bounds: WindowTargetBounds(x: 0, y: 0, width: 100, height: 100),
            isVisible: true,
            isOnScreen: true,
            isFrontmost: true,
            isFocused: true,
            isIPhoneMirroring: false,
            safetyAssessment: WindowTargetSafetyAssessment(
                status: .allowed,
                summary: "No sensitive surface indicators detected"
            )
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "DonkeyAccessibilitySnapshotTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func fileExists(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        )
        return exists && !isDirectory.boolValue
    }

    private func jsonlRecords(from url: URL) throws -> [RunTraceEventRecord] {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        return try text
            .split(separator: "\n")
            .map { line in
                try JSONDecoder().decode(
                    RunTraceEventRecord.self,
                    from: Data(line.utf8)
                )
            }
    }
}

private final class FakeMacAccessibilitySnapshotCapturer: MacAccessibilitySnapshotCapturing {
    var trust: MacAccessibilityTrustStatus
    var tree: MacAccessibilitySnapshotTree
    var error: Error?
    var capturedWindowIDs: [UInt32] = []

    init(
        trustStatus: MacAccessibilityTrustStatus = .trusted,
        tree: MacAccessibilitySnapshotTree = MacAccessibilitySnapshotTreeBuilder.build(
            root: RawMacAccessibilitySnapshotNode(role: "AXWindow", title: "Window"),
            limits: .default
        ),
        error: Error? = nil
    ) {
        self.trust = trustStatus
        self.tree = tree
        self.error = error
    }

    func trustStatus() -> MacAccessibilityTrustStatus {
        trust
    }

    func captureTree(
        target: MacWindowTargetCandidate,
        limits: MacAccessibilitySnapshotLimits
    ) throws -> MacAccessibilitySnapshotTree {
        capturedWindowIDs.append(target.windowID)
        if let error {
            throw error
        }

        return tree
    }
}

private enum FixtureAccessibilityError: Error {
    case failed
}

private struct FixtureWindowProvider: MacWindowMetadataProviding {
    var fixtureWindows: [MacWindowProviderWindow]
    var frontmostProcessID: Int32?
    var focusedWindowID: UInt32?

    init(
        windows: [MacWindowProviderWindow],
        frontmostProcessID: Int32? = nil,
        focusedWindowID: UInt32? = nil
    ) {
        self.fixtureWindows = windows
        self.frontmostProcessID = frontmostProcessID
        self.focusedWindowID = focusedWindowID
    }

    func windows() -> [MacWindowProviderWindow] {
        fixtureWindows
    }

    func frontmostProcessIdentifier() -> Int32? {
        frontmostProcessID
    }

    func focusedWindowIdentifier() -> UInt32? {
        focusedWindowID
    }
}
