import DonkeyContracts
import Foundation

public enum DebugUIInspectionFrameFusion {
    public static func fused(
        accessibilityFrame: DebugUIInspectionFrame,
        aiFrame: DebugUIInspectionFrame
    ) -> DebugUIInspectionFrame {
        let accessibilityElements = accessibilityFrame.elements
        let accessibilityDeduplicationBase = accessibilityElements.filter { $0.type != .draggable }
        let aiOnlyElements = aiFrame.elements.filter { aiElement in
            !accessibilityDeduplicationBase.contains { accessibilityElement in
                isDuplicate(aiElement, of: accessibilityElement)
            }
        }.map(annotatedAIElement)

        return DebugUIInspectionFrame(
            elements: (accessibilityElements + aiOnlyElements).sorted(by: elementSort)
        )
    }

    private static func isDuplicate(
        _ aiElement: DebugUIElement,
        of accessibilityElement: DebugUIElement
    ) -> Bool {
        let smallerArea = min(area(aiElement.bbox), area(accessibilityElement.bbox))
        guard smallerArea > 0 else { return false }

        let aiLabel = normalized(aiElement.label)
        let accessibilityLabel = normalized(accessibilityElement.label)
        if !aiLabel.isEmpty,
           aiLabel == accessibilityLabel,
           centerDistance(aiElement.bbox, accessibilityElement.bbox) <= 32 {
            return true
        }

        guard areCompatibleTypes(aiElement.type, accessibilityElement.type) else {
            return false
        }

        let accessibilityArea = area(accessibilityElement.bbox)
        let aiArea = area(aiElement.bbox)
        let areaRatio = smallerArea / max(accessibilityArea, aiArea)
        guard areaRatio >= 0.25 else {
            return false
        }

        let containmentScore = intersectionArea(aiElement.bbox, accessibilityElement.bbox) / smallerArea
        return containmentScore >= 0.62
    }

    private static func annotatedAIElement(_ element: DebugUIElement) -> DebugUIElement {
        DebugUIElement(
            id: element.id,
            type: element.type,
            label: element.label,
            description: element.description,
            bbox: element.bbox,
            confidence: element.confidence,
            visualStyle: element.visualStyle,
            metadata: element.metadata.merging([
                "debugUIFusion.source": "ai",
                "localUIElement.actionEligibility": "guardedAction",
                "directInputActionsAllowed": "true"
            ]) { current, _ in current }
        )
    }

    private static func elementSort(_ lhs: DebugUIElement, _ rhs: DebugUIElement) -> Bool {
        if lhs.bbox.y != rhs.bbox.y { return lhs.bbox.y < rhs.bbox.y }
        if lhs.bbox.x != rhs.bbox.x { return lhs.bbox.x < rhs.bbox.x }
        return lhs.id < rhs.id
    }

    private static func area(_ box: DebugUIBoundingBox) -> Double {
        max(0, box.width) * max(0, box.height)
    }

    private static func intersectionArea(
        _ lhs: DebugUIBoundingBox,
        _ rhs: DebugUIBoundingBox
    ) -> Double {
        let minX = max(lhs.x, rhs.x)
        let minY = max(lhs.y, rhs.y)
        let maxX = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let maxY = min(lhs.y + lhs.height, rhs.y + rhs.height)
        return max(0, maxX - minX) * max(0, maxY - minY)
    }

    private static func centerDistance(
        _ lhs: DebugUIBoundingBox,
        _ rhs: DebugUIBoundingBox
    ) -> Double {
        hypot(
            (lhs.x + lhs.width / 2) - (rhs.x + rhs.width / 2),
            (lhs.y + lhs.height / 2) - (rhs.y + rhs.height / 2)
        )
    }

    private static func areCompatibleTypes(
        _ lhs: DebugUIElementType,
        _ rhs: DebugUIElementType
    ) -> Bool {
        if lhs == rhs { return true }

        let buttonLike: Set<DebugUIElementType> = [
            .button,
            .toolbarIcon,
            .windowControl,
            .menuItem,
            .tab,
            .sidebarItem,
            .listItem
        ]
        let textLike: Set<DebugUIElementType> = [
            .input,
            .dropdown
        ]
        return buttonLike.contains(lhs) && buttonLike.contains(rhs)
            || textLike.contains(lhs) && textLike.contains(rhs)
    }

    private static func normalized(_ value: String) -> String {
        value
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }
}
