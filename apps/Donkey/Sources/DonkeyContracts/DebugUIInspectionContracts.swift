import Foundation

public enum DebugUIInspectionProvider: String, Codable, Equatable, Sendable {
    case accessibility
    case openai
    case gemini
}

public enum DebugUIInspectionScreenScope: String, Codable, Equatable, Sendable {
    case main
    case all
}

public enum DebugUIElementType: String, Codable, CaseIterable, Equatable, Sendable {
    case button
    case link
    case input
    case checkbox
    case toggle
    case dropdown
    case tab
    case menuItem = "menu_item"
    case windowControl = "window_control"
    case draggable
    case toolbarIcon = "toolbar_icon"
    case sidebarItem = "sidebar_item"
    case listItem = "list_item"
    case slider
    case other
}

public struct DebugUIBoundingBox: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var hasPositiveArea: Bool {
        width > 0 && height > 0
    }
}

public struct DebugUIOverlayStyle: Codable, Equatable, Sendable {
    public var overlayColor: String
    public var borderColor: String
    public var labelColor: String

    public init(
        overlayColor: String,
        borderColor: String,
        labelColor: String = "#FFFFFF"
    ) {
        self.overlayColor = overlayColor
        self.borderColor = borderColor
        self.labelColor = labelColor
    }

    public enum CodingKeys: String, CodingKey {
        case overlayColor = "overlay_color"
        case borderColor = "border_color"
        case labelColor = "label_color"
    }

    public static func style(for type: DebugUIElementType) -> DebugUIOverlayStyle {
        switch type {
        case .button:
            return DebugUIOverlayStyle(overlayColor: "#3B82F6", borderColor: "#60A5FA")
        case .link:
            return DebugUIOverlayStyle(overlayColor: "#06B6D4", borderColor: "#67E8F9")
        case .input:
            return DebugUIOverlayStyle(overlayColor: "#10B981", borderColor: "#6EE7B7")
        case .checkbox:
            return DebugUIOverlayStyle(overlayColor: "#84CC16", borderColor: "#BEF264")
        case .toggle:
            return DebugUIOverlayStyle(overlayColor: "#14B8A6", borderColor: "#5EEAD4")
        case .dropdown:
            return DebugUIOverlayStyle(overlayColor: "#8B5CF6", borderColor: "#C4B5FD")
        case .tab:
            return DebugUIOverlayStyle(overlayColor: "#F59E0B", borderColor: "#FCD34D")
        case .menuItem:
            return DebugUIOverlayStyle(overlayColor: "#EAB308", borderColor: "#FDE047")
        case .windowControl:
            return DebugUIOverlayStyle(overlayColor: "#EF4444", borderColor: "#FCA5A5")
        case .draggable:
            return DebugUIOverlayStyle(overlayColor: "#EC4899", borderColor: "#F9A8D4")
        case .toolbarIcon:
            return DebugUIOverlayStyle(overlayColor: "#6366F1", borderColor: "#A5B4FC")
        case .sidebarItem:
            return DebugUIOverlayStyle(overlayColor: "#A16207", borderColor: "#FCD34D")
        case .listItem:
            return DebugUIOverlayStyle(overlayColor: "#6B7280", borderColor: "#D1D5DB")
        case .slider:
            return DebugUIOverlayStyle(overlayColor: "#34D399", borderColor: "#A7F3D0")
        case .other:
            return DebugUIOverlayStyle(overlayColor: "#FFFFFF", borderColor: "#E5E7EB")
        }
    }
}

public struct DebugUIElement: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var type: DebugUIElementType
    public var label: String
    public var description: String
    public var bbox: DebugUIBoundingBox
    public var confidence: Double
    public var visualStyle: DebugUIOverlayStyle

    public init(
        id: String,
        type: DebugUIElementType,
        label: String,
        description: String = "",
        bbox: DebugUIBoundingBox,
        confidence: Double,
        visualStyle: DebugUIOverlayStyle? = nil
    ) {
        self.id = id
        self.type = type
        self.label = label
        self.description = description
        self.bbox = bbox
        self.confidence = min(max(confidence, 0), 1)
        self.visualStyle = visualStyle ?? DebugUIOverlayStyle.style(for: type)
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case type
        case label
        case description
        case bbox
        case confidence
        case visualStyle = "visual_style"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(DebugUIElementType.self, forKey: .type)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            type: type,
            label: try container.decodeIfPresent(String.self, forKey: .label) ?? "",
            description: try container.decodeIfPresent(String.self, forKey: .description) ?? "",
            bbox: try container.decode(DebugUIBoundingBox.self, forKey: .bbox),
            confidence: try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0,
            visualStyle: try container.decodeIfPresent(DebugUIOverlayStyle.self, forKey: .visualStyle)
        )
    }

    public func replacingID(_ id: String) -> DebugUIElement {
        DebugUIElement(
            id: id,
            type: type,
            label: label,
            description: description,
            bbox: bbox,
            confidence: confidence,
            visualStyle: visualStyle
        )
    }
}

public struct DebugUIInspectionFrame: Codable, Equatable, Sendable {
    public var elements: [DebugUIElement]

    public init(elements: [DebugUIElement] = []) {
        self.elements = elements
    }

    public func validated(minConfidence: Double) -> DebugUIInspectionFrame {
        let threshold = min(max(minConfidence, 0), 1)
        return DebugUIInspectionFrame(
            elements: elements.filter { element in
                !element.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && element.bbox.hasPositiveArea
                    && element.confidence >= threshold
            }
        )
    }
}

public extension RemoteInferenceJSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var objectValue: RemoteInferenceJSONObject? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [RemoteInferenceJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }
}
