import CoreGraphics
import DonkeyContracts
import DonkeyRuntime
import Foundation

/// Grounds a target control by VISION when accessibility can't: screenshot the app window, ask the
/// hosted UI-inspection model for clickable elements, resolve the requested one by text, and map its
/// screenshot bounding box back to a screen point. This is the fallback for apps whose accessibility
/// tree is too sparse to ground by text (e.g. Spotify and other Electron apps).
@MainActor
public enum VisionGroundingFlow {
    public struct Outcome: Sendable {
        public var screenPoint: CGPoint?
        public var reason: String
        public var matchedLabel: String?
        public var resolvedAppName: String?

        public init(screenPoint: CGPoint?, reason: String, matchedLabel: String? = nil, resolvedAppName: String? = nil) {
            self.screenPoint = screenPoint
            self.reason = reason
            self.matchedLabel = matchedLabel
            self.resolvedAppName = resolvedAppName
        }
    }

    public typealias ScreenshotCapture = @Sendable (MacWindowTargetCandidate) async throws -> CapturedWindowScreenshot

    public static func locate(
        appName: String?,
        bundleIdentifier: String?,
        targetQuery: String,
        analyzer: DebugUIInspectionAnalyzing,
        minConfidence: Double = 0.25,
        capture: ScreenshotCapture = { try await ScreenCaptureKitWindowScreenshotCapturer().capture(target: $0) },
        windowResolver: MacWindowResolver = MacWindowResolver()
    ) async -> Outcome {
        guard let target = AccessibilityObserver.resolveTarget(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            resolver: windowResolver
        ) else {
            return Outcome(screenPoint: nil, reason: "noWindowForApp")
        }

        let shot: CapturedWindowScreenshot
        do {
            shot = try await capture(target)
        } catch {
            return Outcome(screenPoint: nil, reason: "screenshotFailed", resolvedAppName: target.appName)
        }
        guard shot.imageWidth > 0, shot.imageHeight > 0 else {
            return Outcome(screenPoint: nil, reason: "emptyScreenshot", resolvedAppName: target.appName)
        }

        // Compress (downscale + JPEG) through the shared helper so this request matches every other
        // hosted-vision request; the model's coordinates then map back through the COMPRESSED size.
        let compressed = ScreenshotCompression.compressedForModel(shot)
        // The hosted vision model occasionally returns malformed JSON; retry a few times.
        let request = DebugUIInspectionRequest(
            imageDataURL: compressed.base64DataURL,
            pixelSize: compressed.pixelSize,
            minConfidence: minConfidence
        )
        var frame: DebugUIInspectionFrame?
        var lastError: Error?
        for _ in 0..<3 {
            do {
                frame = try await analyzer.inspect(request)
                break
            } catch {
                lastError = error
            }
        }
        guard let frame else {
            return Outcome(screenPoint: nil, reason: "visionInspectionFailed: \(lastError.map { "\($0)" } ?? "unknown")", resolvedAppName: target.appName)
        }

        guard let element = resolveElement(targetQuery, in: frame.elements) else {
            return Outcome(screenPoint: nil, reason: "elementNotFound", resolvedAppName: target.appName)
        }
        let point = screenPoint(
            bbox: element.bbox,
            imageWidth: Int(compressed.pixelSize.width.rounded()),
            imageHeight: Int(compressed.pixelSize.height.rounded()),
            window: target.bounds
        )
        return Outcome(screenPoint: point, reason: "ok", matchedLabel: element.label, resolvedAppName: target.appName)
    }

    /// Resolves the best inspected element for `query` by text relevance over its label/description/type.
    nonisolated static func resolveElement(_ query: String, in elements: [DebugUIElement]) -> DebugUIElement? {
        let normalizedQuery = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return nil }
        let queryTokens = ControlTextRelevance.tokens(in: normalizedQuery)

        var best: (element: DebugUIElement, score: Double)?
        for element in elements where element.bbox.hasPositiveArea {
            let candidates = [element.label, element.description, element.type.rawValue]
                .map { $0.lowercased() }
                .filter { !$0.isEmpty }
            let score = ControlTextRelevance.score(
                normalizedQuery: normalizedQuery,
                queryTokens: queryTokens,
                candidates: candidates
            )
            guard score > 0 else { continue }
            // Tie-break toward higher model confidence.
            let composite = score * 1_000 + element.confidence
            if best == nil || composite > best!.score {
                best = (element, composite)
            }
        }
        return best?.element
    }

    /// Maps a screenshot-pixel bounding box center to a screen point, given the window's screen
    /// bounds and the screenshot pixel size (handles Retina scaling between the two).
    nonisolated static func screenPoint(
        bbox: DebugUIBoundingBox,
        imageWidth: Int,
        imageHeight: Int,
        window: WindowTargetBounds
    ) -> CGPoint {
        let scaleX = window.width / Double(imageWidth)
        let scaleY = window.height / Double(imageHeight)
        let centerX = bbox.x + bbox.width / 2
        let centerY = bbox.y + bbox.height / 2
        return CGPoint(
            x: window.x + centerX * scaleX,
            y: window.y + centerY * scaleY
        )
    }
}
