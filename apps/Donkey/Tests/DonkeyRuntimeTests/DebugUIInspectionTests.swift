import DonkeyAI
import DonkeyContracts
@testable import DonkeyRuntime
import CoreGraphics
import Foundation
import Testing

@Suite
struct DebugUIInspectionTests {
    @Test
    func missingConfigDisablesOverlay() throws {
        let url = temporaryDirectory()
            .appendingPathComponent("missing-dev-overlay.json", isDirectory: false)

        let config = DebugUIOverlayConfiguration.load(fileURL: url)

        #expect(config.enabled == false)
        #expect(config.provider == .accessibility)
        #expect(config.screenScope == .main)
    }

    @Test
    func invalidConfigDisablesOverlay() throws {
        let url = temporaryDirectory()
            .appendingPathComponent("invalid-dev-overlay.json", isDirectory: false)
        try Data("{".utf8).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = DebugUIOverlayConfiguration.load(fileURL: url)

        #expect(config.enabled == false)
    }

    @Test
    func enabledConfigUsesSafeDefaults() throws {
        let url = temporaryDirectory()
            .appendingPathComponent("enabled-dev-overlay.json", isDirectory: false)
        try Data(#"{"enabled":true}"#.utf8).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = DebugUIOverlayConfiguration.load(fileURL: url)

        #expect(config.enabled == true)
        #expect(config.provider == .accessibility)
        #expect(config.cadenceSeconds == 1.0)
        #expect(config.screenScope == .main)
        #expect(config.minConfidence == 0.25)
    }

    @Test
    func disabledRepoStyleConfigKeepsOverlayOff() throws {
        let url = temporaryDirectory()
            .appendingPathComponent("disabled-dev-overlay.json", isDirectory: false)
        try Data(
            """
            {
              "enabled": false,
              "provider": "gemini",
              "cadenceSeconds": 0.05,
              "screenScope": "all",
              "minConfidence": 2
            }
            """.utf8
        ).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = DebugUIOverlayConfiguration.load(fileURL: url)

        #expect(config.enabled == false)
        #expect(config.provider == .gemini)
        #expect(config.cadenceSeconds == 0.25)
        #expect(config.screenScope == .all)
        #expect(config.minConfidence == 1)
    }

    @Test
    func debugCandidateConfigURLsIncludeEnvironmentOverride() {
        let path = temporaryDirectory()
            .appendingPathComponent("custom-dev-overlay.json", isDirectory: false)
            .path

        let urls = DebugUIOverlayConfiguration.candidateConfigURLs(
            environment: ["DONKEY_DEV_OVERLAY_CONFIG": path]
        )

        #expect(urls.map(\.path).contains(path))
    }

    @Test
    func inspectionResponseDecodesAndFiltersElements() throws {
        let response = RemoteInferenceJSONValue.object([
            "output_text": .string(
                """
                {"coordinate_space":{"width":1000,"height":500},"elements":[
                  {"id":"save","type":"button","label":"Save","description":"Saves","bbox":{"x":10,"y":20,"width":80,"height":30},"confidence":1.5,"visual_style":{"overlay_color":"#3B82F6","border_color":"#60A5FA","label_color":"#FFFFFF"}},
                  {"id":"low","type":"link","label":"Low","description":"","bbox":{"x":0,"y":0,"width":10,"height":10},"confidence":0.1,"visual_style":{"overlay_color":"#06B6D4","border_color":"#67E8F9","label_color":"#FFFFFF"}}
                ]}
                """
            )
        ])

        let frame = try DebugUIInspectionResponseDecoder.decode(response, minConfidence: 0.25)

        #expect(frame.elements.map(\.id) == ["save"])
        #expect(frame.elements.first?.confidence == 1.0)
        #expect(frame.elements.first?.visualStyle == DebugUIOverlayStyle.style(for: .button))
    }

    @Test
    func inspectionResponseScalesProviderCoordinateSpaceToScreenshotPixels() throws {
        let response = RemoteInferenceJSONValue.object([
            "output_text": .string(
                """
                {"coordinate_space":{"width":960,"height":540},"elements":[
                  {"id":"search","type":"input","label":"Search","description":"","bbox":{"x":120,"y":270,"width":240,"height":30},"confidence":0.9,"visual_style":{"overlay_color":"#10B981","border_color":"#6EE7B7","label_color":"#FFFFFF"}}
                ]}
                """
            )
        ])

        let frame = try DebugUIInspectionResponseDecoder.decode(
            response,
            screenshotPixelSize: HotLoopSize(width: 1920, height: 1080, space: .screen)
        )

        #expect(frame.elements.first?.bbox == DebugUIBoundingBox(x: 240, y: 540, width: 480, height: 60))
    }

    @Test
    func inspectionResponseRejectsProviderActions() {
        let response = RemoteInferenceJSONValue.object([
            "output": .array([
                .object([
                    "type": .string("function_call"),
                    "name": .string("click_at")
                ])
            ])
        ])

        #expect(throws: DebugUIInspectionHostedAdapterError.providerReturnedAction) {
            _ = try DebugUIInspectionResponseDecoder.decode(response)
        }
    }

