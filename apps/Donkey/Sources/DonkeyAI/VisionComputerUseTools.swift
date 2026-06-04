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

    let appName: String
    let appKey: String
    let bundleIdentifier: String?
    let analyzer: any DebugUIInspectionAnalyzing
    let store: ParsedVisionStore
    let minConfidence: Double
    let reuseChangedFractionThreshold: Double
    let capture: VisionActionDriver.ScreenshotCapture
    let uptimeMS: @Sendable () -> Double

    /// Metrics from the most recent `screen.captureAndAnalyze`, so the loop can roll up parse time
    /// and cache-hit telemetry without re-parsing the tool result.
    public private(set) var lastCaptureMetrics: CaptureMetrics?

    public init(
        appName: String,
        appKey: String,
        bundleIdentifier: String?,
        analyzer: any DebugUIInspectionAnalyzing,
        store: ParsedVisionStore = .shared,
        minConfidence: Double = 0.25,
        reuseChangedFractionThreshold: Double = VisionComputerUseToolProvider.reuseChangedFractionThreshold,
        capture: @escaping VisionActionDriver.ScreenshotCapture = { try await ScreenCaptureKitWindowScreenshotCapturer().capture(target: $0) },
        uptimeMS: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime * 1_000 }
    ) {
        self.appName = appName
        self.appKey = appKey
        self.bundleIdentifier = bundleIdentifier
        self.analyzer = analyzer
        self.store = store
        self.minConfidence = minConfidence
        self.reuseChangedFractionThreshold = reuseChangedFractionThreshold
        self.capture = capture
        self.uptimeMS = uptimeMS
    }

    public static var descriptors: [HarnessToolDescriptor] {
        [
            HarnessToolDescriptor(
                name: ToolName.captureAndAnalyze,
                pluginID: "core.computer-use.vision",
                summary: "Screenshot the frontmost window and detect its UI elements with vision. Use when Accessibility is missing or insufficient (canvas/Electron content).",
                outputSchema: ["elements": "Detected element IDs, labels, roles, and click eligibility."],
                requiredPermissions: [.screenCapture],
                safetyClass: .readOnly,
                verificationHints: ["fresh capture reflects the current on-screen state"]
            ),
            HarnessToolDescriptor(
                name: ToolName.click,
                pluginID: "core.computer-use.vision",
                summary: "Click one element returned by vision.capture.",
                inputSchema: ["elementID": "Element ID from the latest screen.captureAndAnalyze."],
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
                summary: "Press one key, e.g. return to submit.",
                inputSchema: ["key": "Key name such as return, tab, escape, or an arrow."],
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
        guard let target = AccessibilityObserver.resolveTarget(appName: appName, bundleIdentifier: bundleIdentifier) else {
            return result(context, status: .failed, summary: "No window for \(appName).", reason: "noWindowForApp")
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
            usedCache = true
            elements = reusable.elements
            elementImageWidth = reusable.imagePixelWidth
            elementImageHeight = reusable.imagePixelHeight
        } else {
            // Compress only on a cache miss: a reused parse never sends the image, so encoding it
            // before the reuse check would be wasted work on the common warm-cache path.
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
        guard isFrontmost(target) else {
            return result(context, status: .failed, summary: "\(appName) is not frontmost.", reason: "targetNotFrontmost")
        }
        let normalized = Self.normalizedCenter(
            bbox: geometry.bbox,
            imageWidth: geometry.imageWidth,
            imageHeight: geometry.imageHeight
        )
        let plan = VisionActionPlanner.PlannedAction(
            action: "click", x: normalized.x, y: normalized.y, text: nil, reason: nil, screenPoint: nil
        )
        guard let point = VisionActionPlanner.screenPoint(action: plan, window: target.bounds) else {
            return result(context, status: .failed, summary: "Could not map element \(elementID) to a screen point.", reason: "unmappablePoint")
        }
        MacPointerInput.moveAndClick(at: point)
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .succeeded,
            summary: "Clicked \(element.label.isEmpty ? elementID : element.label).",
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
              isFrontmost(target) else {
            return result(context, status: .failed, summary: "\(appName) is not frontmost.", reason: "targetNotFrontmost")
        }
        MacKeyboardInput.type(text)
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
              isFrontmost(target) else {
            return result(context, status: .failed, summary: "\(appName) is not frontmost.", reason: "targetNotFrontmost")
        }
        MacKeyboardInput.pressKey(key)
        return HarnessToolResult(
            callID: context.call.id,
            toolName: context.call.name,
            status: .succeeded,
            summary: "Pressed \(key).",
            observations: HarnessObservationDelta(facts: ["lastAcceptedTool": context.call.name]),
            metadata: ["key": key]
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

    struct ElementGeometry: Sendable {
        var bbox: DebugUIBoundingBox
        var imageWidth: Int
        var imageHeight: Int
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
        return ElementGeometry(
            bbox: DebugUIBoundingBox(x: x, y: y, width: width, height: height),
            imageWidth: imageWidth,
            imageHeight: imageHeight
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

    private func isFrontmost(_ target: MacWindowTargetCandidate) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid_t(target.processID)
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
