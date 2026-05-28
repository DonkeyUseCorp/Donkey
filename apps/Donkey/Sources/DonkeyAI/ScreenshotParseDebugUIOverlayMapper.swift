#if DONKEY_DEBUG_OVERLAY

import DonkeyContracts
import DonkeyRuntime
import Foundation

public enum ScreenshotParseDebugUIOverlayMapper {
    public static func frame(
        from result: LocalUIUnderstandingResult,
        target: MacWindowTargetCandidate,
        capturePixelSize: HotLoopSize,
        screenFrame: WindowTargetBounds,
        minConfidence: Double
    ) -> DebugUIInspectionFrame {
        let threshold = min(max(minConfidence, 0), 1)
        let windowControls = macWindowControlElements(
            target: target,
            screenFrame: screenFrame
        )
        return DebugUIInspectionFrame(
            elements: windowControls + result.controls.compactMap { control in
                guard !isMacWindowControl(control) else {
                    return nil
                }
                guard control.confidence >= threshold,
                      let frame = control.frame,
                      let localBounds = overlayLocalBounds(
                        for: frame,
                        target: target,
                        capturePixelSize: capturePixelSize
                      ),
                      let bbox = overlayBoundingBox(
                        for: frame,
                        target: target,
                        capturePixelSize: capturePixelSize,
                        screenFrame: screenFrame
                      )
                else {
                    return nil
                }

                let metadata = control.metadata
                    .merging([
                        "localUIElement.sources": "gemini-screenshot-parser",
                        "localUIElement.actionEligibility": LocalUIElementActionEligibility.guardedAction.rawValue,
                        "remoteScreenshotParsing.status": result.metadata["remoteScreenshotParsing.status"] ?? "used",
                        "remoteScreenshotParsing.provider": result.metadata["parserProvider"] ?? result.metadata["runtime.backend"] ?? "gemini-screenshot-parser",
                        "target.windowID": String(target.windowID),
                        "target.appName": target.appName ?? "",
                        "target.bundleIdentifier": target.bundleIdentifier ?? "",
                        "target.title": target.title ?? "",
                        "coordinate.sourceSpace": frame.space.rawValue,
                        "directInputActionsAllowed": "true"
                    ]) { current, _ in current }
                    .merging(boundsMetadata(prefix: "target.bounds.", bounds: target.bounds)) { current, _ in current }
                    .merging(boundsMetadata(prefix: "debugOverlay.localBounds.", bounds: localBounds)) { current, _ in current }

                return DebugUIElement(
                    id: "gemini-\(target.windowID)-\(control.id)",
                    type: elementType(for: control.kind),
                    label: control.label,
                    description: [
                        "gemini screenshot parser",
                        control.kind.rawValue
                    ].joined(separator: " "),
                    bbox: bbox,
                    confidence: control.confidence,
                    metadata: metadata
                )
            }
        ).validated(minConfidence: threshold)
    }

    private static func macWindowControlElements(
        target: MacWindowTargetCandidate,
        screenFrame: WindowTargetBounds
    ) -> [DebugUIElement] {
        guard target.bounds.hasPositiveArea,
              target.bounds.width >= 120,
              target.bounds.height >= 44
        else {
            return []
        }

        let controls: [(id: String, label: String, centerX: Double)] = [
            ("close", "Close", 23),
            ("minimize", "Minimize", 46),
            ("zoom", "Zoom", 69)
        ]
        let diameter = 14.0
        let centerY = 23.0

        return controls.compactMap { control in
            let localBounds = WindowTargetBounds(
                x: control.centerX - diameter / 2,
                y: centerY - diameter / 2,
                width: diameter,
                height: diameter
            )
            let bounds = WindowTargetBounds(
                x: target.bounds.x + localBounds.x,
                y: target.bounds.y + localBounds.y,
                width: diameter,
                height: diameter
            )
            guard let bbox = clippedBoundingBox(bounds, screenFrame: screenFrame) else {
                return nil
            }
            let metadata = [
                "localUIElement.sources": "window-chrome-geometry",
                "localUIElement.actionEligibility": LocalUIElementActionEligibility.guardedAction.rawValue,
                "target.windowID": String(target.windowID),
                "target.appName": target.appName ?? "",
                "target.bundleIdentifier": target.bundleIdentifier ?? "",
                "target.title": target.title ?? "",
                "coordinate.sourceSpace": "windowChromeGeometry",
                "directInputActionsAllowed": "true"
            ]
                .merging(boundsMetadata(prefix: "target.bounds.", bounds: target.bounds)) { current, _ in current }
                .merging(boundsMetadata(prefix: "debugOverlay.localBounds.", bounds: localBounds)) { current, _ in current }
            return DebugUIElement(
                id: "window-chrome-\(target.windowID)-\(control.id)",
                type: .windowControl,
                label: control.label,
                description: "macOS window chrome",
                bbox: bbox,
                confidence: 1,
                metadata: metadata
            )
        }
    }

