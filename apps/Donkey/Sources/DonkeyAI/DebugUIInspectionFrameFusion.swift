import DonkeyContracts
import Foundation

public enum DebugUIInspectionFrameFusion {
    public static func fused(
        accessibilityFrame: DebugUIInspectionFrame,
        geminiFrame: DebugUIInspectionFrame
    ) -> DebugUIInspectionFrame {
        let accessibilityElements = accessibilityFrame.elements
        let accessibilityDeduplicationBase = accessibilityElements.filter { $0.type != .draggable }
        let geminiOnlyElements = geminiFrame.elements.filter { geminiElement in
            !accessibilityDeduplicationBase.contains { accessibilityElement in
                isDuplicate(geminiElement, of: accessibilityElement)
            }
        }.map(annotatedGeminiElement)

        return DebugUIInspectionFrame(
            elements: (accessibilityElements + geminiOnlyElements).sorted(by: elementSort)
        )
    }

    private static func isDuplicate(
        _ geminiElement: DebugUIElement,
        of accessibilityElement: DebugUIElement
    ) -> Bool {
        let smallerArea = min(area(geminiElement.bbox), area(accessibilityElement.bbox))
        guard smallerArea > 0 else { return false }

        let geminiLabel = normalized(geminiElement.label)
        let accessibilityLabel = normalized(accessibilityElement.label)
        if !geminiLabel.isEmpty,
           geminiLabel == accessibilityLabel,
           centerDistance(geminiElement.bbox, accessibilityElement.bbox) <= 32 {
            return true
        }

        guard areCompatibleTypes(geminiElement.type, accessibilityElement.type) else {
            return false
        }

        let accessibilityArea = area(accessibilityElement.bbox)
        let geminiArea = area(geminiElement.bbox)
        let areaRatio = smallerArea / max(accessibilityArea, geminiArea)
        guard areaRatio >= 0.25 else {
            return false
        }

        let containmentScore = intersectionArea(geminiElement.bbox, accessibilityElement.bbox) / smallerArea
        return containmentScore >= 0.62
    }

    private static func annotatedGeminiElement(_ element: DebugUIElement) -> DebugUIElement {
        DebugUIElement(
            id: element.id,
            type: element.type,
            label: element.label,
            description: element.description,
            bbox: element.bbox,
            confidence: element.confidence,
            visualStyle: element.visualStyle,
            metadata: element.metadata.merging([
                "debugUIFusion.source": "gemini",
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
