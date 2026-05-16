import DonkeyContracts
@testable import DonkeyRuntime
import Foundation
import Testing

@Suite
struct ManualCaptureDebugCommandTests {
    @Test
    func noArgumentsAreNotHandled() throws {
        let command = try ManualCaptureDebugCommandParser.parse(arguments: [])

        #expect(command == nil)
        #expect(!ManualCaptureDebugCommandParser.containsDebugCommand(arguments: []))
    }

    @Test
    func listWindowCandidatesSelectsListMode() throws {
        let command = try ManualCaptureDebugCommandParser.parse(
            arguments: ["Donkey", "--", "--list-window-candidates"]
        )

        #expect(command == .listWindowCandidates)
        #expect(ManualCaptureDebugCommandParser.containsDebugCommand(
            arguments: ["Donkey", "--", "--list-window-candidates"]
        ))
    }

    @Test
    func manualCaptureWindowIDBuildsDurableSelection() throws {
        let command = try ManualCaptureDebugCommandParser.parse(
            arguments: [
                "Donkey",
                "--manual-capture",
                "--window-id",
                "22",
                "--run-id",
                "run.debug-1",
                "--trace-id",
                "trace.debug-1"
            ]
        )

        #expect(command == .manualCapture(
            ManualCaptureDebugCaptureOptions(
                selection: MacWindowSelectionRequest(windowID: 22),
                runID: "run.debug-1",
                traceID: "trace.debug-1"
            )
        ))
    }

    @Test
    func invalidWindowIDReturnsCommandError() throws {
        #expect(throws: ManualCaptureDebugCommandParseError.invalidWindowID("window 2")) {
            _ = try ManualCaptureDebugCommandParser.parse(
                arguments: ["--manual-capture", "--window-id", "window 2"]
            )
        }
    }

    @Test
    func missingWindowIDValueReturnsCommandError() throws {
        #expect(throws: ManualCaptureDebugCommandParseError.missingValue("--window-id")) {
            _ = try ManualCaptureDebugCommandParser.parse(
                arguments: ["--manual-capture", "--window-id"]
            )
        }
    }

    @Test
    func invalidRunIDAndTraceIDReturnCommandErrors() throws {
        #expect(throws: ManualCaptureDebugCommandParseError.invalidIdentifier(
            option: "--run-id",
            value: "../run"
        )) {
            _ = try ManualCaptureDebugCommandParser.parse(
                arguments: ["--manual-capture", "--run-id", "../run"]
            )
        }

        #expect(throws: ManualCaptureDebugCommandParseError.invalidIdentifier(
            option: "--trace-id",
            value: " "
        )) {
            _ = try ManualCaptureDebugCommandParser.parse(
                arguments: ["--manual-capture", "--trace-id", " "]
            )
        }
    }

    @Test
    func missingRunIDAndTraceIDValuesReturnCommandErrors() throws {
        #expect(throws: ManualCaptureDebugCommandParseError.missingValue("--run-id")) {
            _ = try ManualCaptureDebugCommandParser.parse(
                arguments: ["--manual-capture", "--run-id"]
            )
        }

        #expect(throws: ManualCaptureDebugCommandParseError.missingValue("--trace-id")) {
            _ = try ManualCaptureDebugCommandParser.parse(
                arguments: ["--manual-capture", "--trace-id"]
            )
        }
    }

    @Test
    func listFormatterPrintsLabelsAndDurableWindowIDsInResolverOrder() {
        let snapshot = MacWindowResolver(
            provider: FixtureWindowProvider(
                windows: [
                    fixtureWindow(windowID: 11, processID: 100, appName: "Terminal", title: "Shell"),
                    fixtureWindow(windowID: 22, processID: 200, appName: "Safari", title: "Docs")
                ],
                frontmostProcessID: 100
            )
        )
        .enumerateCandidateList()

        let lines = ManualCaptureDebugCommandFormatter.lines(for: snapshot)

        #expect(lines == [
            "window 1 | windowID=11 | app=Terminal | title=Shell | safety=allowed | iPhoneMirroring=false",
            "window 2 | windowID=22 | app=Safari | title=Docs | safety=allowed | iPhoneMirroring=false"
        ])
    }

    @Test
    func manualCaptureModeCanDriveExistingServiceWithExplicitWindowID() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let command = try ManualCaptureDebugCommandParser.parse(
            arguments: ["--manual-capture", "--window-id", "22"]
        )
        guard case .manualCapture(let options) = command else {
            Issue.record("Expected manual capture command")
            return
        }

        let store = try LocalRunArtifactStore(baseDirectory: root)
        let screenshotCapturer = FakeWindowScreenshotCapturer()
        let accessibilityCapturer = FakeMacAccessibilitySnapshotCapturer()
        let service = makeManualService(
            store: store,
            windows: [
                fixtureWindow(windowID: 11, processID: 100, appName: "Terminal"),
                fixtureWindow(windowID: 22, processID: 200, appName: "Safari")
            ],
            frontmostProcessID: 100,
            screenshotCapturer: screenshotCapturer,
            accessibilityCapturer: accessibilityCapturer
        )

        let result = try await service.capture(
            session: RunSession(id: "run-debug-command", userGoal: "debug capture", targetID: "target-1"),
            selection: options.selection,
            traceID: "trace-debug-command",
            screenshotArtifactID: "screenshot-debug-command",
            accessibilityArtifactID: "accessibility-debug-command"
        )

        #expect(result.target.windowID == 22)
        #expect(screenshotCapturer.capturedWindowIDs == [22])
        #expect(accessibilityCapturer.capturedWindowIDs == [22])
    }

    private func makeManualService(
        store: LocalRunArtifactStore,
        windows: [MacWindowProviderWindow],
        frontmostProcessID: Int32? = nil,
        focusedWindowID: UInt32? = nil,
        screenshotCapturer: FakeWindowScreenshotCapturer,
        accessibilityCapturer: FakeMacAccessibilitySnapshotCapturer
    ) -> ManualTargetContextCaptureService {
        let provider = FixtureWindowProvider(
            windows: windows,
            frontmostProcessID: frontmostProcessID,
            focusedWindowID: focusedWindowID
        )
        let screenshotService = WindowScreenshotCaptureService(
            artifactStore: store,
            windowResolver: MacWindowResolver(provider: provider),
            capturer: screenshotCapturer
        )
        let accessibilityService = MacAccessibilitySnapshotCaptureService(
            artifactStore: store,
            windowResolver: MacWindowResolver(provider: provider),
            capturer: accessibilityCapturer
        )

        return ManualTargetContextCaptureService(
            coordinator: RunCoordinator(),
            artifactStore: store,
            windowResolver: MacWindowResolver(provider: provider),
            screenshotService: screenshotService,
            accessibilityService: accessibilityService
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

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "DonkeyManualCaptureDebugCommandTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}

private final class FakeWindowScreenshotCapturer: WindowScreenshotCapturing {
    var pngData: Data
    var imageWidth: Int
    var imageHeight: Int
    var captureMethod: WindowScreenshotCaptureMethod
    var requiresOverlapFreeTarget: Bool
    var capturedWindowIDs: [UInt32] = []

    init(
        pngData: Data = Data([0x89, 0x50, 0x4E, 0x47]),
        imageWidth: Int = 100,
        imageHeight: Int = 100,
        captureMethod: WindowScreenshotCaptureMethod = .screenCaptureKitDesktopIndependentWindow,
        requiresOverlapFreeTarget: Bool = false
    ) {
        self.pngData = pngData
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.captureMethod = captureMethod
        self.requiresOverlapFreeTarget = requiresOverlapFreeTarget
    }

    func capture(
        target: MacWindowTargetCandidate
    ) async throws -> CapturedWindowScreenshot {
        capturedWindowIDs.append(target.windowID)
        return CapturedWindowScreenshot(
            pngData: pngData,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            captureMethod: captureMethod,
            coordinateSpace: "fixture.pixels"
        )
    }
}

private final class FakeMacAccessibilitySnapshotCapturer: MacAccessibilitySnapshotCapturing {
    var trust: MacAccessibilityTrustStatus
    var tree: MacAccessibilitySnapshotTree
    var capturedWindowIDs: [UInt32] = []

    init(
        trustStatus: MacAccessibilityTrustStatus = .trusted,
        tree: MacAccessibilitySnapshotTree = MacAccessibilitySnapshotTreeBuilder.build(
            root: RawMacAccessibilitySnapshotNode(role: "AXWindow", title: "Window"),
            limits: .default
        )
    ) {
        self.trust = trustStatus
        self.tree = tree
    }

    func trustStatus() -> MacAccessibilityTrustStatus {
        trust
    }

    func captureTree(
        target: MacWindowTargetCandidate,
        limits: MacAccessibilitySnapshotLimits
    ) throws -> MacAccessibilitySnapshotTree {
        capturedWindowIDs.append(target.windowID)
        return tree
    }
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