    @Test
    func trackerPreservesStableIDForMovedSemanticMatch() {
        var tracker = DebugUIElementTracker()
        _ = tracker.update(with: DebugUIInspectionFrame(elements: [
            element(id: "button-1", label: "Save", x: 10, y: 20)
        ]))

        let updated = tracker.update(with: DebugUIInspectionFrame(elements: [
            element(id: "provider-new-id", label: "Save", x: 36, y: 24)
        ]))

        #expect(updated.elements.first?.id == "button-1")
    }

    @Test
    func geometryConvertsScreenshotPixelsToAppKitPoints() {
        let frame = DebugUIOverlayGeometry.appKitFrame(
            for: DebugUIBoundingBox(x: 200, y: 100, width: 400, height: 200),
            screenshotPixelSize: HotLoopSize(width: 2000, height: 1000, space: .screen),
            screenFrame: HotLoopRect(x: 0, y: 0, width: 1000, height: 500, space: .screen)
        )

        #expect(frame == CGRect(x: 100, y: 350, width: 200, height: 100))
    }

    @Test
    func geometryConvertsTopLeftScreenPixelsToLocalLayerPoints() {
        let frame = DebugUIOverlayGeometry.localLayerFrame(
            for: DebugUIBoundingBox(x: 200, y: 100, width: 400, height: 200),
            screenshotPixelSize: HotLoopSize(width: 2000, height: 1000, space: .screen),
            screenPointSize: HotLoopSize(width: 1000, height: 500, space: .screen)
        )

        #expect(frame == CGRect(x: 100, y: 350, width: 200, height: 100))
    }

    @Test
    func accessibilityGeometryClipsScreenLocalBounds() {
        let bbox = DebugUIAccessibilityGeometry.boundingBox(
            for: WindowTargetBounds(x: 900, y: 750, width: 200, height: 100),
            screenFrame: WindowTargetBounds(x: 0, y: 0, width: 1000, height: 800)
        )

        #expect(bbox == DebugUIBoundingBox(x: 900, y: 750, width: 100, height: 50))
    }

    @Test
    func accessibilityGeometryNormalizesWindowLocalAxisWhenItBetterFitsTarget() {
        let normalized = DebugUIAccessibilityGeometry.normalizedBounds(
            for: WindowTargetBounds(x: 436, y: 117, width: 160, height: 240),
            targetBounds: WindowTargetBounds(x: 50, y: 253, width: 1530, height: 930),
            rootBounds: WindowTargetBounds(x: 50, y: 253, width: 1530, height: 930)
        )

        #expect(normalized == WindowTargetBounds(x: 436, y: 370, width: 160, height: 240))
    }

    @Test
    func accessibilityGeometryGroundsGlobalFrameOnMovedWindowPosition() {
        let normalized = DebugUIAccessibilityGeometry.normalizedBounds(
            for: WindowTargetBounds(x: 436, y: 370, width: 160, height: 240),
            targetBounds: WindowTargetBounds(x: 80, y: 400, width: 1530, height: 930),
            rootBounds: WindowTargetBounds(x: 50, y: 253, width: 1530, height: 930)
        )

        #expect(normalized == WindowTargetBounds(x: 466, y: 517, width: 160, height: 240))
    }

