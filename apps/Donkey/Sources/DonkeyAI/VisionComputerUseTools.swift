import AppKit
import CoreGraphics
import DonkeyContracts
import DonkeyHarness
import DonkeyRuntime
import Foundation

/// Vision computer-use tools registered into a `HarnessToolRegistry` so the model can drive the
/// FRONTMOST app by *choosing* when to look and when to act — capture and analyze the screen on
/// demand, then click / type / press a key against the elements that capture detected.
///
/// These are real harness tools (descriptors, permissions, safety class, guarded execution), but
/// unlike the catalog's placeholder `element.perform`/`text.enter` they perform real input. They are
/// scoped to one frontmost target and built fresh per drive, so they live in the vision loop's own
/// registry rather than the global `BuiltInHarnessToolCatalog` (whose upfront planner would otherwise
/// emit them with no executor on non-vision paths).
///
/// Safety mirrors `VisionActionDriver`: every input action re-checks that the target is frontmost at
/// the instant of the click/keystroke, so input never lands on a window the user switched to during a
/// model round-trip. Click coordinates are mapped from the parse image's pixel space through the
/// window's *current* bounds, re-resolved at action time in case the window moved between turns.
@MainActor
public final class VisionComputerUseToolProvider {
    /// Tool names this provider registers. Stable identifiers the loop's planner names per turn.
    public enum ToolName {
        public static let captureAndAnalyze = "vision.capture"
        public static let click = "vision.click"
        // Keyboard input is modality-agnostic (shared by AX and vision), so it keeps generic names.
        public static let typeText = "text.enter"
        public static let pressKey = "keyboard.press"
    }

    public struct CaptureMetrics: Sendable {
        public var usedCache: Bool
        public var parseMS: Double
        public var elementCount: Int
    }

    /// The app this run is currently driving — shared with the AX/pointer providers and mutable when an
    /// observe step retargets it. Read per call (via the computed accessors) so capture/click/keystroke
    /// always resolve against the app the planner last looked at, not one pinned for the whole run.
    let target: HarnessTargetContext
    var appName: String { target.appName }
    var appKey: String { target.appKey }
    var bundleIdentifier: String? { target.bundleIdentifier }
    let executionPreference: ExecutionPreference
    let analyzer: any DebugUIInspectionAnalyzing
    let store: ParsedVisionStore
    let minConfidence: Double
    let reuseChangedFractionThreshold: Double
    let capture: VisionActionDriver.ScreenshotCapture
    /// Full-display capture, used by `vision.capture scope=screen` to see things drawn OUTSIDE the
    /// target window — modal confirmation sheets, system dialogs, right-click menus.
    let displayCapture: DisplayCapture
    /// Whole-desktop capture across all displays, used by `vision.capture scope=desktop` — the widest
    /// fallback for when the target isn't on the active display (another monitor, a background window).
    let desktopCapture: DesktopCapture
    let uptimeMS: @Sendable () -> Double

    public typealias DisplayCapture = @MainActor (CGDirectDisplayID) async throws -> CapturedDisplayScreenshot
    public typealias DesktopCapture = @MainActor () async throws -> CapturedDisplayScreenshot

    /// Metrics from the most recent `screen.captureAndAnalyze`, so the loop can roll up parse time
    /// and cache-hit telemetry without re-parsing the tool result.
    public private(set) var lastCaptureMetrics: CaptureMetrics?

