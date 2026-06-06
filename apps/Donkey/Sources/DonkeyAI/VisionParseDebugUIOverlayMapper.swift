#if DONKEY_DEBUG_OVERLAY

import DonkeyContracts
import DonkeyRuntime
import Foundation

// Maps hosted vision results (RunPod OmniParser V2) into overlay elements. Vision
// boxes are pixels relative to the uploaded image, so they normalize against the
// response image size and reuse the same window->screen geometry as the older
// screenshot-parse mapper. Marked as AI evidence so fusion and badges treat them
// the same way the screenshot-parse path did.
public enum VisionParseDebugUIOverlayMapper {
    public static func frame(
        from response: RemoteVisionParseResponse,
        target: MacWindowTargetCandidate,
        screenFrame: WindowTargetBounds,
        minConfidence: Double
    ) -> DebugUIInspectionFrame {
        let threshold = min(max(minConfidence, 0), 1)
        let capturePixelSize = HotLoopSize(
            width: response.image.width,
            height: response.image.height,
            space: .window
        )
        let windowControls = ScreenshotParseDebugUIOverlayMapper.macWindowControlElements(
            target: target,
            screenFrame: screenFrame
        )

        let parsed = response.elements.enumerated().compactMap { visionIndex, element -> DebugUIElement? in
            guard !isMacWindowControl(label: element.label) else {
                return nil
            }
            let rect = HotLoopRect(
                x: element.box.x,
                y: element.box.y,
                width: element.box.width,
                height: element.box.height,
                space: .window
            )
            guard element.confidence >= threshold,
                  let localBounds = ScreenshotParseDebugUIOverlayMapper.overlayLocalBounds(
                    for: rect,
                    target: target,
                    capturePixelSize: capturePixelSize
                  ),
                  let bbox = ScreenshotParseDebugUIOverlayMapper.overlayBoundingBox(
                    for: rect,
                    target: target,
                    capturePixelSize: capturePixelSize,
                    screenFrame: screenFrame
                  )
            else {
                return nil
            }

            let metadata = [
                "localUIElement.sources": "remote-vision-parser",
                "localUIElement.actionEligibility": LocalUIElementActionEligibility.guardedAction.rawValue,
                "remoteScreenshotParsing.status": "used",
                "remoteScreenshotParsing.provider": "omniparser-v2",
                "vision.kind": element.kind,
                "vision.index": String(visionIndex),
                "vision.interactive": String(element.interactive),
                "target.windowID": String(target.windowID),
                "target.appName": target.appName ?? "",
                "target.bundleIdentifier": target.bundleIdentifier ?? "",
                "target.title": target.title ?? "",
                "coordinate.sourceSpace": rect.space.rawValue,
                "directInputActionsAllowed": "true"
            ]
            .merging(boundsMetadata(prefix: "target.bounds.", bounds: target.bounds)) { current, _ in current }
            .merging(boundsMetadata(prefix: "debugOverlay.localBounds.", bounds: localBounds)) { current, _ in current }

            return DebugUIElement(
                id: "ai-\(target.windowID)-\(element.id)",
                type: elementType(forKind: element.kind, interactive: element.interactive),
                label: element.label,
                description: ["donkey vision", element.kind].joined(separator: " "),
                bbox: bbox,
                confidence: element.confidence,
                metadata: metadata
            )
        }

        return DebugUIInspectionFrame(elements: windowControls + parsed)
            .validated(minConfidence: threshold)
    }

    private static func isMacWindowControl(label: String) -> Bool {
        let normalized = label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["close", "minimize", "zoom", "fullscreen", "full screen"].contains(normalized)
    }

    private static func elementType(forKind kind: String, interactive: Bool) -> DebugUIElementType {
        switch kind.lowercased() {
        case "button":
            return .button
        case "text":
            return .other
        case "icon":
            return interactive ? .toolbarIcon : .other
        default:
            return interactive ? .button : .other
        }
    }

    private static func boundsMetadata(
        prefix: String,
        bounds: WindowTargetBounds
    ) -> [String: String] {
        [
            prefix + "x": String(bounds.x),
            prefix + "y": String(bounds.y),
            prefix + "width": String(bounds.width),
            prefix + "height": String(bounds.height)
        ]
    }
}

#endif