    @Test
    func accessibilityInspectionBuildsScreenLocalWindowFrames() throws {
        let screen = DebugUIScreenMetadata(
            screenID: 3,
            appKitFrame: HotLoopRect(x: 0, y: 0, width: 1000, height: 800, space: .screen),
            captureFrame: WindowTargetBounds(x: 0, y: 0, width: 1000, height: 800)
        )
        let capturer = DebugUIFakeAccessibilityCapturer(
            tree: MacAccessibilitySnapshotTreeBuilder.build(
                root: RawMacAccessibilitySnapshotNode(
                    role: "AXWindow",
                    title: "Window",
                    frame: WindowTargetBounds(x: 100, y: 200, width: 500, height: 300),
                    children: [
                        RawMacAccessibilitySnapshotNode(
                            role: "AXButton",
                            title: "Save",
                            frame: WindowTargetBounds(x: 120, y: 230, width: 80, height: 30),
                            isEnabled: true,
                            actions: ["AXPress"]
                        ),
                        RawMacAccessibilitySnapshotNode(
                            role: "AXGroup",
                            title: "Container",
                            frame: WindowTargetBounds(x: 0, y: 0, width: 1000, height: 800),
                            isEnabled: true
                        )
                    ]
                ),
                limits: MacAccessibilitySnapshotLimits(maxDepth: 6)
            )
        )
        let service = DebugUIAccessibilityInspectionService(
            windowResolver: MacWindowResolver(
                provider: DebugUIFixtureWindowProvider(
                    windows: [
                        MacWindowProviderWindow(
                            windowID: 11,
                            processID: 100,
                            appName: "Notes",
                            title: "Window",
                            bounds: WindowTargetBounds(x: 100, y: 200, width: 500, height: 300)
                        )
                    ],
                    frontmostProcessID: 100
                )
            ),
            capturer: capturer,
            screenProvider: DebugUIFixtureScreenProvider(screens: [screen]),
            currentProcessID: 999
        )

        let results = try service.inspect(scope: .main, minConfidence: 0.25)

        #expect(capturer.capturedWindowIDs == [11])
        #expect(results.map(\.snapshot.screenID) == [3])
        #expect(results.first?.frame.elements.count == 1)
        let element = results.first?.frame.elements.first
        #expect(element?.id == "window-11")
        #expect(element?.label == "Notes")
        #expect(element?.bbox == DebugUIBoundingBox(x: 100, y: 200, width: 500, height: 300))
    }

    @Test
    func accessibilityInspectionSkipsCurrentProcess() throws {
        let screen = DebugUIScreenMetadata(
            screenID: 1,
            appKitFrame: HotLoopRect(x: 0, y: 0, width: 500, height: 500, space: .screen),
            captureFrame: WindowTargetBounds(x: 0, y: 0, width: 500, height: 500)
        )
        let capturer = DebugUIFakeAccessibilityCapturer()
        let service = DebugUIAccessibilityInspectionService(
            windowResolver: MacWindowResolver(
                provider: DebugUIFixtureWindowProvider(
                    windows: [
                        MacWindowProviderWindow(
                            windowID: 1,
                            processID: 42,
                            appName: "Donkey Dev",
                            bounds: WindowTargetBounds(x: 0, y: 0, width: 200, height: 200)
                        )
                    ],
                    frontmostProcessID: 42
                )
            ),
            capturer: capturer,
            screenProvider: DebugUIFixtureScreenProvider(screens: [screen]),
            currentProcessID: 42
        )

        let results = try service.inspect(scope: .main, minConfidence: 0.25)

        #expect(capturer.capturedWindowIDs.isEmpty)
        #expect(results.first?.frame.elements.isEmpty == true)
    }

