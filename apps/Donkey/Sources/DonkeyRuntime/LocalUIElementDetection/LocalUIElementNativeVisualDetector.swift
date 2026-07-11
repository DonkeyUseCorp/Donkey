import DonkeyContracts
import Foundation

public enum NativeVisualDetectionAlgorithm: String, Codable, Equatable, Sendable {
    case interactablesV2 = "interactables-v2"
    case borderUI = "border-ui"
}

public struct LocalUIElementNativeVisualDetector: Sendable {
    private var algorithm: NativeVisualDetectionAlgorithm
    private var interactableDetector: GenericInteractableDetector
    private var borderDetector: GenericBorderUIDetector

    public init(
        maxAnalysisDimension: Int = 900,
        algorithm: NativeVisualDetectionAlgorithm? = nil,
        magickPath: String? = nil,
        tesseractPath: String? = nil
    ) {
        _ = maxAnalysisDimension
        self.algorithm = algorithm ?? .borderUI
        self.interactableDetector = GenericInteractableDetector(
            magickPath: magickPath,
            tesseractPath: tesseractPath
        )
        self.borderDetector = GenericBorderUIDetector(
            magickPath: magickPath,
            tesseractPath: tesseractPath
        )
    }

    public func candidates(
        fromPNGData data: Data?,
        imagePath: String? = nil,
        pixelSize: HotLoopSize
    ) -> (candidates: [LocalUIElementCandidate], latencyMS: [String: Double], metadata: [String: String]) {
        let startedAt = ProcessInfo.processInfo.systemUptime

        let fileManager = FileManager.default
        let workingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("donkey-native-visual-\(UUID().uuidString)", isDirectory: true)

        do {
            try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: workingDirectory) }

