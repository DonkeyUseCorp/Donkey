import DonkeyContracts
import Foundation

enum LocalAppObservationGeometry {
    static func targetBoundsMetadata(_ bounds: WindowTargetBounds) -> [String: String] {
        [
            "target.bounds.x": String(bounds.x),
            "target.bounds.y": String(bounds.y),
            "target.bounds.width": String(bounds.width),
            "target.bounds.height": String(bounds.height),
            "target.bounds.space": HotLoopCoordinateSpace.screen.rawValue
        ]
    }

    static func cropBoundsMetadata(_ bounds: HotLoopRect) -> [String: String] {
        [
            "crop.bounds.x": String(bounds.origin.x),
            "crop.bounds.y": String(bounds.origin.y),
            "crop.bounds.width": String(bounds.size.width),
            "crop.bounds.height": String(bounds.size.height),
            "crop.bounds.space": bounds.space.rawValue
        ]
    }

    static func pixelSizeMetadata(_ size: HotLoopSize) -> [String: String] {
        [
            "pixelSize.width": String(size.width),
            "pixelSize.height": String(size.height),
            "pixelSize.space": size.space.rawValue
        ]
    }

    static func controlMetadata(
        controlID: String,
        frame: HotLoopRect?,
        source: AgentVisualizationGroundingSource,
        label: String? = nil,
        kind: LocalAppControlKind? = nil,
        confidence: Double? = nil,
        extra: [String: String] = [:]
    ) -> [String: String] {
        let prefix = controlPrefix(controlID)
        var metadata: [String: String] = [:]
        for (key, value) in extra {
            metadata["\(prefix)metadata.\(key)"] = value
        }
        metadata["\(prefix)source"] = source.rawValue
        if let label {
            metadata["\(prefix)label"] = label
        }
        if let kind {
            metadata["\(prefix)kind"] = kind.rawValue
        }
        if let confidence {
            metadata["\(prefix)confidence"] = String(confidence)
        }
        if let frame {
            metadata["\(prefix)bounds.x"] = String(frame.origin.x)
            metadata["\(prefix)bounds.y"] = String(frame.origin.y)
            metadata["\(prefix)bounds.width"] = String(frame.size.width)
            metadata["\(prefix)bounds.height"] = String(frame.size.height)
            metadata["\(prefix)bounds.space"] = frame.space.rawValue
        }
        return metadata
    }

    static func groundedMetadata(
        controlID: String?,
        observation: LocalAppTaskObservation?
    ) -> [String: String] {
        guard let controlID,
              let observation
        else {
            return [:]
        }

        let prefix = controlPrefix(controlID)
        var metadata: [String: String] = [:]
        if let normalizedBounds = normalizedControlBounds(controlID: controlID, metadata: observation.metadata) {
            metadata["control.bounds.x"] = String(normalizedBounds.origin.x)
            metadata["control.bounds.y"] = String(normalizedBounds.origin.y)
            metadata["control.bounds.width"] = String(normalizedBounds.size.width)
            metadata["control.bounds.height"] = String(normalizedBounds.size.height)
            metadata["control.bounds.space"] = normalizedBounds.space.rawValue
        }

        for suffix in ["source", "label", "kind", "confidence"] {
            if let value = observation.metadata["\(prefix)\(suffix)"] {
                metadata["control.\(suffix)"] = value
            }
        }
        for prefix in ["target.bounds.", "crop.bounds."] {
            for suffix in ["x", "y", "width", "height", "space"] {
                if let value = observation.metadata["\(prefix)\(suffix)"] {
                    metadata["\(prefix)\(suffix)"] = value
                }
            }
        }
        return metadata
    }

    static func hasNormalizedControlBounds(
        controlID: String,
        metadata: [String: String]
    ) -> Bool {
        normalizedControlBounds(controlID: controlID, metadata: metadata) != nil
    }