    @Test
    func accessibilityInspectionSkipsFullyCoveredWindowFrame() throws {
        let screen = DebugUIScreenMetadata(
            screenID: 1,
            appKitFrame: HotLoopRect(x: 0, y: 0, width: 500, height: 500, space: .screen),
            captureFrame: WindowTargetBounds(x: 0, y: 0, width: 500, height: 500)
        )
        let capturer = DebugUIFakeAccessibilityCapturer(
            treesByWindowID: [
                1: MacAccessibilitySnapshotTreeBuilder.build(
                    root: RawMacAccessibilitySnapshotNode(
                        role: "AXWindow",
                        title: "Front",
                        frame: WindowTargetBounds(x: 100, y: 100, width: 200, height: 200),
                        children: [
                            RawMacAccessibilitySnapshotNode(
                                role: "AXButton",
                                title: "Visible",
                                frame: WindowTargetBounds(x: 120, y: 120, width: 80, height: 30),
                                isEnabled: true,
                                actions: ["AXPress"]
                            )
                        ]
                    ),
                    limits: MacAccessibilitySnapshotLimits(maxDepth: 6)
                ),
                2: MacAccessibilitySnapshotTreeBuilder.build(
                    root: RawMacAccessibilitySnapshotNode(
                        role: "AXWindow",
                        title: "Back",
                        frame: WindowTargetBounds(x: 100, y: 100, width: 200, height: 200),
                        children: [
                            RawMacAccessibilitySnapshotNode(
                                role: "AXButton",
                                title: "Hidden",
                                frame: WindowTargetBounds(x: 130, y: 130, width: 80, height: 30),
                                isEnabled: true,
                                actions: ["AXPress"]
                            )
                        ]
                    ),
                    limits: MacAccessibilitySnapshotLimits(maxDepth: 6)
                )
            ]
        )
        let service = DebugUIAccessibilityInspectionService(
            windowResolver: MacWindowResolver(
                provider: DebugUIFixtureWindowProvider(
                    windows: [
                        MacWindowProviderWindow(
                            windowID: 1,
                            processID: 100,
                            appName: "Front",
                            bounds: WindowTargetBounds(x: 100, y: 100, width: 200, height: 200)
                        ),
                        MacWindowProviderWindow(
                            windowID: 2,
                            processID: 200,
                            appName: "Back",
                            bounds: WindowTargetBounds(x: 100, y: 100, width: 200, height: 200)
                        )
                    ],
                    frontmostProcessID: 100
                )
            ),
            capturer: capturer,
            screenProvider: DebugUIFixtureScreenProvider(screens: [screen]),
            currentProcessID: 999
        )

        let results = try service.inspect(scope: .main, minConfidence: 0.25)

        #expect(capturer.capturedWindowIDs == [1, 2])
        #expect(results.first?.frame.elements.map(\.id) == ["window-1"])
        #expect(results.first?.frame.elements.map(\.label) == ["Front"])
    }

    @Test
    func accessibilityInspectionKeepsPartiallyVisibleWindowFrame() throws {
        let screen = DebugUIScreenMetadata(
            screenID: 1,
            appKitFrame: HotLoopRect(x: 0, y: 0, width: 500, height: 500, space: .screen),
            captureFrame: WindowTargetBounds(x: 0, y: 0, width: 500, height: 500)
        )
        let capturer = DebugUIFakeAccessibilityCapturer(
            treesByWindowID: [
                1: MacAccessibilitySnapshotTreeBuilder.build(
                    root: RawMacAccessibilitySnapshotNode(
                        role: "AXWindow",
                        title: "Front",
                        frame: WindowTargetBounds(x: 100, y: 100, width: 100, height: 100)
                    ),
                    limits: MacAccessibilitySnapshotLimits(maxDepth: 0)
                ),
                2: MacAccessibilitySnapshotTreeBuilder.build(
                    root: RawMacAccessibilitySnapshotNode(
                        role: "AXWindow",
                        title: "Back",
                        frame: WindowTargetBounds(x: 150, y: 150, width: 200, height: 200)
                    ),
                    limits: MacAccessibilitySnapshotLimits(maxDepth: 0)
                )
            ]
        )
        let service = DebugUIAccessibilityInspectionService(
            windowResolver: MacWindowResolver(
                provider: DebugUIFixtureWindowProvider(
                    windows: [
                        MacWindowProviderWindow(
                            windowID: 1,
                            processID: 100,
                            appName: "Front",
                            bounds: WindowTargetBounds(x: 100, y: 100, width: 100, height: 100)
                        ),
                        MacWindowProviderWindow(
                            windowID: 2,
                            processID: 200,
                            appName: "Back",
                            bounds: WindowTargetBounds(x: 150, y: 150, width: 200, height: 200)
                        )
                    ],
                    frontmostProcessID: 100
                )
            ),
            capturer: capturer,
            screenProvider: DebugUIFixtureScreenProvider(screens: [screen]),
            currentProcessID: 999
        )

        let results = try service.inspect(scope: .main, minConfidence: 0.25)

        #expect(capturer.capturedWindowIDs == [1, 2])
        #expect(results.first?.frame.elements.map(\.id) == ["window-1", "window-2"])
        #expect(results.first?.frame.elements.map(\.label) == ["Front", "Back"])
        #expect(results.first?.frame.elements.map(\.visualStyle.borderColor) == ["#F87171", "#FB923C"])
    }