    private static func isMacWindowControl(_ control: LocalUIUnderstandingControl) -> Bool {
        let label = control.label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["close", "minimize", "zoom", "fullscreen", "full screen"].contains(label)
    }

    public static func overlayBoundingBox(
        for rect: HotLoopRect,
        target: MacWindowTargetCandidate,
        capturePixelSize: HotLoopSize,
        screenFrame: WindowTargetBounds
    ) -> DebugUIBoundingBox? {
        guard rect.hasPositiveArea,
              target.bounds.hasPositiveArea,
              screenFrame.hasPositiveArea,
              capturePixelSize.width > 0,
              capturePixelSize.height > 0
        else {
            return nil
        }

        if rect.space == .screen {
            return clippedBoundingBox(
                WindowTargetBounds(
                    x: rect.origin.x,
                    y: rect.origin.y,
                    width: rect.size.width,
                    height: rect.size.height
                ),
                screenFrame: screenFrame
            )
        }

        guard let localRect = overlayLocalBounds(
            for: rect,
            target: target,
            capturePixelSize: capturePixelSize
        ) else {
            return nil
        }

        return clippedBoundingBox(
            WindowTargetBounds(
                x: target.bounds.x + localRect.x,
                y: target.bounds.y + localRect.y,
                width: localRect.width,
                height: localRect.height
            ),
            screenFrame: screenFrame
        )
    }

    private static func overlayLocalBounds(
        for rect: HotLoopRect,
        target: MacWindowTargetCandidate,
        capturePixelSize: HotLoopSize
    ) -> WindowTargetBounds? {
        guard rect.hasPositiveArea,
              target.bounds.hasPositiveArea,
              capturePixelSize.width > 0,
              capturePixelSize.height > 0
        else {
            return nil
        }

        switch rect.space {
        case .window, .crop:
            return WindowTargetBounds(
                x: rect.origin.x / capturePixelSize.width * target.bounds.width,
                y: rect.origin.y / capturePixelSize.height * target.bounds.height,
                width: rect.size.width / capturePixelSize.width * target.bounds.width,
                height: rect.size.height / capturePixelSize.height * target.bounds.height
            )
        case .normalizedTarget:
            return WindowTargetBounds(
                x: rect.origin.x * target.bounds.width,
                y: rect.origin.y * target.bounds.height,
                width: rect.size.width * target.bounds.width,
                height: rect.size.height * target.bounds.height
            )
        case .screen:
            return WindowTargetBounds(
                x: rect.origin.x - target.bounds.x,
                y: rect.origin.y - target.bounds.y,
                width: rect.size.width,
                height: rect.size.height
            )
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

    private static func clippedBoundingBox(
        _ bounds: WindowTargetBounds,
        screenFrame: WindowTargetBounds
    ) -> DebugUIBoundingBox? {
        let minX = max(bounds.x, screenFrame.x)
        let minY = max(bounds.y, screenFrame.y)
        let maxX = min(bounds.x + bounds.width, screenFrame.x + screenFrame.width)
        let maxY = min(bounds.y + bounds.height, screenFrame.y + screenFrame.height)
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0, height > 0 else {
            return nil
        }

        return DebugUIBoundingBox(
            x: minX - screenFrame.x,
            y: minY - screenFrame.y,
            width: width,
            height: height
        )
    }

    private static func elementType(for kind: LocalAppControlKind) -> DebugUIElementType {
        switch kind {
        case .button:
            return .button
        case .textField, .searchField:
            return .input
        case .checkbox:
            return .checkbox
        case .link:
            return .link
        case .menuItem:
            return .menuItem
        case .listItem:
            return .listItem
        case .group, .unknown:
            return .other
        }
    }
}

#endif
