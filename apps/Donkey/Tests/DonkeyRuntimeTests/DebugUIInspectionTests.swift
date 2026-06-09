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
        #expect(config.mode == "donkeyVision")
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
        #expect(config.mode == "donkeyVision")
        #expect(config.cadenceSeconds == 1.0)
        #expect(config.screenScope == .main)
        #expect(config.minConfidence == 0.25)
        #expect(config.activeWindowOnly == false)
        #expect(config.targetBundleIdentifiers.isEmpty)
        #expect(config.targetAppNames.isEmpty)
    }

    @Test
    func configLoadsTargetFilters() throws {
        let url = temporaryDirectory()
            .appendingPathComponent("targeted-dev-overlay.json", isDirectory: false)
        try Data(
            """
            {
              "enabled": true,
              "activeWindowOnly": true,
              "targetBundleIdentifiers": ["com.apple.Music", " com.apple.Music "],
              "targetAppNames": ["Music"]
            }
            """.utf8
        ).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = DebugUIOverlayConfiguration.load(fileURL: url)

        #expect(config.targetBundleIdentifiers == ["com.apple.Music"])
        #expect(config.targetAppNames == ["Music"])
        #expect(config.activeWindowOnly == true)
    }

    @Test
    func disabledRepoStyleConfigKeepsOverlayOff() throws {
        let url = temporaryDirectory()
            .appendingPathComponent("disabled-dev-overlay.json", isDirectory: false)
        try Data(
            """
            {
              "enabled": false,
              "cadenceSeconds": 0.05,
              "screenScope": "all",
              "minConfidence": 2
            }
            """.utf8
        ).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = DebugUIOverlayConfiguration.load(fileURL: url)

        #expect(config.enabled == false)
        #expect(config.mode == "donkeyVision")
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
    func trackerWithoutCarryForwardClearsPreviousFrameBeforeRenderingNext() {
        // Mirrors the debug overlay's tracker config (appearanceThreshold 1, disappearanceTolerance 0):
        // vision reassigns element IDs every parse, so any carry-forward leaves stale boxes stacked on
        // screen. With no carry-forward, the previous overlay is fully replaced by the next parse.
        var tracker = DebugUIElementTracker(
            appearanceThreshold: 1,
            disappearanceTolerance: 0,
            movementConfirmationSamples: 1
        )
        let first = tracker.update(
            with: DebugUIInspectionFrame(elements: [
                element(id: "ai-1-a", label: "Coldplay", x: 10, y: 20),
                element(id: "ai-1-b", label: "Notifications", x: 100, y: 20)
            ]),
            renderNewElementsImmediately: true
        )
        #expect(Set(first.elements.map(\.id)) == ["ai-1-a", "ai-1-b"])

        // Next parse: brand-new IDs, no semantic overlap. The old boxes must not linger.
        let second = tracker.update(
            with: DebugUIInspectionFrame(elements: [
                element(id: "ai-2-c", label: "Search", x: 300, y: 400)
            ]),
            renderNewElementsImmediately: true
        )
        #expect(second.elements.map(\.id) == ["ai-2-c"])
    }

    @Test
    func trackerKeepsStableAccessibilityBoxThroughBriefDetectionGap() {
        // Mirrors the debug overlay's tracker config: vision boxes (ai-) drop immediately, but
        // stable accessibility boxes (ax-) get a few frames of hysteresis so a single missed scan
        // does not strobe the overlay.
        var tracker = DebugUIElementTracker(
            appearanceThreshold: 1,
            disappearanceTolerance: 0,
            movementConfirmationSamples: 1,
            stableDisappearanceTolerance: 4,
            stableIDPrefixes: ["ax-", "window-chrome-"]
        )
        _ = tracker.update(
            with: DebugUIInspectionFrame(elements: [
                element(id: "ax-1.1.1.1", label: "Scroll Area", x: 10, y: 20)
            ]),
            renderNewElementsImmediately: true
        )

        // One scan omits the accessibility box: it must persist instead of flickering out.
        let gap = tracker.update(with: DebugUIInspectionFrame(elements: []))
        #expect(gap.elements.map(\.id) == ["ax-1.1.1.1"])

        // A genuinely vanished box still clears once the hysteresis is exhausted.
        for _ in 0..<4 {
            _ = tracker.update(with: DebugUIInspectionFrame(elements: []))
        }
        let cleared = tracker.update(with: DebugUIInspectionFrame(elements: []))
        #expect(cleared.elements.isEmpty)
    }

    @Test
    func trackerDropsVolatileBoxImmediatelyEvenWithStableHysteresis() {
        // The stable hysteresis must not leak onto vision boxes — a parse that omits an ai- box
        // clears it on the very next frame, so stale vision boxes never stack.
        var tracker = DebugUIElementTracker(
            appearanceThreshold: 1,
            disappearanceTolerance: 0,
            movementConfirmationSamples: 1,
            stableDisappearanceTolerance: 4,
            stableIDPrefixes: ["ax-", "window-chrome-"]
        )
        _ = tracker.update(
            with: DebugUIInspectionFrame(elements: [
                element(id: "ai-1-a", label: "Coldplay", x: 10, y: 20)
            ]),
            renderNewElementsImmediately: true
        )
        let next = tracker.update(
            with: DebugUIInspectionFrame(elements: [
                element(id: "ai-2-b", label: "Search", x: 300, y: 400)
            ]),
            renderNewElementsImmediately: true
        )
        #expect(next.elements.map(\.id) == ["ai-2-b"])
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
    func trackerFreezesTinyBoundingBoxJitter() {
        var tracker = DebugUIElementTracker()
        _ = tracker.update(with: DebugUIInspectionFrame(elements: [
            element(id: "button-1", label: "Save", x: 10, y: 20)
        ]))

        let updated = tracker.update(with: DebugUIInspectionFrame(elements: [
            element(id: "button-1", label: "Save", x: 11.4, y: 20.8)
        ]))

        #expect(updated.elements.first?.bbox == DebugUIBoundingBox(x: 10, y: 20, width: 80, height: 30))
    }

    @Test
    func trackerFreezesLargerBoundingBoxJitter() {
        var tracker = DebugUIElementTracker()
        _ = tracker.update(with: DebugUIInspectionFrame(elements: [
            element(id: "button-1", label: "Save", x: 10, y: 20)
        ]))
        _ = tracker.update(with: DebugUIInspectionFrame(elements: [
            element(id: "button-1", label: "Save", x: 10, y: 20)
        ]))

        let updated = tracker.update(with: DebugUIInspectionFrame(elements: [
            element(id: "button-1", label: "Save", x: 15.8, y: 24.9)
        ]))

        #expect(updated.elements.first?.bbox == DebugUIBoundingBox(x: 10, y: 20, width: 80, height: 30))
    }

    @Test
    func trackerRequiresRepeatedSamplesBeforeRenderingModerateMovement() {
        var tracker = DebugUIElementTracker()
        _ = tracker.update(with: DebugUIInspectionFrame(elements: [
            element(id: "button-1", label: "Save", x: 10, y: 20)
        ]))
        _ = tracker.update(with: DebugUIInspectionFrame(elements: [
            element(id: "button-1", label: "Save", x: 10, y: 20)
        ]))

        let firstMoved = tracker.update(with: DebugUIInspectionFrame(elements: [
            element(id: "button-1", label: "Save", x: 28, y: 20)
        ]))
        let secondMoved = tracker.update(with: DebugUIInspectionFrame(elements: [
            element(id: "button-1", label: "Save", x: 28.5, y: 20.2)
        ]))

        #expect(firstMoved.elements.first?.bbox == DebugUIBoundingBox(x: 10, y: 20, width: 80, height: 30))
        #expect(secondMoved.elements.first?.bbox == DebugUIBoundingBox(x: 28.5, y: 20.2, width: 80, height: 30))
    }

    @Test
    func trackerAcceptsLargeMovementImmediately() {
        var tracker = DebugUIElementTracker()
        _ = tracker.update(with: DebugUIInspectionFrame(elements: [
            element(id: "button-1", label: "Save", x: 10, y: 20)
        ]))
        _ = tracker.update(with: DebugUIInspectionFrame(elements: [
            element(id: "button-1", label: "Save", x: 10, y: 20)
        ]))

        let moved = tracker.update(with: DebugUIInspectionFrame(elements: [
            element(id: "button-1", label: "Save", x: 95, y: 20)
        ]))

        #expect(moved.elements.first?.bbox == DebugUIBoundingBox(x: 95, y: 20, width: 80, height: 30))
    }

    @Test
    func trackerRequiresRepeatedSamplesBeforeRenderingLabelAndSourceBadgeChanges() {
        var tracker = DebugUIElementTracker()
        let accessibilityElement = element(
            id: "button-1",
            label: "Save",
            x: 10,
            y: 20,
            metadata: ["localUIElement.sources": "accessibility"]
        )
        _ = tracker.update(with: DebugUIInspectionFrame(elements: [accessibilityElement]))
        let rendered = tracker.update(with: DebugUIInspectionFrame(elements: [accessibilityElement]))

        let changed = element(
            id: "button-1",
            label: "Save file",
            x: 10,
            y: 20,
            metadata: ["localUIElement.sources": "accessibility,ocr"]
        )
        let firstChanged = tracker.update(with: DebugUIInspectionFrame(elements: [changed]))
        let secondChanged = tracker.update(with: DebugUIInspectionFrame(elements: [changed]))

        #expect(firstChanged.isOverlayRenderEquivalent(to: rendered))
        #expect(secondChanged.elements.first?.label == "Save file")
        #expect(secondChanged.elements.first?.metadata["localUIElement.sources"] == "accessibility,ocr")
    }

    @Test
    func trackerRendersInitialElementsImmediatelyThenRequiresMultipleSamplesForNewElements() {
        var tracker = DebugUIElementTracker()

        let first = tracker.update(with: DebugUIInspectionFrame(elements: [
            element(id: "button-1", label: "Save", x: 10, y: 20)
        ]))
        let newElementFirstSample = tracker.update(with: DebugUIInspectionFrame(elements: [
            element(id: "button-1", label: "Save", x: 10, y: 20),
            element(id: "button-2", label: "Cancel", x: 110, y: 20)
        ]))
        let newElementSecondSample = tracker.update(with: DebugUIInspectionFrame(elements: [
            element(id: "button-1", label: "Save", x: 10, y: 20),
            element(id: "button-2", label: "Cancel", x: 110, y: 20)
        ]))

        #expect(first.elements.map(\.id) == ["button-1"])
        #expect(newElementFirstSample.elements.map(\.id) == ["button-1"])
        #expect(newElementSecondSample.elements.map(\.id) == ["button-1", "button-2"])
    }

    @Test
    func trackerRetainsMissingElementForAFewSamplesBeforeRemoving() {
        var tracker = DebugUIElementTracker()
        _ = tracker.update(with: DebugUIInspectionFrame(elements: [
            element(id: "button-1", label: "Save", x: 10, y: 20)
        ]))
        _ = tracker.update(with: DebugUIInspectionFrame(elements: [
            element(id: "button-1", label: "Save", x: 10, y: 20)
        ]))

        let firstMissing = tracker.update(with: DebugUIInspectionFrame())
        let secondMissing = tracker.update(with: DebugUIInspectionFrame())
        let thirdMissing = tracker.update(with: DebugUIInspectionFrame())

        #expect(firstMissing.elements.map(\.id) == ["button-1"])
        #expect(secondMissing.elements.map(\.id) == ["button-1"])
        #expect(thirdMissing.elements.isEmpty)
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
    func labelGeometryUsesStableWidthBuckets() {
        let short = DebugUIOverlayGeometry.stableLabelFrame(
            for: "Save",
            boxFrame: CGRect(x: 24, y: 80, width: 80, height: 30),
            containerSize: CGSize(width: 500, height: 400)
        )
        let medium = DebugUIOverlayGeometry.stableLabelFrame(
            for: "Save current document",
            boxFrame: CGRect(x: 24, y: 80, width: 80, height: 30),
            containerSize: CGSize(width: 500, height: 400)
        )
        let topEdge = DebugUIOverlayGeometry.stableLabelFrame(
            for: "Toolbar",
            boxFrame: CGRect(x: 24, y: 4, width: 80, height: 30),
            containerSize: CGSize(width: 500, height: 400)
        )

        #expect(short == CGRect(x: 24, y: 60, width: 96, height: 18))
        #expect(medium == CGRect(x: 24, y: 60, width: 160, height: 18))
        #expect(topEdge == CGRect(x: 24, y: 6, width: 96, height: 18))
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
        #expect(results.first?.frame.elements.map(\.id) == ["window-11", "ax-11-ax-1.1"])
        let window = results.first?.frame.elements.first
        #expect(window?.label == "Notes")
        #expect(window?.bbox == DebugUIBoundingBox(x: 100, y: 200, width: 500, height: 300))
        let button = results.first?.frame.elements.last
        #expect(button?.type == .button)
        #expect(button?.label == "Save")
        #expect(button?.metadata["target.windowID"] == "11")
        #expect(button?.metadata["debugOverlay.localBounds.x"] == "20.0")
        #expect(button?.metadata["debugOverlay.localBounds.y"] == "30.0")
        #expect(button?.metadata["debugOverlay.localBounds.width"] == "80.0")
        #expect(button?.metadata["debugOverlay.localBounds.height"] == "30.0")
        #expect(button?.bbox == DebugUIBoundingBox(x: 120, y: 230, width: 80, height: 30))
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
        #expect(results.isEmpty)
    }

    @Test
    func accessibilityInspectionCanTargetMusicOnly() throws {
        let screen = DebugUIScreenMetadata(
            screenID: 1,
            appKitFrame: HotLoopRect(x: 0, y: 0, width: 1000, height: 800, space: .screen),
            captureFrame: WindowTargetBounds(x: 0, y: 0, width: 1000, height: 800)
        )
        let capturer = DebugUIFakeAccessibilityCapturer(
            treesByWindowID: [
                1: MacAccessibilitySnapshotTreeBuilder.build(
                    root: RawMacAccessibilitySnapshotNode(
                        role: "AXWindow",
                        title: "Music",
                        frame: WindowTargetBounds(x: 0, y: 0, width: 500, height: 400),
                        children: [
                            RawMacAccessibilitySnapshotNode(
                                role: "AXButton",
                                title: "Play",
                                frame: WindowTargetBounds(x: 40, y: 60, width: 80, height: 34),
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
                        title: "Notes",
                        frame: WindowTargetBounds(x: 500, y: 0, width: 500, height: 400),
                        children: [
                            RawMacAccessibilitySnapshotNode(
                                role: "AXButton",
                                title: "New Note",
                                frame: WindowTargetBounds(x: 520, y: 60, width: 100, height: 34),
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
                            appName: "Music",
                            bundleIdentifier: "com.apple.Music",
                            bounds: WindowTargetBounds(x: 0, y: 0, width: 500, height: 400)
                        ),
                        MacWindowProviderWindow(
                            windowID: 2,
                            processID: 200,
                            appName: "Notes",
                            bundleIdentifier: "com.apple.Notes",
                            bounds: WindowTargetBounds(x: 500, y: 0, width: 500, height: 400)
                        )
                    ],
                    frontmostProcessID: 100
                )
            ),
            capturer: capturer,
            screenProvider: DebugUIFixtureScreenProvider(screens: [screen]),
            currentProcessID: 999
        )

        let results = try service.inspect(
            scope: .main,
            minConfidence: 0.25,
            targetBundleIdentifiers: ["com.apple.Music"],
            targetAppNames: ["Music"]
        )

        #expect(capturer.capturedWindowIDs == [1])
        #expect(results.first?.frame.elements.map(\.label).contains("Music") == true)
        #expect(results.first?.frame.elements.map(\.label).contains("Play") == true)
        #expect(results.first?.frame.elements.map(\.label).contains("Notes") == false)
        #expect(results.first?.frame.elements.map(\.label).contains("New Note") == false)
    }

    @Test
    func accessibilityInspectionRequiresFocusedMusicWhenRequested() throws {
        let screen = DebugUIScreenMetadata(
            screenID: 1,
            appKitFrame: HotLoopRect(x: 0, y: 0, width: 1000, height: 800, space: .screen),
            captureFrame: WindowTargetBounds(x: 0, y: 0, width: 1000, height: 800)
        )
        let capturer = DebugUIFakeAccessibilityCapturer(
            treesByWindowID: [
                1: MacAccessibilitySnapshotTreeBuilder.build(
                    root: RawMacAccessibilitySnapshotNode(
                        role: "AXWindow",
                        title: "Music",
                        frame: WindowTargetBounds(x: 0, y: 0, width: 500, height: 400),
                        children: [
                            RawMacAccessibilitySnapshotNode(
                                role: "AXButton",
                                title: "Play",
                                frame: WindowTargetBounds(x: 40, y: 60, width: 80, height: 34),
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
                            appName: "Music",
                            bundleIdentifier: "com.apple.Music",
                            bounds: WindowTargetBounds(x: 0, y: 0, width: 500, height: 400)
                        ),
                        MacWindowProviderWindow(
                            windowID: 2,
                            processID: 200,
                            appName: "Notes",
                            bundleIdentifier: "com.apple.Notes",
                            bounds: WindowTargetBounds(x: 500, y: 0, width: 500, height: 400)
                        )
                    ],
                    frontmostProcessID: 200,
                    focusedWindowID: 2
                )
            ),
            capturer: capturer,
            screenProvider: DebugUIFixtureScreenProvider(screens: [screen]),
            currentProcessID: 999
        )

        let results = try service.inspect(
            scope: .main,
            minConfidence: 0.25,
            frontmostOnly: true,
            focusedOnly: true,
            targetBundleIdentifiers: ["com.apple.Music"],
            targetAppNames: ["Music"]
        )

        #expect(results.isEmpty)
        #expect(capturer.capturedWindowIDs.isEmpty)
    }

    @Test
    func accessibilityInspectionScalesAXBoxesToDownsampledScreenshotPixels() throws {
        let screen = DebugUIScreenMetadata(
            screenID: 1,
            appKitFrame: HotLoopRect(x: 0, y: 0, width: 1000, height: 800, space: .screen),
            captureFrame: WindowTargetBounds(x: 0, y: 0, width: 1000, height: 800)
        )
        let capturer = DebugUIFakeAccessibilityCapturer(
            tree: MacAccessibilitySnapshotTreeBuilder.build(
                root: RawMacAccessibilitySnapshotNode(
                    role: "AXWindow",
                    title: "Music",
                    frame: WindowTargetBounds(x: 100, y: 200, width: 500, height: 300),
                    children: [
                        RawMacAccessibilitySnapshotNode(
                            role: "AXButton",
                            title: "Play",
                            frame: WindowTargetBounds(x: 120, y: 240, width: 80, height: 32),
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
                            bundleIdentifier: "com.apple.Music",
                            bounds: WindowTargetBounds(x: 100, y: 200, width: 500, height: 300)
                        )
                    ],
                    frontmostProcessID: 100
                )
            ),
            capturer: capturer,
            screenProvider: DebugUIFixtureScreenProvider(screens: [screen]),
            screenCapturer: DebugUIFixtureScreenCapturer(
                snapshots: [
                    DebugUIScreenCaptureSnapshot(
                        screenID: 1,
                        screenFrame: screen.appKitFrame,
                        pixelSize: HotLoopSize(width: 500, height: 400, space: .screen),
                        pngData: Data(),
                        fingerprint: "downsampled"
                    )
                ]
            ),
            currentProcessID: 999
        )

        let results = try service.inspect(scope: .main, minConfidence: 0.25)
        let window = try #require(results.first?.frame.elements.first { $0.id == "window-1" })
        let play = try #require(results.first?.frame.elements.first { $0.label == "Play" })

        #expect(window.bbox == DebugUIBoundingBox(x: 50, y: 100, width: 250, height: 150))
        #expect(play.bbox == DebugUIBoundingBox(x: 60, y: 120, width: 40, height: 16))
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
        #expect(results.first?.frame.elements.map(\.id) == ["window-1", "ax-1-ax-1.1"])
        #expect(results.first?.frame.elements.map(\.label) == ["Front", "Visible"])
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
    func accessibilityInspectionFiltersLargeTextAreasButKeepsUsableInputs() throws {
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
        #expect(results.first?.frame.elements.map(\.id) == ["window-1", "ax-1-ax-1.2"])
        #expect(results.first?.frame.elements.last?.type == .input)
        #expect(results.first?.frame.elements.last?.label == "Search")
        #expect(results.first?.frame.elements.first?.bbox == DebugUIBoundingBox(
            x: 0,
            y: 0,
            width: 1000,
            height: 800
        ))
    }

    @Test
    func accessibilityInspectionDrawsMusicWindowAndClickableCardTile() throws {
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

        #expect(results.first?.frame.elements.map(\.id) == ["window-1", "ax-1-ax-1.1"])
        #expect(results.first?.frame.elements.first?.bbox == DebugUIBoundingBox(
            x: 50,
            y: 253,
            width: 1530,
            height: 930
        ))
        #expect(results.first?.frame.elements.last?.type == .button)
        #expect(results.first?.frame.elements.last?.label == "K-Pop Hits")
        #expect(results.first?.frame.elements.last?.bbox == DebugUIBoundingBox(
            x: 436,
            y: 370,
            width: 160,
            height: 240
        ))
    }

    @Test
    func accessibilityInspectionDrawsMovedMusicWindowAndClickableCardTile() throws {
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

        #expect(results.first?.frame.elements.map(\.id) == ["ax-1-ax-1.1", "window-1"])
        #expect(results.first?.frame.elements.first?.type == .button)
        #expect(results.first?.frame.elements.first?.label == "K-Pop Hits")
        #expect(results.first?.frame.elements.first?.bbox == DebugUIBoundingBox(
            x: 436,
            y: 370,
            width: 160,
            height: 240
        ))
        #expect(results.first?.frame.elements.last?.bbox == DebugUIBoundingBox(
            x: 80,
            y: 400,
            width: 1530,
            height: 930
        ))
    }

    @Test
    func accessibilityInspectionDrawsWholeSidebarRowsFromDescendantText() throws {
        let screen = DebugUIScreenMetadata(
            screenID: 1,
            appKitFrame: HotLoopRect(x: 0, y: 0, width: 800, height: 700, space: .screen),
            captureFrame: WindowTargetBounds(x: 0, y: 0, width: 800, height: 700)
        )
        let capturer = DebugUIFakeAccessibilityCapturer(
            tree: MacAccessibilitySnapshotTreeBuilder.build(
                root: RawMacAccessibilitySnapshotNode(
                    role: "AXWindow",
                    title: "Notes",
                    frame: WindowTargetBounds(x: 0, y: 0, width: 800, height: 700),
                    children: [
                        RawMacAccessibilitySnapshotNode(
                            role: "AXRow",
                            frame: WindowTargetBounds(x: 10, y: 240, width: 190, height: 52),
                            isEnabled: true,
                            actions: ["AXPress"],
                            children: [
                                RawMacAccessibilitySnapshotNode(
                                    role: "AXStaticText",
                                    valueSummary: "Improve UI element detection",
                                    frame: WindowTargetBounds(x: 32, y: 252, width: 140, height: 18)
                                ),
                                RawMacAccessibilitySnapshotNode(
                                    role: "AXStaticText",
                                    valueSummary: "10:07 AM",
                                    frame: WindowTargetBounds(x: 32, y: 272, width: 70, height: 16)
                                )
                            ]
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
                            windowID: 7,
                            processID: 100,
                            appName: "Notes",
                            bounds: WindowTargetBounds(x: 0, y: 0, width: 800, height: 700)
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
        let row = try #require(results.first?.frame.elements.first { $0.type == .listItem })

        #expect(row.label == "Improve UI element detection 10:07 AM")
        #expect(row.bbox == DebugUIBoundingBox(x: 10, y: 240, width: 190, height: 52))
    }

    @Test
    func accessibilityInspectionDrawsNativeMusicTilesFromAXGroups() throws {
        let screen = DebugUIScreenMetadata(
            screenID: 1,
            appKitFrame: HotLoopRect(x: 0, y: 0, width: 1200, height: 900, space: .screen),
            captureFrame: WindowTargetBounds(x: 0, y: 0, width: 1200, height: 900)
        )
        let capturer = DebugUIFakeAccessibilityCapturer(
            tree: MacAccessibilitySnapshotTreeBuilder.build(
                root: RawMacAccessibilitySnapshotNode(
                    role: "AXWindow",
                    title: "Music",
                    frame: WindowTargetBounds(x: 0, y: 0, width: 1200, height: 900),
                    children: [
                        RawMacAccessibilitySnapshotNode(
                            role: "AXGroup",
                            frame: WindowTargetBounds(x: 560, y: 540, width: 250, height: 260),
                            isEnabled: true,
                            actions: [],
                            children: [
                                RawMacAccessibilitySnapshotNode(
                                    role: "AXImage",
                                    label: "New This Week artwork",
                                    frame: WindowTargetBounds(x: 560, y: 540, width: 250, height: 220)
                                ),
                                RawMacAccessibilitySnapshotNode(
                                    role: "AXStaticText",
                                    valueSummary: "New This Week",
                                    frame: WindowTargetBounds(x: 560, y: 770, width: 160, height: 24)
                                )
                            ]
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
                            windowID: 8,
                            processID: 100,
                            appName: "Music",
                            bounds: WindowTargetBounds(x: 0, y: 0, width: 1200, height: 900)
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
        let tile = try #require(results.first?.frame.elements.first { $0.label.contains("New This Week") })

        #expect(tile.type == .listItem)
        #expect(tile.bbox == DebugUIBoundingBox(x: 560, y: 540, width: 250, height: 260))
        #expect(tile.metadata.values.contains("readOnlyEvidence") || tile.metadata.values.contains("cursorVisualization"))
    }

    @Test
    func accessibilityInspectionDrawsMusicTileTextAndImagesFromBroadAXNodes() throws {
        let screen = DebugUIScreenMetadata(
            screenID: 1,
            appKitFrame: HotLoopRect(x: 0, y: 0, width: 1200, height: 900, space: .screen),
            captureFrame: WindowTargetBounds(x: 0, y: 0, width: 1200, height: 900)
        )
        let capturer = DebugUIFakeAccessibilityCapturer(
            tree: MacAccessibilitySnapshotTreeBuilder.build(
                root: RawMacAccessibilitySnapshotNode(
                    role: "AXWindow",
                    title: "Music",
                    frame: WindowTargetBounds(x: 0, y: 0, width: 1200, height: 900),
                    children: [
                        RawMacAccessibilitySnapshotNode(
                            role: "AXImage",
                            label: "Happy Hits artwork",
                            frame: WindowTargetBounds(x: 530, y: 175, width: 290, height: 290)
                        ),
                        RawMacAccessibilitySnapshotNode(
                            role: "AXStaticText",
                            valueSummary: "Happy Hits",
                            frame: WindowTargetBounds(x: 530, y: 482, width: 120, height: 24)
                        ),
                        RawMacAccessibilitySnapshotNode(
                            role: "AXStaticText",
                            valueSummary: "Apple Music Feel Good",
                            frame: WindowTargetBounds(x: 530, y: 512, width: 210, height: 22)
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
                            windowID: 9,
                            processID: 100,
                            appName: "Music",
                            bounds: WindowTargetBounds(x: 0, y: 0, width: 1200, height: 900)
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
        let labels = results.first?.frame.elements.map(\.label) ?? []

        #expect(labels.contains { $0.contains("Happy Hits artwork") })
        #expect(labels.contains { $0.contains("Happy Hits") })
        #expect(labels.contains { $0.contains("Apple Music Feel Good") })
    }

    @Test
    func accessibilityProgressiveInspectionPublishesBroadAXNodes() throws {
        let screen = DebugUIScreenMetadata(
            screenID: 1,
            appKitFrame: HotLoopRect(x: 0, y: 0, width: 1200, height: 900, space: .screen),
            captureFrame: WindowTargetBounds(x: 0, y: 0, width: 1200, height: 900)
        )
        let tileNodes = (0..<8).map { index in
            RawMacAccessibilitySnapshotNode(
                role: "AXStaticText",
                valueSummary: "Music tile \(index + 1)",
                frame: WindowTargetBounds(x: 530, y: 180 + Double(index * 34), width: 180, height: 24)
            )
        }
        let capturer = DebugUIFakeAccessibilityCapturer(
            tree: MacAccessibilitySnapshotTreeBuilder.build(
                root: RawMacAccessibilitySnapshotNode(
                    role: "AXWindow",
                    title: "Music",
                    frame: WindowTargetBounds(x: 0, y: 0, width: 1200, height: 900),
                    children: tileNodes
                ),
                limits: MacAccessibilitySnapshotLimits(maxDepth: 6)
            )
        )
        let service = DebugUIAccessibilityInspectionService(
            windowResolver: MacWindowResolver(
                provider: DebugUIFixtureWindowProvider(
                    windows: [
                        MacWindowProviderWindow(
                            windowID: 10,
                            processID: 100,
                            appName: "Music",
                            bounds: WindowTargetBounds(x: 0, y: 0, width: 1200, height: 900)
                        )
                    ],
                    frontmostProcessID: 100
                )
            ),
            capturer: capturer,
            screenProvider: DebugUIFixtureScreenProvider(screens: [screen]),
            currentProcessID: 999
        )
        var partialBatches: [[DebugUIAccessibilityInspectionResult]] = []

        let finalResults = try service.inspectProgressively(
            scope: .main,
            minConfidence: 0.25,
            onPartialResults: { partialBatches.append($0) }
        )
        let partialLabels = partialBatches.flatMap { batch in
            batch.flatMap { $0.frame.elements.map(\.label) }
        }
        let finalLabels = finalResults.flatMap { $0.frame.elements.map(\.label) }

        #expect(partialLabels.contains("Music tile 8"))
        #expect(finalLabels.contains("Music tile 8"))
    }

    private func element(
        id: String,
        label: String,
        x: Double,
        y: Double,
        width: Double = 80,
        height: Double = 30,
        type: DebugUIElementType = .button,
        metadata: [String: String] = [:]
    ) -> DebugUIElement {
        DebugUIElement(
            id: id,
            type: type,
            label: label,
            bbox: DebugUIBoundingBox(x: x, y: y, width: width, height: height),
            confidence: 0.9,
            metadata: metadata
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("donkey-debug-ui-tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class DebugUIFakeAccessibilityCapturer: MacAccessibilitySnapshotProgressCapturing, @unchecked Sendable {
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

    func captureTree(
        target: MacWindowTargetCandidate,
        limits: MacAccessibilitySnapshotLimits,
        onNode: (MacAccessibilitySnapshotNode) -> Void
    ) throws -> MacAccessibilitySnapshotTree {
        let tree = try captureTree(target: target, limits: limits)
        emit(tree.root, to: onNode)
        return tree
    }

    private func emit(
        _ node: MacAccessibilitySnapshotNode,
        to onNode: (MacAccessibilitySnapshotNode) -> Void
    ) {
        onNode(node)
        for child in node.children {
            emit(child, to: onNode)
        }
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

private struct DebugUIFixtureScreenCapturer: DebugUIScreenCapturing {
    var snapshots: [DebugUIScreenCaptureSnapshot]

    func captureScreens(
        scope: DebugUIInspectionScreenScope
    ) throws -> [DebugUIScreenCaptureSnapshot] {
        switch scope {
        case .main:
            return snapshots.prefix(1).map { $0 }
        case .all:
            return snapshots
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