    public init(
        target: HarnessTargetContext,
        executionPreference: ExecutionPreference = .foreground,
        analyzer: any DebugUIInspectionAnalyzing,
        store: ParsedVisionStore = .shared,
        minConfidence: Double = 0.25,
        reuseChangedFractionThreshold: Double = VisionComputerUseToolProvider.reuseChangedFractionThreshold,
        capture: @escaping VisionActionDriver.ScreenshotCapture = { try await ScreenCaptureKitWindowScreenshotCapturer().capture(target: $0) },
        displayCapture: @escaping DisplayCapture = { try await ScreenCaptureKitWindowScreenshotCapturer().captureDisplay(displayID: $0) },
        desktopCapture: @escaping DesktopCapture = { try await ScreenCaptureKitWindowScreenshotCapturer().captureDesktop() },
        uptimeMS: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime * 1_000 }
    ) {
        self.target = target
        self.executionPreference = executionPreference
        self.analyzer = analyzer
        self.store = store
        self.minConfidence = minConfidence
        self.reuseChangedFractionThreshold = reuseChangedFractionThreshold
        self.capture = capture
        self.displayCapture = displayCapture
        self.desktopCapture = desktopCapture
        self.uptimeMS = uptimeMS
    }

    public static var descriptors: [HarnessToolDescriptor] {
        [
            HarnessToolDescriptor(
                name: ToolName.captureAndAnalyze,
                pluginID: "core.computer-use.vision",
                summary: "Screenshot and detect UI elements with vision. Three scopes, smallest first: scope=window (default) captures the target window; scope=screen captures the WHOLE display the window is on — use it for things drawn outside the window like a modal confirmation dialog/sheet or a system prompt; scope=desktop captures the ENTIRE desktop across all displays — the fallback when what you need isn't on the active display (another monitor, a background app's window). Widen only as far as you must. Pass app=\"<App Name>\" to capture a specific app and make it the active target for the actions that follow; omit it to capture the current target. vision.click works the same on elements from any scope.",
                inputSchema: [
                    "scope": "\"window\" (default), \"screen\" (whole display) for modals/dialogs, or \"desktop\" (all displays) when the target is off the active screen.",
                    "app": "Optional app name to capture and switch the run's active target to; omit to use the current target."
                ],
                optionalInputKeys: ["scope", "app"],
                outputSchema: ["elements": "Detected element IDs, labels, roles, and click eligibility."],
                requiredPermissions: [.screenCapture],
                safetyClass: .readOnly,
                verificationHints: ["fresh capture reflects the current on-screen state"]
            ),
            HarnessToolDescriptor(
                name: ToolName.click,
                pluginID: "core.computer-use.vision",
                summary: "Click one element returned by vision.capture. Supports right-click (context menus) and double/triple click.",
                inputSchema: [
                    "elementID": "Element ID from the latest screen.captureAndAnalyze.",
                    "button": "\"left\" (default) or \"right\" for a context menu.",
                    "clicks": "1 (default), 2 (double-click), or 3 (triple-click)."
                ],
                optionalInputKeys: ["button", "clicks"],
                requiredPermissions: [.input],
                safetyClass: .guardedInput,
                requiredContext: ["frontmost target", "captured element"],
                verificationHints: ["re-capture to confirm the click changed the screen"]
            ),
            HarnessToolDescriptor(
                name: ToolName.typeText,
                pluginID: "core.computer-use.vision",
                summary: "Type text into the currently focused field.",
                inputSchema: ["text": "Text to type into the focused field."],
                requiredPermissions: [.input],
                safetyClass: .guardedInput,
                requiredContext: ["frontmost target", "focused field"]
            ),
            HarnessToolDescriptor(
                name: ToolName.pressKey,
                pluginID: "core.computer-use.vision",
                summary: "Press one key, optionally chorded with modifiers — e.g. return to submit, or key=c with modifiers=command to copy.",
                inputSchema: [
                    "key": "Key name such as return, tab, escape, an arrow, or a single letter/digit.",
                    "modifiers": "Modifier chord such as \"command\", \"command+shift\", \"option\", \"control\"."
                ],
                optionalInputKeys: ["modifiers"],
                requiredPermissions: [.input],
                safetyClass: .guardedInput,
                requiredContext: ["frontmost target"]
            )
        ]
    }

    public func makeTools() -> [HarnessTool] {
        Self.descriptors.map { descriptor in
            HarnessTool(descriptor: descriptor) { context in
                await self.execute(context)
            }
        }
    }

    private func execute(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        switch context.call.name {
        case ToolName.captureAndAnalyze: return await captureAndAnalyze(context)
        case ToolName.click: return await click(context)
        case ToolName.typeText: return await typeText(context)
        case ToolName.pressKey: return await pressKey(context)
        default:
            return result(context, status: .unknownTool, summary: "Unknown vision tool.", reason: "unknownVisionTool")
        }
    }

    // MARK: - Capture + analyze

    private func captureAndAnalyze(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        // The planner can name an app to look at; that becomes the active target for the actions that
        // follow, so a run can capture and drive any app (or acquire its first one on an app-less run).
        if let requested = trimmed(context.call.input["app"]) {
            retarget(to: requested)
        }
        guard !self.target.isEmpty else {
            return result(context, status: .failed, summary: "No active app to capture. Pass app=\"<App Name>\" to target one, or open the app first.", reason: "noActiveTarget")
        }
        guard let target = AccessibilityObserver.resolveTarget(appName: appName, bundleIdentifier: bundleIdentifier) else {
            return result(context, status: .failed, summary: "No window for \(appName).", reason: "noWindowForApp")
        }
        switch trimmed(context.call.input["scope"])?.lowercased() {
        case "screen": return await captureWideAndAnalyze(context, target: target, scope: "screen")
        case "desktop": return await captureWideAndAnalyze(context, target: target, scope: "desktop")
        default: break
        }
        let shot: CapturedWindowScreenshot
        do {
            shot = try await capture(target)
        } catch {
            return result(context, status: .failed, summary: "Screenshot failed.", reason: "screenshotFailed")
        }

        let signature = ScreenshotSignature.make(fromImageData: shot.pngData)

        var usedCache = false
        var parseMS = 0.0
        let elements: [DebugUIElement]
        let elementImageWidth: Int
        let elementImageHeight: Int

        if let signature,
           let reusable = store.reusableEntry(
               appKey: appKey,
               signature: signature,
               changedFractionThreshold: reuseChangedFractionThreshold
           ) {
            // Reuse an earlier capture from THIS run when the window hasn't changed since (e.g.
            // capture → click → re-capture on an unchanged screen), so the agent doesn't pay for a
            // redundant parse. The entry was written by this same tool below on its last cache miss —
            // nothing parses the screen except this on-demand tool inside a live run.
            usedCache = true
            elements = reusable.elements
            elementImageWidth = reusable.imagePixelWidth
            elementImageHeight = reusable.imagePixelHeight
        } else {
            // Compress only on a cache miss: a reused parse never sends the image, so encoding it
            // before the reuse check would be wasted work on the common reuse path.
            let compressed = ScreenshotCompression.compressedForModel(shot)
            let imageWidth = max(1, Int(compressed.pixelSize.width.rounded()))
            let imageHeight = max(1, Int(compressed.pixelSize.height.rounded()))
            let started = uptimeMS()
            let frame: DebugUIInspectionFrame
            do {
                frame = try await analyzer.inspect(
                    DebugUIInspectionRequest(
                        imageDataURL: compressed.base64DataURL,
                        pixelSize: compressed.pixelSize,
                        minConfidence: minConfidence
                    )
                )
            } catch {
                return result(context, status: .failed, summary: "Vision parse failed.", reason: "visionParseFailed")
            }
            parseMS = uptimeMS() - started
            elements = frame.elements
            elementImageWidth = imageWidth
            elementImageHeight = imageHeight
            if let signature {
                store.store(
                    appKey: appKey,
                    entry: ParsedVisionStore.Entry(
                        signature: signature,
                        elements: frame.elements,
                        imagePixelWidth: imageWidth,
                        imagePixelHeight: imageHeight,
                        capturedAtUptimeMS: uptimeMS()
                    )
                )
            }
        }

        let actionable = elements.filter { $0.bbox.hasPositiveArea }
        let worldElements = actionable.map {
            Self.worldElement(from: $0, imageWidth: elementImageWidth, imageHeight: elementImageHeight)
        }
        lastCaptureMetrics = CaptureMetrics(usedCache: usedCache, parseMS: parseMS, elementCount: worldElements.count)

        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .succeeded,
            summary: "Captured \(worldElements.count) element(s) in \(appName).",
            observations: HarnessObservationDelta(
                focusedApp: appName,
                elements: worldElements,
                facts: [
                    "vision.capture.usedCache": String(usedCache),
                    "vision.capture.parseMS": String(format: "%.0f", parseMS),
                    "vision.capture.elementCount": String(worldElements.count),
                    "lastAcceptedTool": context.call.name
                ]
            ),
            metadata: [
                "usedCache": String(usedCache),
                "parseMS": String(format: "%.0f", parseMS),
                "elementCount": String(worldElements.count)
            ]
        )
    }

    /// Capture wider than the target window and analyze it. `scope=screen` grabs the whole display the
    /// window sits on (modal sheets, system prompts, right-click menus drawn outside the window);
    /// `scope=desktop` grabs the entire desktop across all displays (a target on another monitor or a
    /// background app). The capture's screen-space frame is stamped onto each element as its mapping
    /// `region`, so a click maps the element's box through that rect exactly as a window capture maps
    /// through the window rect. No cache: these surfaces are transient, so each wide capture parses fresh.
    private func captureWideAndAnalyze(
        _ context: HarnessToolExecutionContext,
        target: MacWindowTargetCandidate,
        scope: String
    ) async -> HarnessToolResult {
        let shot: CapturedDisplayScreenshot
        do {
            switch scope {
            case "desktop": shot = try await desktopCapture()
            default: shot = try await displayCapture(Self.displayID(forWindowBounds: target.bounds))
            }
        } catch {
            let label = scope == "desktop" ? "Full-desktop" : "Full-screen"
            return result(context, status: .failed, summary: "\(label) capture failed.", reason: "screenCaptureFailed")
        }
        let asWindow = CapturedWindowScreenshot(
            pngData: shot.pngData,
            imageWidth: shot.imageWidth,
            imageHeight: shot.imageHeight,
            captureMethod: .boundsCrop,
            coordinateSpace: "display.points"
        )
        let compressed = ScreenshotCompression.compressedForModel(asWindow)
        let imageWidth = max(1, Int(compressed.pixelSize.width.rounded()))
        let imageHeight = max(1, Int(compressed.pixelSize.height.rounded()))
        let started = uptimeMS()
        let frame: DebugUIInspectionFrame
        do {
            frame = try await analyzer.inspect(
                DebugUIInspectionRequest(
                    imageDataURL: compressed.base64DataURL,
                    pixelSize: compressed.pixelSize,
                    minConfidence: minConfidence
                )
            )
        } catch {
            return result(context, status: .failed, summary: "Vision parse failed.", reason: "visionParseFailed")
        }
        let parseMS = uptimeMS() - started
        let region = WindowTargetBounds(
            x: Double(shot.displayBounds.minX),
            y: Double(shot.displayBounds.minY),
            width: Double(shot.displayBounds.width),
            height: Double(shot.displayBounds.height)
        )
        let worldElements = frame.elements
            .filter { $0.bbox.hasPositiveArea }
            .map { Self.worldElement(from: $0, imageWidth: imageWidth, imageHeight: imageHeight, region: region) }
        lastCaptureMetrics = CaptureMetrics(usedCache: false, parseMS: parseMS, elementCount: worldElements.count)

        let where_ = scope == "desktop" ? "the whole desktop" : "the full screen"
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .succeeded,
            summary: "Captured \(worldElements.count) element(s) across \(where_).",
            observations: HarnessObservationDelta(
                focusedApp: appName,
                elements: worldElements,
                facts: [
                    "vision.capture.scope": scope,
                    "vision.capture.usedCache": "false",
                    "vision.capture.parseMS": String(format: "%.0f", parseMS),
                    "vision.capture.elementCount": String(worldElements.count),
                    "lastAcceptedTool": context.call.name
                ]
            ),
            metadata: [
                "scope": scope,
                "usedCache": "false",
                "parseMS": String(format: "%.0f", parseMS),
                "elementCount": String(worldElements.count)
            ]
        )
    }

    /// The display whose frame contains the target window's center (the one a modal will appear on),
    /// falling back to the main display. Window bounds and `CGDisplayBounds` share the same top-left
    /// global coordinate space, so the center point can be tested directly.
    nonisolated static func displayID(forWindowBounds bounds: WindowTargetBounds) -> CGDirectDisplayID {
        let center = CGPoint(x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2)
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(center, 8, &ids, &count) == .success, count > 0, ids[0] != 0 {
            return ids[0]
        }
        return CGMainDisplayID()
    }

    // MARK: - Guarded input

    private func click(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        guard let elementID = trimmed(context.call.input["elementID"]) else {
            return result(context, status: .invalidInput, summary: "element.click requires an elementID.", reason: "missingElementID")
        }
        guard let element = context.worldModel.elements.first(where: { $0.id == elementID }) else {
            return result(context, status: .failed, summary: "Element \(elementID) is not in the latest capture.", reason: "elementNotFound")
        }
        guard element.isActionEligible,
              let geometry = Self.geometry(from: element.metadata) else {
            return result(context, status: .failed, summary: "Element \(elementID) cannot be clicked.", reason: "elementNotClickable")
        }
        guard let target = AccessibilityObserver.resolveTarget(appName: appName, bundleIdentifier: bundleIdentifier) else {
            return result(context, status: .failed, summary: "No window for \(appName).", reason: "noWindowForApp")
        }
        guard let routing = await inputRouting(for: target) else {
            return notFrontmost(context)
        }
        let inputTarget = routing.inputTarget
        let normalized = Self.normalizedCenter(
            bbox: geometry.bbox,
            imageWidth: geometry.imageWidth,
            imageHeight: geometry.imageHeight
        )
        let plan = VisionActionPlanner.PlannedAction(
            action: "click", x: normalized.x, y: normalized.y, text: nil, reason: nil, screenPoint: nil
        )
        // A screen-scope element carries the display rect it was detected in; map through that. A
        // window-scope element has no region, so map through the window's CURRENT bounds (re-resolved
        // above) to stay correct if the window moved between the capture and this click.
        let mappingRegion = geometry.region ?? target.bounds
        guard let point = VisionActionPlanner.screenPoint(action: plan, window: mappingRegion) else {
            return result(context, status: .failed, summary: "Could not map element \(elementID) to a screen point.", reason: "unmappablePoint")
        }
        let button: MacPointerInput.Button = context.call.input["button"] == "right" ? .right : .left
        let clicks = context.call.input["clicks"].flatMap(Int.init) ?? 1
        MacPointerInput.moveAndClick(at: point, button: button, clickCount: clicks, target: inputTarget)
        let clickWord = button == .right ? "Right-clicked" : (clicks >= 3 ? "Triple-clicked" : (clicks == 2 ? "Double-clicked" : "Clicked"))
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .succeeded,
            summary: "\(clickWord) \(element.label.isEmpty ? elementID : element.label) at screen (\(Int(point.x)),\(Int(point.y))).",
            observations: HarnessObservationDelta(facts: ["lastAcceptedTool": context.call.name]),
            metadata: [
                "elementID": elementID,
                "label": element.label,
                "screenPoint": "\(Int(point.x)),\(Int(point.y))"
            ]
        )
    }

    private func typeText(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        guard let text = context.call.input["text"], !text.isEmpty else {
            return result(context, status: .invalidInput, summary: "text.enter requires non-empty text.", reason: "missingText")
        }
        guard let target = AccessibilityObserver.resolveTarget(appName: appName, bundleIdentifier: bundleIdentifier),
              let routing = await inputRouting(for: target) else {
            return notFrontmost(context)
        }
        MacKeyboardInput.type(text, target: routing.inputTarget)
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .succeeded,
            summary: "Typed \(text.count) character(s).",
            observations: HarnessObservationDelta(facts: ["lastAcceptedTool": context.call.name]),
            metadata: ["characterCount": String(text.count)]
        )
    }

    private func pressKey(_ context: HarnessToolExecutionContext) async -> HarnessToolResult {
        guard let key = trimmed(context.call.input["key"]) else {
            return result(context, status: .invalidInput, summary: "keyboard.press requires a key.", reason: "missingKey")
        }
        guard let target = AccessibilityObserver.resolveTarget(appName: appName, bundleIdentifier: bundleIdentifier),
              let routing = await inputRouting(for: target) else {
            return notFrontmost(context)
        }
        let modifiers = trimmed(context.call.input["modifiers"]).map { [$0] } ?? []
        MacKeyboardInput.pressKey(key, modifiers: modifiers, target: routing.inputTarget)
        let chord = modifiers.first.map { "\($0)+\(key)" } ?? key
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .succeeded,
            summary: "Pressed \(chord).",
            observations: HarnessObservationDelta(facts: ["lastAcceptedTool": context.call.name]),
            metadata: ["key": key, "modifiers": modifiers.joined(separator: "+")]
        )
    }

    // MARK: - Element ⇄ world-model mapping

    /// Maps a vision-detected element into a world-model element, stashing the bbox and parse-image
    /// pixel size in metadata so a later `element.click` can re-derive the screen point against the
    /// window's current bounds.
    nonisolated static func worldElement(
        from element: DebugUIElement,
        imageWidth: Int,
        imageHeight: Int
    ) -> HarnessWorldElement {
        HarnessWorldElement(
            id: element.id,
            label: element.label,
            role: element.type.rawValue,
            isActionEligible: element.bbox.hasPositiveArea,
            actions: ["click"],
            metadata: [
                "vision.bbox.x": String(element.bbox.x),
                "vision.bbox.y": String(element.bbox.y),
                "vision.bbox.width": String(element.bbox.width),
                "vision.bbox.height": String(element.bbox.height),
                "vision.image.width": String(imageWidth),
                "vision.image.height": String(imageHeight),
                "vision.confidence": String(element.confidence)
            ]
        )
    }

    /// Screen-scope variant: same mapping metadata plus the display rect the image covered, so a later
    /// `vision.click` maps the element's box through that display rect instead of the window's bounds.
    nonisolated static func worldElement(
        from element: DebugUIElement,
        imageWidth: Int,
        imageHeight: Int,
        region: WindowTargetBounds
    ) -> HarnessWorldElement {
        let base = worldElement(from: element, imageWidth: imageWidth, imageHeight: imageHeight)
        var metadata = base.metadata
        metadata["vision.region.x"] = String(region.x)
        metadata["vision.region.y"] = String(region.y)
        metadata["vision.region.width"] = String(region.width)
        metadata["vision.region.height"] = String(region.height)
        metadata["vision.scope"] = "screen"
        return HarnessWorldElement(
            id: base.id,
            label: base.label,
            role: base.role,
            isActionEligible: base.isActionEligible,
            actions: base.actions,
            metadata: metadata
        )
    }

    struct ElementGeometry: Sendable {
        var bbox: DebugUIBoundingBox
        var imageWidth: Int
        var imageHeight: Int
        /// The screen-space rect the parse image covered, for a `scope=screen` capture. nil for a
        /// window capture, where the click maps through the window's re-resolved bounds instead.
        var region: WindowTargetBounds?
    }

    nonisolated static func geometry(from metadata: [String: String]) -> ElementGeometry? {
        guard let x = metadata["vision.bbox.x"].flatMap(Double.init),
              let y = metadata["vision.bbox.y"].flatMap(Double.init),
              let width = metadata["vision.bbox.width"].flatMap(Double.init),
              let height = metadata["vision.bbox.height"].flatMap(Double.init),
              let imageWidth = metadata["vision.image.width"].flatMap(Int.init),
              let imageHeight = metadata["vision.image.height"].flatMap(Int.init) else {
            return nil
        }
        var region: WindowTargetBounds?
        if let rx = metadata["vision.region.x"].flatMap(Double.init),
           let ry = metadata["vision.region.y"].flatMap(Double.init),
           let rw = metadata["vision.region.width"].flatMap(Double.init),
           let rh = metadata["vision.region.height"].flatMap(Double.init) {
            region = WindowTargetBounds(x: rx, y: ry, width: rw, height: rh)
        }
        return ElementGeometry(
            bbox: DebugUIBoundingBox(x: x, y: y, width: width, height: height),
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            region: region
        )
    }

    // MARK: - Vision-grounding geometry

    /// Below this fraction of changed screenshot grid cells we treat the window as unchanged and reuse
    /// the cached parse instead of paying for another vision call.
    public static let reuseChangedFractionThreshold = 0.02

    /// The element box center expressed in Gemini's 0–1000 normalized image space, so the shared
    /// `VisionActionPlanner.screenPoint` maps it into the window exactly as it does for raw-coordinate
    /// planning. Pure mapping, extracted so it is unit-testable without any capture or network.
    nonisolated static func normalizedCenter(
        bbox: DebugUIBoundingBox,
        imageWidth: Int,
        imageHeight: Int
    ) -> (x: Double, y: Double) {
        let width = Double(max(1, imageWidth))
        let height = Double(max(1, imageHeight))
        let centerX = bbox.x + bbox.width / 2
        let centerY = bbox.y + bbox.height / 2
        return (
            x: centerX / width * VisionActionPlanner.normalizedCoordinateScale,
            y: centerY / height * VisionActionPlanner.normalizedCoordinateScale
        )
    }

    // MARK: - Helpers

    /// How input should reach the resolved target.
    private enum InputRouting {
        /// Deliver to the pinned target cursor-neutrally (no focus steal).
        case background(InputTarget)
        /// The target was brought frontmost; deliver via the HID tap as before.
        case foreground

        /// The pinned target for background delivery, or nil for the foreground HID path.
        var inputTarget: InputTarget? {
            if case .background(let target) = self { return target }
            return nil
        }
    }

    /// Decides how to deliver input to `target`: a pinned background target (no cursor move, no app
    /// raise) when the turn asked for background and the surface is safe, otherwise foreground after one
    /// recovery activation. Returns nil only when a required foreground activation failed.
    private func inputRouting(for target: MacWindowTargetCandidate) async -> InputRouting? {
        switch TargetActionGuard.resolve(candidate: target, preference: executionPreference, lane: .pidEventPost) {
        case .background(let inputTarget):
            return .background(inputTarget)
        case .foreground:
            return await ensureFrontmost(target) ? .foreground : nil
        }
    }

    /// Frontmost check with one recovery activation of the target app (never any other app).
    private func ensureFrontmost(_ target: MacWindowTargetCandidate) async -> Bool {
        await TargetFocusRecovery.ensureFrontmost(processID: pid_t(target.processID))
    }

    private func notFrontmost(_ context: HarnessToolExecutionContext) -> HarnessToolResult {
        result(
            context,
            status: .failed,
            summary: "\(appName) is not frontmost; \(TargetFocusRecovery.frontmostAppName()) is in front and refocusing failed.",
            reason: "targetNotFrontmost"
        )
    }

    /// Switch the run's active target to `requestedApp`. Resolves it to a running window's exact identity
    /// when open; otherwise pins it by name so a re-capture after the planner launches it resolves cleanly.
    private func retarget(to requestedApp: String) {
        if let resolved = AccessibilityObserver.resolveTarget(appName: requestedApp, bundleIdentifier: nil) {
            target.retarget(appName: resolved.appName ?? requestedApp, bundleIdentifier: resolved.bundleIdentifier)
        } else {
            target.retarget(appName: requestedApp, bundleIdentifier: nil)
        }
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func result(
        _ context: HarnessToolExecutionContext,
        status: HarnessToolResultStatus,
        summary: String,
        reason: String
    ) -> HarnessToolResult {
        HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: status,
            summary: summary,
            metadata: ["reason": reason]
        )
    }
}