            let inputURL: URL
            if let imagePath,
               !imagePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                inputURL = URL(fileURLWithPath: imagePath)
            } else if let data {
                inputURL = workingDirectory.appendingPathComponent("input.png", isDirectory: false)
                try data.write(to: inputURL, options: .atomic)
            } else {
                return failureResult(
                    reason: "missingScreenshot",
                    startedAt: startedAt
                )
            }

            let detectionResult = try detect(
                inputURL: inputURL,
                outputDirectory: workingDirectory,
                pixelSize: pixelSize
            )
            let totalMS = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000

            return (
                detectionResult.candidates,
                ["nativeVisual.total": totalMS],
                [
                    "nativeVisual.status": "ok",
                    "nativeVisual.detector": detectionResult.detectorName,
                    "nativeVisual.algorithm": algorithm.rawValue,
                    "nativeVisual.box.count": String(detectionResult.boxCount),
                    "nativeVisual.candidate.count": String(detectionResult.candidates.count),
                    "nativeVisual.output": detectionResult.summary,
                    "nativeVisual.rawPixelsRead": "true",
                    "nativeVisual.rawPixelsPersisted": "false"
                ]
            )
        } catch {
            return failureResult(
                reason: String(describing: error),
                startedAt: startedAt
            )
        }
    }

    private func failureResult(
        reason: String,
        startedAt: TimeInterval
    ) -> (candidates: [LocalUIElementCandidate], latencyMS: [String: Double], metadata: [String: String]) {
        let totalMS = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        return (
            [],
            ["nativeVisual.total": totalMS],
            [
                "nativeVisual.status": "failed",
                "nativeVisual.reason": reason,
                "nativeVisual.detector": detectorName,
                "nativeVisual.algorithm": algorithm.rawValue,
                "nativeVisual.rawPixelsRead": "false",
                "nativeVisual.rawPixelsPersisted": "false"
            ]
        )
    }

    private var detectorName: String {
        switch algorithm {
        case .interactablesV2:
            return "detect_interactables_generic_v2"
        case .borderUI:
            return "generic_border_ui_detector"
        }
    }

    private func detect(
        inputURL: URL,
        outputDirectory: URL,
        pixelSize: HotLoopSize
    ) throws -> NativeVisualDetectionResult {
        switch algorithm {
        case .interactablesV2:
            let result = try interactableDetector.detect(inputURL: inputURL, outputDirectory: outputDirectory)
            return NativeVisualDetectionResult(
                detectorName: "detect_interactables_generic_v2",
                boxCount: result.boxes.count,
                candidates: result.boxes.compactMap { Self.candidate(from: $0, pixelSize: pixelSize) },
                summary: result.summary
            )
        case .borderUI:
            let result = try borderDetector.detect(inputURL: inputURL, outputDirectory: outputDirectory)
            return NativeVisualDetectionResult(
                detectorName: "generic_border_ui_detector",
                boxCount: result.boxes.count,
                candidates: result.boxes.compactMap { Self.candidate(from: $0, pixelSize: pixelSize) },
                summary: result.summary
            )
        }
    }

    static func candidate(
        from box: GenericInteractableBox,
        pixelSize: HotLoopSize
    ) -> LocalUIElementCandidate? {
        let width = max(0, box.x2 - box.x1)
        let height = max(0, box.y2 - box.y1)
        guard width > 0, height > 0 else { return nil }

        let role = debugOverlayRole(for: box.kind)
        var metadata = [
            "debug.overlayRole": role,
            "nativeVisual.detector": "detect_interactables_generic_v2",
            "nativeVisual.scriptID": String(box.id),
            "nativeVisual.kind": box.kind,
            "nativeVisual.source": box.source,
            "classification.reason": "detectInteractablesGenericV2"
        ]
        if box.kind.contains("container") {
            metadata["element.kind"] = "visualContainer"
        }

        return LocalUIElementCandidate(
            id: "native-cv-\(box.id)-\(slug(box.kind))",
            source: candidateSource(for: box.source, kind: box.kind),
            signalKind: signalKind(for: box.source, kind: box.kind),
            typeHint: elementType(for: box.kind),
            label: label(for: box),
            bounds: HotLoopRect(
                x: Double(box.x1),
                y: Double(box.y1),
                width: Double(width),
                height: Double(height),
                space: pixelSize.space
            ),
            confidence: box.confidence,
            actions: [],
            metadata: metadata
        )
    }

    private static func candidateSource(
        for source: String,
        kind: String
    ) -> LocalUIElementCandidateSource {
        if source.contains("connected_component") {
            return .connectedComponent
        }
        if source.contains("ocr") || source.contains("tesseract") || source.contains("inference") {
            return .ocr
        }
        if kind.contains("container") || source.contains("midtone") {
            return .layout
        }
        return .shape
    }

    private static func signalKind(
        for source: String,
        kind: String
    ) -> LocalUIElementSignalKind {
        if source.contains("connected_component") {
            return .connectedComponent
        }
        if source.contains("ocr") || source.contains("tesseract") || source.contains("inference") {
            return .text
        }
        if kind.contains("container") || kind.contains("row") {
            return .rowGrouping
        }
        return .rectangle
    }

    private static func elementType(for kind: String) -> DebugUIElementType {
        switch kind {
        case "menu_bar_item", "menu_bar_status":
            return .menuItem
        case "left_nav_row":
            return .sidebarItem
        case "right_panel_row":
            return .listItem
        case "text_input_container", "text_input_placeholder":
            return .input
        case "composer_icon_button", "icon_button":
            return .toolbarIcon
        case "composer_control", "review_button_or_status", "text_button_or_row", "visual_control":
            return .button
        case "panel_container", "visual_container":
            return .other
        default:
            return .other
        }
    }

    private static func debugOverlayRole(for kind: String) -> String {
        switch kind {
        case "menu_bar_item", "menu_bar_status":
            return "menuBarItem"
        case "left_nav_row":
            return "sidebarRow"
        case "right_panel_row":
            return "panelRow"
        case "panel_container":
            return "panel"
        case "text_input_container":
            return "bottomInput"
        case "text_input_placeholder":
            return "messageInput"
        case "composer_icon_button", "composer_control":
            return "bottomInputAccessory"
        case "review_button_or_status", "text_button_or_row", "visual_control", "icon_button":
            return "actionButton"
        case "visual_container":
            return "userBubble"
        default:
            return "actionButton"
        }
    }

    private static func label(for box: GenericInteractableBox) -> String {
        let trimmed = box.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return box.kind.replacingOccurrences(of: "_", with: " ")
    }

    private static func slug(_ value: String) -> String {
        let normalized = value
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .prefix(6)
            .joined(separator: "-")
        return normalized.isEmpty ? "element" : normalized
    }

    static func candidate(
        from box: GenericBorderUIBox,
        pixelSize: HotLoopSize
    ) -> LocalUIElementCandidate? {
        let width = max(0, box.x2 - box.x1)
        let height = max(0, box.y2 - box.y1)
        guard width > 0, height > 0 else { return nil }

        var metadata = [
            "nativeVisual.detector": "generic_border_ui_detector",
            "nativeVisual.scriptID": String(box.id),
            "nativeVisual.kind": box.kind,
            "nativeVisual.source": box.source,
            "nativeVisual.borderStrength": String(format: "%.3f", box.borderStrength),
            "nativeVisual.fillDensity": String(format: "%.3f", box.fillDensity),
            "nativeVisual.childCount": String(box.childCount),
            "nativeVisual.textCount": String(box.textCount),
            "classification.reason": "genericBorderUIDetector"
        ]
        if let role = borderDebugOverlayRole(for: box.kind) {
            metadata["debug.overlayRole"] = role
        }

        return LocalUIElementCandidate(
            id: "native-border-\(box.id)-\(slug(box.kind))",
            source: borderCandidateSource(for: box.source, kind: box.kind),
            signalKind: borderSignalKind(for: box.source, kind: box.kind),
            typeHint: borderElementType(for: box.kind),
            label: label(for: box),
            bounds: HotLoopRect(
                x: Double(box.x1),
                y: Double(box.y1),
                width: Double(width),
                height: Double(height),
                space: pixelSize.space
            ),
            confidence: box.confidence,
            actions: [],
            metadata: metadata
        )
    }

    private static func borderCandidateSource(
        for source: String,
        kind: String
    ) -> LocalUIElementCandidateSource {
        if source == "containerRowInference" {
            return .ocr
        }
        if ["section", "panel", "card", "controlGroup", "row"].contains(kind) {
            return .layout
        }
        if source == "edgeComponent" {
            return .shape
        }
        return .color
    }

    private static func borderSignalKind(
        for source: String,
        kind: String
    ) -> LocalUIElementSignalKind {
        if source == "containerRowInference" || kind == "row" {
            return .rowGrouping
        }
        if source == "edgeComponent" {
            return .rectangle
        }
        if ["section", "panel", "card", "controlGroup"].contains(kind) {
            return .roundedRectangle
        }
        return .colorCluster
    }

    private static func borderElementType(for kind: String) -> DebugUIElementType {
        switch kind {
        case "button":
            return .button
        case "iconButton":
            return .toolbarIcon
        case "textField":
            return .input
        case "row":
            return .listItem
        case "menuItem":
            return .menuItem
        case "section", "panel", "card", "controlGroup", "unknownControl":
            return .other
        default:
            return .other
        }
    }

    private static func borderDebugOverlayRole(for kind: String) -> String? {
        switch kind {
        case "button", "iconButton":
            return "actionButton"
        case "textField":
            return "messageInput"
        case "row":
            return "panelRow"
        case "panel", "card", "section", "controlGroup":
            return "panel"
        case "unknownControl":
            return nil
        default:
            return nil
        }
    }

    private static func label(for box: GenericBorderUIBox) -> String {
        let trimmed = box.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return box.kind
    }

}

private struct NativeVisualDetectionResult: Equatable, Sendable {
    var detectorName: String
    var boxCount: Int
    var candidates: [LocalUIElementCandidate]
    var summary: String
}