    static func screenControlBounds(
        controlID: String,
        metadata: [String: String]
    ) -> HotLoopRect? {
        guard let rect = metadataRect(prefix: "\(controlPrefix(controlID))bounds.", metadata: metadata),
              rect.hasPositiveArea
        else {
            return nil
        }
        if rect.space == .screen {
            return rect
        }
        guard let mapper = coordinateMapper(metadata: metadata),
              let screenRect = mapper.convert(rect, to: .screen),
              screenRect.hasPositiveArea
        else {
            return nil
        }
        return screenRect
    }

    static func normalizedStepBounds(metadata: [String: String]) -> HotLoopRect? {
        metadataRect(prefix: "control.bounds.", metadata: metadata).flatMap { rect in
            normalizedBounds(rect, metadata: metadata)
        }
    }

    private static func normalizedControlBounds(
        controlID: String,
        metadata: [String: String]
    ) -> HotLoopRect? {
        metadataRect(prefix: "\(controlPrefix(controlID))bounds.", metadata: metadata).flatMap { rect in
            normalizedBounds(rect, metadata: metadata)
        }
    }

    private static func normalizedBounds(
        _ rect: HotLoopRect,
        metadata: [String: String]
    ) -> HotLoopRect? {
        guard rect.hasPositiveArea else { return nil }
        if rect.space == .normalizedTarget {
            return clamped(rect)
        }

        if rect.space == .screen,
           let targetBounds = metadataRect(prefix: "target.bounds.", metadata: metadata) {
            let mapper = HotLoopCoordinateMapper(
                windowBoundsInScreen: targetBounds,
                cropBoundsInWindow: HotLoopRect(
                    x: 0,
                    y: 0,
                    width: targetBounds.size.width,
                    height: targetBounds.size.height,
                    space: .window
                )
            )
            return mapper.convert(rect, to: HotLoopCoordinateSpace.normalizedTarget).map { clamped($0) }
        }

        guard let mapper = coordinateMapper(metadata: metadata),
              let normalized = mapper.convert(rect, to: .normalizedTarget)
        else {
            return nil
        }
        return clamped(normalized)
    }

    private static func coordinateMapper(metadata: [String: String]) -> HotLoopCoordinateMapper? {
        let targetBounds = metadataRect(prefix: "target.bounds.", metadata: metadata)
        let cropBounds = metadataRect(prefix: "crop.bounds.", metadata: metadata)

        if let targetBounds {
            return HotLoopCoordinateMapper(
                windowBoundsInScreen: targetBounds,
                cropBoundsInWindow: cropBounds ?? HotLoopRect(
                    x: 0,
                    y: 0,
                    width: targetBounds.size.width,
                    height: targetBounds.size.height,
                    space: .window
                )
            )
        }

        guard let cropBounds else { return nil }
        return HotLoopCoordinateMapper(
            windowBoundsInScreen: HotLoopRect(
                x: 0,
                y: 0,
                width: cropBounds.size.width,
                height: cropBounds.size.height,
                space: .screen
            ),
            cropBoundsInWindow: cropBounds
        )
    }

    private static func metadataRect(prefix: String, metadata: [String: String]) -> HotLoopRect? {
        guard let x = Double(metadata["\(prefix)x"] ?? ""),
              let y = Double(metadata["\(prefix)y"] ?? ""),
              let width = Double(metadata["\(prefix)width"] ?? ""),
              let height = Double(metadata["\(prefix)height"] ?? ""),
              let spaceValue = metadata["\(prefix)space"],
              let space = HotLoopCoordinateSpace(rawValue: spaceValue)
        else {
            return nil
        }
        let rect = HotLoopRect(x: x, y: y, width: width, height: height, space: space)
        return rect.hasPositiveArea ? rect : nil
    }

    private static func clamped(_ rect: HotLoopRect) -> HotLoopRect {
        HotLoopRect(
            x: min(max(rect.origin.x, 0), 1),
            y: min(max(rect.origin.y, 0), 1),
            width: min(max(rect.size.width, 0.01), 1),
            height: min(max(rect.size.height, 0.01), 1),
            space: .normalizedTarget
        )
    }

    private static func controlPrefix(_ controlID: String) -> String {
        "control.\(controlID)."
    }
}