    @Test
    func accessibilityInspectionIgnoresChildElementsWhenDrawingWindowFramesOnly() throws {
        let screen = DebugUIScreenMetadata(
            screenID: 1,
            appKitFrame: HotLoopRect(x: 0, y: 0, width: 1000, height: 800, space: .screen),
            captureFrame: WindowTargetBounds(x: 0, y: 0, width: 1000, height: 800)
        )
        let capturer = DebugUIFakeAccessibilityCapturer(
            tree: MacAccessibilitySnapshotTreeBuilder.build(
                root: RawMacAccessibilitySnapshotNode(
                    role: "AXWindow",
                    title: "Terminal",
                    frame: WindowTargetBounds(x: 0, y: 0, width: 1000, height: 800),
                    children: [
                        RawMacAccessibilitySnapshotNode(
                            role: "AXTextArea",
                            title: "Terminal output",
                            frame: WindowTargetBounds(x: 100, y: 100, width: 700, height: 300),
                            isEnabled: true
                        ),
                        RawMacAccessibilitySnapshotNode(
                            role: "AXTextField",
                            title: "Search",
                            frame: WindowTargetBounds(x: 100, y: 450, width: 300, height: 34),
                            isEnabled: true
                        )
                    ]
                ),
                limits: MacAccessibilitySnapshotLimits(maxDepth: 6)
            )
        )
        let service = DebugUIAccessibilityInspectionService(
            windowResolver: MacWindowResolver(
                provider: DebugUIFixtureWindowProvider(
                    windows: [
                        MacWindowProviderWindow(
                            windowID: 1,
                            processID: 100,
                            appName: "Terminal",
                            bounds: WindowTargetBounds(x: 0, y: 0, width: 1000, height: 800)
                        )
                    ],
                    frontmostProcessID: 100
                )
            ),
            capturer: capturer,
            screenProvider: DebugUIFixtureScreenProvider(screens: [screen]),
            currentProcessID: 999
        )

        let results = try service.inspect(scope: .main, minConfidence: 0.25)

        #expect(capturer.capturedWindowIDs == [1])
        #expect(results.first?.frame.elements.map(\.id) == ["window-1"])
        #expect(results.first?.frame.elements.first?.bbox == DebugUIBoundingBox(
            x: 0,
            y: 0,
            width: 1000,
            height: 800
        ))
    }

    @Test
    func accessibilityInspectionDrawsMusicWindowFrameOnly() throws {
        let screen = DebugUIScreenMetadata(
            screenID: 1,
            appKitFrame: HotLoopRect(x: 0, y: 0, width: 1800, height: 1400, space: .screen),
            captureFrame: WindowTargetBounds(x: 0, y: 0, width: 1800, height: 1400)
        )
        let capturer = DebugUIFakeAccessibilityCapturer(
            tree: MacAccessibilitySnapshotTreeBuilder.build(
                root: RawMacAccessibilitySnapshotNode(
                    role: "AXWindow",
                    title: "Music",
                    frame: WindowTargetBounds(x: 50, y: 253, width: 1530, height: 930),
                    children: [
                        RawMacAccessibilitySnapshotNode(
                            role: "AXButton",
                            title: "K-Pop Hits",
                            frame: WindowTargetBounds(x: 436, y: 117, width: 160, height: 240),
                            isEnabled: true,
                            actions: ["AXPress"]
                        )
                    ]
                ),
                limits: MacAccessibilitySnapshotLimits(maxDepth: 6)
            )
        )
        let service = DebugUIAccessibilityInspectionService(
            windowResolver: MacWindowResolver(
                provider: DebugUIFixtureWindowProvider(
                    windows: [
                        MacWindowProviderWindow(
                            windowID: 1,
                            processID: 100,
                            appName: "Music",
                            bounds: WindowTargetBounds(x: 50, y: 253, width: 1530, height: 930)
                        )
                    ],
                    frontmostProcessID: 100
                )
            ),
            capturer: capturer,
            screenProvider: DebugUIFixtureScreenProvider(screens: [screen]),
            currentProcessID: 999
        )

        let results = try service.inspect(scope: .main, minConfidence: 0.25)

        #expect(results.first?.frame.elements.first?.bbox == DebugUIBoundingBox(
            x: 50,
            y: 253,
            width: 1530,
            height: 930
        ))
    }

    @Test
    func accessibilityInspectionDrawsMovedMusicWindowFrameOnly() throws {
        let screen = DebugUIScreenMetadata(
            screenID: 1,
            appKitFrame: HotLoopRect(x: 0, y: 0, width: 1800, height: 1400, space: .screen),
            captureFrame: WindowTargetBounds(x: 0, y: 0, width: 1800, height: 1400)
        )
        let capturer = DebugUIFakeAccessibilityCapturer(
            tree: MacAccessibilitySnapshotTreeBuilder.build(
                root: RawMacAccessibilitySnapshotNode(
                    role: "AXWindow",
                    title: "Music",
                    frame: WindowTargetBounds(x: 80, y: 400, width: 1530, height: 930),
                    children: [
                        RawMacAccessibilitySnapshotNode(
                            role: "AXButton",
                            title: "K-Pop Hits",
                            frame: WindowTargetBounds(x: 436, y: 370, width: 160, height: 240),
                            isEnabled: true,
                            actions: ["AXPress"]
                        )
                    ]
                ),
                limits: MacAccessibilitySnapshotLimits(maxDepth: 6)
            )
        )
        let service = DebugUIAccessibilityInspectionService(
            windowResolver: MacWindowResolver(
                provider: DebugUIFixtureWindowProvider(
                    windows: [
                        MacWindowProviderWindow(
                            windowID: 1,
                            processID: 100,
                            appName: "Music",
                            bounds: WindowTargetBounds(x: 80, y: 400, width: 1530, height: 930)
                        )
                    ],
                    frontmostProcessID: 100
                )
            ),
            capturer: capturer,
            screenProvider: DebugUIFixtureScreenProvider(screens: [screen]),
            currentProcessID: 999
        )

        let results = try service.inspect(scope: .main, minConfidence: 0.25)

        #expect(results.first?.frame.elements.first?.bbox == DebugUIBoundingBox(
            x: 80,
            y: 400,
            width: 1530,
            height: 930
        ))
    }

    private func element(
        id: String,
        label: String,
        x: Double,
        y: Double
    ) -> DebugUIElement {
        DebugUIElement(
            id: id,
            type: .button,
            label: label,
            bbox: DebugUIBoundingBox(x: x, y: y, width: 80, height: 30),
            confidence: 0.9
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("donkey-debug-ui-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class DebugUIFakeAccessibilityCapturer: MacAccessibilitySnapshotCapturing, @unchecked Sendable {
    var trust: MacAccessibilityTrustStatus
    var tree: MacAccessibilitySnapshotTree
    var treesByWindowID: [UInt32: MacAccessibilitySnapshotTree]
    var capturedWindowIDs: [UInt32] = []

    init(
        trustStatus: MacAccessibilityTrustStatus = .trusted,
        tree: MacAccessibilitySnapshotTree = MacAccessibilitySnapshotTreeBuilder.build(
            root: RawMacAccessibilitySnapshotNode(role: "AXWindow", title: "Window"),
            limits: .default
        ),
        treesByWindowID: [UInt32: MacAccessibilitySnapshotTree] = [:]
    ) {
        self.trust = trustStatus
        self.tree = tree
        self.treesByWindowID = treesByWindowID
    }

    func trustStatus() -> MacAccessibilityTrustStatus {
        trust
    }

    func captureTree(
        target: MacWindowTargetCandidate,
        limits: MacAccessibilitySnapshotLimits
    ) throws -> MacAccessibilitySnapshotTree {
        capturedWindowIDs.append(target.windowID)
        return treesByWindowID[target.windowID] ?? tree
    }
}

private struct DebugUIFixtureScreenProvider: DebugUIScreenMetadataProviding {
    var screens: [DebugUIScreenMetadata]

    func screens(scope: DebugUIInspectionScreenScope) throws -> [DebugUIScreenMetadata] {
        switch scope {
        case .main:
            return screens.prefix(1).map { $0 }
        case .all:
            return screens
        }
    }
}

private struct DebugUIFixtureWindowProvider: MacWindowMetadataProviding {
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
